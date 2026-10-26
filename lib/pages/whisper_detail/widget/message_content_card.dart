import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/badge.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';

class MessageContentCard extends StatelessWidget {
  const MessageContentCard({
    super.key,
    required this.coverUrls,
    required this.title,
    required this.onTap,
    this.summary,
    this.coverLabel,
    this.footer,
  });

  final List<String> coverUrls;
  final String title;
  final String? summary;
  final String? coverLabel;
  final Widget? footer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final covers = coverUrls.take(3).toList();
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.onInverseSurface,
          borderRadius: Style.mdRadius,
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (covers.isNotEmpty)
                AspectRatio(
                  aspectRatio: Style.aspectRatio16x9,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      fit: StackFit.expand,
                      children: [
                        Row(
                          spacing: 3,
                          children: [
                            for (final url in covers)
                              Expanded(
                                child: NetworkImgLayer(
                                  src: url,
                                  width:
                                      (constraints.maxWidth -
                                          3 * (covers.length - 1)) /
                                      covers.length,
                                  height: constraints.maxHeight,
                                  borderRadius: BorderRadius.zero,
                                ),
                              ),
                          ],
                        ),
                        if (coverLabel?.isNotEmpty ?? false)
                          PBadge(
                            text: coverLabel,
                            type: .gray,
                            left: 6,
                            bottom: 6,
                          ),
                        if (coverUrls.length > 3)
                          PBadge(
                            text: '共 ${coverUrls.length} 张',
                            type: .gray,
                            right: 6,
                            bottom: 6,
                          ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        letterSpacing: 0.6,
                        height: 1.5,
                        color: colors.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (summary?.isNotEmpty ?? false) ...[
                      const SizedBox(height: 4),
                      Text(
                        summary!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          letterSpacing: 0.6,
                          height: 1.5,
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (footer != null) ...[
                      const SizedBox(height: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(6),
                          ),
                        ),
                        child: footer,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
