// mpv --hwdec=help
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;

enum HwDecType {
  no('no', '启用软解'),
  auto('auto', '启用任意可用解码器'),
  autoSafe('auto-safe', '启用最佳解码器'),
  autoCopy('auto-copy', '启用带拷贝功能的最佳解码器'),
  d3d12va('d3d12va', 'DirectX 12 (Windows10 及以上)'),
  d3d12vaCopy('d3d12va-copy', 'DirectX 12 (Windows10 及以上) (非直通)'),
  d3d11va('d3d11va', 'DirectX 11 (Windows8 及以上)'),
  d3d11vaCopy('d3d11va-copy', 'DirectX 11 (Windows8 及以上) (非直通)'),
  dxva2('dxva2', 'DXVA2 (Windows7 及以上)'),
  dxva2Copy('dxva2-copy', 'DXVA2 (Windows7 及以上) (非直通)'),
  nvdec('nvdec', 'NVDEC (NVIDIA独占)'),
  nvdecCopy('nvdec-copy', 'NVDEC (NVIDIA独占) (非直通)'),
  vulkan('vulkan', 'Vulkan (全平台) (实验性)'),
  vulkanCopy('vulkan-copy', 'Vulkan (全平台) (实验性) (非直通)'),
  mediacodec('mediacodec', 'MediaCodec (Android)'),
  mediacodecCopy('mediacodec-copy', 'MediaCodec (Android) (非直通)'),
  cuda('cuda', 'CUDA (NVIDIA独占) (过时)'),
  cudaCopy('cuda-copy', 'CUDA (NVIDIA独占) (过时) (非直通)'),
  crystalhd('crystalhd', 'CrystalHD (全平台) (过时)'),
  rkmpp('rkmpp', 'Rockchip MPP (仅部分Rockchip芯片)'),
  amf('amf', 'AMF (AMD独占)'),
  amfCopy('amf-copy', 'AMF (AMD独占) (非直通)'),
  qsv('qsv', 'Quick Sync Video (Intel独占)'),
  qsvCopy('qsv-copy', 'Quick Sync Video (Intel独占) (非直通)'),
  ;

  final String hwdec;
  final String desc;
  const HwDecType(this.hwdec, this.desc);

  static final String kHwdec = Platform.isAndroid
      ? kDebugMode
            ? autoSafe.hwdec
            : [mediacodec.hwdec, autoSafe.hwdec].join(',')
      : auto.hwdec;

  /// 按硬件解码效率排列候选项。`auto` 先交给 mpv 选择，失败后再逐个探测。
  static List<String> orderedCandidates(String? configured) {
    if (configured == null || configured.trim().isEmpty) {
      return const ['no'];
    }

    final result = <String>[];
    void add(String value) {
      if (value.isEmpty || result.contains(value)) return;
      result.add(value);
    }

    final requested = configured
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);
    for (final value in requested) {
      add(value);
    }

    if (result.any(_isAutomaticMode)) {
      for (final value in _platformFallbacks) {
        add(value);
      }
    }

    add(no.hwdec);
    return result;
  }

  static bool _isAutomaticMode(String value) =>
      value == auto.hwdec || value == autoSafe.hwdec || value == autoCopy.hwdec;

  static List<String> get _platformFallbacks {
    if (Platform.isAndroid) {
      return const [
        'mediacodec',
        'mediacodec-copy',
        'auto-safe',
        'auto-copy',
        'auto',
      ];
    }
    if (Platform.isWindows) {
      return const [
        // 直通路径优先，copy 路径作为兼容性退路。
        'd3d12va',
        'd3d12va-copy',
        'd3d11va',
        'd3d11va-copy',
        'dxva2',
        'dxva2-copy',
        'nvdec',
        'nvdec-copy',
        'qsv',
        'qsv-copy',
        'amf',
        'amf-copy',
        'vulkan',
        'vulkan-copy',
      ];
    }
    return const ['auto-safe', 'auto-copy', 'auto'];
  }
}
