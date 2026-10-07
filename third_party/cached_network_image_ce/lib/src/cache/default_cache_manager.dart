import 'dart:async';
import 'dart:io' as io;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/src/cache/cache_entry_metadata_adapter.dart';
import 'package:cached_network_image_ce/src/cache/extension.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_ce/hive.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/hive_impl.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'cache_entry_metadata.dart';
import 'shared_http_client.dart';

export 'cache_entry_metadata.dart';

const _kBoxName = 'cached_network_image_cache';
const _kDefaultMaxAge = Duration(days: 30);
const _kDefaultMaxCacheLength = 200 << 20;
const _kDefaultStalePeriod = Duration(days: 7);

const _supportedFileNames = {'jpg', 'jpeg', 'png', 'tga', 'cur', 'ico', 'webp'};

/// Signature for a function that returns the cache base directory.
///
/// Defaults to [getTemporaryDirectory] when not specified.
typedef CacheDirectoryProvider = Future<io.Directory> Function();

/// Default cache manager implementation using Hive CE for metadata storage,
/// the http package for downloads, and path_provider for file system access.
class DefaultCacheManager extends CacheManager with ImageCacheManager {
  /// Creates a [DefaultCacheManager] with optional configuration.
  ///
  /// [stalePeriod] is how long a file remains valid in the cache.
  /// [maxNrOfCacheLength] is the maximum length before cleanup triggers.
  /// [_httpClientFactory] allows injecting a custom HTTP client (useful for testing).
  /// [_cacheDirectoryProvider] allows overriding where cache files are stored.
  ///   Defaults to [getTemporaryDirectory]. Pass [getApplicationSupportDirectory]
  ///   if you need a more persistent location (but note that files may be
  ///   backed up on iOS/Android).
  DefaultCacheManager._(
    this.stalePeriod,
    this.maxNrOfCacheLength,
    ConnectionParameters? connectionParameters,
    http.Client Function() httpClientFactory,
    this._cacheDirectoryProvider,
  )   : requestTimeout = connectionParameters?.requestTimeout,
        _httpClient = SharedHttpClient(
          httpClientFactory,
          connectionParameters?.connectionTimeout,
        );

  static DefaultCacheManager? instance;

  @Deprecated('use [DefaultCacheManager.instance!] instead')
  factory DefaultCacheManager() => instance!;

  static Future<DefaultCacheManager> init({
    Duration stalePeriod = _kDefaultStalePeriod,
    int maxNrOfCacheLength = _kDefaultMaxCacheLength,
    ConnectionParameters? connectionParameters,
    http.Client Function() httpClientFactory = http.Client.new,
    CacheDirectoryProvider cacheDirectoryProvider = getTemporaryDirectory,
  }) {
    assert(instance == null ||
        io.Platform.environment.containsKey('FLUTTER_TEST'));
    return DefaultCacheManager._(
      stalePeriod,
      maxNrOfCacheLength,
      connectionParameters,
      httpClientFactory,
      cacheDirectoryProvider,
    )._doInit();
  }

  /// Duration before cached files are considered stale.
  final Duration stalePeriod;

  /// Maximum length of objects in the cache before cleanup.
  final int maxNrOfCacheLength;

  /// Optional connection parameters for HTTP timeouts.
  ///
  /// When `null` (the default), no timeouts are applied and downloads may
  /// wait indefinitely — preserving the existing behaviour.
  final Duration? requestTimeout;

  final SharedHttpClient _httpClient;

  /// Provider for the base cache directory.
  final CacheDirectoryProvider _cacheDirectoryProvider;

  /// Private Hive instance to avoid conflicts with the host app's global
  /// [Hive] singleton. Each [DefaultCacheManager] gets its own isolated
  /// Hive registry.
  final HiveInterface _hive = HiveImpl();

  Box<CacheEntryMetadata>? _cacheBox;
  String? _cacheDir;

  String get cacheDir => _cacheDir!;

