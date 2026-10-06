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

  test(
    'download persistence has no direct application, UI or network dependency',
    () {
      final file = File('lib/services/download/download_repository.dart');
      expect(
        dependencies(file).where(
          (uri) =>
              uri.startsWith('package:flutter/') ||
              uri.startsWith('package:get/') ||
              uri.startsWith('package:dio/') ||
              uri.contains('/pages/') ||
              uri.contains('/http/') ||
              uri.contains('/storage') ||
              uri.contains('/logger.dart'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'download executor cannot obtain its client from the global request layer',
    () {
      final file = File('lib/services/download/download_manager.dart');
      expect(
        dependencies(file).where((uri) => uri.contains('/http/')),
        isEmpty,
      );
    },
  );
}
