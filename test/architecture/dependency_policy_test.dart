import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import '../../tool/check_dependencies.dart';

const _version = '1.2.3+piliaurora.1';

class _Fixture {
  _Fixture()
    : directory = Directory.systemTemp.createTempSync('dependency_policy_');

  final Directory directory;
  final Map<String, Object?> root = {
    'name': 'fixture',
    'dependencies': {'local_package': _version},
    'dependency_overrides': {
      'local_package': {'path': 'third_party/local_package'},
    },
  };
  final Map<String, Object?> local = {
    'name': 'local_package',
    'version': _version,
    'publish_to': 'none',
    'dependencies': {'hosted_package': '^1.0.0'},
  };
  final Map<String, Object?> record = {
    'name': 'local_package',
    'version': _version,
    'upstream_version': '1.2.3',
    'path': 'third_party/local_package',
    'source': {
      'url': 'https://example.com/upstream.git',
      'commit': '0123456789abcdef0123456789abcdef01234567',
      'path': '.',
    },
    'licenses': ['LICENSE'],
    'reason': '保留测试定制接口。',
  };
  final Map<String, Object?> locked = {
    'dependency': 'direct main',
    'source': 'path',
    'version': _version,
    'description': {'path': 'third_party/local_package', 'relative': true},
  };

  final Map<String, Object?> hosted = {
    'source': 'hosted',
    'version': '1.0.0',
  };

  Map<String, Object?> get registry => {
    'schema_version': 1,
    'packages': [record],
  };

