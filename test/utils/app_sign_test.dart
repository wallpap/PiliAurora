import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/app_sign.dart';

void main() {
  for (final value in ['', '普通签名 & = +', 'normal']) {
    test('app signature matches form encoding for "$value"', () {
      final params = <String, dynamic>{'field': value};
      AppSign.appSign(params, appkey: 'fixture-key', appsec: 'fixture-secret');
      final query =
          'appkey=fixture-key&field=${Uri.encodeComponent(value)}'
          '&ts=${params['ts']}';
      expect(
        params['sign'],
        md5.convert(utf8.encode('${query}fixture-secret')).toString(),
      );
    });
  }
}
