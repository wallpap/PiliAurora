import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/prewarm_policy.dart';

void main() {
  bool allowed(
    DanmakuPrewarmPolicy policy, {
    int pending = 4,
    int bytes = 0,
    int nowMs = 0,
  }) => policy.allowImages(
    pending: pending,
    activeBytes: bytes,
    maxActiveBytes: 100,
    nowMs: nowMs,
  );

  test('cold, dense and memory-pressured scenes only prepare layouts', () {
    final policy = DanmakuPrewarmPolicy();
    expect(allowed(policy), isFalse);
    for (var i = 0; i < 8; i++) {
      policy.recordAdmission(true);
    }
    expect(allowed(policy), isTrue);
    expect(allowed(policy, pending: 17), isFalse);
    expect(allowed(policy, bytes: 75), isFalse);
    policy
      ..recordAdmission(false)
      ..recordAdmission(false)
      ..recordAdmission(false);
    expect(allowed(policy), isFalse);
  });

  test('bounded admission history adapts to a new scene and clears safely', () {
    final policy = DanmakuPrewarmPolicy();
    for (var i = 0; i < 32; i++) {
      policy.recordAdmission(false);
    }
    expect(allowed(policy), isFalse);
    for (var i = 0; i < 24; i++) {
      policy.recordAdmission(true);
    }
    expect(policy.samples, 32);
    expect(policy.accepted, 24);
    expect(allowed(policy), isTrue);
    policy.clear();
    expect(policy.samples, 0);
    expect(allowed(policy), isFalse);
  });

  test('slow-frame backoff blocks images but has a bounded lifetime', () {
    final policy = DanmakuPrewarmPolicy();
    for (var i = 0; i < 8; i++) {
      policy.recordAdmission(true);
    }
    policy.backoff(100);
    expect(allowed(policy, nowMs: 599), isFalse);
    expect(allowed(policy, nowMs: 600), isTrue);
    policy.clear();
    for (var i = 0; i < 8; i++) {
      policy.recordAdmission(true);
    }
    expect(allowed(policy), isTrue);
  });
}
