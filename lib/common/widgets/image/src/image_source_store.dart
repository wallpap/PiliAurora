import 'dart:async';
import 'dart:io';

class ImageSourceStore {
  ImageSourceStore(this.directory) {
    _copyTail = _initialize();
  }

  final Directory directory;
  final _entries = <String, _SourceEntry>{};
  final _retired = <_Snapshot>{};
  final _deletions = <_Snapshot, Future<void>>{};
  Future<void> _copyTail = Future.value();
  static int _nextVersion = 0;
  int _leases = 0;
  int _snapshots = 0;
  int _snapshotBytes = 0;
  int _queuedCopies = 0;
  int _activeCopies = 0;

  Future<void> get ready => _copyTail;

  Map<String, int> get statistics => {
    'leases': _leases,
    'snapshots': _snapshots,
    'snapshotBytes': _snapshotBytes,
    'queuedCopies': _queuedCopies,
    'activeCopies': _activeCopies,
    'retiredSnapshots': _retired.length,
    'pendingDeletions': _deletions.length,
  };

  Future<void> _initialize() async {
    await directory.create(recursive: true);
    await for (final file in directory.list(followLinks: false)) {
      if (file is File && file.uri.pathSegments.last.startsWith('snapshot-')) {
        await file.delete();
      }
    }
  }

  Future<ImageSourceLease> acquire(File source) async {
    final key = source.absolute.path;
    final entry = _entries.putIfAbsent(key, () {
      final preceding = _copyTail;
      _queuedCopies++;
      final operation = (() async {
        var active = false;
        try {
          await preceding;
          _queuedCopies--;
          _activeCopies++;
          active = true;
          return await _copy(source);
        } finally {
          if (active) {
            _activeCopies--;
          } else {
            _queuedCopies--;
          }
        }
      })();
      _copyTail = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      return _SourceEntry(operation);
    });
    entry.users++;
    _leases++;
    try {
      final snapshot = await entry.future;
      return ImageSourceLease._(this, key, entry, snapshot);
    } catch (_) {
      entry.users--;
      _leases--;
      if (identical(_entries[key], entry)) _entries.remove(key);
      rethrow;
    }
  }

  Future<_Snapshot> _copy(File source) async {
    await directory.create(recursive: true);
    for (var attempt = 0; attempt < 3; attempt++) {
      final before = await source.stat();
      if (before.type != FileSystemEntityType.file) {
        throw FileSystemException('图片来源不是文件', source.path);
      }
      final version = ++_nextVersion;
      final file = File(
        '${directory.path}/snapshot-$version-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await source.openRead().pipe(file.openWrite());
        final after = await source.stat();
        if (before.size == after.size &&
            before.modified == after.modified &&
            await file.length() == before.size) {
          _snapshots++;
          _snapshotBytes += before.size;
          return _Snapshot(file, Object(), before.size);
        }
      } catch (_) {
        if (await file.exists()) await file.delete();
        rethrow;
      }
      await file.delete();
    }
    throw FileSystemException('复制期间图片来源持续变化', source.path);
  }

  Future<void> _release(
    String key,
    _SourceEntry entry,
    _Snapshot snapshot,
  ) async {
    _leases--;
    if (--entry.users != 0) return;
    if (identical(_entries[key], entry)) _entries.remove(key);
    _retired.add(snapshot);
    await _deleteSnapshot(snapshot);
  }

  ImageSourceLease _retain(String key, _SourceEntry entry, _Snapshot snapshot) {
    entry.users++;
    _leases++;
    return ImageSourceLease._(this, key, entry, snapshot);
  }

  Future<void> _deleteSnapshot(_Snapshot snapshot) =>
      _deletions[snapshot] ??= _deleteFile(snapshot);

  Future<void> _deleteFile(_Snapshot snapshot) async {
    try {
      if (await snapshot.file.exists()) await snapshot.file.delete();
      if (_retired.remove(snapshot)) {
        _snapshots--;
        _snapshotBytes -= snapshot.bytes;
      }
    } finally {
      _deletions.remove(snapshot);
    }
  }

  Future<void> clear() async {
    await _copyTail;
    await Future.wait(_retired.toList().map(_deleteSnapshot));
  }
}

class _SourceEntry {
  _SourceEntry(this.future);
  final Future<_Snapshot> future;
  int users = 0;
}

class _Snapshot {
  _Snapshot(this.file, this.version, this.bytes);
  final File file;
  final Object version;
  final int bytes;
}

class ImageSourceLease {
  ImageSourceLease._(this._store, this._key, this._entry, this._snapshot);
  final ImageSourceStore _store;
  final String _key;
  final _SourceEntry _entry;
  final _Snapshot _snapshot;
  Future<void>? _released;
  File get file => _snapshot.file;
  Object get version => _snapshot.version;
  ImageSourceLease retain() {
    if (_released != null) throw StateError('已释放的图片来源租约不能继续持有');
    return _store._retain(_key, _entry, _snapshot);
  }

  Future<void> dispose() =>
      _released ??= _store._release(_key, _entry, _snapshot);
}
