import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 控件避让仅属于本次呈现，不能覆盖用户保存的字幕位置。
class PlayerSubtitleView extends StatefulWidget {
  const PlayerSubtitleView({
    super.key,
    required this.controller,
    required this.configuration,
    required this.controlsVisible,
    required this.enableDragSubtitle,
    required this.onUpdatePadding,
  });

  final VideoController controller;
  final SubtitleViewConfiguration configuration;
  final bool controlsVisible;
  final bool enableDragSubtitle;
  final ValueChanged<EdgeInsets> onUpdatePadding;

  @override
  State<PlayerSubtitleView> createState() => _PlayerSubtitleViewState();
}

class _PlayerSubtitleViewState extends State<PlayerSubtitleView> {
  bool _positionEdited = false;

  @override
  void didUpdateWidget(PlayerSubtitleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controlsVisible != oldWidget.controlsVisible) {
      _positionEdited = false;
    } else if (widget.configuration.padding.bottom !=
        oldWidget.configuration.padding.bottom) {
      _positionEdited = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    var configuration = widget.configuration;
    if (widget.controlsVisible &&
        !_positionEdited &&
        configuration.padding.bottom < 70) {
      configuration = configuration.copyWith(
        padding: configuration.padding.copyWith(bottom: 70),
      );
    }
    return SubtitleView(
      controller: widget.controller,
      configuration: configuration,
      enableDragSubtitle: widget.enableDragSubtitle,
      onUpdatePadding: (padding) {
        setState(() => _positionEdited = true);
        widget.onUpdatePadding(padding);
      },
    );
  }
}
