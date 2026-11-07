import 'package:pili_aurora/utils/extension/num_ext.dart';

abstract final class NumUtils {
  static final _numRegExp = RegExp(r'([\d\.]+)([千万亿])?');

  static int parseNum(String numberStr) {
    final match = _numRegExp.firstMatch(numberStr);
    if (match == null) return 0;
    final number = double.tryParse(match.group(1)!);
    if (number == null) return 0;
    final unit = switch (match.group(2)) {
      '千' => 1000,
      '万' => 10000,
      '亿' => 100000000,
      _ => 1,
    };
    final value = number * unit;
    return value.isFinite ? value.toInt() : 0;
  }

  static String numFormat(dynamic number) {
    if (number == null) {
      return '0';
    }
    if (number is String) {
      number = int.tryParse(number) ?? number;
      if (number is String) {
        return number;
      }
    }

    String format(first, second) {
      double result = ((number / first) as double).toPrecision(1);
      int intRes = result.toInt();
      if (result == intRes) {
        return '$intRes$second';
      } else {
        return '$result$second';
      }
    }

    if (number >= 100000000) {
      return format(100000000, '亿');
    } else if (number >= 10000) {
      return format(10000, '万');
    } else {
      return number.toString();
    }
  }

  static String formatPositiveDecimal(int number) {
    if (number < 1000) return number.toString();

    final numStr = number.toString();
    final length = numStr.length;
    final sb = StringBuffer();

    int firstLength = length % 3;
    if (firstLength == 0) firstLength = 3;

    sb.write(numStr.substring(0, firstLength));
    for (int i = firstLength; i < length; i += 3) {
      sb
        ..write(',')
        ..write(numStr.substring(i, i + 3));
    }

    return sb.toString();
  }
}
