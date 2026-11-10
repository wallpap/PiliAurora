import 'dart:async';

import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/video/cdn_type.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/video_utils.dart';
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';

class SelectDialog<T> extends StatelessWidget {
  final T? value;
  final String title;
  final List<(T, String)> values;
  final Widget Function(BuildContext, int)? subtitleBuilder;
  final bool toggleable;

  const SelectDialog({
    super.key,
    this.value,
    required this.values,
    required this.title,
    this.subtitleBuilder,
    this.toggleable = false,
  });

  @override
  Widget build(BuildContext context) {
    final titleMedium = TextTheme.of(context).titleMedium!;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(title),
      constraints: subtitleBuilder != null
          ? const BoxConstraints.tightFor(width: 320)
          : null,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: .transparency,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            onChanged: (v) => Navigator.of(context).pop(v ?? value),
            groupValue: value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                values.length,
                (index) {
                  final item = values[index];
                  return RadioListTile<T>(
                    toggleable: toggleable,
                    dense: true,
                    value: item.$1,
                    title: Text(
                      item.$2,
                      style: titleMedium,
                    ),
                    subtitle: subtitleBuilder?.call(context, index),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CdnSelectDialog extends StatefulWidget {
  final BaseItem? sample;
  // 与默认客户端一样由弹窗拥有并释放，便于离线验证测速结果。
  final Dio? client;

  const CdnSelectDialog({
    super.key,
    this.sample,
    this.client,
  });

  @override
  State<CdnSelectDialog> createState() => _CdnSelectDialogState();
}

class _CdnSelectDialogState extends State<CdnSelectDialog> {
  late final List<ValueNotifier<String?>> _cdnResList;
  late final List<CancelToken?> _tokens;
  late final bool _cdnSpeedTest;

  @override
  void initState() {
    super.initState();
    _cdnSpeedTest = Pref.cdnSpeedTest;
    if (_cdnSpeedTest) {
      _dio = widget.client ?? Dio();
      _dio.options
        ..connectTimeout = const Duration(seconds: 15)
        ..receiveTimeout = const Duration(seconds: 15)
        ..headers.addAll({
          'user-agent': BrowserUa.pc,
          'referer': HttpString.baseUrl,
        });
      final length = CDNService.values.length;
      _cdnResList = List.generate(
        length,
        (_) => ValueNotifier<String?>(null),
      );
      _tokens = List.generate(length, (_) => CancelToken());
      _startSpeedTest();
    }
  }

  @override
  void dispose() {
    if (_cdnSpeedTest) {
      for (final e in _tokens) {
        e?.cancel();
      }
      for (final notifier in _cdnResList) {
        notifier.dispose();
      }
      _dio.close(force: true);
    }
    super.dispose();
  }

  Future<BaseItem> _getSampleUrl() async {
    final result = await VideoHttp.videoUrl(
      cid: 196018899,
      bvid: 'BV1fK4y1t7hj',
      qn: VideoQuality.high1080.code,
      tryLook: false,
      videoType: VideoType.ugc,
    );
    if (!result.isSuccess) throw result;
    final item = result.dataOrNull?.dash?.video?.firstOrNull;
    if (item == null) throw const FormatException('响应缺少测速视频流');
    return item;
  }

  Future<void> _startSpeedTest() async {
    try {
      final videoItem = widget.sample ?? await _getSampleUrl();
      await _testAllCdnServices(videoItem);
    } catch (e, stackTrace) {
      if (!mounted) return;
      logger
          .scoped('cdnProbe')
          .w(
            'CDN 测速采样失败',
            error: e.runtimeType,
            stackTrace: stackTrace,
          );
      for (final notifier in _cdnResList) {
        notifier.value ??= '无法获取测速来源，请重试';
      }
    }
  }

  Future<void> _testAllCdnServices(BaseItem videoItem) async {
    for (final item in CDNService.values) {
      if (!mounted) break;
      await _testSingleCdn(item, videoItem);
    }
  }

  Future<void> _testSingleCdn(CDNService item, BaseItem videoItem) async {
    try {
      final cdnUrl = VideoUtils.getCdnUrl(
        videoItem.playUrls,
        defaultCDNService: item,
      );
      await _measureDownloadSpeed(cdnUrl, item.index);
    } catch (e, stack) {
      _handleSpeedTestError(e, stack, item.index);
    }
  }

  late final Dio _dio;

  Future<void> _measureDownloadSpeed(String url, int index) async {
    const maxSize = 8 * 1024 * 1024;
    int downloaded = 0;
    final cancelToken = _tokens[index];
    final watch = Stopwatch()..start();
    try {
      final response = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
        cancelToken: cancelToken,
        onReceiveProgress: (count, total) {
          if (!mounted) return;
          downloaded = count;
          if (watch.elapsedMicroseconds >= 15000000 || downloaded >= maxSize) {
            if (downloaded > 0) {
              _updateSpeedResult(index, downloaded, watch.elapsedMicroseconds);
            }
            cancelToken?.cancel();
          }
        },
      );
      if (!mounted || _cdnResList[index].value != null) return;
      downloaded = response.data?.length ?? downloaded;
      if (downloaded <= 0) throw const FormatException('测速响应为空');
      // 小于采样上限的完整响应也是有效样本，不能一直停留在等待状态。
      _updateSpeedResult(index, downloaded, watch.elapsedMicroseconds);
    } finally {
      watch.stop();
      cancelToken?.cancel();
      _tokens[index] = null;
    }
  }

  void _updateSpeedResult(int index, int downloaded, int duration) {
    if (!mounted) return;
    final speed = (downloaded / (duration > 0 ? duration : 1))
        .toStringAsPrecision(3);
    _cdnResList[index].value = '${speed}MB/s';
  }

  void _handleSpeedTestError(Object error, StackTrace stack, int index) {
    if (!mounted) return;
    _tokens
      ..[index]?.cancel()
      ..[index] = null;
    final item = _cdnResList[index];
    if (item.value != null) return;
    logger
        .scoped('cdnProbe')
        .w(
          'CDN 测速失败',
          error: error.runtimeType,
          stackTrace: stack,
        );
    // Dio 异常正文包含请求地址，签名参数不能进入设置页或日志。
    item.value = switch (error) {
      DioException(response: Response(statusCode: final int code))
          when code >= 400 && code < 500 =>
        '此视频可能无法替换为该CDN',
      DioException(
        type: DioExceptionType.connectionTimeout ||
            DioExceptionType.receiveTimeout ||
            DioExceptionType.sendTimeout,
      ) ||
      TimeoutException() => '测速超时，请重试',
      _ => '测速失败，请重试',
    };
  }

  @override
  Widget build(BuildContext context) {
    return SelectDialog<CDNService>(
      title: 'CDN 设置',
      values: CDNService.values.map((i) => (i, i.desc)).toList(),
      value: VideoUtils.cdnService,
      subtitleBuilder: _cdnSpeedTest
          ? (context, index) {
              final item = _cdnResList[index];
              return ValueListenableBuilder(
                valueListenable: item,
                builder: (context, value, _) {
                  return Text(
                    value ?? '---',
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              );
            }
          : null,
    );
  }
}
