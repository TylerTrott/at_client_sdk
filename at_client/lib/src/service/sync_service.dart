import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:at_client/src/util/network_util.dart';
import 'package:at_client/src/util/sync_util.dart';
import 'package:at_commons/at_commons.dart';
import 'package:at_commons/at_builders.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';

///A [SyncService] object is used to ensure data in local secondary(e.g mobile device) and cloud secondary are in sync.
class SyncService {
  var _syncInProgress = false;

  late String _atSign;

  String? _regex;

  final _logger = AtSignLogger('SyncService');

  static final Map<String, SyncService> _syncServiceMap = {};

  SyncService._internal(this._atSign);

  factory SyncService.getInstance(String atSign) {
    if (!_syncServiceMap.containsKey(_syncServiceMap)) {
      _syncServiceMap[atSign] = SyncService._internal(atSign);
    }
    return _syncServiceMap[atSign]!;
  }

  late LocalSecondary localSecondary;

  late RemoteSecondary remoteSecondary;

  late AtClientPreference preference;

  /// Calling sync with [regex] will ensure only matching keys are synced.
  /// sync will be retried on any connection related errors.
  /// [onDone] callback is invoked when sync completes successfully.
  /// e.g onDone callback
  /// ```
  /// void onDone(SyncService SyncService) {
  ///  // add your sync completion logic
  /// }
  /// ```
  /// Call isSyncInProgress to know if the sync is completed or if it is still in progress.
  /// Murali - there is no need for two methods sync and syncOnce.. can we just have sync to keep it simple ?
//  Future<void> sync(Function onDone, {String? regex}) async {
//    // Return is there is any sync already in progress
//    _regex = regex;
//    await syncOnce(onDone, _onError, regex: _regex);
//    return;
//  }

  void _onError(SyncService SyncService, Exception e) {
    _logger.finer('error during sync process ${e.toString()}');
  }

  void _handleError(
      var syncService, Exception e, Function onDone, Function onError) {
    if (e is AtConnectException) {
      Future.delayed(Duration(seconds: 3),
          () => sync(onDone: onDone, onError: _onError, regex: _regex));
    } else {
      onError(syncService, e);
    }
  }

  /// Initiates a Sync with the server.
  /// If another sync is already inProgress, method returns immediately
  /// If cloud server and local server are in sync, then [onDone] is called and method returns.
  /// If the sync encounters any exceptions
  /// [onError] call back is called and the Sync is terminated.
  /// e.g onError callback
  /// ```
  /// void onError(SyncManagar SyncService, Exception e) {
  /// // add your sync error logic
  /// }
  /// ```
  /// [onDone] callback is called if the sync completes successfully.
  /// e.g onDone callback
  /// ```
  /// void onDone(SyncService SyncService) {
  /// // add your sync completion logic
  /// }
  /// ```
  /// If no callbacks are passed, use await sync() or await sync(regex: regex)
  /// Optionally pass [regex] to sync only keys that matches the [regex]
  /// If no [onError] callback is passed, below exceptions are thrown.
  /// [AtConnectException] is thrown if internet is not available
  /// [SecondaryNotFoundException] is thrown if the secondary service is down or not available
  Future<void> sync(
      {Function? onDone, Function? onError, String? regex}) async {
    if (_syncInProgress) {
      _logger.finer('Another Sync process is in progress.');
      return;
    }
    _syncInProgress = true;
    try {
      await _checkConnectivity();
      var syncObject = await _getSyncObject(regex: regex);
      var lastSyncedCommitId = syncObject.lastSyncedCommitId;
      var serverCommitId = syncObject.serverCommitId;
      var isInSync = SyncUtil.isInSync(syncObject.uncommittedEntries,
          syncObject.serverCommitId, syncObject.lastSyncedCommitId);
      if (isInSync) {
        _logger.finer('Server and local secondary are in sync');
        _syncInProgress = false;
        _onDone(onDone);
        return;
      }
      lastSyncedCommitId ??= -1;
      serverCommitId ??= -1;
      syncObject.lastSyncedCommitId ??= -1;
      if (serverCommitId > lastSyncedCommitId) {
        //pull changes from cloud to local. Setting isStream to true if there are more than 10 entries to sync
        await _pullChanges(syncObject,
            regex: regex, isStream: (serverCommitId - lastSyncedCommitId) > 10);
      }
      //push changes from local to cloud
      await _pushChanges(syncObject, regex: regex);
      _syncInProgress = false;
      _onDone(onDone);
    } on Exception catch (e) {
      _syncInProgress = false;
      if (onDone != null && onError != null) {
        _handleError(this, e, onDone, onError);
      } else {
        rethrow;
      }
    }
  }

  void _onDone(Function? onDone) {
    if (onDone != null) {
      _logger.finer('sync service onDone invoked');
      onDone(this);
    }
  }

