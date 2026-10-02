import 'dart:async';
import 'dart:io';

import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models_new/download/bili_download_entry_info.dart';
import 'package:pili_aurora/services/download/response_adapter.dart';
import 'package:pili_aurora/services/download/stream_writer.dart';
import 'package:pili_aurora/utils/extension/file_ext.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:dio/dio.dart';

class DownloadManager {
  final String url;
  final String path;
  final void Function(int, int)? onReceiveProgress;
  final void Function([Object? error]) onDone;

  DownloadStatus _status = DownloadStatus.downloading;

  DownloadStatus get status => _status;
  final _cancelToken = CancelToken();
  late Future<void> task;
  final Dio? client;

  DownloadManager({
    required this.url,
    required this.path,
    required this.onReceiveProgress,
    required this.onDone,
    this.client,
  }) {
    task = _start();
  }

  Future<void> _start() async {
    int received;

    final file = File(path);
    if (file.existsSync()) {
      received = await file.length();
    } else {
      file.createSync(recursive: true);
      received = 0;
    }

    final sink = file.openWrite(
      mode: received == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend,
    );

    Future<void> onError(Object e, {bool delete = false}) async {
      // 消费者失败时仅取消 Dio 输出订阅不足以释放底层网络源。
      if (!_cancelToken.isCancelled) _cancelToken.cancel(e);
      try {
        await sink.close();
      } catch (_) {}
      if (_status == DownloadStatus.downloading) {
        _status = DownloadStatus.failDownload;
        if (delete && file.existsSync()) {
          await file.tryDel();
        }
      }
      onDone(e);
    }

    Response<ResponseBody> response;
    try {
      response = await (client ?? Request.http11Dio).get<ResponseBody>(
        url.http2https,
        options: Options(
          headers: {'range': 'bytes=$received-'},
          extra: {DownloadResponseAdapter.pauseAwareTimeoutKey: true},
          responseType: ResponseType.stream,
          validateStatus: (status) =>
              status != null &&
              (status == 416 || (status >= 200 && status < 300)),
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      await onError(e, delete: true);
      return;
    }
    final data = response.data!;
    final contentLength = data.contentLength + received;

    if (received == 0) {
      onReceiveProgress?.call(0, contentLength);
    }

    int? last;
    try {
      await writeDownloadStream(
        data.stream,
        sink,
        initialBytes: received,
        onProgress: (received) {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (last != now) {
            last = now;
            onReceiveProgress?.call(received, contentLength);
          }
        },
      );
      await sink.close();
      if (_cancelToken.isCancelled) {
        onDone(
          DioException.requestCancelled(
            requestOptions: response.requestOptions,
            reason: _cancelToken.cancelError,
          ),
        );
        return;
      }
      _status = DownloadStatus.completed;
      onDone();
    } catch (e) {
      await onError(e);
      return;
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
