import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:pili_aurora/grpc/bilibili/rpc.pb.dart';
import 'package:pili_aurora/grpc/decode_policy.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts/account_manager/account_mgr.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:protobuf/protobuf.dart' show GeneratedMessage;

/// 传输都使用 POST，必须由调用方声明是否写入，不能按账号或 HTTP 方法推断。
enum GrpcCallKind { query, mutation }

/// 输出在首次展开前按获配上限分配；gzip 尾部长度仅用于预约，
/// 实际解压仍逐块核对，损坏或伪造的长度无法扩大工作集。
class _BoundedDecodeSink implements Sink<List<int>> {
  _BoundedDecodeSink(int limit) : _buffer = Uint8List(limit);

  final Uint8List _buffer;
  int _length = 0;

  Uint8List get bytes => Uint8List.sublistView(_buffer, 0, _length);

  @override
  void add(List<int> data) {
    final next = _length + data.length;
    if (next > _buffer.length) {
      throw DanmakuWorkTooLarge(next, _buffer.length);
    }
    _buffer.setRange(_length, next, data);
    _length = next;
  }

  @override
  void close() {}
}

abstract final class GrpcReq {
  static const _gzipMinLength = 64;

  static final options = Options(
    contentType: 'application/grpc',
    responseType: ResponseType.bytes,
  );

  static Uint8List compressProtobuf(Uint8List proto) {
    final compress = proto.length > _gzipMinLength;
    if (compress) {
      proto = const GZipEncoder().encodeBytes(proto);
    }
    return Uint8List(5 + proto.length)
      ..[0] = compress ? 1 : 0
      ..buffer.asByteData(1, 4).setInt32(0, proto.length, Endian.big)
      ..setAll(5, proto);
  }

  static Uint8List decompressProtobuf(Uint8List data, {int? maxDecodedBytes}) {
    if (data.length < 5 || (data[0] != 0 && data[0] != 1)) {
      throw const FormatException('gRPC 帧头无效');
    }
    final length = ByteData.sublistView(data, 1, 5).getInt32(0, Endian.big);
    if (length < 0 || length != data.length - 5) {
      throw const FormatException('gRPC 帧长度越界');
    }

    if (data[0] == 1) {
      if (maxDecodedBytes != null) {
        final output = _BoundedDecodeSink(maxDecodedBytes);
        final decoder = gzip.decoder.startChunkedConversion(output);
        // 分片投喂，避免一次输入在底层解码器中积累整份展开结果。
        for (var offset = 5; offset < length + 5; offset += 16384) {
          final end = (offset + 16384).clamp(0, length + 5);
          decoder.add(Uint8List.sublistView(data, offset, end));
        }
        decoder.close();
        return output.bytes;
      }
      return const GZipDecoder().decodeBytes(
        Uint8List.sublistView(data, 5, length + 5),
      );
    } else {
      if (maxDecodedBytes != null && length > maxDecodedBytes) {
        throw DanmakuWorkTooLarge(length, maxDecodedBytes);
      }
      return Uint8List.sublistView(data, 5, length + 5);
    }
  }

  static (LoadingState<T>, int) _parse<T>(
    (Uint8List, T Function(Uint8List), int?, int Function(Uint8List)?, int?)
    args,
  ) {
    try {
      final data = decompressProtobuf(args.$1, maxDecodedBytes: args.$3);
      final storage = args.$4?.call(data) ?? 0;
      if (args.$5 case final limit?) {
        final bytes =
            2 * args.$1.length + 2 * (args.$3 ?? data.length) + 2 * storage;
        if (bytes > limit) throw DanmakuWorkTooLarge(bytes, limit);
      }
      final grpcResponse = args.$2(data);
      return (Success(grpcResponse), storage);
    } catch (e, s) {
      return (
        Error(
          e is DanmakuWorkTooLarge ? '弹幕响应超过处理预算' : '响应数据解析失败，请重试',
          cause: e,
          stackTrace: s,
        ),
        0,
      );
    }
  }

