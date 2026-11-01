// 本地诊断工具复用已解析的Flutter工具链依赖。
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vm_service/src/snapshot_graph.dart';

/// 按RenderObject._owner区分attached，反查旧子树；从不访问object.data。
Future<void> main(List<String> args) async {
  try {
    String requiredOption(String name) {
      final index = args.indexOf(name);
      if (index < 0 || index + 1 >= args.length) throw ArgumentError(name);
      return args[index + 1];
    }

    final input = File(requiredOption('--input'));
    final output = File(requiredOption('--output'));
    if (output.existsSync()) throw StateError('new output file required');
    if (await input.length() > 512 << 20) throw StateError('snapshotTooLarge');
    final bytes = await input.readAsBytes();
    final graph = HeapSnapshotGraph.fromChunks(
      [ByteData.sublistView(bytes)],
      calculateReferrers: true,
      decodeObjectData: false,
      decodeExternalProperties: false,
      decodeIdentityHashCodes: false,
    );
    final objects = graph.objects;
    if (objects.length > 2000000 || graph.referenceCount > 20000000) {
      throw StateError('graphExceedsAnalysisBudget');
    }
    final reachable = Uint8List(objects.length);
    final pending = <int>[1];
    reachable[1] = 1;
    while (pending.isNotEmpty) {
      for (final child in objects[pending.removeLast()].references) {
        if (child != 0 && reachable[child] == 0) {
          reachable[child] = 1;
          pending.add(child);
        }
      }
    }
    final fields = <int, Map<String, int>>{};
    Map<String, int> fieldIndexes(int id) => fields.putIfAbsent(
      objects[id].classId,
      () => {
        for (final field in objects[id].klass.fields) field.name: field.index,
      },
    );
    int? field(int id, String name) {
      final index = fieldIndexes(id)[name];
      return index == null || index >= objects[id].references.length
          ? null
          : objects[id].references[index];
    }

    bool isNull(int? id) =>
        id == 0 ||
        (id != null && ['Null', '_Null'].contains(objects[id].klass.name));
    bool attached(int id) =>
        field(id, '_owner') != null && !isNull(field(id, '_owner'));
    final renders = <int>[];
    final detachedParagraphs = <int>[];
    final classCounts = <String, Map<String, int>>{};
    for (var id = 1; id < objects.length; id++) {
      final name = objects[id].klass.name;
      if ((!name.startsWith('Render') && !name.startsWith('_Render')) ||
          !fieldIndexes(id).containsKey('_owner')) {
        continue;
      }
      renders.add(id);
      final counts = classCounts.putIfAbsent(
        name,
        () => {
          'attached': 0,
          'detached': 0,
          'attachedRootReachable': 0,
          'detachedRootReachable': 0,
        },
      );
      final key = attached(id) ? 'attached' : 'detached';
      counts[key] = counts[key]! + 1;
      if (reachable[id] != 0) {
        counts['${key}RootReachable'] = counts['${key}RootReachable']! + 1;
      }
      if (key == 'detached' &&
          name.contains('Paragraph') &&
          reachable[id] != 0) {
        detachedParagraphs.add(id);
      }
    }
    Map<String, Object?> describe(int id) => {
      'objectId': id,
      'class': objects[id].klass.name,
      'libraryUri': objects[id].klass.libraryUri.toString(),
      'shallowBytes': objects[id].shallowSize,
      if (fieldIndexes(id).containsKey('_owner')) 'attached': attached(id),
    };
    Map<String, Object?> edge(int from, int to) => {
      ...describe(from),
      'toObject': to,
      'fields': [
        for (final entry in fieldIndexes(from).entries)
          if (entry.value < objects[from].references.length &&
              objects[from].references[entry.value] == to)
            entry.key,
      ],
    };
    final paths = <Map<String, Object?>>[];
    final targets = <int>[];
    if (detachedParagraphs.isNotEmpty) {
      // 均匀抽样，避免只落在同一张卡片的相邻对象。
      for (var i = 0; i < 8 && i < detachedParagraphs.length; i++) {
        targets.add(
          detachedParagraphs[(i * detachedParagraphs.length ~/ 8).clamp(
            0,
            detachedParagraphs.length - 1,
          )],
        );
      }
    }
    for (final target in targets) {
      final queue = <int>[target];
      final child = <int, int>{target: 0};
      var head = 0;
      int? found;
      while (head < queue.length && head < 12000) {
        final id = queue[head++];
        final name = objects[id].klass.name;
        if (attached(id) &&
            (name.startsWith('RenderSliver') || name.contains('Viewport'))) {
          found = id;
          break;
        }
        for (final parent in objects[id].referrers) {
          if (parent == 0 ||
              child.containsKey(parent) ||
              child.length >= 12000) {
            continue;
          }
          child[parent] = id;
          queue.add(parent);
        }
      }
      final path = <Map<String, Object?>>[];
      var truncated = false;
      if (found != null) {
        var id = found;
        while (id != target && path.length < 40) {
          final next = child[id]!;
          path.add(edge(id, next));
          id = next;
        }
        truncated = id != target;
        path.add(describe(id));
      }
      paths.add({
        'target': describe(target),
        'retainingPath': path,
        'pathTruncated': truncated,
        'searchVisitedNodes': head,
        'coverage': found == null
            ? 'notFoundWithin12000Nodes'
            : 'found; max40Edges',
      });
    }
    final summary = {
      'schemaVersion': 1,
      'semantics': 'attachedMeansRenderObject_ownerNonNull; metadataOnly; boundedReferrerPaths',
      'renderObjectCount': renders.length,
      'classCounts': classCounts,
      'detachedParagraphCount': detachedParagraphs.length,
      'sampledDetachedParagraphs': paths,
    };
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(summary),
    );
    stdout.writeln(
      jsonEncode({
        'renderObjectCount': renders.length,
        'detachedParagraphCount': detachedParagraphs.length,
        'pathsFound': paths
            .where((path) => (path['retainingPath'] as List).isNotEmpty)
            .length,
      }),
    );
  } catch (error) {
    stderr.writeln(
      jsonEncode({
        'status': 'failed',
        'errorType': error.runtimeType.toString(),
      }),
    );
    exitCode = 1;
  }
}
