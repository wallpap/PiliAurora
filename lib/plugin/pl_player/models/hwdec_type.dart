// mpv --hwdec=help
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;

enum HwDecType {
  no('no', '软件解码：由处理器解码，兼容性好、功耗较高'),
  auto('auto', '自动选择：由播放器挑选可用的硬件解码器'),
  autoSafe('auto-safe', '自动选择（兼容优先）：避开已知不稳定的解码器'),
  autoCopy('auto-copy', '自动选择（兼容优先）：解码后复制画面，兼容性更好'),
  d3d12va('d3d12va', 'DirectX 12：显卡解码并直接显示画面（Windows 10+）'),
  d3d12vaCopy('d3d12va-copy', 'DirectX 12：显卡解码后复制画面（Windows 10+）'),
  d3d11va('d3d11va', 'DirectX 11：显卡解码并直接显示画面（Windows 8+）'),
  d3d11vaCopy('d3d11va-copy', 'DirectX 11：显卡解码后复制画面（Windows 8+）'),
  dxva2('dxva2', 'DXVA2：Windows 显卡硬件解码'),
  dxva2Copy('dxva2-copy', 'DXVA2：显卡解码后复制画面'),
  nvdec('nvdec', 'NVDEC：NVIDIA 显卡硬件解码'),
  nvdecCopy('nvdec-copy', 'NVDEC：NVIDIA 显卡解码后复制画面'),
  vulkan('vulkan', 'Vulkan：跨平台硬件解码（实验性）'),
  vulkanCopy('vulkan-copy', 'Vulkan：跨平台解码后复制画面（实验性）'),
  mediacodec('mediacodec', 'MediaCodec：Android 设备硬件解码'),
  mediacodecCopy('mediacodec-copy', 'MediaCodec：Android 解码后复制画面'),
  cuda('cuda', 'CUDA：NVIDIA 显卡硬件解码（已过时）'),
  cudaCopy('cuda-copy', 'CUDA：NVIDIA 解码后复制画面（已过时）'),
  crystalhd('crystalhd', 'CrystalHD：旧款专用硬件解码器（已过时）'),
  rkmpp('rkmpp', 'Rockchip MPP：部分瑞芯微设备可用'),
  amf('amf', 'AMF：AMD 显卡硬件解码'),
  amfCopy('amf-copy', 'AMF：AMD 显卡解码后复制画面'),
  qsv('qsv', 'Quick Sync：Intel 核显硬件解码'),
  qsvCopy('qsv-copy', 'Quick Sync：Intel 核显解码后复制画面'),
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