  Future<DefaultCacheManager> _doInit() async {
    instance = this;
    final dir = await _cacheDirectoryProvider();
    _cacheDir = path.join(dir.path, 'cached_network_image_ce');
    await io.Directory(_cacheDir!).create(recursive: true);

    final hivePath = path.join(_cacheDir!, 'hive');
    await io.Directory(hivePath).create(recursive: true);

    _hive.registerAdapter(CacheEntryMetadataAdapter());

    // Open the box with an explicit path on the private Hive instance.
    // This avoids calling Hive.init() which would conflict with the
    // host application's own Hive initialization.
    try {
      _cacheBox =
          await _hive.openBox<CacheEntryMetadata>(_kBoxName, path: hivePath);
    } on HiveError catch (e) {
      // Box corruption (e.g. "Cannot read, unknown typeId: 121").
      // Since this is a cache, we can safely delete the corrupted box
      // and start fresh. Cached images will simply be re-downloaded.
      cacheLogger.log(
        'CacheManager: Hive box corrupted, resetting cache: $e',
        CacheManagerLogLevel.warning,
      );
      await _safeDeleteBox(_kBoxName, hivePath);
      _cacheBox =
          await _hive.openBox<CacheEntryMetadata>(_kBoxName, path: hivePath);

      // Also remove cached files since their metadata is gone.
      await _deleteCacheFiles();
    }

    // Run cleanup in background
    unawaited(_cleanupOldFiles());

    return this;
  }

  /// Attempts to delete a Hive box from disk, tolerating missing files.
  ///
  /// [HiveImpl.deleteBoxFromDisk] can throw [PathNotFoundException] when
  /// auxiliary files (e.g. `.lock`) are already gone. In that case we
  /// fall back to manually deleting the `.hive` file.
  Future<void> _safeDeleteBox(String boxName, String boxPath) async {
    try {
      await _hive.deleteBoxFromDisk(boxName, path: boxPath);
    } catch (_) {
      // Fallback: delete the .hive file directly.
      final boxFile = io.File(path.join(boxPath, '$boxName.hive'));
      if (await boxFile.exists()) {
        await boxFile.delete();
      }
    }
  }

  /// Deletes all cached image files in the cache directory.
  ///
  /// Called after a corruption recovery to remove orphaned files whose
  /// metadata has been lost.
  Future<void> _deleteCacheFiles() async {
    try {
      final cacheDir = io.Directory(_cacheDir!);
      if (cacheDir.existsSync()) {
        await for (final entity in cacheDir.list()) {
          if (entity is io.File) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      cacheLogger.log(
        'CacheManager: Error cleaning orphaned cache files: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  String _cacheFilePath(String relativePath) {
    return path.join(_cacheDir!, relativePath);
  }

  Future<void> _ensureCacheDirectoryExists() {
    return io.Directory(_cacheDir!).create(recursive: true);
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    key ??= url;

    FileInfo? cachedFile;
    try {
      cachedFile = await getFileFromCache(key);
      if (cachedFile != null) {
        yield cachedFile;
        withProgress = false;
      }
    } catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to load cached file for $url with error:\n$e',
        CacheManagerLogLevel.debug,
      );
    }

    if (cachedFile == null || cachedFile.validTill.isBefore(DateTime.now())) {
      try {
        await for (final response
            in _downloadFile(url, key, headers, withProgress)) {
          if (response is DownloadProgress) {
            if (withProgress) yield response;
          } else {
            yield response;
          }
        }
      } catch (e) {
        cacheLogger.log(
          'CacheManager: Failed to download file from $url with error:\n$e',
          CacheManagerLogLevel.debug,
        );
        if (cachedFile != null &&
            e is HttpExceptionWithStatus &&
            e.statusCode == 404) {
          await removeFile(key);
        }
        rethrow;
      }
    }
  }

  @override
  Future<io.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    key ??= url;

    FileInfo? cachedFile;
    try {
      cachedFile = await getFileFromCache(key);
    } catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to load cached file for $url with error:\n$e',
        CacheManagerLogLevel.debug,
      );
    }

