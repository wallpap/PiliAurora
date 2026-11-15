import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/player_subtitle_view.dart';

class _Streams implements PlayerStream {
  final subtitles = StreamController<Subtitle>.broadcast();
  @override
  Stream<Subtitle> get subtitle => subtitles.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  final state = PlayerState(subtitle: const Subtitle.raw('字幕'));
  @override
  final _Streams stream = _Streams();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VideoController implements VideoController {
  @override
  final _Player player = _Player();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _VideoController video;
  setUp(() => video = _VideoController());
  tearDown(() => video.player.stream.subtitles.close());

  Future<void> mount(
    WidgetTester tester, {
    required bool visible,
    required SubtitleViewConfiguration configuration,
    ValueChanged<EdgeInsets>? onUpdate,
  }) => tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: 800,
        height: 450,
        child: PlayerSubtitleView(
          controller: video,
          configuration: configuration,
          controlsVisible: visible,
          enableDragSubtitle: true,
          onUpdatePadding: onUpdate ?? (_) {},
        ),
      ),
    ),
  );

  double displayedPadding(WidgetTester tester) => tester
      .widget<SubtitleView>(find.byType(SubtitleView))
      .configuration
      .padding
      .bottom;

  testWidgets(
    'control avoidance leaves user configuration intact across hide and disposal',
    (
      tester,
    ) async {
      const configuration = SubtitleViewConfiguration(
        padding: EdgeInsets.only(bottom: 24),
      );
      await mount(tester, visible: true, configuration: configuration);
      expect(displayedPadding(tester), 70);
      expect(configuration.padding.bottom, 24);
      await mount(tester, visible: false, configuration: configuration);
      expect(displayedPadding(tester), 24);
      await mount(tester, visible: true, configuration: configuration);
      await tester.pumpWidget(const SizedBox());
      expect(configuration.padding.bottom, 24);
      await mount(tester, visible: false, configuration: configuration);
      expect(displayedPadding(tester), 24);
    },
  );

  testWidgets(
    'drag while controls are visible retains the edited position on hide',
    (
      tester,
    ) async {
      var configuration = const SubtitleViewConfiguration(
        padding: EdgeInsets.only(bottom: 24),
      );
      void onUpdate(EdgeInsets padding) {
        configuration = configuration.copyWith(padding: padding);
      }

      await mount(
        tester,
        visible: true,
        configuration: configuration,
        onUpdate: onUpdate,
      );
      await tester.drag(find.text('字幕'), const Offset(0, 30));
      await tester.pumpAndSettle();
      expect(configuration.padding.bottom, lessThan(70));
      expect(configuration.padding.bottom, isNot(24));
      final edited = configuration.padding.bottom;
      await mount(
        tester,
        visible: true,
        configuration: configuration,
        onUpdate: onUpdate,
      );
      expect(displayedPadding(tester), edited);
      await mount(tester, visible: false, configuration: configuration);
      expect(displayedPadding(tester), edited);
      await mount(tester, visible: true, configuration: configuration);
      expect(displayedPadding(tester), 70);
      expect(configuration.padding.bottom, edited);
    },
  );

  testWidgets(
    'style changes preserve avoidance and explicit position edits win',
    (
      tester,
    ) async {
      var configuration = const SubtitleViewConfiguration(
        padding: EdgeInsets.only(bottom: 24),
      );
      await mount(tester, visible: true, configuration: configuration);
      configuration = configuration.copyWith(
        style: const TextStyle(fontSize: 24),
      );
      await mount(tester, visible: true, configuration: configuration);
      expect(displayedPadding(tester), 70);
      configuration = configuration.copyWith(
        padding: const EdgeInsets.only(bottom: 36),
      );
      await mount(tester, visible: true, configuration: configuration);
      expect(displayedPadding(tester), 36);
      await mount(tester, visible: false, configuration: configuration);
      expect(displayedPadding(tester), 36);
      configuration = configuration.copyWith(
        padding: const EdgeInsets.only(bottom: 100),
      );
      await mount(tester, visible: true, configuration: configuration);
      expect(displayedPadding(tester), 100);
    },
  );
}
