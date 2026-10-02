import 'dart:math' as math;

class DanmakuTrajectory {
  const DanmakuTrajectory({
    required this.startMs,
    required this.endMs,
    required this.startX,
    required this.y,
    required this.width,
    required this.height,
    required this.velocity,
  });

  final double startMs;
  final double endMs;
  final double startX;
  final double y;
  final double width;
  final double height;
  final double velocity;

  double xAt(double milliseconds) =>
      startX - (milliseconds - startMs) * velocity;

  bool overlapsDuring(DanmakuTrajectory other, {double padding = 0}) {
    if (y + height + padding <= other.y - padding ||
        other.y + other.height + padding <= y - padding) {
      return false;
    }
    final start = math.max(startMs, other.startMs);
    final end = math.min(endMs, other.endMs);
    if (end <= start) return false;
    final relativeStart = xAt(start) - other.xAt(start);
    final relativeEnd = xAt(end) - other.xAt(end);
    return math.max(relativeStart, relativeEnd) > -width - padding * 2 &&
        math.min(relativeStart, relativeEnd) < other.width + padding * 2;
  }

  bool canBeFollowedBy(
    double nextWidth,
    double nextVelocity,
    double viewWidth,
    double milliseconds,
  ) {
    final right = xAt(milliseconds) + width;
    return right <= viewWidth &&
        (nextVelocity <= velocity ||
            right * nextVelocity <= viewWidth * velocity);
  }
}