  Future<void> _pullChanges(SyncObject syncObject,
      {String? regex, bool isStream = false}) async {
    // If isStream is true, execute sync:stream
    if (isStream) {
      _logger.info('Stream sync process started');
      await remoteSecondary.sync(syncObject.lastSyncedCommitId,
          syncCallBack: _syncLocal, regex: regex, isStream: isStream);
      return;
    }
    // If isStream is false, execute regular sync
    _logger.info('Sync process started');
    var syncResponse =
        await remoteSecondary.sync(syncObject.lastSyncedCommitId, regex: regex);
    if (syncResponse != null && syncResponse != 'data:null') {
      syncResponse = syncResponse.replaceFirst('data:', '');
      var syncResponseJson = jsonDecode(syncResponse);
      await Future.forEach(syncResponseJson,
          (dynamic serverCommitEntry) => _syncLocal(serverCommitEntry));
    }
  }

  Future<void> _pushChanges(SyncObject syncObject, {String? regex}) async {
    var uncommittedEntryBatch =
        _getUnCommittedEntryBatch(syncObject.uncommittedEntries!);
    for (var unCommittedEntryList in uncommittedEntryBatch) {
      var batchRequests = await _getBatchRequests(unCommittedEntryList);
      var batchResponse = await _sendBatch(batchRequests);
      for (var entry in batchResponse) {
        try {
          var batchId = entry['id'];
          var serverResponse = entry['response'];
          var responseObject = Response.fromJson(serverResponse);
          var commitId = -1;
          if (responseObject.data != null) {
            commitId = int.parse(responseObject.data!);
          }
          var commitEntry = unCommittedEntryList.elementAt(batchId - 1);
          if (commitId == -1) {
            _logger.severe(
                'update/delete for key ${commitEntry.atKey} failed. Error code ${responseObject.errorCode} error message ${responseObject.errorMessage}');
          }

          _logger.finer('***batchId:$batchId key: ${commitEntry.atKey}');
          await SyncUtil.updateCommitEntry(commitEntry, commitId, _atSign);
        } on Exception catch (e) {
          //entire batch should not fail.So handle any exception
          _logger.severe(
              'exception while updating commit entry for entry:$entry ${e.toString()}');
        }
      }
    }
  }

  Future<void> _syncLocal(serverCommitEntry) async {
    _logger.info('Syncing ${serverCommitEntry['atKey']}');
    print('_syncLocal ${serverCommitEntry['atKey']}');
    switch (serverCommitEntry['operation']) {
      case '+':
      case '#':
      case '*':
        var builder = UpdateVerbBuilder()
          ..atKey = serverCommitEntry['atKey']
          ..value = serverCommitEntry['value'];
        builder.operation = UPDATE_ALL;
        _setMetaData(builder, serverCommitEntry);
        await _pullToLocal(builder, serverCommitEntry, CommitOp.UPDATE_ALL);
        break;
      case '-':
        var builder = DeleteVerbBuilder()..atKey = serverCommitEntry['atKey'];
        await _pullToLocal(builder, serverCommitEntry, CommitOp.DELETE);
        break;
    }
  }

  Future<bool> isInSync({String? regex}) async {
    await _checkConnectivity();
    var syncObject = await _getSyncObject(regex: regex);
    var isInSync = SyncUtil.isInSync(syncObject.uncommittedEntries,
        syncObject.serverCommitId, syncObject.lastSyncedCommitId);
    return isInSync;
  }

  Future<SyncObject> _getSyncObject({String? regex}) async {
    var lastSyncedEntry =
        await SyncUtil.getLastSyncedEntry(regex, atSign: _atSign);
    var lastSyncedCommitId = lastSyncedEntry?.commitId;
    var serverCommitId =
        await SyncUtil.getLatestServerCommitId(remoteSecondary, regex);
    var lastSyncedLocalSeq = lastSyncedEntry != null ? lastSyncedEntry.key : -1;
    var unCommittedEntries = await SyncUtil.getChangesSinceLastCommit(
        lastSyncedLocalSeq, regex,
        atSign: _atSign);
    return SyncObject()
      ..uncommittedEntries = unCommittedEntries
      ..serverCommitId = serverCommitId
      ..lastSyncedCommitId = lastSyncedCommitId;
  }

  Future<void> _checkConnectivity() async {
    if (!(await NetworkUtil.isNetworkAvailable())) {
      throw AtConnectException('Internet connection unavailable to sync');
    }
    if (!(await remoteSecondary.isAvailable())) {
      throw SecondaryNotFoundException('Secondary server is unavailable');
    }
  }

  Future<void> _pullToLocal(
      VerbBuilder builder, serverCommitEntry, CommitOp operation) async {
    var verbResult = await localSecondary.executeVerb(builder, sync: false);
    var sequenceNumber = int.parse(verbResult!.split(':')[1]);
    var commitEntry = await SyncUtil.getCommitEntry(sequenceNumber, _atSign);
    commitEntry!.operation = operation;
    await SyncUtil.updateCommitEntry(
        commitEntry, serverCommitEntry['commitId'], _atSign);
  }