  void write(String relativePath, String contents) {
    final file = File(path.join(directory.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  void save() {
    // JSON 是合法 YAML，fixture 使用同一种编码避免手写缩进导致误测。
    write('pubspec.yaml', jsonEncode(root));
    write(
      'pubspec.lock',
      jsonEncode({
        'packages': {'local_package': locked, 'hosted_package': hosted},
      }),
    );
    write('third_party/dependencies.json', jsonEncode(registry));
    write('third_party/local_package/pubspec.yaml', jsonEncode(local));
    write('third_party/local_package/LICENSE', 'Fixture license\n');
  }

  List<String> check() => checkDependencyPolicy(directory.path);
}

void main() {
  late _Fixture fixture;

  setUp(() {
    fixture = _Fixture()..save();
  });
  tearDown(() {
    // 仅删除本次测试通过 systemTemp 创建并独占的目录。
    fixture.directory.deleteSync(recursive: true);
  });

  void expectIssue(String fragment) {
    final issues = fixture.check();
    expect(issues, contains(contains(fragment)), reason: issues.join('\n'));
  }

  test('valid fixture passes deterministically without modifying files', () {
    final file = File(path.join(fixture.directory.path, 'pubspec.yaml'));
    final before = file.readAsStringSync();
    expect(fixture.check(), isEmpty);
    expect(fixture.check(), isEmpty);
    expect(file.readAsStringSync(), before);
  });

  Map<String, Object?> mergedSource() => {
    'name': 'merged_package',
    'upstream_version': '2.0.0',
    'source': Map<String, Object?>.from(fixture.record['source'] as Map),
    'path': 'lib/merged',
    'licenses': ['LICENSE'],
    'reason': '合并仅由主包使用的类型。',
  };

  void saveMerged(Map<String, Object?> merged) {
    fixture
      ..record['merged_sources'] = [merged]
      ..save()
      ..write(
        'third_party/local_package/lib/merged/types.dart',
        '// fixture',
      );
  }

  test('accepts merged source provenance and preserved licenses', () {
    saveMerged(mergedSource());
    expect(fixture.check(), isEmpty);
  });

  test('rejects missing merged source commit or invalid source fields', () {
    final merged = mergedSource();
    (merged['source'] as Map).remove('commit');
    saveMerged(merged);
    expectIssue('merged_sources[0] source.commit');
    (merged['source'] as Map)['commit'] = 'branch-name';
    saveMerged(merged);
    expectIssue('完整 40 位');
  });

  test('rejects merged source path escaping its owner', () {
    saveMerged(mergedSource()..['path'] = '../other_package');
    expectIssue('merged_sources[0] path：路径越界');
  });

  test('rejects missing merged implementation directory', () {
    saveMerged(mergedSource()..['path'] = 'lib/missing');
    expectIssue('合并源码目录缺失');
  });

  test('rejects missing merged source license', () {
    saveMerged(mergedSource()..['licenses'] = ['missing-license']);
    expectIssue('许可证');
  });

  test('rejects merged license not registered in owner', () {
    saveMerged(mergedSource()..['licenses'] = ['MERGED_LICENSE']);
    fixture.write('third_party/local_package/MERGED_LICENSE', 'Merged license');
    expectIssue('许可证未登记到主包');
  });

  test('rejects empty or malformed merged source list', () {
    for (final value in [null, 'invalid', <Object?>[]]) {
      fixture.record['merged_sources'] = value;
      fixture.save();
      expectIssue('merged_sources 必须是非空列表');
    }
  });

  test('rejects duplicate merged source names and owner as source', () {
    final merged = mergedSource();
    saveMerged(merged);
    fixture.record['merged_sources'] = [merged, merged];
    fixture.save();
    expectIssue('来源名称重复');
    saveMerged(merged..['name'] = 'local_package');
    expectIssue('来源名称重复');
  });

  test('accepts a consistent second local revision', () {
    const revision = '1.2.3+piliaurora.2';
    fixture.root['dependencies'] = {'local_package': revision};
    fixture.local['version'] = revision;
    fixture.record['version'] = revision;
    fixture.locked['version'] = revision;
    fixture.save();
    expect(fixture.check(), isEmpty);
  });

  for (final suffix in [
    'piliaurora.0',
    'piliaurora.-1',
    'piliaurora.01',
    'piliaurora.x',
    'piliaurora.1.extra',
  ]) {
    test('rejects invalid local revision $suffix', () {
      final revision = '1.2.3+$suffix';
      fixture.root['dependencies'] = {'local_package': revision};
      fixture.local['version'] = revision;
      fixture.record['version'] = revision;
      fixture.locked['version'] = revision;
      fixture.save();
      expectIssue('登记版本必须为 upstream_version 加 +piliaurora.N');
    });
  }

  test(
    'rejects caret and range constraints even when local versions match',
    () {
      for (final constraint in ['^1.2.3', '>=1.2.3 <2.0.0']) {
        fixture.root['dependencies'] = {'local_package': constraint};
        fixture.save();
        expectIssue('版本约束必须精确固定');
      }
    },
  );

  test(
    'registered transitive local package need not be a direct dependency',
    () {
      fixture.root['dependencies'] = {'hosted_package': '1.0.0'};
      fixture.locked['dependency'] = 'transitive';
      fixture.save();
      expect(fixture.check(), isEmpty);
    },
  );

  for (final section in [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    test('rejects root Git in $section including commit-pinned sources', () {
      fixture.root[section] = {
        if (section == 'dependency_overrides')
          'local_package': {'path': 'third_party/local_package'},
        'git_package': {
          'git': {
            'url': 'https://example.com/package.git',
            'ref': '0123456789abcdef0123456789abcdef01234567',
          },
        },
      };
      fixture.save();
      expectIssue('pubspec.yaml $section.git_package：禁止 Git');
    });

    test('rejects vendored transitive Git in $section', () {
      fixture.local[section] = {
        'git_package': {'git': 'https://example.com/package.git'},
      };
      fixture.save();
      expectIssue(
        'third_party/local_package/pubspec.yaml $section.git_package：禁止 Git',
      );
    });
  }

  test('scans unregistered nested pubspecs for Git sources', () {
    fixture.write(
      'third_party/local_package/nested/pubspec.yaml',
      jsonEncode({
        'name': 'nested_package',
        'version': _version,
        'publish_to': 'none',
        'dependencies': {
          'git_package': {'git': 'https://example.com/package.git'},
        },
      }),
    );
    expectIssue('nested/pubspec.yaml dependencies.git_package：禁止 Git');
    expectIssue('nested_package：实际 third_party 包未登记');
  });

  test('rejects transitive Git lock entry not mentioned in pubspec', () {
    fixture.write(
      'pubspec.lock',
      jsonEncode({
        'packages': {
          'local_package': fixture.locked,
          'git_package': {
            'source': 'git',
            'version': '1.0.0',
            'description': {'url': 'https://example.com/package.git'},
          },
        },
      }),
    );
    expectIssue('pubspec.lock git_package：禁止 Git');
  });

  for (final badPath in [
    '../outside',
    'third_party/../../outside',
    'third_party',
    '/tmp/outside',
    r'C:\outside',
    r'..\outside',
  ]) {
    test('rejects override path escape: $badPath', () {
      fixture.root['dependency_overrides'] = {
        'local_package': {'path': badPath},
      };
      fixture.save();
      expectIssue('dependency_overrides.local_package');
    });
  }

  test('rejects registry path escape', () {
    fixture.record['path'] = '../outside';
    fixture.save();
    expectIssue('dependencies.json local_package path：路径越界');
  });

  test('rejects path escape from a vendored override', () {
    fixture.local['dependency_overrides'] = {
      'other': {'path': '../../outside'},
    };
    fixture.save();
    expectIssue('local_package/pubspec.yaml dependency_overrides.other：路径越界');
  });

  test('rejects lock path escape', () {
    fixture.locked['description'] = {'path': '../outside', 'relative': true};
    fixture.save();
    expectIssue('pubspec.lock local_package path：路径越界');
  });

  test('rejects local pubspec version mismatch', () {
    fixture.local['version'] = '1.2.4+piliaurora.1';
    fixture.save();
    expectIssue('本地 pubspec version 与登记版本不一致');
  });

  test('rejects upstream version mismatch', () {
    fixture.record['upstream_version'] = '1.2.4';
    fixture.save();
    expectIssue('登记版本必须为 upstream_version 加 +piliaurora.N');
  });

  test('rejects lock version mismatch', () {
    fixture.locked['version'] = '1.2.4+piliaurora.1';
    fixture.save();
    expectIssue('lock version 与登记版本不一致');
  });

  test(
    'rejects mismatched direct version constraints and unpatched exact version',
    () {
      for (final constraint in ['^2.0.0', '1.2.3', 'any']) {
        fixture.root['dependencies'] = {'local_package': constraint};
        fixture.save();
        expectIssue('根 dependencies 版本约束');
      }
    },
  );

  test('checks local direct dev dependency constraints', () {
    fixture.root['dependencies'] = <String, Object?>{};
    fixture.root['dev_dependencies'] = {'local_package': '^2.0.0'};
    fixture.save();
    expectIssue('根 dev_dependencies 版本约束');
  });

  test('rejects path instead of direct version constraint', () {
    fixture.root['dependencies'] = {
      'local_package': {'path': 'third_party/local_package'},
    };
    fixture.save();
    expectIssue('根 dependencies 必须声明版本约束');
  });

  for (final section in [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ]) {
    test('accepts exact hosted version in $section', () {
      fixture.root[section] = {
        ...fixture.root[section] as Map? ?? {},
        'hosted_package': '1.0.0',
      };
      fixture.save();
      expect(fixture.check(), isEmpty);
    });

    for (final constraint in ['^1.0.0', '>=1.0.0 <2.0.0', 'any', '', 'bad']) {
      test('rejects floating hosted $constraint in $section', () {
        fixture.root[section] = {
          ...fixture.root[section] as Map? ?? {},
          'hosted_package': constraint,
        };
        fixture.save();
        expectIssue('$section.hosted_package：必须声明精确版本号');
      });
    }
  }

  test('accepts hosted mapping including prerelease and build version', () {
    fixture.root['dependencies'] = {
      'local_package': _version,
      'hosted_package': {
        'hosted': 'https://example.com',
        'version': '2.0.0-beta.1+build.2',
      },
    };
    fixture.hosted['version'] = '2.0.0-beta.1+build.2';
    fixture.save();
    expect(fixture.check(), isEmpty);
  });

  test('SDK dependencies are managed by the pinned Flutter SDK', () {
    fixture.root['dependencies'] = {
      'local_package': _version,
      'flutter': {'sdk': 'flutter'},
    };
    fixture.save();
    expect(fixture.check(), isEmpty);
  });

  test('rejects a missing hosted lock entry and unexpected lock source', () {
    (fixture.root['dependencies'] as Map)['hosted_package'] = '1.0.0';
    fixture.save();
    fixture.write(
      'pubspec.lock',
      jsonEncode({
        'packages': {'local_package': fixture.locked},
      }),
    );
    expectIssue('hosted_package：lock 必须包含对应 hosted 依赖');
    fixture.hosted['source'] = 'sdk';
    fixture.save();
    expectIssue('hosted_package：lock 必须包含对应 hosted 依赖');
  });

  test('rejects hosted lock version drift including build suffix', () {
    (fixture.root['dependencies'] as Map)['hosted_package'] = '1.0.0';
    for (final version in ['1.0.1', '1.0.0+other']) {
      fixture.hosted['version'] = version;
      fixture.save();
      expectIssue('hosted_package：精确版本');
    }
  });

  test('rejects missing local version suffix and publish_to none', () {
    fixture.local['version'] = '1.2.3';
    fixture.local.remove('publish_to');
    fixture.save();
    expectIssue('本地版本必须带 +piliaurora.N');
    expectIssue('本地包 publish_to 必须为 none');
  });

  test('rejects local pubspec name mismatch', () {
    fixture.local['name'] = 'wrong_name';
    fixture.save();
    expectIssue('local_package：登记包缺少实际 third_party pubspec');
    expectIssue('wrong_name：实际 third_party 包未登记');
  });

  test('rejects missing registry entry', () {
    fixture.write(
      'third_party/dependencies.json',
      jsonEncode({'schema_version': 1, 'packages': []}),
    );
    expectIssue('local_package：path override 未登记');
    expectIssue('local_package：实际 third_party 包未登记');
  });

  test('rejects missing override for registered package', () {
    fixture.root['dependency_overrides'] = <String, Object?>{};
    fixture.save();
    expectIssue('登记包缺少 path override');
  });

  test('rejects missing lock entry and non-path lock source', () {
    fixture.write('pubspec.lock', jsonEncode({'packages': {}}));
    expectIssue('lock source 必须为 path');
    fixture.locked['source'] = 'hosted';
    fixture.save();
    expectIssue('lock source 必须为 path');
  });

  test('rejects override and lock paths that differ from registry', () {
    fixture.root['dependency_overrides'] = {
      'local_package': {'path': 'third_party/wrong'},
    };
    fixture.locked['description'] = {
      'path': 'third_party/wrong',
      'relative': true,
    };
    fixture.save();
    expectIssue('override 路径与登记路径不一致');
    expectIssue('lock path 与登记路径不一致');
  });

  test('rejects missing and empty licenses', () {
    final license = File(
      path.join(fixture.directory.path, 'third_party/local_package/LICENSE'),
    )..deleteSync();
    expectIssue('许可证 third_party/local_package/LICENSE 缺失');
    license.writeAsStringSync(' \n\t');
    expectIssue('许可证 third_party/local_package/LICENSE 为空');
  });

  test('rejects license escape and empty license list', () {
    fixture.record['licenses'] = ['../LICENSE'];
    fixture.save();
    expectIssue('local_package licenses：路径越界');
    fixture.record['licenses'] = <String>[];
    fixture.save();
    expectIssue('licenses 必须是非空列表');
  });

  test('validates source metadata and full commit SHA', () {
    fixture.record['source'] = {'url': '', 'commit': 'main', 'path': '.'};
    fixture.record['reason'] = '';
    fixture.save();
    expectIssue('source.url：必须是非空字符串');
    expectIssue('source.commit 必须为完整 40 位十六进制 SHA');
    expectIssue('reason：必须是非空字符串');
  });

  test('rejects duplicate registry names and unsupported schema', () {
    fixture.write(
      'third_party/dependencies.json',
      jsonEncode({
        'schema_version': 2,
        'packages': [fixture.record, fixture.record],
      }),
    );
    expectIssue('schema_version 必须为 1');
    expectIssue('local_package 重复登记');
  });

  test('reports malformed files instead of throwing', () {
    fixture
      ..write('pubspec.yaml', 'dependencies: [')
      ..write('third_party/dependencies.json', '{');
    expectIssue('pubspec.yaml：YAML 格式无效');
    expectIssue('dependencies.json：JSON 格式');
  });

  test('reports missing workspace files instead of throwing', () {
    File(path.join(fixture.directory.path, 'pubspec.yaml')).deleteSync();
    File(path.join(fixture.directory.path, 'pubspec.lock')).deleteSync();
    File(path.join(fixture.directory.path, 'third_party/dependencies.json'))
        .deleteSync();
    expectIssue('pubspec.yaml：文件缺失');
    expectIssue('pubspec.lock：文件缺失');
    expectIssue('dependencies.json：登记文件缺失');
  });
}
