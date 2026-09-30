import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/response_decoder.dart';
import 'package:pili_aurora/http/response_transformer.dart';

Future<dynamic> _transform(
  List<int> bytes, {
  String? encoding,
  String contentType = 'application/json',
  ResponseType responseType = ResponseType.json,
  ResponseDecoder? decoder,
}) => CompressedResponseTransformer().transformResponse(
  RequestOptions(
    path: '/test',
    responseType: responseType,
    responseDecoder: decoder,
  ),
  ResponseBody(
    Stream.value(Uint8List.fromList(bytes)),
    200,
    headers: {
      'content-type': [contentType],
      if (encoding != null) 'content-encoding': [encoding],
    },
  ),
);

void main() {
  test(
    'Dio serializes requests and delivers compressed typed JSON responses',
    () async {
      final adapter = _JsonAdapter();
      final dio = Dio()
        ..httpClientAdapter = adapter
        ..transformer = CompressedResponseTransformer();
      try {
        final response = await dio.post<Map<String, dynamic>>(
          'https://example.test/api',
          data: {'payload': '请求'},
          options: Options(contentType: Headers.jsonContentType),
        );
        expect(adapter.requestBody, '{"payload":"请求"}');
        expect(response.data, {'result': '响应'});
      } finally {
        dio.close(force: true);
      }
    },
  );
  test('plain and gzip JSON decode to the same Unicode values', () async {
    final source = utf8.encode('{"title":"弹幕✓","items":[1,2,3]}');
    const expected = {
      'title': '弹幕✓',
      'items': [1, 2, 3],
    };
    expect(await _transform(source), expected);
    expect(
      await _transform(
        const GZipEncoder().encodeBytes(source),
        encoding: 'gzip',
      ),
      expected,
    );
  });

  test(
    'highly compressed large JSON is decoded in the background path',
    () async {
      final source = utf8.encode(jsonEncode({'text': '弹幕' * 30000}));
      final gzip = const GZipEncoder().encodeBytes(source);
      expect(gzip.length, lessThan(50 * 1024));
      expect(ResponseBodyDecoder.shouldUseIsolate(gzip, 'gzip'), isTrue);
      expect(await _transform(gzip, encoding: 'gzip'), {'text': '弹幕' * 30000});
      expect(await _transform(source), {'text': '弹幕' * 30000});
    },
  );

  test('Brotli text and empty responses retain text semantics', () async {
    // 合法的 Brotli 非压缩块，内容为 ASCII time。
    const brotli = [0x8b, 1, 0x80, 116, 105, 109, 101, 3];
    expect(
      await _transform(brotli, encoding: 'br', contentType: 'text/plain'),
      'time',
    );
    expect(await _transform([6], encoding: 'br'), '');
    expect(await _transform([]), '');
    expect(await _transform([], contentType: 'text/plain'), '');
  });

  test(
    'JSON MIME types, plain text and malformed UTF-8 match existing behavior',
    () async {
      final json = utf8.encode('{"ok":true}');
      expect(await _transform(json, contentType: 'application/problem+json'), {
        'ok': true,
      });
      expect(await _transform(json, contentType: 'text/plain'), '{"ok":true}');
      expect(
        await _transform(json, responseType: ResponseType.plain),
        '{"ok":true}',
      );
      expect(await _transform([0xff], contentType: 'text/plain'), '\uFFFD');
    },
  );

  test('bytes and streams bypass compression and decoding', () async {
    const bytes = [1, 2, 3];
    expect(
      await _transform(
        bytes,
        encoding: 'gzip',
        responseType: ResponseType.bytes,
      ),
      bytes,
    );
    final result = await _transform(
      bytes,
      encoding: 'gzip',
      responseType: ResponseType.stream,
    ) as ResponseBody;
    expect(await result.stream.expand((chunk) => chunk).toList(), bytes);
  });

  test('custom sync and async decoders keep control of conversion', () async {
    expect(await _transform([0xff], decoder: (_, _, _) => '{"custom":true}'), {
      'custom': true,
    });
    expect(
      await _transform([
        0xff,
      ], decoder: (_, _, _) => Future.value('{"async":true}')),
      {'async': true},
    );
  });

  test(
    'invalid JSON, invalid compression and response stream errors propagate',
    () async {
      await expectLater(
        _transform(utf8.encode('{broken')),
        throwsFormatException,
      );
      await expectLater(
        _transform([1, 2, 3], encoding: 'gzip'),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        _transform([1, 2, 3], encoding: 'br'),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        CompressedResponseTransformer().transformResponse(
          RequestOptions(path: '/test'),
          ResponseBody(Stream.error(StateError('network failed')), 200),
        ),
        throwsStateError,
      );
    },
  );
}

class _JsonAdapter implements HttpClientAdapter {
  String? requestBody;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestBody = await utf8.decodeStream(requestStream!);
    return ResponseBody.fromBytes(
      const GZipEncoder().encodeBytes(utf8.encode('{"result":"响应"}')),
      200,
      headers: {
        'content-type': ['application/json'],
        'content-encoding': ['gzip'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