    if (cachedFile == null || cachedFile.validTill.isBefore(DateTime.now())) {
      try {
        return ((await _downloadFile(url, key, headers, false).last)
                as FileInfo)
            .file;
      } on HttpExceptionWithStatus catch (e) {
        if (cachedFile != null && e.statusCode == 404) {
          await removeFile(key);
        }
        rethrow;
      }
    } else {
      return cachedFile.file;
    }
  }

  Stream<FileResponse> _downloadFile(
    String url,
    String key,
    Map<String, String>? headers,
    bool withProgress,
  ) async* {
    cacheLogger.log(
      'CacheManager: Downloading $url',
      CacheManagerLogLevel.verbose,
    );

    SharedHttpClientResponse? clientResponse;
    http.StreamedResponse? rawResponse;
    try {
      clientResponse =
          await _httpClient.send(uri: Uri.parse(url), headers: headers);
      final response = clientResponse.response;
      rawResponse = response;

      if (response.statusCode != 200 && response.statusCode != 202) {
        // Cancel the body stream before throwing, as we won't consume it.
        await _cancelResponseStream(response);
        throw HttpExceptionWithStatus(
          response.statusCode,
          'Invalid statusCode: ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }
      // After this point rawResponse should not be canceled here;
      // we will read the stream ourselves. Set to null to avoid double-cancel.
      rawResponse = null;

      final contentLength = response.contentLength;
      final fileExtension = url.fileExtension;
      final filePath = _cacheFilePath(key.fnvHashStr + fileExtension);
      final finalFile = io.File(filePath);

      await _ensureCacheDirectoryExists();

      final tempFile =
          io.File('$filePath.${DateTime.now().microsecondsSinceEpoch}.tmp');
      final sink = tempFile.openWrite();

      final requestTimeout = this.requestTimeout;
      Stream<List<int>> stream = response.stream;
      if (requestTimeout != null) stream = stream.timeout(requestTimeout);

      var receivedBytes = 0;
      var movedToFinalPath = false;
      try {
        await for (final chunk in stream) {
          receivedBytes += chunk.length;
          sink.add(chunk);
          if (withProgress) {
            yield DownloadProgress(url, contentLength, receivedBytes);
          }
        }
        await sink.flush();
        await sink.close();

        try {
          await tempFile.rename(filePath);
          movedToFinalPath = true;
        } catch (_) {
          io.File? backupFile;
          try {
            if (await finalFile.exists()) {
              final backupPath =
                  '$filePath.${DateTime.now().microsecondsSinceEpoch}.bak';
              backupFile = await finalFile.rename(backupPath);
            }

            await tempFile.rename(filePath);
            movedToFinalPath = true;
          } catch (_) {
            if (backupFile != null && await backupFile.exists()) {
              if (await finalFile.exists()) {
                await finalFile.delete();
              }
              await backupFile.rename(filePath);
            }
            rethrow;
          }

          if (backupFile != null && await backupFile.exists()) {
            try {
              await backupFile.delete();
            } catch (e) {
              cacheLogger.log(
                'CacheManager: Failed to delete backup file for $filePath with error:\n$e',
                CacheManagerLogLevel.warning,
              );
            }
          }
        }
      } catch (_) {
        await sink.close();
        rethrow;
      } finally {
        if (!movedToFinalPath && await tempFile.exists()) {
          await tempFile.delete();
        }
      }

      // Store metadata in Hive
      final validTill = DateTime.now().add(stalePeriod);
      final cacheHeaders = response.headers;
      final eTag = cacheHeaders['etag'];

      await _cacheBox!.put(
        key.fnvHashStr,
        CacheEntryMetadata(
          url: url,
          fileExtension: fileExtension,
          validTill: validTill,
          eTag: eTag,
          length: receivedBytes,
        ),
      );

      yield FileInfo(finalFile, FileSource.Online, validTill, url);
    } catch (_) {
      // Cancel the stream if we still hold a rawResponse that hasn't been consumed.
      final response = rawResponse;
      if (response != null) {
        await _cancelResponseStream(response);
      }
      rethrow;
    } finally {
      clientResponse?.release();
    }
  }

  Future<void> _cancelResponseStream(http.StreamedResponse response) async {
    try {
      await response.stream
          .listen(null, onError: (_, __) {}, cancelOnError: true)
          .cancel();
    } on StateError catch (_) {
      // A downstream owner may already have consumed the single-subscription
      // stream. Other cleanup failures should remain visible.
    }
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    key = key.fnvHashStr;

    final metadata = _cacheBox!.get(key);
    if (metadata == null) {
      return null;
    }

    final file = io.File(_cacheFilePath(key + metadata.fileExtension));
    if (!file.existsSync()) {
      // Metadata exists but file is missing, clean up
      await _cacheBox!.delete(key);
      return null;
    }

    return FileInfo(file, FileSource.Cache, metadata.validTill, metadata.url);
  }

  @override
  Future<io.File> putFile(
    String url,
    List<int> fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = _kDefaultMaxAge,
    String fileExtension = 'file',
  }) async {
    key ??= url;
    key = key.fnvHashStr;
    final relativePath = '$key.$fileExtension';

    await _ensureCacheDirectoryExists();

    final file = io.File(_cacheFilePath(relativePath));
    await file.writeAsBytes(fileBytes);

    final validTill = DateTime.now().add(maxAge);
    _cacheBox!.put(
        key,
        CacheEntryMetadata(
          url: url,
          fileExtension: fileExtension,
          validTill: validTill,
          eTag: eTag,
          length: fileBytes.length,
        ));

    return file;
  }

  @override
  Future<void> removeFile(String key) async {
    key = key.fnvHashStr;
    final metadata = _cacheBox!.get(key);
    if (metadata != null) {
      final file = io.File(_cacheFilePath(key + metadata.fileExtension));
      if (await file.exists()) {
        await file.delete();
      }
      await _cacheBox!.delete(key);
    }
  }

  @override
  Future<void> emptyCache() {
    // Delete all cached files
    return Future.wait([_deleteCacheFiles(), _cacheBox!.clear()]);
  }

  @override
  Future<void> dispose() async {
    _httpClient.dispose();

    if (_cacheBox != null && _cacheBox!.isOpen) {
      try {
        await _cacheBox!.close();
      } catch (_) {
        // Ignore errors when closing box (e.g. PathNotFoundException if the
        // cache directory was deleted before dispose was called).
      }
    }
    try {
      await _hive.close();
    } catch (_) {
      // Ignore errors when closing Hive (e.g. residual lock file already gone).
    }

    _cacheBox = null;
    _cacheDir = null;
    instance = null;
  }

  /// Clean up files that haven't been used in a while.
  Future<void> _cleanupOldFiles() async {
    if (maxNrOfCacheLength <= 0) {
      return emptyCache();
    }
    if (_cacheBox!.isEmpty) return;
    try {
      final now = DateTime.now();

      // Remove expired entries
      final map = _cacheBox!.toMap();
      final keysToRemove = <String>[];
      int totalLength = 0;
      for (String key in map.keys) {
        final value = map[key]!;
        if (value.validTill.isBefore(now)) {
          final file = io.File(_cacheFilePath(key + value.fileExtension));
          if (await file.exists()) {
            await file.delete();
          }
          keysToRemove.add(key);
        } else {
          totalLength += value.length;
        }
      }

      // If cache is still too large, remove oldest entries
      if (totalLength > maxNrOfCacheLength) {
        final halfMaxNrOfCacheLength = maxNrOfCacheLength ~/ 2;
        for (var key in keysToRemove) {
          map.remove(key);
        }
        final sortedEntries = map.entries.toList()
          ..sort((a, b) => a.value.validTill.compareTo(b.value.validTill));

        for (var i = 0; i < sortedEntries.length; i++) {
          final entry = sortedEntries[i];
          final file =
              io.File(_cacheFilePath(entry.key + entry.value.fileExtension));
          if (await file.exists()) {
            await file.delete();
          }
          keysToRemove.add(entry.key);
          totalLength -= entry.value.length;
          if (totalLength < halfMaxNrOfCacheLength) {
            break;
          }
        }
      }
      if (keysToRemove.isNotEmpty) await _cacheBox!.deleteAll(keysToRemove);
    } catch (e) {
      cacheLogger.log(
        'CacheManager: Error during cleanup: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  int getTotalLength() {
    return _cacheBox!.values.fold(0, (p, n) => p + n.length);
  }

  // ---- ImageCacheManager mixin implementation ----

  final Map<String, Stream<FileResponse>> _runningResizes = {};

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) async* {
    if (maxHeight == null && maxWidth == null) {
      yield* getFileStream(
        url,
        key: key,
        headers: headers,
        withProgress: withProgress,
      );
      return;
    }

    key ??= url;
    var resizedKey = 'resized';
    if (maxWidth != null) resizedKey += '_w$maxWidth';
    if (maxHeight != null) resizedKey += '_h$maxHeight';
    resizedKey += '_$key';

    final fromCache = await getFileFromCache(resizedKey);
    if (fromCache != null) {
      yield fromCache;
      if (fromCache.validTill.isAfter(DateTime.now())) {
        return;
      }
      withProgress = false;
    }

    var runningResize = _runningResizes[resizedKey];
    if (runningResize == null) {
      runningResize = _fetchedResizedFile(
        url,
        key,
        resizedKey,
        headers,
        withProgress,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ).asBroadcastStream();
      _runningResizes[resizedKey] = runningResize;
    }
    yield* runningResize;
    _runningResizes.remove(resizedKey);
  }

  Stream<FileResponse> _fetchedResizedFile(
    String url,
    String originalKey,
    String resizedKey,
    Map<String, String>? headers,
    bool withProgress, {
    int? maxWidth,
    int? maxHeight,
  }) async* {
    await for (final response in getFileStream(
      url,
      key: originalKey,
      headers: headers,
      withProgress: withProgress,
    )) {
      if (response is DownloadProgress) {
        yield response;
      }
      if (response is FileInfo) {
        yield await _resizeImageFile(
          response,
          resizedKey,
          maxWidth,
          maxHeight,
        );
      }
    }
  }

  Future<FileInfo> _resizeImageFile(
    FileInfo originalFile,
    String key,
    int? maxWidth,
    int? maxHeight,
  ) async {
    final originalFileName = originalFile.file.path;
    final fileExtension = originalFileName.split('.').last;
    if (!_supportedFileNames.contains(fileExtension)) {
      return originalFile;
    }

    final image = await _decodeImage(originalFile.file);

    final shouldResize = (maxWidth != null && image.width > maxWidth) ||
        (maxHeight != null && image.height > maxHeight);
    if (!shouldResize) return originalFile;

    if (maxWidth != null && maxHeight != null) {
      final resizeFactorWidth = image.width / maxWidth;
      final resizeFactorHeight = image.height / maxHeight;
      final resizeFactor = max(resizeFactorHeight, resizeFactorWidth);
      maxWidth = (image.width / resizeFactor).round();
      maxHeight = (image.height / resizeFactor).round();
    }

    final resized = await _decodeImage(
      originalFile.file,
      width: maxWidth,
      height: maxHeight,
    );
    final resizedBytes =
        (await resized.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
    final maxAge = originalFile.validTill.difference(DateTime.now());

    final file = await putFile(
      originalFile.originalUrl,
      resizedBytes,
      key: key,
      maxAge: maxAge,
      fileExtension: 'png',
    );

    return FileInfo(
      file,
      originalFile.source,
      originalFile.validTill,
      originalFile.originalUrl,
    );
  }
}

Future<ui.Image> _decodeImage(
  io.File file, {
  int? width,
  int? height,
  bool allowUpscaling = false,
}) {
  final shouldResize = width != null || height != null;
  final fileImage = FileImage(file);
  final image = shouldResize
      ? ResizeImage(
          fileImage,
          width: width,
          height: height,
          allowUpscaling: allowUpscaling,
        )
      : fileImage as ImageProvider;
  final completer = Completer<ui.Image>();
  image.resolve(ImageConfiguration.empty).addListener(
        ImageStreamListener(
          (info, _) {
            completer.complete(info.image);
            image.evict();
          },
          onError: (e, s) {
            completer.completeError(e, s);
            image.evict();
          },
        ),
      );
  return completer.future;
}
