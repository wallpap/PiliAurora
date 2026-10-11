import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';

void main() {
  test('redacts credentials in maps, headers, URLs and quoted text', () {
    final output = jsonEncode(
      DiagnosticRedactor.clean({
        'Cookie': 'session-cookie-test',
        'accessToken': 'token-test-value',
        'message': 'Cookie: first=cookie-test-one; other=cookie-test-two\nAuthorization: Bearer auth-test-value\n{"password": "password-test-value"}\nhttps://user:pwd@host/path?sign=query-test-value',
        'path': r'C:\Users\SensitiveUser\private\file.txt',
        'key': '-----BEGIN PRIVATE KEY-----\nprivate-key-test-value\n-----END PRIVATE KEY-----',
        'credentials': 'apiKey=api-key-test-value\npasswd=passwd-test-value',
        'unixPath': '/home/PrivateUser/file',
      }),
    );
    for (final value in [
      'session-cookie-test',
      'token-test-value',
      'cookie-test-one',
      'cookie-test-two',
      'auth-test-value',
      'password-test-value',
      'query-test-value',
      'SensitiveUser',
      'user:pwd',
      'private-key-test-value',
      'api-key-test-value',
      'passwd-test-value',
      'PrivateUser',
    ]) {
      expect(output, isNot(contains(value)));
    }
    expect(output, contains('https://host/path'));
  });

  test('redacts signed queries in mpv filenames and relative URLs', () {
    final output = DiagnosticRedactor.text(
      "Audio 'track.m4s?e=synthetic-signature&mid=synthetic-user&upsig=synthetic-upsig' (aac)\n"
      '/video/chunk.m4s?token=synthetic-token&expires=123\n'
      '//cdn.example/chunk?sign=synthetic-cdn-signature#fragment',
    );
    for (final value in [
      'synthetic-signature',
      'synthetic-user',
      'synthetic-upsig',
      'synthetic-token',
      'synthetic-cdn-signature',
      '#fragment',
    ]) {
      expect(output, isNot(contains(value)));
    }
    expect(output, contains("Audio 'track.m4s?<redacted>' (aac)"));
    expect(output, contains('/video/chunk.m4s?<redacted>'));
  });

  test('redacting queries retains ordinary diagnostic questions', () {
    expect(
      DiagnosticRedactor.text('GPU ready? paused=true'),
      'GPU ready? paused=true',
    );
  });

  test('nested diagnostic payloads remain bounded', () {
    final large = List.generate(64, (_) => List.filled(64, 'x' * 10000));
    expect(jsonEncode(DiagnosticRedactor.clean(large)).length, lessThan(65536));
  });
}
