import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/app/desktop_theme.dart';
import 'package:pili_aurora/plugin/pl_player/utils/fullscreen.dart';
import 'package:pili_aurora/utils/desktop_window_background.dart';

void main() {
  testWidgets('浅深色背景、全屏期间换主题及退出恢复保持一致', (tester) async {
    const native = MethodChannel('com.alexmercerind/media_kit_video');
    const manager = MethodChannel('window_manager');
    int? erasedColor;
    int? compositionColor;
    final transitions = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(DesktopWindowBackground.channel, (
        call,
      ) async {
        erasedColor = call.arguments as int;
        return null;
      })
      ..setMockMethodCallHandler(manager, (call) async {
        if (call.method == 'setBackgroundColor') {
          final args = call.arguments as Map;
          compositionColor =
              (args['backgroundColorR'] as int) << 16 |
              (args['backgroundColorG'] as int) << 8 |
              args['backgroundColorB'];
        }
        return call.method == 'isMinimized' ? false : null;
      })
      ..setMockMethodCallHandler(native, (call) async {
        transitions.add(call.method);
        expect(erasedColor, compositionColor);
        expect(
          erasedColor,
          call.method == 'Utils.EnterNativeFullscreen' ? 0 : 0xEDE6DC,
        );
        return null;
      });
    addTearDown(() async {
      await exitDesktopFullScreen();
      for (final channel in [
        native,
        manager,
        DesktopWindowBackground.channel,
      ]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    Future<void> theme(
      Brightness brightness,
      Color color, {
      bool player = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            scaffoldBackgroundColor: color,
          ),
          home: DesktopWindowTheme(
            backgroundColor: player ? Colors.black : null,
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await theme(Brightness.light, const Color(0xFFF8F4EF));
    expect(erasedColor, 0xF8F4EF);
    expect(compositionColor, erasedColor);
    await theme(Brightness.dark, const Color(0xFF17191D));
    expect(erasedColor, 0x17191D);
    expect(compositionColor, erasedColor);
    await enterDesktopFullScreen();
    expect(erasedColor, 0);
    await theme(Brightness.light, const Color(0xFFEDE6DC));
    expect(erasedColor, 0, reason: '全屏内切主题不应露出浅色背景');
    await exitDesktopFullScreen();
    expect(erasedColor, 0xEDE6DC);
    expect(compositionColor, erasedColor);
    // 同亮度更换主题色也必须同步，不能只监听 brightness。
    await theme(Brightness.light, const Color(0xFFF1F5FA));
    expect(erasedColor, 0xF1F5FA);
    await theme(Brightness.light, Colors.white, player: true);
    expect(erasedColor, 0, reason: '独立播放窗口始终保持播放器背景');
    expect(compositionColor, erasedColor);
    expect(transitions, [
      'Utils.EnterNativeFullscreen',
      'Utils.ExitNativeFullscreen',
    ]);
  }, skip: !Platform.isWindows);
}
