import 'package:material_ui/material_ui.dart';

/// The detail page's overview, comments and playlist share one constrained area.
class VideoDetailPanels extends StatelessWidget {
  const VideoDetailPanels({
    super.key,
    required this.panelBuilders,
    required this.headerBuilder,
    required this.tabbedBuilder,
  }) : assert(panelBuilders.length > 0);

  final List<Widget Function(double width)> panelBuilders;
  final Widget Function(bool sideBySide) headerBuilder;
  final Widget Function(List<Widget> children) tabbedBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Decide from the actual logical constraints, including UI scaling and
      // safe-area padding. Do not divide a narrow window into unreadable panes.
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final minimumPanelWidth = 320 * textScale.clamp(1.0, double.infinity);
      final sideBySide =
          constraints.maxWidth >= minimumPanelWidth * panelBuilders.length;
      final panelWidth = sideBySide
          ? constraints.maxWidth / panelBuilders.length
          : constraints.maxWidth;
      final header = headerBuilder(sideBySide);
      final panels = [for (final builder in panelBuilders) builder(panelWidth)];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          Expanded(
            child: sideBySide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final panel in panels) Expanded(child: panel),
                    ],
                  )
                : tabbedBuilder(panels),
          ),
        ],
      );
    },
  );
}
