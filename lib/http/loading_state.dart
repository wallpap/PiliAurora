import 'package:flutter/foundation.dart' show immutable;
import 'package:pili_aurora/services/diagnostics/redact.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 本地保留的操作结果码，不是远端业务码；服务端可能已完成本次写入。
const unknownOperationResultCode = -10001;

sealed class LoadingState<T> {
  const LoadingState();

  factory LoadingState.loading() => const Loading._internal();

  bool get isSuccess => this is Success<T>;

  T get data => switch (this) {
    Success(:final response) => response,
    Error error => throw error,
    Loading() => throw StateError('数据尚未加载完成，请先检查加载状态'),
  };

  T? get dataOrNull => switch (this) {
    Success(:final response) => response,
    _ => null,
  };

  Future<void> toast() => SmartDialog.showToast(toString());
}

class Loading extends LoadingState<Never> {
  const Loading._internal();

  @override
  String toString() {
    return 'ApiException: loading';
  }
}

@immutable
class Success<T> extends LoadingState<T> {
  final T response;
  const Success(this.response);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is Success<T>) {
      return response == other.response;
    }
    return false;
  }

  @override
  int get hashCode => response.hashCode;
}

@immutable
class Error extends LoadingState<Never> implements Exception {
  final int? code;
  final String? errMsg;
  const Error(this.errMsg, {this.code, this.cause, this.stackTrace});

  /// 协议解析失败保留原因供调用方诊断，界面只展示可操作的提示。
  factory Error.fromException(Object cause, StackTrace stackTrace) {
    const message = '响应数据解析失败，请重试';
    // 异常正文可能包含响应数据；日志只记录类型与位置，避免写入凭据。
    logger.e(message, error: cause.runtimeType, stackTrace: stackTrace);
    return Error(message, cause: cause, stackTrace: stackTrace);
  }

  final Object? cause;
  final StackTrace? stackTrace;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is Error) {
      return errMsg == other.errMsg && code == other.code;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(errMsg, code);

  @override
  String toString() {
    final message = errMsg?.trim();
    return DiagnosticRedactor.text(
      message != null && message.isNotEmpty
          ? message
          : code != null
          ? '请求失败（错误码：$code）'
          : '请求失败，请稍后重试',
    );
  }
}

/// 响应未能确认写入结果，调用方应先核对远端状态，不能直接重发。
class UnknownResult extends Error {
  const UnknownResult({super.cause, super.stackTrace})
    : super(
        '操作结果待确认，请先核对后再操作',
        code: unknownOperationResultCode,
      );
}
