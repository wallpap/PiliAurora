import 'dart:ui' as ui;

/// 缓存持有原始句柄；显示组件通过 acquire 获取独立句柄。
class PreviewImageCache {
  PreviewImageCache({this.maxEntries = 3, this.maxBytes = 24 << 20})
    : assert(maxEntries > 0),
      assert(maxBytes > 0);

  final int maxEntries;
  final int maxBytes;
  final _cache = <String, ui.Image>{};
  int _generation = 0;
  int _sizeBytes = 0;

  int get generation => _generation;
  int get sizeBytes => _sizeBytes;

  ui.Image? acquire(String key) {
    final image = _cache.remove(key);
    if (image == null) return null;
    _cache[key] = image;
    return image.clone();
  }

  /// 接管 image 的所有权。单张超限时不缓存，调用者应先取得自己的句柄。
  void put(String key, ui.Image image) {
    if (identical(_cache[key], image)) return;
    final previous = _cache.remove(key);
    if (previous != null) {
      _sizeBytes -= previous.width * previous.height * 4;
      previous.dispose();
    }
    final bytes = image.width * image.height * 4;
    if (bytes > maxBytes) {
      image.dispose();
      return;
    }
    _cache[key] = image;
    _sizeBytes += bytes;
    while (_cache.length > maxEntries || _sizeBytes > maxBytes) {
      final oldest = _cache.remove(_cache.keys.first)!;
      _sizeBytes -= oldest.width * oldest.height * 4;
      oldest.dispose();
    }
  }

  void clear() {
    _generation++;
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
    _sizeBytes = 0;
  }
}
