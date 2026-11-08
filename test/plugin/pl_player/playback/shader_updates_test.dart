import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/shader_updates.dart';

void main() {
  test('关闭或切换超分时保留运行时必需的边界 shader', () async {
    final commands = <List<String>>[];
    for (final effects in [
      ['quality'],
      <String>[],
      ['efficiency'],
    ]) {
      await applyShaderList(
        playbackShaderList(
          effects,
          baseShaders: 'chroma-clamp',
          separator: ';',
        ),
        command: (args) async => commands.add(args),
      );
    }
    expect(commands, [
      ['change-list', 'glsl-shaders', 'set', 'chroma-clamp;quality'],
      ['change-list', 'glsl-shaders', 'set', 'chroma-clamp'],
      ['change-list', 'glsl-shaders', 'set', 'chroma-clamp;efficiency'],
    ]);
    expect(
      playbackShaderList(['quality'], separator: ':'),
      'quality',
    );
    expect(playbackShaderList([], separator: ':'), isEmpty);
  });

  test('新列表先提交再恢复视频输出，重建失败也恢复 vo', () async {
    final events = <String>[];
    Future<void> command(List<String> args) async => events.add(args.join(' '));
    await applyShaderList(
      '',
      command: command,
      resetRenderer: () async {
        events.add('reset');
      },
    );
    expect(events, [
      'set vo null',
      'reset',
      'change-list glsl-shaders clr ',
      'set vo libmpv',
    ]);
    events.clear();
    await expectLater(
      applyShaderList(
        'quality',
        command: command,
        resetRenderer: () => Future<void>.error(StateError('reset failure')),
      ),
      throwsStateError,
    );
    expect(events, ['set vo null', 'set vo libmpv']);
  });

  test('加载准备时直接提交 shader 并清除上一媒体的滤镜', () async {
    final commands = <List<String>>[];
    await applyShaderList(
      'quality',
      command: (args) async => commands.add(args),
    );
    await applyShaderList('', command: (args) async => commands.add(args));
    expect(commands, [
      ['change-list', 'glsl-shaders', 'set', 'quality'],
      ['change-list', 'glsl-shaders', 'clr', ''],
    ]);
  });
}
