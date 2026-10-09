import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/src/player/native/player/seek_command.dart';

void main() {
  test('Android progress seeks use keyframes instead of exact decode', () {
    expect(
      nativeSeekCommand(
        const Duration(seconds: 20, milliseconds: 500),
        keyframe: true,
      ),
      ['seek', '20.500', 'absolute+keyframes'],
    );
  });

  test('other platforms retain exact absolute seeks', () {
    expect(
      nativeSeekCommand(const Duration(milliseconds: 1250)),
      ['seek', '1.250', 'absolute'],
    );
  });
}