  static Future<LoadingState<T>> request<T extends GeneratedMessage>(
    String url,
    GeneratedMessage request,
    T Function(Uint8List) grpcParser, {
    required GrpcCallKind kind,
    bool isolate = false,
    bool danmakuWork = false,
    int Function(Uint8List)? inspectDecoded,
    DanmakuWorkToken? workToken,
    Future<void> Function(T, DanmakuWorkLease)? consume,
    Account? account,
  }) async {
    final requestOptions = options.copyWith(
      extra: {
        ...?options.extra,
        'account': ?account,
        'noRetry': kind == GrpcCallKind.mutation,
      },
    );
    Request();
    final payload = compressProtobuf(request.writeToBuffer());
    final Response response;
    try {
      response = await Request.dio.post<dynamic>(
        HttpString.appBaseUrl + url,
        data: payload,
        options: requestOptions,
      );
    } on DioException catch (error, stack) {
      if (kind == GrpcCallKind.mutation) {
        return UnknownResult(cause: error, stackTrace: stack);
      }
      return Error(
        await AccountManager.dioError(error),
        code: error.response?.statusCode,
        cause: error,
        stackTrace: stack,
      );
    }

    if (response.headers.value('Grpc-Status') == '0') {
      final data = response.data;
      if (data is Uint8List) {
        final background = isolate && GrpcDecodePolicy.shouldUseIsolate(data);
        final decodeDetails = <String, Object?>{
          'bytes': data.length,
          'background': background,
        };
        final operation = Diagnostics.instance.begin(
          'grpcDecode',
          '解析 gRPC 响应',
          details: decodeDetails,
        );
        try {
          final decodedLimit = danmakuWork
              ? GrpcDecodePolicy.estimatedDecodedBytes(data)
              : null;
          if (decodedLimit != null &&
              decodedLimit > DanmakuProcessingBudget.maxDecodedBytes) {
            throw DanmakuWorkTooLarge(
              decodedLimit,
              DanmakuProcessingBudget.maxDecodedBytes,
            );
          }
          final parseArgs = (
            data,
            grpcParser,
            decodedLimit,
            inspectDecoded,
            danmakuWork ? DanmakuWorkQuota.instance.maxBytes : null,
          );
          Future<(LoadingState<T>, int)> decode() async {
            final watch = operation == null ? null : (Stopwatch()..start());
            try {
              return background
                  ? await compute(_parse<T>, parseArgs)
                  : _parse<T>(parseArgs);
            } finally {
              if (watch != null) {
                decodeDetails['parseMs'] = watch.elapsedMicroseconds / 1000;
              }
            }
          }

          final admission = operation == null ? null : (Stopwatch()..start());
          final result = danmakuWork
              ? await DanmakuWorkQuota.instance.runWithLease(
                  DanmakuWorkQuota.instance.maxBytes,
                  (lease) async {
                    if (admission != null) {
                      decodeDetails['quotaWaitMs'] =
                          admission.elapsedMicroseconds / 1000;
                    }
                    final (decoded, storage) = await decode();
                    if (workToken?.isCancelled ?? false) {
                      throw const DanmakuWorkCancelled();
                    }
                    if (decoded case Success(:final response)) {
                      final watch = operation == null
                          ? null
                          : (Stopwatch()..start());
                      await consume?.call(
                        response,
                        lease.retaining(
                          // compute 已结束；下一阶段保留主 isolate 的输入与解析结果。
                          data.length + decodedLimit! + storage,
                        ),
                      );
                      if (workToken?.isCancelled ?? false) {
                        throw const DanmakuWorkCancelled();
                      }
                      if (watch != null) {
                        // 包含消费阶段的后台任务等待，不能当作主 isolate CPU 时间。
                        decodeDetails['consumeMs'] =
                            watch.elapsedMicroseconds / 1000;
                      }
                    }
                    return decoded;
                  },
                  token: workToken,
                  waitingBytes: data.length + 256,
                )
              : (await decode()).$1;
          operation?.finish(error: result is Error ? result.errMsg : null);
          if (result case Error(:final cause?, :final stackTrace?)) {
            final failure = cause is DanmakuWorkTooLarge
                ? result
                : Error.fromException(cause, stackTrace);
            return kind == GrpcCallKind.mutation
                ? UnknownResult(cause: cause, stackTrace: stackTrace)
                : failure;
          }
          return result;
        } on DanmakuWorkBusy catch (error, stack) {
          operation?.finish(error: '弹幕处理等待额度已满');
          return Error('弹幕处理等待额度已满', cause: error, stackTrace: stack);
        } on DanmakuWorkCancelled catch (error, stack) {
          operation?.finish(error: '弹幕任务已失效');
          return Error('弹幕任务已失效', cause: error, stackTrace: stack);
        } on DanmakuWorkTooLarge catch (error, stack) {
          operation?.finish(error: '弹幕响应超过处理预算');
          return Error('弹幕响应超过处理预算', cause: error, stackTrace: stack);
        } catch (error) {
          operation?.finish(error: error.runtimeType);
          rethrow;
        } finally {
          operation?.finish();
        }
      } else {
        const cause = FormatException('gRPC 响应不是字节数据');
        return kind == GrpcCallKind.mutation
            ? const UnknownResult(cause: cause)
            : const Error('响应数据解析失败，请重试', cause: cause);
      }
    } else {
      return _statusFailure(response, kind);
    }
  }

