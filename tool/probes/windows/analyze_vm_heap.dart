// 本地工具复用已解析的Flutter工具链依赖。
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vm_service/src/snapshot_graph.dart';

/// 只导出类型/字段元数据和大小，绝不访问或导出object.data。
Future<void> main(List<String> args) async {
  try {
    String? option(String name) {
      final index = args.indexOf(name);
      return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
    }

    final input = option('--input');
    final destination = option('--output');
    if (input == null || destination == null) {
      throw ArgumentError('--input heap.heapsnapshot --output new-directory');
    }
    final limit = (int.tryParse(option('--top') ?? '') ?? 30).clamp(1, 100);
    final file = File(input);
    if (await file.length() > 512 << 20) throw StateError('snapshotTooLarge');
    final bytes = await file.readAsBytes();
    final graph = HeapSnapshotGraph.fromChunks(
      [ByteData.sublistView(bytes)],
      calculateReferrers: true,
      decodeObjectData: false,
      decodeExternalProperties: false,
      decodeIdentityHashCodes: false,
    );
    if (graph.objects.length > 2000000 || graph.referenceCount > 20000000) {
      throw StateError('graphExceedsAnalysisBudget');
    }
    final output = Directory(destination);
    if (output.existsSync()) throw StateError('outputAlreadyExists');
    final objects = graph.objects;
    final classes = <int, Map<String, Object?>>{};
    for (var id = 1; id < objects.length; id++) {
      final object = objects[id];
      final entry = classes.putIfAbsent(
        object.classId,
        () => {
          'class': object.klass.name,
          'libraryUri': object.klass.libraryUri.toString(),
          'count': 0,
          'shallowBytes': 0,
        },
      );
      entry['count'] = (entry['count']! as int) + 1;
      entry['shallowBytes'] =
          (entry['shallowBytes']! as int) + object.shallowSize;
    }
    final classRows = classes.values.toList()
      ..sort(
        (a, b) =>
            (b['shallowBytes']! as int).compareTo(a['shallowBytes']! as int),
      );
    final dominators = _dominators(graph);
    final idom = dominators.idom;
    final retained = dominators.retained;
    var rootReachableObjects = 0;
    if (idom != null) {
      for (var id = 1; id < objects.length; id++) {
        if (idom[id] < 0) continue;
        rootReachableObjects++;
        final entry = classes[objects[id].classId]!;
        entry['rootReachableCount'] =
            (entry['rootReachableCount'] as int? ?? 0) + 1;
        entry['rootReachableShallowBytes'] =
            (entry['rootReachableShallowBytes'] as int? ?? 0) +
            objects[id].shallowSize;
      }
    }
    Map<String, Object?> describe(int id) => {
      'objectId': id,
      'class': objects[id].klass.name,
      'libraryUri': objects[id].klass.libraryUri.toString(),
      'shallowBytes': objects[id].shallowSize,
      if (retained != null) 'retainedBytes': retained[id],
    };
    List<int> largest(
      bool Function(int) include,
      int Function(int) size,
      int count,
    ) {
      final result = <int>[];
      for (var id = 2; id < objects.length; id++) {
        if (!include(id) ||
            (result.length == count && size(id) <= size(result.last))) {
          continue;
        }
        final index = result.indexWhere((other) => size(id) > size(other));
        result.insert(index < 0 ? result.length : index, id);
        if (result.length > count) result.removeLast();
      }
      return result;
    }

    final storagePattern = RegExp(r'Uint8|String|Array|Map');
    final targets = largest(
      (id) => storagePattern.hasMatch(objects[id].klass.name),
      (id) => objects[id].shallowSize,
      12,
    );
    final focusedClasses =
        (option('--focus') ??
                'SemanticsConfiguration,_RenderObjectSemantics,TextPainter,SingleChildRenderObjectElement')
            .split(',')
            .where((name) => name.isNotEmpty)
            .take(8);
    for (final name in focusedClasses) {
      targets.addAll(
        largest(
          (id) => objects[id].klass.name == name,
          (id) => retained?[id] ?? objects[id].shallowSize,
          2,
        ).where((id) => !targets.contains(id)),
      );
    }
    final paths = <Map<String, Object?>>[];
    for (final target in targets) {
      final path = <Map<String, Object?>>[describe(target)];
      if (idom != null) {
        var id = target;
        for (var depth = 0; depth < 24 && id != 1 && idom[id] > 0; depth++) {
          id = idom[id];
          path.add(describe(id));
        }
      }
      // 反向引用BFS寻找最近的应用owner，仅输出元数据；有严格节点/深度预算。
      final queue = <int>[target];
      final child = <int, int>{target: 0};
      var head = 0;
      int? owner;
      while (head < queue.length && head < 3000 && owner == null) {
        final id = queue[head++];
        final uri = objects[id].klass.libraryUri.toString();
        if (id != target && uri.startsWith('package:pili_aurora/')) {
          owner = id;
          break;
        }
        for (final parent in objects[id].referrers) {
          if (parent == 0 ||
              child.containsKey(parent) ||
              child.length >= 3000) {
            continue;
          }
          child[parent] = id;
          queue.add(parent);
        }
      }
      final ownerPath = <Map<String, Object?>>[];
      if (owner != null) {
        var id = owner;
        while (id != target && ownerPath.length < 24) {
          final next = child[id]!;
          final parent = objects[id];
          final indexes = <int>[];
          for (var i = 0; i < parent.references.length; i++) {
            if (parent.references[i] == next) indexes.add(i);
          }
          ownerPath.add({
            ...describe(id),
            'edgeToObject': next,
            'fields': [
              for (final field in parent.klass.fields)
                if (indexes.contains(field.index)) field.name,
            ],
          });
          id = next;
        }
        ownerPath.add(describe(target));
      }
      paths.add({
        'target': describe(target),
        'immediateDominatorChain': path,
        'nearestApplicationOwnerPath': ownerPath,
        'ownerSearchNodes': head,
        'ownerSearchCoverage': owner == null
            ? 'notFoundWithin3000Nodes'
            : 'found; pathMax24Edges',
      });
    }
    final summary = {
      'schemaVersion': 1,
      'objectCount': objects.length - 1,
      'referenceCount': graph.referenceCount,
      'shallowBytes': graph.shallowSize,
      'capacityBytes': graph.capacity,
      'externalBytes': graph.externalSize,
      'objectDataDecoded': false,
      'dominators': {
        'status': dominators.status,
        'iterations': dominators.iterations,
        'rootReachableObjects': rootReachableObjects,
        'rootRetainedShallowBytes': retained?[1],
        'semantics': 'reachableFromSnapshotRoot1; shallowOnlyRetained; overlappingOwnersMustNotBeSummed',
      },
      'classes': classRows,
      'largestRetainers': retained == null
          ? []
          : [
              for (final id in largest(
                (id) => idom![id] >= 0,
                (id) => retained[id],
                limit,
              ))
                describe(id),
            ],
      'largeStorageOwnerCandidates': paths,
    };
    await output.create(recursive: true);
    await File('${output.path}/heap-summary.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(summary));
    for (final row in classRows.take(limit)) {
      stdout.writeln(jsonEncode(row));
    }
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

({String status, int iterations, Int32List? idom, Int64List? retained})
_dominators(HeapSnapshotGraph graph) {
  final objects = graph.objects;
  final count = objects.length;
  final clock = Stopwatch()..start();
  final visited = Uint8List(count);
  final next = Uint32List(count);
  final stack = <int>[1];
  final postorder = <int>[];
  visited[1] = 1;
  while (stack.isNotEmpty) {
    final id = stack.last;
    final references = objects[id].references;
    if (next[id] < references.length) {
      final child = references[next[id]++];
      if (child != 0 && visited[child] == 0) {
        visited[child] = 1;
        stack.add(child);
      }
    } else {
      postorder.add(stack.removeLast());
    }
  }
  final order = postorder.reversed.toList();
  final rank = Int32List(count)..fillRange(0, count, -1);
  final idom = Int32List(count)..fillRange(0, count, -1);
  for (var index = 0; index < order.length; index++) {
    rank[order[index]] = index;
  }
  idom[1] = 1;
  int intersect(int a, int b) {
    while (a != b) {
      while (rank[a] > rank[b]) {
        a = idom[a];
      }
      while (rank[b] > rank[a]) {
        b = idom[b];
      }
    }
    return a;
  }

  var changed = true;
  var iterations = 0;
  while (changed && iterations < 50 && clock.elapsed.inSeconds < 60) {
    changed = false;
    iterations++;
    for (final id in order.skip(1)) {
      var parent = -1;
      for (final predecessor in objects[id].referrers) {
        if (idom[predecessor] >= 0) {
          parent = parent < 0 ? predecessor : intersect(parent, predecessor);
        }
      }
      if (idom[id] != parent) {
        idom[id] = parent;
        changed = true;
      }
    }
  }
  if (changed) {
    return (
      status: 'budgetExceeded; noRetainedSizes',
      iterations: iterations,
      idom: null,
      retained: null,
    );
  }
  final retained = Int64List(count);
  for (final id in order) {
    retained[id] = objects[id].shallowSize;
  }
  for (final id in postorder) {
    if (id != 1 && idom[id] >= 0) retained[idom[id]] += retained[id];
  }
  return (
    status: 'converged',
    iterations: iterations,
    idom: idom,
    retained: retained,
  );
}
