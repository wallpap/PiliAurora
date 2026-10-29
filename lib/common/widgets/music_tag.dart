import 'package:flutter/material.dart';
import 'package:pili_aurora/common/widgets/video_tag_colors.dart';

class MusicTag extends StatelessWidget {
  const MusicTag({
    super.key,
    required this.text,
    this.onTap,
    this.onLongPress,
  });

  final String text;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    const radius = BorderRadius.all(Radius.circular(8));
    return Material(
      color: VideoTagColors.topicBackground(
        isDark: colorScheme.brightness == Brightness.dark,
        primary: colorScheme.primary,
        primaryContainer: colorScheme.primaryContainer,
      ),
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: radius,
        child: SizedBox(
          height: 32,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.music_note_rounded,
                  size: 17,
                  color: VideoTagColors.topicForeground(
                    isDark: colorScheme.brightness == Brightness.dark,
                    primary: colorScheme.primary,
                    onSurface: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  text,
                  style: TextStyle(
                    color: VideoTagColors.topicForeground(
                      isDark: colorScheme.brightness == Brightness.dark,
                      primary: colorScheme.primary,
                      onSurface: colorScheme.onSurface,
                    ),
                    fontSize: 13,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
