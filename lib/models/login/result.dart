/// 登录协议既可能返回身份信息，也可能要求极验或手机验证。
/// 失败仍保留验证所需的数据，页面无需猜测 status/msg 等字典字段的类型。
class LoginResult {
  LoginResult._({
    required this.isSuccess,
    required this.code,
    required this.message,
    required Map<String, dynamic> data,
  }) : data = Map.unmodifiable(data);

  factory LoginResult.fromResponse(
    Object? response, {
    required bool Function(Map<String, dynamic>) validate,
    bool smsChallenge = false,
  }) {
    const malformed = '登录服务返回的数据不完整，请重试';
    if (response is! Map) return LoginResult.failure(malformed);
    final code = response['code'];
    final message = response['message'];
    final payload = response['data'];
    final data = payload is Map<String, dynamic>
        ? payload
        : const <String, dynamic>{};
    if (code == 0) {
      final recaptchaUrl = data['recaptcha_url'];
      if (smsChallenge && recaptchaUrl is String && recaptchaUrl.isNotEmpty) {
        return LoginResult._(
          isSuccess: false,
          code: 0,
          message: '请先完成验证',
          data: data,
        );
      }
      if (!validate(data)) return LoginResult.failure(malformed);
      return LoginResult._(
        isSuccess: true,
        code: 0,
        message: '',
        data: data,
      );
    }
    return LoginResult._(
      isSuccess: false,
      code: code is int ? code : null,
      message: message is String && message.trim().isNotEmpty
          ? message
          : '登录请求失败，请重试',
      data: data,
    );
  }

  factory LoginResult.failure(String message) => LoginResult._(
    isSuccess: false,
    code: null,
    message: message,
    data: const {},
  );

  final bool isSuccess;
  final int? code;
  final String message;
  final Map<String, dynamic> data;
}
