import 'package:flutter/material.dart';

class TopicTag extends StatelessWidget {
  const TopicTag({super.key, required this.text, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Material(
      color: colorScheme.primaryContainer.withValues(alpha: 0.32),
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: SizedBox(
          height: 32,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 21,
                  height: 21,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    borderRadius: const BorderRadius.all(Radius.circular(6)),
                  ),
                  child: Text(
                    '#',
                    style: TextStyle(
                      color: colorScheme.onPrimary,
                      fontSize: 13,
                      height: 1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  text,
                  style: TextStyle(
                    color: colorScheme.primary,
                    fontSize: 13,
                    height: 1,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 16,
                  color: colorScheme.primary.withValues(alpha: 0.72),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
