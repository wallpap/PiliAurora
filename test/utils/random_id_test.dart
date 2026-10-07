import 'dart:math';

import 'package:pili_aurora/utils/random_id.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:flutter_test/flutter_test.dart';

class _BytesRandom implements Random {
  _BytesRandom(this.bytes);
  final List<int> bytes;
  var offset = 0;

  @override
  int nextInt(int max) {
    expect(max, 256);
    return bytes[offset++];
  }

  @override
  bool nextBool() => throw UnsupportedError('unused');

  @override
  double nextDouble() => throw UnsupportedError('unused');
}

void main() {
  final pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  test(
    'UUID v4 consumes 16 bytes and changes only version and variant bits',
    () {
      final random = _BytesRandom(List.generate(16, (index) => index));
      expect(
        newUuidV4(random: random),
        '00010203-0405-4607-8809-0a0b0c0d0e0f',
      );
      expect(random.offset, 16);
    },
  );

  test('zero entropy input still has version and variant markers', () {
    expect(
      newUuidV4(random: _BytesRandom(List.filled(16, 0))),
      '00000000-0000-4000-8000-000000000000',
    );
  });

  test('one bits are masked rather than appended', () {
    expect(
      newUuidV4(random: _BytesRandom(List.filled(16, 255))),
      'ffffffff-ffff-4fff-bfff-ffffffffffff',
    );
  });

  test('all four variant low-bit combinations are preserved', () {
    for (final byte in [0x00, 0x10, 0x20, 0x30]) {
      final bytes = List.filled(16, 0)..[8] = byte;
      final uuid = newUuidV4(random: _BytesRandom(bytes));
      expect(pattern.hasMatch(uuid), isTrue);
      expect(int.parse(uuid.substring(19, 21), radix: 16), 0x80 | byte);
    }
  });

  test('secure default produces correctly formatted distinct IDs', () {
    final ids = List.generate(100, (_) => newUuidV4());
    expect(ids.every(pattern.hasMatch), isTrue);
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('Buvid3 preserves uppercase UUID, five digit suffix and infoc', () {
    final value = IdUtils.genBuvid3();
    expect(
      RegExp(
        r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\d{5}infoc$',
      ).hasMatch(value),
      isTrue,
    );
  });
}
