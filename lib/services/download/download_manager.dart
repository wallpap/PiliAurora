import 'dart:async';
import 'dart:io';

import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/services/download/response_adapter.dart';
import 'package:pili_aurora/services/download/stream_writer.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:dio/dio.dart';

/// 传输单条媒体流，并按已有文件长度请求剩余字节以支持续传。
///
/// 文件 sink 消费速度会反压响应流；调用方负责在暂停、删除和结束时统一
/// 管理任务生命周期。
class DownloadManager {
  final String url;
  final String path;
  final void Function(int, int)? onReceiveProgress;
  final void Function([Object? error]) onDone;

  DownloadStatus _status = DownloadStatus.downloading;

  DownloadStatus get status => _status;
  final _cancelToken = CancelToken();
  late Future<void> task;
  final Dio client;

  DownloadManager({
    required this.url,
    required this.path,
    required this.onReceiveProgress,
    required this.onDone,
    required this.client,
  }) {
    task = _start();
  }

  Future<void> _start() async {
    IOSink? sink;
    try {
      final file = File(path);
      final received = file.existsSync() ? file.lengthSync() : 0;
      if (!file.existsSync()) file.createSync(recursive: true);
      sink = file.openWrite(
        mode: received == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend,
      );
      final response = await client.get<ResponseBody>(
        url.http2https,
        options: Options(
          headers: {'range': 'bytes=$received-'},
          extra: {DownloadResponseAdapter.pauseAwareTimeoutKey: true},
          responseType: ResponseType.stream,
          validateStatus: (status) =>
              status == 200 || status == 206 || status == 416,
        ),
        cancelToken: _cancelToken,
      );
      final data = response.data!;
      final range = response.headers.value('content-range');
      final partial = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$')
          .firstMatch(range ?? '');
      final rangeStart = partial == null ? -1 : int.parse(partial[1]!);
      final rangeEnd = partial == null ? -1 : int.parse(partial[2]!);
      final declaredTotal = partial == null ? null : int.tryParse(partial[3]!);
      // 不匹配的范围不能追加到已有媒体；416 只有长度一致才表示已完成。
      if ((received > 0 && response.statusCode == 200) ||
          (response.statusCode == 206 &&
              (partial == null ||
                  rangeStart != received ||
                  rangeEnd < rangeStart ||
                  (data.contentLength >= 0 &&
                      data.contentLength != rangeEnd - rangeStart + 1))) ||
          (response.statusCode == 416 &&
              (received == 0 || range != 'bytes */$received'))) {
        throw StateError('服务器未返回匹配的下载范围，已保留本地文件');
      }
      final total = response.statusCode == 416
          ? received
          : declaredTotal ??
              (data.contentLength >= 0 ? received + data.contentLength : 0);
      onReceiveProgress?.call(received, total);
      var written = received;
      if (response.statusCode == 416) {
        await data.stream.drain<void>();
      } else {
        int? last;
        written = await writeDownloadStream(
          data.stream,
          sink,
          initialBytes: received,
          onProgress: (count) {
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            if (last != now) {
              last = now;
              onReceiveProgress?.call(count, total);
            }
          },
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (_cancelToken.isCancelled) throw _cancelToken.cancelError!;
      if (response.statusCode != 416 && total <= 0) {
        throw StateError('服务器未声明可验证的下载长度，已保留本地文件');
      }
      if (total > 0 && written != total) {
        throw StateError('下载长度与服务器声明不一致，已保留本地文件');
      }
      onReceiveProgress?.call(written, written);
      _status = DownloadStatus.completed;
      onDone();
    } catch (error) {
      // 保留所有已写入字节；失败与暂停都等待文件关闭后再通知状态所有者。
      if (!_cancelToken.isCancelled) _cancelToken.cancel(error);
      try {
        await sink?.close();
      } catch (_) {}
      if (_status == DownloadStatus.downloading) {
        _status = DownloadStatus.failDownload;
      }
      onDone(error);
    }
  }

  Future<void> cancel({required bool isDelete}) {
    if (!isDelete && _status == DownloadStatus.downloading) {
      _status = DownloadStatus.pause;
    }
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel();
    }
    return task;
  }
}
