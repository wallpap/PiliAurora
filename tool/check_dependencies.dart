import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// 只读取工作区文件，不修改文件、访问网络或改变进程退出状态。
List<String> checkDependencyPolicy(String workspacePath) {
  final checker = _DependencyPolicyChecker(workspacePath)..check();
  return List.unmodifiable(checker.issues);
}

void main(List<String> arguments) {
  if (arguments.length > 1) {
    stderr.writeln('用法：dart run tool/check_dependencies.dart [工作区路径]');
    exitCode = 64;
    return;
  }
  final workspace = arguments.isEmpty
      ? Directory.current.path
      : arguments.single;
  final issues = checkDependencyPolicy(workspace);
  if (issues.isEmpty) {
    stdout.writeln('依赖维护验收通过：无 Git 依赖，本地版本、来源和许可证一致。');
    return;
  }
  stderr.writeln('依赖维护验收失败（${issues.length} 项）：');
  for (final issue in issues) {
    stderr.writeln('  - $issue');
  }
  exitCode = 1;
}

class _DependencyPolicyChecker {
  _DependencyPolicyChecker(String workspacePath)
    : workspace = path.normalize(path.absolute(workspacePath));

  // 修订号允许递增；与上一提交的单调性需在维护 review 中核对。
  static final _revisionSuffix = RegExp(r'\+piliaurora\.[1-9][0-9]*$');

  final String workspace;
  final List<String> issues = [];
  final Map<String, Map> registry = {};
  final Map<String, String> overrides = {};
  final Map<String, Map> localPubspecs = {};
  final Map<String, String> localPaths = {};

  String get thirdParty => path.join(workspace, 'third_party');

  String label(String filePath) =>
      path.relative(filePath, from: workspace).replaceAll('\\', '/');

  void check() {
    final root = readYaml(path.join(workspace, 'pubspec.yaml'));
    final lock = readYaml(path.join(workspace, 'pubspec.lock'));
    if (root != null) {
      checkDependencySources(root, path.join(workspace, 'pubspec.yaml'));
      readOverrides(root);
    }
    readRegistry();
    scanLocalPubspecs();
    checkSets();
    final lockPackages = lock == null
        ? <dynamic, dynamic>{}
        : requireMap(lock['packages'], 'pubspec.lock packages');
    checkLockSources(lockPackages);
    for (final entry in registry.entries) {
      checkPackage(entry.key, entry.value, root, lockPackages);
    }
    issues.sort();
  }

  Map? readYaml(String filePath) {
    try {
      return requireMap(
        loadYaml(File(filePath).readAsStringSync()),
        label(filePath),
      );
    } on FileSystemException {
      issues.add('${label(filePath)}：文件缺失或不可读取');
    } on YamlException catch (error) {
      issues.add('${label(filePath)}：YAML 格式无效：${error.message}');
    } on FormatException {
      issues.add('${label(filePath)}：文件编码无效');
    }
    return null;
  }

  Map requireMap(Object? value, String context) {
    if (value is Map) return value;
    issues.add('$context：必须是映射对象');
    return <dynamic, dynamic>{};
  }

  String? requireString(Map value, String key, String context) {
    final field = value[key];
    if (field is String && field.trim().isNotEmpty) return field;
    issues.add('$context.$key：必须是非空字符串');
    return null;
  }

