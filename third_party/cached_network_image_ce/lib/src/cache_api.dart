/// 由本地图片缓存包共同拥有的缓存模型和 IO 加载契约。
library cached_network_image_cache_api;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'cache_api/cache_manager.dart';

export 'cache_api/cache_manager.dart';
export 'cache_api/connection_parameters.dart';
export 'cache_api/file_response.dart';
export 'cache_api/http_exception.dart';
export 'cache_api/image_format_detector.dart';
export 'cache_api/unsupported_image_format_exception.dart';

/// Listener for errors
typedef ErrorListener = void Function(Object);

/// Render options for images on the web platform.
enum ImageRenderMethodForWeb {
  /// HtmlImage uses a default web image including default browser caching.
  /// This is the recommended and default choice.
  HtmlImage, // ignore: constant_identifier_names

  /// HttpGet uses an http client to fetch an image. It enables the use of
  /// headers, but loses some default web functionality.
  HttpGet, // ignore: constant_identifier_names
}

/// ImageLoader class to load images differently on various platforms.
class ImageLoader {
  /// loads the images async and gives the resulted codecs on a Stream. The
  /// Stream gives the option to show multiple images after each other.
  @Deprecated('Use loadImageAsync instead')
  Stream<ui.Codec> loadBufferAsync(
    String url,
    String? cacheKey,
    StreamController<ImageChunkEvent> chunkEvents,
    DecoderBufferCallback decode,
    BaseCacheManager cacheManager,
    int? maxHeight,
    int? maxWidth,
    Map<String, String>? headers,
    ImageRenderMethodForWeb imageRenderMethodForWeb,
    VoidCallback evictImage,
  ) {
    throw UnimplementedError();
  }

  /// loads the images async and gives the resulted codecs on a Stream. The
  /// Stream gives the option to show multiple images after each other.
  Stream<ui.Codec> loadImageAsync(
    String url,
    String? cacheKey,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
    BaseCacheManager cacheManager,
    int? maxHeight,
    int? maxWidth,
    Map<String, String>? headers,
    ImageRenderMethodForWeb imageRenderMethodForWeb,
    VoidCallback evictImage,
  ) {
    throw UnimplementedError();
  }
}
