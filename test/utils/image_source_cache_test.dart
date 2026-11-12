import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart' as cache;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/cache_manager.dart';

class _Cache extends Fake implements cache.DefaultCacheManager {
  _Cache(this.cacheDir);
  @override
  final String cacheDir;
  @override
  Future<void> emptyCache() async {}
}

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final String directory;
  @override
  Future<String?> getTemporaryPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Directory originals;
  late File original;
  late Directory preview;
  late Directory images;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('image-source-cache-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    originals = await Directory.systemTemp.createTemp('image-source-original-');
    original = await File(path.join(originals.path, 'source.bin'))
        .writeAsBytes([1, 2, 3]);
    images = await Directory(path.join(directory.path, 'images')).create();
    preview = await Directory(path.join(directory.path, 'image_preview_v1'))
        .create();
    await File(path.join(preview.path, 'snapshot-orphan')).writeAsBytes([4, 5]);
    CacheManager.manager = _Cache(images.path);
    await CacheManager.imageSources.ready;
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    await CacheManager.imageSources.clear();
    await directory.delete(recursive: true);
    await originals.delete(recursive: true);
  });

  test(
    'startup removes orphan snapshots and publishes bounded counters',
    () async {
      expect(await preview.list().toList(), isEmpty);
      final sources = Diagnostics.instance.readSources(prefix: 'image.sources');
      expect(sources['image.sources'], containsPair('leases', 0));
      expect(sources['image.sources'], containsPair('snapshotBytes', 0));
    },
  );

  test(
    'application cache counts live previews and clearing respects leases',
    () async {
      final lease = await CacheManager.imageSources.acquire(original);
      await File(path.join(images.path, 'frame')).writeAsBytes([4, 5]);
      expect(await CacheManager.loadApplicationCache(), 5);
      await CacheManager.clearLibraryCache();
      expect(await CacheManager.loadApplicationCache(), 3);
      expect(await lease.file.readAsBytes(), [1, 2, 3]);
      expect(await original.readAsBytes(), [1, 2, 3]);
      await lease.dispose();
      expect(await CacheManager.loadApplicationCache(), 0);
      expect(CacheManager.imageSources.statistics.values, everyElement(0));
    },
  );
}