  // 既检查词法路径，也解析已存在的链接，避免 ../ 和符号链接绕过范围限制。
  String? checkedPath(
    Object? value,
    String base,
    String boundary,
    String context,
  ) {
    if (value is! String || value.trim().isEmpty) {
      issues.add('$context：必须是非空相对路径');
      return null;
    }
    final portable = value.replaceAll('\\', '/');
    if (path.posix.isAbsolute(portable) || path.windows.isAbsolute(value)) {
      issues.add('$context：不允许绝对路径');
      return null;
    }
    final target = path.normalize(path.join(base, portable));
    if (!path.isWithin(boundary, target)) {
      issues.add('$context：路径越界，必须位于 ${label(boundary)} 内');
      return null;
    }
    try {
      if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
        final resolved = File(target).resolveSymbolicLinksSync();
        final resolvedBoundary = path.join(
          Directory(workspace).resolveSymbolicLinksSync(),
          path.relative(boundary, from: workspace),
        );
        if (!path.isWithin(resolvedBoundary, resolved)) {
          issues.add('$context：符号链接路径越界');
          return null;
        }
      }
    } on FileSystemException {
      issues.add('$context：路径不可解析');
      return null;
    }
    return target;
  }

  void checkDependencySources(Map pubspec, String filePath) {
    for (final section in const [
      'dependencies',
      'dev_dependencies',
      'dependency_overrides',
    ]) {
      if (!pubspec.containsKey(section)) continue;
      final dependencies = requireMap(
        pubspec[section],
        '${label(filePath)} $section',
      );
      for (final entry in dependencies.entries) {
        final spec = entry.value;
        final context = '${label(filePath)} $section.${entry.key}';
        if (spec is Map &&
            (spec.containsKey('git') || spec['source'] == 'git')) {
          issues.add('$context：禁止 Git 来源');
        }
        if (section == 'dependency_overrides' &&
            spec is Map &&
            spec.containsKey('path')) {
          checkedPath(
            spec['path'],
            path.dirname(filePath),
            thirdParty,
            context,
          );
        }
      }
    }
  }

  void readOverrides(Map root) {
    if (!root.containsKey('dependency_overrides')) return;
    final entries = requireMap(
      root['dependency_overrides'],
      'pubspec.yaml dependency_overrides',
    );
    for (final entry in entries.entries) {
      if (entry.key is! String) {
        issues.add('pubspec.yaml dependency_overrides：包名必须是字符串');
        continue;
      }
      final spec = entry.value;
      if (spec is! Map || !spec.containsKey('path')) continue;
      // 范围错误由来源扫描报告；此处仍保留集合信息以报告遗漏登记。
      if (spec['path'] is String) {
        overrides[entry.key as String] = path.normalize(
          path.join(workspace, (spec['path'] as String).replaceAll('\\', '/')),
        );
      }
    }
  }

  void readRegistry() {
    const context = 'third_party/dependencies.json';
    try {
      final data = requireMap(
        jsonDecode(
          File(path.join(thirdParty, 'dependencies.json')).readAsStringSync(),
        ),
        context,
      );
      if (data['schema_version'] is! int || data['schema_version'] != 1) {
        issues.add('$context：schema_version 必须为 1');
      }
      final packages = data['packages'];
      if (packages is! List) {
        issues.add('$context：packages 必须是数组');
        return;
      }
      for (var index = 0; index < packages.length; index++) {
        final item = requireMap(packages[index], '$context packages[$index]');
        final name = requireString(item, 'name', '$context packages[$index]');
        if (name == null) continue;
        if (registry.containsKey(name)) {
          issues.add('$context：$name 重复登记');
        } else {
          registry[name] = item;
        }
      }
    } on FileSystemException {
      issues.add('$context：登记文件缺失或不可读取');
    } on FormatException {
      issues.add('$context：JSON 格式或文件编码无效');
    }
  }

  void scanLocalPubspecs() {
    try {
      final files =
          Directory(thirdParty)
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => path.basename(file.path) == 'pubspec.yaml')
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final pubspec = readYaml(file.path);
        if (pubspec == null) continue;
        checkDependencySources(pubspec, file.path);
        final name = requireString(pubspec, 'name', label(file.path));
        if (name == null) continue;
        if (localPubspecs.containsKey(name)) {
          issues.add('${label(file.path)}：本地包名 $name 重复');
          continue;
        }
        localPubspecs[name] = pubspec;
        localPaths[name] = path.normalize(file.parent.path);
        if (pubspec['publish_to'] != 'none') {
          issues.add('${label(file.path)}：本地包 publish_to 必须为 none');
        }
        final version = parseVersion(
          pubspec['version'],
          '${label(file.path)} version',
        );
        if (version != null && !_revisionSuffix.hasMatch(version.toString())) {
          issues.add('${label(file.path)}：本地版本必须带 +piliaurora.N（N 为正整数）');
        }
      }
    } on FileSystemException {
      issues.add('third_party：目录缺失或不可扫描');
    }
  }

  void checkSets() {
    for (final name in overrides.keys) {
      if (!registry.containsKey(name)) issues.add('$name：path override 未登记');
    }
    for (final name in localPubspecs.keys) {
      if (!registry.containsKey(name)) issues.add('$name：实际 third_party 包未登记');
    }
    for (final name in registry.keys) {
      if (!overrides.containsKey(name)) issues.add('$name：登记包缺少 path override');
      if (!localPubspecs.containsKey(name)) {
        issues.add('$name：登记包缺少实际 third_party pubspec');
      }
    }
  }

  void checkLockSources(Map lockPackages) {
    for (final entry in lockPackages.entries) {
      final spec = requireMap(entry.value, 'pubspec.lock ${entry.key}');
      if (spec['source'] == 'git' || spec.containsKey('git')) {
        issues.add('pubspec.lock ${entry.key}：禁止 Git 来源');
      }
      if (spec['source'] == 'path' && !registry.containsKey(entry.key)) {
        issues.add('pubspec.lock ${entry.key}：path 来源未登记');
      }
    }
  }

  Version? parseVersion(Object? value, String context) {
    if (value is String) {
      try {
        return Version.parse(value);
      } on FormatException {
        // 统一报告无效版本，不依赖解析库的错误文本。
      }
    }
    issues.add('$context：无效版本号');
    return null;
  }

  void checkPackage(String name, Map item, Map? root, Map lockPackages) {
    final context = 'third_party/dependencies.json $name';
    final versionText = requireString(item, 'version', context);
    final version = parseVersion(versionText, '$context version');
    final upstreamText = requireString(item, 'upstream_version', context);
    parseVersion(upstreamText, '$context upstream_version');
    if (versionText != null && upstreamText != null) {
      final suffix = _revisionSuffix.firstMatch(versionText);
      if (suffix == null ||
          versionText.substring(0, suffix.start) != upstreamText) {
        issues.add('$name：登记版本必须为 upstream_version 加 +piliaurora.N（N 为正整数）');
      }
    }
    requireString(item, 'reason', context);
    checkSource(item['source'], '$context source');
    final packagePath = checkedPath(
      item['path'],
      workspace,
      thirdParty,
      '$context path',
    );
    if (packagePath != null) {
      if (overrides.containsKey(name) && overrides[name] != packagePath) {
        issues.add('$name：override 路径与登记路径不一致');
      }
      if (localPaths.containsKey(name) && localPaths[name] != packagePath) {
        issues.add('$name：本地 pubspec name 或路径与登记不一致');
      }
      checkLicenses(name, item['licenses'], packagePath);
      if (item.containsKey('merged_sources')) {
        checkMergedSources(name, item, packagePath);
      }
    }
    final local = localPubspecs[name];
    if (local != null && local['version'] != versionText) {
      issues.add('$name：本地 pubspec version 与登记版本不一致');
    }
    final locked = requireMap(lockPackages[name], 'pubspec.lock $name');
    if (locked['source'] != 'path') {
      issues.add('$name：lock source 必须为 path');
    } else {
      final description = requireMap(
        locked['description'],
        'pubspec.lock $name description',
      );
      final lockedPath = checkedPath(
        description['path'],
        workspace,
        thirdParty,
        'pubspec.lock $name path',
      );
      if (lockedPath != null &&
          packagePath != null &&
          lockedPath != packagePath) {
        issues.add('$name：lock path 与登记路径不一致');
      }
    }
    if (locked['version'] != versionText) {
      issues.add('$name：lock version 与登记版本不一致');
    }
    if (root != null && version != null) {
      checkDirectConstraint(name, version, root);
    }
  }

  void checkSource(Object? value, String context) {
    final source = requireMap(value, context);
    requireString(source, 'url', context);
    requireString(source, 'path', context);
    final commit = requireString(source, 'commit', context);
    if (commit != null && !RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(commit)) {
      issues.add('$context.commit 必须为完整 40 位十六进制 SHA');
    }
  }

  void checkMergedSources(String owner, Map item, String packagePath) {
    final value = item['merged_sources'];
    if (value is! List || value.isEmpty) {
      issues.add('$owner：merged_sources 必须是非空列表');
      return;
    }
    final names = <String>{owner};
    for (var index = 0; index < value.length; index++) {
      final context = '$owner merged_sources[$index]';
      final merged = requireMap(value[index], context);
      final name = requireString(merged, 'name', context);
      if (name != null && !names.add(name)) {
        issues.add('$context：来源名称重复');
      }
      final upstream = requireString(merged, 'upstream_version', context);
      parseVersion(upstream, '$context upstream_version');
      requireString(merged, 'reason', context);
      checkSource(merged['source'], '$context source');
      final sourcePath = checkedPath(
        merged['path'],
        packagePath,
        packagePath,
        '$context path',
      );
      if (sourcePath != null && !Directory(sourcePath).existsSync()) {
        issues.add('$context：合并源码目录缺失');
      }
      checkLicenses(context, merged['licenses'], packagePath);
      final licenses = merged['licenses'];
      if (licenses is List && item['licenses'] is List) {
        for (final license in licenses) {
          if (!(item['licenses'] as List).contains(license)) {
            issues.add('$context：许可证未登记到主包 licenses');
          }
        }
      }
    }
  }

  void checkLicenses(String name, Object? value, String packagePath) {
    if (value is! List || value.isEmpty) {
      issues.add('$name：licenses 必须是非空列表');
      return;
    }
    for (final license in value) {
      final filePath = checkedPath(
        license,
        packagePath,
        packagePath,
        '$name licenses',
      );
      if (filePath == null) continue;
      try {
        if (File(filePath).readAsStringSync().trim().isEmpty) {
          issues.add('$name：许可证 ${label(filePath)} 为空');
        }
      } on FileSystemException {
        issues.add('$name：许可证 ${label(filePath)} 缺失或不可读取');
      } on FormatException {
        issues.add('$name：许可证 ${label(filePath)} 编码无效');
      }
    }
  }

  void checkDirectConstraint(String name, Version version, Map root) {
    for (final section in const ['dependencies', 'dev_dependencies']) {
      final dependencies = root[section];
      if (dependencies is! Map || !dependencies.containsKey(name)) continue;
      final spec = dependencies[name];
      final constraintText = spec is Map ? spec['version'] : spec;
      if (constraintText is! String ||
          constraintText.trim().isEmpty ||
          (spec is Map &&
              (spec.containsKey('path') ||
                  spec.containsKey('git') ||
                  spec.containsKey('sdk')))) {
        issues.add('$name：根 $section 必须声明版本约束');
        continue;
      }
      try {
        final constraint = VersionConstraint.parse(constraintText);
        if (constraint.isAny || !constraint.allows(version)) {
          issues.add('$name：根 $section 版本约束 $constraintText 不匹配本地版本 $version');
        }
      } on FormatException {
        issues.add('$name：根 $section 版本约束无效');
      }
    }
  }
}
