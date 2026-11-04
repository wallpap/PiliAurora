import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

final _directives = RegExp(
  r'''(?:import|export|part)\s+['"]([^'"]+)['"]''',
);

Iterable<String> dependencies(File file) => _directives
    .allMatches(file.readAsStringSync())
    .map((match) => match.group(1)!);

String? localDependency(File file, String uri) {
  const prefix = 'package:pili_aurora/';
  if (uri.startsWith(prefix)) return uri.substring(prefix.length);
  if (uri.contains(':')) return null;
  return path
      .relative(
        path.normalize(path.join(file.parent.path, uri)),
        from: 'lib',
      )
      .replaceAll('\\', '/');
}

void main() {
  const sharedRestrictions = [
    'package:flutter/',
    'package:get/',
    '/pages/',
    '/http/',
  ];
  const coreRestrictions = [
    ...sharedRestrictions,
    'package:dio/',
    '/storage',
  ];
  const rules = <String, List<String>>{
    'plugin/pl_player/playback/playback_session.dart': coreRestrictions,
    'plugin/pl_player/playback/network_recovery.dart': coreRestrictions,
    'services/download/download_repository.dart': [
      ...coreRestrictions,
      '/logger.dart',
    ],
    'services/settings/settings_backup.dart': [
      ...sharedRestrictions,
      'package:dio/',
      '/utils/storage',
      '/logger.dart',
    ],
    'services/settings/webdav_sync.dart': [
      ...sharedRestrictions,
      'package:flutter_smart_dialog/',
      '/utils/storage',
      '/device_utils',
    ],
    'services/download/download_manager.dart': ['/http/'],
  };
  for (final entry in rules.entries) {
    test('${entry.key} respects its dependency boundary', () {
      final file = File('lib/${entry.key}');
      expect(
        dependencies(file).where(
          (uri) =>
              !(entry.key == 'services/settings/settings_backup.dart' &&
                  localDependency(file, uri) == 'utils/storage_key.dart') &&
              entry.value.any(
                (restriction) => restriction.startsWith('package:')
                    ? uri.startsWith(restriction)
                    : uri.contains(restriction),
              ),
        ),
        isEmpty,
        reason: file.path,
      );
    });
  }
  test(
    'main and app composition modules are never imported by lower layers',
    () {
      final violations = <String>[];
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final source = path
            .relative(file.path, from: 'lib')
            .replaceAll('\\', '/');
        for (final uri in dependencies(file)) {
          final target = localDependency(file, uri);
          if (target == 'main.dart' ||
              (source != 'main.dart' &&
                  !source.startsWith('app/') &&
                  (target?.startsWith('app/') ?? false))) {
            violations.add('$source -> $uri');
          }
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );
}