  static Error _statusFailure(Response response, GrpcCallKind kind) {
    final status = int.tryParse(response.headers.value('Grpc-Status') ?? '');
    int? businessCode;
    String? message;
    Object? cause;
    StackTrace? stack;
    try {
      final details = response.headers.value('Grpc-Status-Details-Bin');
      if (details != null && details.isNotEmpty) {
        final outer = Status.fromBuffer(
          base64Decode(base64.normalize(details)),
        );
        message = outer.message;
        final nested = outer.details
            .where(
              (detail) =>
                  detail.typeUrl.isEmpty ||
                  detail.typeUrl.endsWith('/bilibili.rpc.Status') ||
                  detail.typeUrl.endsWith('/google.rpc.Status'),
            )
            .map((detail) => Status.fromBuffer(detail.value))
            .toList();
        businessCode = nested
            .where((detail) => detail.code != 0)
            .firstOrNull
            ?.code;
        final messages = nested
            .map((detail) => detail.message)
            .where((text) => text.trim().isNotEmpty)
            .toList();
        message = messages.isNotEmpty ? messages.join('\n') : outer.message;
      }
    } catch (error, trace) {
      cause = error;
      stack = trace;
    }
    if (message == null || message.trim().isEmpty) {
      try {
        message = Uri.decodeComponent(
          response.headers.value('Grpc-Message') ?? '',
        );
      } catch (error, trace) {
        cause ??= error;
        stack ??= trace;
      }
    }
    final failure = Error(
      message?.trim().isNotEmpty == true
          ? message
          : status != null && status > 0 && status <= 16
          ? 'gRPC 请求失败（状态码：$status）'
          : 'gRPC 响应缺少有效状态，请重试',
      code: businessCode ?? status,
      cause: cause,
      stackTrace: stack,
    );
    // 没有明确业务拒绝时，取消、超时、内部及传输故障可能发生在写入完成之后。
    return kind == GrpcCallKind.mutation &&
            businessCode == null &&
            !const {3, 5, 6, 7, 8, 9, 10, 11, 12, 16}.contains(status)
        ? UnknownResult(cause: failure, stackTrace: stack)
        : failure;
  }

  // static Future playerOnline({
  //   int aid = 0,
  //   int cid = 0,
  // }) {
  //   return _request(
  //       GrpcUrl.playerOnline,
  //       PlayerOnlineReq(aid: Int64(aid), cid: Int64(cid), playOpen: true),
  //       PlayerOnlineReply.fromBuffer,
  //       onSuccess: (response) => response.totalNumberText);
  // }

  // static Future popular(int idx) {
  //   return _request(GrpcUrl.popular, PopularResultReq(idx: Int64(idx)),
  //       PopularReply.fromBuffer, onSuccess: (response) {
  //     response.items.retainWhere((item) => item.smallCoverV5.base.goto == 'av');
  //     return {'status': true, 'data': response.items};
  //   });
  // }
}
