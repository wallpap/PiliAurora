import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/request_failure_policy.dart';

void main() {
  bool expected(
    String url, {
    String method = 'GET',
    DioExceptionType type = DioExceptionType.unknown,
  }) => isExpectedHttpFailure(
    DioException(
      requestOptions: RequestOptions(path: url, method: method),
      type: type,
    ),
  );

  test(
    'resource host matching respects domain boundaries and ignores query text',
    () {
      expect(expected('https://img.hdslb.com/image'), isTrue);
      expect(expected('https://api.github.com/repos/example'), isTrue);
      expect(expected('https://github.com.example.test/path'), isFalse);
      expect(expected('https://nothdslb.com/image'), isFalse);
      expect(
        expected(
          'https://example.test/path?redirect=github.com&task=heartbeat',
        ),
        isFalse,
      );
      expect(
        expected('https://api.bilibili.com/x/player/online/total/extra'),
        isFalse,
      );
    },
  );

  test('custom SponsorBlock endpoints are optional for GET requests', () {
    expect(
      expected('https://custom.example/api/skipSegments?videoID=fixture'),
      isTrue,
    );
    expect(
      expected('https://custom.example/api/skipSegments', method: 'POST'),
      isFalse,
    );
    expect(
      expected('https://custom.example/api/submitSegments', method: 'POST'),
      isFalse,
    );
  });

  test('播放列表上报降噪只匹配实际服务端点', () {
    expect(
      expected(
        'https://api.bilibili.com/x/v1/medialist/history',
        method: 'POST',
      ),
      true,
    );
    expect(
      expected('https://example.test/x/v1/medialist/history', method: 'POST'),
      false,
    );
    expect(
      expected(
        'https://api.bilibili.com/x/v1/medialist/history/extra',
        method: 'POST',
      ),
      false,
    );
  });

  test('active cancellation is expected for any request', () {
    expect(
      expected('https://example.test/video', type: DioExceptionType.cancel),
      isTrue,
    );
    expect(expected('https://example.test/video'), isFalse);
  });
}
