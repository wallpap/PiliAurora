import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 仅观察安装 hook 后创建的 Dart 句柄，不代表引擎/GPU 实际驻留内存。
/// Image clone 各计一个句柄，像素估算不可当作独立 backing 总量。
class FlutterGraphicsMetrics {
  FlutterGraphicsMetrics({
    this.maxResources = 128,
    this.maxGroups = 64,
    @visibleForTesting this.useFrameworkEvents = true,
  }) : assert(maxResources > 0),
       assert(maxGroups > 0);

  final int maxResources;
  final int maxGroups;
  final bool useFrameworkEvents;
  _Generation? _generation;
  void Function()? _restore;

  bool get isRunning => _restore != null;

  void start({bool captureStacks = false}) {
    if (isRunning) return;
    final generation = _Generation(maxResources, maxGroups, captureStacks);
    _generation = generation;
    // Debug 的 DevTools 同样使用该分发器，不能夺取它管理的 SDK hook。
    if (kFlutterMemoryAllocationsEnabled && useFrameworkEvents) {
      void listener(ObjectEvent event) {
        if (!generation.active) return;
        final object = event.object;
        if (object is! ui.Image && object is! ui.Picture) return;
        if (event is ObjectDisposed) {
          generation.dispose(object);
        } else if (event is ObjectCreated) {
          if (object is ui.Image) {
            generation.create(
              object,
              'image',
              object.width * object.height * 4,
              '${object.width}x${object.height}',
            );
          } else if (object is ui.Picture) {
            generation.create(
              object,
              'picture',
              object.approximateBytesUsed,
              null,
            );
          }
        }
      }

      FlutterMemoryAllocations.instance.addListener(listener);
      _restore = () {
        generation.active = false;
        FlutterMemoryAllocations.instance.removeListener(listener);
      };
      return;
    }
    final imageCreate = ui.Image.onCreate;
    final imageDispose = ui.Image.onDispose;
    final pictureCreate = ui.Picture.onCreate;
    final pictureDispose = ui.Picture.onDispose;
    void onImageCreate(ui.Image image) {
      if (generation.active) {
        generation.create(
          image,
          'image',
          image.width * image.height * 4,
          '${image.width}x${image.height}',
        );
      }
      imageCreate?.call(image);
    }

    void onImageDispose(ui.Image image) {
      if (generation.active) generation.dispose(image);
      imageDispose?.call(image);
    }

    void onPictureCreate(ui.Picture picture) {
      if (generation.active) {
        generation.create(
          picture,
          'picture',
          picture.approximateBytesUsed,
          null,
        );
      }
      pictureCreate?.call(picture);
    }

    void onPictureDispose(ui.Picture picture) {
      if (generation.active) generation.dispose(picture);
      pictureDispose?.call(picture);
    }

    ui.Image.onCreate = onImageCreate;
    ui.Image.onDispose = onImageDispose;
    ui.Picture.onCreate = onPictureCreate;
    ui.Picture.onDispose = onPictureDispose;
    _restore = () {
      generation.active = false;
      if (identical(ui.Image.onCreate, onImageCreate)) {
        ui.Image.onCreate = imageCreate;
      }
      if (identical(ui.Image.onDispose, onImageDispose)) {
        ui.Image.onDispose = imageDispose;
      }
      if (identical(ui.Picture.onCreate, onPictureCreate)) {
        ui.Picture.onCreate = pictureCreate;
      }
      if (identical(ui.Picture.onDispose, onPictureDispose)) {
        ui.Picture.onDispose = pictureDispose;
      }
    };
  }

  void stop() {
    _restore?.call();
    _restore = null;
  }

  Map<String, Object?> snapshot({int limit = 16}) => {
    'running': isRunning,
    'coverage':
        'createdWhileHooksInstalled; currentIsNotYetDisposedOrGcObserved',
    'imageByteSemantics':
        'handleEstimatedBytes=width*height*4; clonesCountSeparately',
    'gcSemantics': 'bestEffortFinalizerObservation; notNativeRelease',
    ...?_generation?.snapshot(limit < 0 ? 0 : limit),
  };
}

