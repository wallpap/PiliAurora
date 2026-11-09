import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';

void main() {
  test('仅成功结果提供数据，失败保留原错误，加载中明确拒绝读取', () {
    expect(const Success(42).data, 42);
    expect(const Success<void>(null).isSuccess, isTrue);
    expect(const Success<int?>(null).dataOrNull, isNull);
    const failure = Error('服务器拒绝请求', code: -1);
    expect(failure, isA<Exception>());
    expect(() => failure.data, throwsA(same(failure)));
    expect(() => LoadingState<int>.loading().data, throwsStateError);
  });

  test('缺失错误文案时始终提供可读提示', () {
    for (final message in <String?>[null, '', '  ']) {
      expect(Error(message).toString(), '请求失败，请稍后重试');
      expect(Error(message, code: -403).toString(), contains('-403'));
    }
  });

  test('解析错误保留原因和堆栈，展示内容不拼接协议正文', () {
    const cause = FormatException('synthetic response body');
    final stack = StackTrace.current;
    final result = Error.fromException(cause, stack);
    expect(result.cause, same(cause));
    expect(result.stackTrace, same(stack));
    expect(result.toString(), '响应数据解析失败，请重试');
    expect(result.toString(), isNot(contains('synthetic')));
  });
}
