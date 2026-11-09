import 'package:dio/dio.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/accounts/account_manager/account_mgr.dart';

enum ApiCallKind { query, mutation }

typedef ApiResponseDecoder<T> = T Function(Map<String, dynamic> response);

String _message(Map<String, dynamic> body, Map<int, String> messages) {
  final code = body['code'] as int;
  if (messages[code] case final message?) {
    return Error(message, code: code).toString();
  }
  for (final field in ['message', 'msg']) {
    if (body[field] case final String message when message.trim().isNotEmpty) {
      return Error(message, code: code).toString();
    }
  }
  return Error(null, code: code).toString();
}

/// 只处理 code/message/data 风格的业务协议；具体字段与可空语义由领域解码器决定。
LoadingState<T> decodeApiResponse<T>(
  Response<dynamic> response, {
  required ApiCallKind kind,
  required ApiResponseDecoder<T> decode,
  Map<int, String> errorMessages = const {},
}) {
  try {
    final body = response.data;
    if (body is! Map<String, dynamic> || body['code'] is! int) {
      throw const FormatException('业务响应缺少整数状态码');
    }
    final code = body['code'] as int;
    if (code != 0) return Error(_message(body, errorMessages), code: code);
    final status = response.statusCode;
    if (status != null && (status < 200 || status >= 300)) {
      throw FormatException('业务成功码与 HTTP $status 冲突');
    }
    return Success(decode(body));
  } catch (error, stackTrace) {
    final failure = Error.fromException(error, stackTrace);
    return kind == ApiCallKind.mutation
        ? UnknownResult(cause: error, stackTrace: stackTrace)
        : failure;
  }
}

Future<Error> decodeApiException(
  DioException error,
  StackTrace stackTrace, {
  required ApiCallKind kind,
  Map<int, String> errorMessages = const {},
}) async {
  // HTTP 失败或 Cookie 持久化失败也可能携带明确的业务拒绝，不能丢失业务码。
  final body = error.response?.data;
  if (body is Map<String, dynamic> &&
      body['code'] is int &&
      body['code'] != 0) {
    return Error(
      _message(body, errorMessages),
      code: body['code'] as int,
      cause: error,
      stackTrace: stackTrace,
    );
  }
  // 传输层不能证明写入未执行；取消、断连与损坏响应均须先核对远端状态。
  if (kind == ApiCallKind.mutation) {
    return UnknownResult(cause: error, stackTrace: stackTrace);
  }
  if (error.error is FormatException) {
    return Error.fromException(error, stackTrace);
  }
  return Error(
    await AccountManager.dioError(error),
    code: error.response?.statusCode,
    cause: error,
    stackTrace: stackTrace,
  );
}
