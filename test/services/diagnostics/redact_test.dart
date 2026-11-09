import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';

void main() {
  test(
    'long ordinary words stay intact and prefixed token keys stay redacted',
    () {
      final ordinary = 'x' * 65000;
      expect(DiagnosticRedactor.text(ordinary, maxLength: 65536), ordinary);
      final output = DiagnosticRedactor.text(
        'accessToken=prefixed-secret\nx-custom-token: hyphen-secret\n'
        '"token":"quoted-secret"\n${'a' * 12000}Token=long-prefix-secret',
        maxLength: 65536,
      );
      for (final secret in [
        'prefixed-secret',
        'hyphen-secret',
        'quoted-secret',
        'long-prefix-secret',
      ]) {
        expect(output, isNot(contains(secret)));
      }
    },
  );
  test('redaction remains stable through error and toast boundaries', () {
    final once = DiagnosticRedactor.text(
      'GET https://user:pass@example.test:8443/path?access_key=secret#private',
    );
    expect(DiagnosticRedactor.text(once), once);
    expect(once, 'GET https://example.test:8443/path?<redacted>');
  });
  test(
    'credential suffixes retain long prefixes and skip ordinary mentions',
    () {
      final prefix = 'segment-' * 1024;
      final ordinary = '${'buvid' * 512} ordinary=value';
      final input =
          '$ordinary\n'
          '${prefix}ToKeN="token-secret"; safe=1\n'
          'buvidMention buvidOther_3 = buvid-secret; safe=2\n'
          'notBuvid before-token-word my-access_token: token-two; safe=3\n'
          'tokenMention apiKeyMention authCodeMention signMention\n'
          'prefixBuvid_3: device-secret; safe=4';
      expect(
        DiagnosticRedactor.text(input, maxLength: 65536),
        '$ordinary\n'
        '${prefix}ToKeN=<redacted>; safe=1\n'
        'buvidMention buvidOther_3 = <redacted>; safe=2\n'
        'notBuvid before-token-word my-access_token: <redacted>; safe=3\n'
        'tokenMention apiKeyMention authCodeMention signMention\n'
        'prefixBuvid_3: <redacted>; safe=4',
      );
    },
  );
  test('redacts standalone markers without assignment delimiters', () {
    final cases = {
      'bEaReR\tstandalone-secret': 'bEaReR <redacted>',
      'BASIC\u2003standalone-secret': 'BASIC <redacted>',
      '/home/PrivateUser/file': '/<user>/file',
      '/Users/PrivateUser/file': '/<user>/file',
      '-----BEGIN RSA PRIVATE KEY-----\nunclosed-secret': '<private-key>',
      "track.m4s?unknown=standalone-secret": 'track.m4s?<redacted>',
    };
    for (final entry in cases.entries) {
      expect(DiagnosticRedactor.text(entry.key), entry.value);
    }
  });
  test('buvid mentions do not hide overlapping hyphenated credential keys', () {
    for (final key in ['api-key', 'access-key', 'private-key', 'auth-code']) {
      expect(
        DiagnosticRedactor.text('buvid$key=overlap-secret; safe=1'),
        'buvid$key=<redacted>; safe=1',
      );
    }
  });
  test(
    'ordinary keyword mentions do not hide overlapping credential names',
    () {
      for (final key in [
        'secretoken',
        'secreticket',
        'tickeToken',
        'passworDedeUserID',
        'SESSDATApi-key',
        'w_riDedeUserID',
      ]) {
        expect(
          DiagnosticRedactor.text('$key=overlap-secret; safe=1'),
          '$key=<redacted>; safe=1',
        );
      }
    },
  );
  test('redacts signatures, auth parameters and websocket credentials', () {
    final output = jsonEncode(
      DiagnosticRedactor.clean({
        'sign': 'map-sign-secret',
        'w_rid': 'map-wrid-secret',
        'authCode': 'map-auth-secret',
        'message':
            'sign=text-sign-secret\naccessToken=text-token-secret\n'
            'Basic basic-secret\nwss://user:pass@example.com:8443/socket?ticket=ws-secret#fragment-secret',
      }),
    );
    for (final secret in [
      'map-sign-secret',
      'map-wrid-secret',
      'map-auth-secret',
      'text-sign-secret',
      'text-token-secret',
      'basic-secret',
      'user:pass',
      'ws-secret',
      'fragment-secret',
    ]) {
      expect(output, isNot(contains(secret)));
    }
    expect(output, contains('wss://example.com:8443/socket'));
  });

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