  void _setMetaData(builder, serverCommitEntry) {
    var metaData = serverCommitEntry['metadata'];
    if (metaData != null && metaData.isNotEmpty) {
      if (metaData[AT_TTL] != null) builder.ttl = int.parse(metaData[AT_TTL]);
      if (metaData[AT_TTB] != null) builder.ttb = int.parse(metaData[AT_TTB]);
      if (metaData[AT_TTR] != null) builder.ttr = int.parse(metaData[AT_TTR]);
      if (metaData[CCD] != null) {
        (metaData[CCD].toLowerCase() == 'true')
            ? builder.ccd = true
            : builder.ccd = false;
      }
      if (metaData[PUBLIC_DATA_SIGNATURE] != null) {
        builder.dataSignature = metaData[PUBLIC_DATA_SIGNATURE];
      }
      if (metaData[IS_BINARY] != null) {
        (metaData[IS_BINARY].toLowerCase() == 'true')
            ? builder.isBinary = true
            : builder.isBinary = false;
      }
      if (metaData[IS_ENCRYPTED] != null) {
        (metaData[IS_ENCRYPTED].toLowerCase() == 'true')
            ? builder.isEncrypted = true
            : builder.isEncrypted = false;
      }
      if (metaData[SHARED_KEY_STATUS] != null) {
        builder.sharedKeyStatus = metaData[SHARED_KEY_STATUS];
      }
    }
  }

  List<dynamic> _getUnCommittedEntryBatch(
      List<CommitEntry> uncommittedEntries) {
    var unCommittedEntryBatch = [];
    var batchSize = preference.syncBatchSize, i = 0;
    var totalEntries = uncommittedEntries.length;
    var totalBatch = (totalEntries % batchSize == 0)
        ? totalEntries / batchSize
        : (totalEntries / batchSize).floor() + 1;
    var startIndex = i;
    while (i < totalBatch) {
      var endIndex = startIndex + batchSize < totalEntries
          ? startIndex + batchSize
          : totalEntries;
      var currentBatch = uncommittedEntries.sublist(startIndex, endIndex);
      unCommittedEntryBatch.add(currentBatch);
      startIndex += batchSize;
      i++;
    }
    return unCommittedEntryBatch;
  }

  Future<List<BatchRequest>> _getBatchRequests(
      List<CommitEntry> uncommittedEntries) async {
    var batchRequests = <BatchRequest>[];
    var batchId = 1;
    for (var entry in uncommittedEntries) {
      var command = await _getCommand(entry);
      command = command.replaceAll('cached:', '');
      command = VerbUtil.replaceNewline(command);
      var batchRequest = BatchRequest(batchId, command);
      _logger.finer('batchId:$batchId key:${entry.atKey}');
      batchRequests.add(batchRequest);
      batchId++;
    }
    return batchRequests;
  }

  dynamic _sendBatch(List<BatchRequest> requests) async {
    var command = 'batch:';
    command += jsonEncode(requests);
    command += '\n';
    var verbResult = await remoteSecondary.executeCommand(command, auth: true);
    _logger.finer('batch result:$verbResult');
    if (verbResult != null) {
      verbResult = verbResult.replaceFirst('data:', '');
    }
    return jsonDecode(verbResult!);
  }

  Future<String> _getCommand(CommitEntry entry) async {
    var command;
    switch (entry.operation) {
      case CommitOp.UPDATE:
        var key = entry.atKey;
        var value = await localSecondary.keyStore!.get(key);
        command = 'update:$key ${value?.data}';
        break;
      case CommitOp.DELETE:
        var key = entry.atKey;
        command = 'delete:$key';
        break;
      case CommitOp.UPDATE_META:
        var key = entry.atKey!;
        var metaData = await localSecondary.keyStore!.getMeta(key);
        if (metaData != null) {
          key += _metadataToString(metaData);
        }
        command = 'update:meta:$key';
        break;
      case CommitOp.UPDATE_ALL:
        var key = entry.atKey;
        var value = await localSecondary.keyStore!.get(key);
        var metaData = await localSecondary.keyStore!.getMeta(key);
        var keyGen = '';
        if (metaData != null) {
          keyGen = _metadataToString(metaData);
        }
        keyGen += ':$key';
        value?.metaData = metaData;
        command = 'update$keyGen ${value?.data}';
        break;
      default:
        break;
    }
    return command;
  }

  String _metadataToString(dynamic metadata) {
    var metadataStr = '';
    if (metadata.ttl != null) metadataStr += ':ttl:${metadata.ttl}';
    if (metadata.ttb != null) metadataStr += ':ttb:${metadata.ttb}';
    if (metadata.ttr != null) metadataStr += ':ttr:${metadata.ttr}';
    if (metadata.isCascade != null) {
      metadataStr += ':ccd:${metadata.isCascade}';
    }
    if (metadata.dataSignature != null) {
      metadataStr += ':dataSignature:${metadata.dataSignature}';
    }
    if (metadata.isBinary != null) {
      metadataStr += ':isBinary:${metadata.isBinary}';
    }
    if (metadata.isEncrypted != null) {
      metadataStr += ':isEncrypted:${metadata.isEncrypted}';
    }
    return metadataStr;
  }

  bool isSyncInProgress() {
    return _syncInProgress;
  }
}

class SyncObject {
  List<CommitEntry>? uncommittedEntries;
  int? serverCommitId;
  int? lastSyncedCommitId;
}