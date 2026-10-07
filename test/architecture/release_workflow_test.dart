import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

Map<dynamic, dynamic> workflow(String name) =>
    loadYaml(File('.github/workflows/$name.yml').readAsStringSync()) as Map;

void main() {
  for (final (name, event) in [
    ('build', 'workflow_dispatch'),
    ('win_x64', 'workflow_call'),
    ('win_x64', 'workflow_dispatch'),
  ]) {
    test('$name $event keeps draft publishing opt-in', () {
      final input = workflow(name)['on'][event]['inputs']['draft_release'];
      expect(input['type'], 'boolean');
      expect(input['default'], isFalse);
      expect(input['required'], isFalse);
    });
  }

  for (final (name, job) in [
    ('build', 'android'),
    ('win_x64', 'build-windows-app'),
  ]) {
    test('$name release action obeys the selected draft mode', () {
      final steps = workflow(name)['jobs'][job]['steps'] as List;
      final release =
          steps.singleWhere((step) => step['name'] == 'Release') as Map;
      expect(release['uses'], startsWith('softprops/action-gh-release@'));
      expect(release['with']['draft'], r'${{ inputs.draft_release }}');
    });
  }

  test(
    'Android coordinator passes draft mode to the reusable Windows workflow',
    () {
      final job = workflow('build')['jobs']['win_x64'];
      expect(job['uses'], './.github/workflows/win_x64.yml');
      expect(
        job['with']['draft_release'],
        r"${{ github.event_name == 'workflow_dispatch' && inputs.draft_release }}",
      );
    },
  );
}
