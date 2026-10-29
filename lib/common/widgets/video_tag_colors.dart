import 'package:flutter/material.dart';

class VideoTagColors {
  static const opacity = 0.15;

  static Color topicBackground({
    required bool isDark,
    required Color primary,
    required Color primaryContainer,
  }) => (isDark ? primaryContainer : primary).withValues(alpha: opacity);

  static Color topicForeground({
    required bool isDark,
    required Color primary,
    required Color onSurface,
  }) => isDark ? onSurface : primary;

  static Color plainBackground({
    required bool isDark,
    required Color onSurface,
    required Color onSurfaceVariant,
  }) => (isDark ? onSurface : onSurfaceVariant).withValues(alpha: opacity);

  static Color plainForeground({
    required bool isDark,
    required Color onSurface,
    required Color onSurfaceVariant,
  }) => isDark ? onSurface : onSurfaceVariant;
}
