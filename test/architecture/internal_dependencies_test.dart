import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

const _retiredDirectDependencies = [
  'easy_debounce',
  'stream_transform',
  'uuid',
  'json_annotation',
  'package_info_plus',
  'logger',
  'webdav_client',
];

void main() {
  test('internalized and unused APIs no longer create direct dependencies', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as Map;
    final dependencies = pubspec['dependencies'] as Map;
    for (final name in _retiredDirectDependencies) {
      expect(dependencies.containsKey(name), isFalse, reason: name);
    }
  });

  test('application code does not bypass the owned utility modules', () {
    final directives = RegExp(r'''(?:import|export)\s+['"]package:([^/]+)/''');
    final violations = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      for (final match in directives.allMatches(file.readAsStringSync())) {
        if (_retiredDirectDependencies.contains(match.group(1))) {
          violations.add('${file.path}: ${match.group(1)}');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('catcher logs use host callbacks without a second logging package', () {
    final pubspec = loadYaml(
      File('third_party/catcher_2/pubspec.yaml').readAsStringSync(),
    ) as Map;
    expect((pubspec['dependencies'] as Map).containsKey('logger'), isFalse);
    for (final file in Directory(
      'third_party/catcher_2/lib',
    ).listSync(recursive: true)) {
      if (file is File && file.path.endsWith('.dart')) {
        expect(
          file.readAsStringSync(),
          isNot(contains('package:logger/')),
          reason: file.path,
        );
      }
    }
  });

  test('cache models are owned by the cache implementation package', () {
    const retired = 'cached_network_image_platform_interface_ce';
    final root = loadYaml(File('pubspec.yaml').readAsStringSync()) as Map;
    final cache = loadYaml(
      File('third_party/cached_network_image_ce/pubspec.yaml')
          .readAsStringSync(),
    ) as Map;
    expect((root['dependency_overrides'] as Map).containsKey(retired), isFalse);
    expect((cache['dependencies'] as Map).containsKey(retired), isFalse);
    final violations = <String>[];
    for (final file in Directory(
      'third_party/cached_network_image_ce/lib',
    ).listSync(recursive: true)) {
      if (file is File &&
          file.path.endsWith('.dart') &&
          file.readAsStringSync().contains('package:$retired/')) {
        violations.add(file.path);
      }
    }
    expect(violations, isEmpty);
  });
}
