import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/gesture/immediate_tap_gesture_recognizer.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/desktop_volume_control.dart';

void main() {
  testWidgets('点击视频区域关闭音量面板并保留播放状态，下一次点击正常播放暂停', (tester) async {
    var playing = true;
    var videoTaps = 0;
    final videoTap = ImmediateTapGestureRecognizer(
      onTapUp: (_) {
        playing = !playing;
        videoTaps++;
      },
    );
    addTearDown(videoTap.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: videoTap.addPointer,
            child: Align(
              alignment: Alignment.bottomRight,
              child: DesktopVolumeControl(
                volume: 0.8.obs,
                muted: false.obs,
                maxVolume: 2,
                onChanged: (_) {},
                onMuteChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 200));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(playing, isTrue);
    expect(videoTaps, 0);
    await tester.tapAt(const Offset(400, 200));
    await tester.pumpAndSettle();
    expect(playing, isFalse);
    expect(videoTaps, 1);
  });

  testWidgets('面板打开时画面滚轮和播放器快捷键保持可用', (tester) async {
    final volume = 0.8.obs;
    final muted = false.obs;
    void changeVolume(double value) {
      volume.value = value;
      muted.value = false;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.keyM) {
                muted.toggle();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (_) {
                      changeVolume(
                        desktopVolumeAfterScroll(
                          volume.value,
                          event.scrollDelta.dy,
                          2,
                        ),
                      );
                    },
                  );
                }
              },
              child: Align(
                alignment: Alignment.bottomRight,
                child: DesktopVolumeControl(
                  volume: volume,
                  muted: muted,
                  maxVolume: 2,
                  onChanged: changeVolume,
                  onMuteChanged: (value) => muted.value = value,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(400, 200),
        scrollDelta: Offset(0, -400),
      ),
    );
    await tester.pump();
    expect(volume.value, closeTo(0.9, 0.001));
    expect(find.byType(Slider), findsOneWidget);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(Slider)),
        scrollDelta: const Offset(0, -400),
      ),
    );
    await tester.pump();
    expect(volume.value, closeTo(1.0, 0.001));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(muted.value, isTrue);
    expect(find.byTooltip('取消静音'), findsOneWidget);
    await tester.tap(find.byTooltip('音量：静音'));
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('打开音量面板后滚轮仍调节音量并同步滑块', (tester) async {
    final volume = 0.8.obs;
    final muted = false.obs;
    var opened = 0;
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopVolumeControl(
            volume: volume,
            muted: muted,
            maxVolume: 2,
            onChanged: (value) {
              volume.value = value;
              muted.value = false;
            },
            onMuteChanged: (value) => muted.value = value,
            onOpened: () => opened++,
            onClosed: () => closed++,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(Slider)),
        scrollDelta: const Offset(0, -100),
      ),
    );
    await tester.pump();
    expect(volume.value, closeTo(0.825, 0.001));
    expect(tester.widget<Slider>(find.byType(Slider)).value, volume.value);
    expect(opened, 1);
    await tester.tapAt(const Offset(700, 500));
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
    expect(closed, 1);
  });

  testWidgets('音量菜单支持增强音量、静音与外部状态同步', (tester) async {
    final volume = 0.8.obs;
    final muted = false.obs;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopVolumeControl(
            volume: volume,
            muted: muted,
            maxVolume: 2,
            onChanged: (value) {
              volume.value = value;
              muted.value = false;
            },
            onMuteChanged: (value) => muted.value = value,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pumpAndSettle();
    expect(find.text('80%'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.max, 2);
    slider.onChanged!(1.5);
    await tester.pump();
    expect(find.text('150%'), findsOneWidget);
    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(muted.value, isTrue);
    expect(volume.value, 1.5);
    volume.value = 0.4;
    await tester.pump();
    expect(find.text('40%'), findsOneWidget);
    await tester.tap(find.byTooltip('取消静音'));
    await tester.pump();
    expect(muted.value, isFalse);
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
  });
}