class _Counts {
  int created = 0, disposed = 0, gcObserved = 0, current = 0, bytes = 0;
  int peakCount = 0, peakBytes = 0;

  void add(int size) {
    created++;
    current++;
    bytes += size;
    if (current > peakCount) peakCount = current;
    if (bytes > peakBytes) peakBytes = bytes;
  }

  void remove(int size, bool gc) {
    if (gc) {
      gcObserved++;
    } else {
      disposed++;
    }
    current--;
    bytes -= size;
  }

  Map<String, Object> json() => {
    'created': created,
    'explicitlyDisposed': disposed,
    'gcObserved': gcObserved,
    'currentHandles': current,
    'currentBytes': bytes,
    'peakHandles': peakCount,
    'peakBytes': peakBytes,
  };
}

class _Resource {
  _Resource(this.id, this.kind, this.bytes, this.dimensions, this.group);
  final int id;
  final String kind;
  final int bytes;
  final String? dimensions;
  final String group;
  bool ended = false;
}

class _Generation {
  _Generation(this.maxResources, this.maxGroups, this.captureStacks) {
    finalizer = Finalizer<_Resource>((resource) {
      if (active) end(resource, true);
    });
  }
  final int maxResources, maxGroups;
  final bool captureStacks;
  bool active = true;
  int nextId = 0;
  final metadata = Expando<_Resource>();
  late final Finalizer<_Resource> finalizer;
  final counts = {'image': _Counts(), 'picture': _Counts()};
  final groups = <String, _Counts>{};
  final resources = <int, _Resource>{};

  void create(Object object, String kind, int bytes, String? dimensions) {
    var group = '$kind:${dimensions ?? 'nominal'}';
    if (captureStacks) {
      group +=
          ':${StackTrace.current.toString().split('\n').take(12).join('\n')}';
    }
    if (!groups.containsKey(group) && groups.length >= maxGroups) {
      group = 'other';
    }
    final resource = _Resource(++nextId, kind, bytes, dimensions, group);
    metadata[object] = resource;
    finalizer.attach(object, resource, detach: resource);
    counts[kind]!.add(bytes);
    (groups[group] ??= _Counts()).add(bytes);
    // 只保留最大的有限个活句柄；移出的条目仍由 Expando/finalizer 计数。
    if (resources.length >= maxResources) {
      final smallest = resources.values.reduce(
        (a, b) => a.bytes < b.bytes ? a : b,
      );
      if (smallest.bytes >= bytes) return;
      resources.remove(smallest.id);
    }
    resources[resource.id] = resource;
  }

  void dispose(Object object) {
    final resource = metadata[object];
    if (resource == null || resource.ended) return;
    finalizer.detach(resource);
    end(resource, false);
  }

  void end(_Resource resource, bool gc) {
    if (resource.ended) return;
    resource.ended = true;
    counts[resource.kind]!.remove(resource.bytes, gc);
    groups[resource.group]!.remove(resource.bytes, gc);
    resources.remove(resource.id);
  }

  Map<String, Object> snapshot(int limit) {
    final largest = resources.values.toList()
      ..sort((a, b) => b.bytes.compareTo(a.bytes));
    return {
      'image': {
        ...counts['image']!.json(),
        'byteSemantics': 'handleEstimatedBytes',
      },
      'picture': {
        ...counts['picture']!.json(),
        'byteSemantics': 'approximateBytesUsed',
      },
      'groups': {for (final e in groups.entries) e.key: e.value.json()},
      'resourceSummaryCoverage':
          'boundedCandidates; evictedHandlesNotBackfilled',
      'trackedResourceLimit': maxResources,
      'largestResources': [
        for (final r in largest.take(limit))
          {
            'id': r.id,
            'kind': r.kind,
            'bytes': r.bytes,
            if (r.dimensions != null) 'dimensions': r.dimensions!,
          },
      ],
    };
  }
}
