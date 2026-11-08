/// 必需的输出修正与可选超分共用列表，关闭超分不能清掉输出修正。
String playbackShaderList(
  Iterable<String> shaders, {
  String? baseShaders,
  required String separator,
}) => [
  if (baseShaders != null && baseShaders.isNotEmpty) baseShaders,
  ...shaders,
].join(separator);

/// 重建期间用空输出维持媒体；在恢复视频前提交新 shader，避免再次分配旧图。
Future<void> applyShaderList(
  String shaders, {
  required Future<void> Function(List<String>) command,
  Future<void> Function()? resetRenderer,
}) async {
  final update = [
    'change-list',
    'glsl-shaders',
    shaders.isEmpty ? 'clr' : 'set',
    shaders,
  ];
  if (resetRenderer == null) {
    await command(update);
    return;
  }
  await command(const ['set', 'vo', 'null']);
  try {
    await resetRenderer();
    await command(update);
  } finally {
    await command(const ['set', 'vo', 'libmpv']);
  }
}
