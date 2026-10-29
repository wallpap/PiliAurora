import 'package:flutter/material.dart';

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
      color: colorScheme.secondaryContainer,
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
                  color: colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 3),
                Text(
                  text,
                  style: TextStyle(
                    color: colorScheme.onSecondaryContainer,
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
