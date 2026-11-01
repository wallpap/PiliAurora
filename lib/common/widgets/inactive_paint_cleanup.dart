import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Windows 隐藏的保活页面卸载图片后，同时交还旧绘制记录。
///
/// 页面 State 和 RenderObject 继续保留；恢复可见时重新绘制。
class InactivePaintCleanup extends StatelessWidget {
  const InactivePaintCleanup({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.windows) return child;
    return _InactivePaintCleanup(
      active: TickerMode.valuesOf(context).enabled,
      child: child,
    );
  }
}

class _InactivePaintCleanup extends SingleChildRenderObjectWidget {
  const _InactivePaintCleanup({required this.active, required super.child});

  final bool active;

  @override
  _RenderInactivePaintCleanup createRenderObject(BuildContext context) =>
      _RenderInactivePaintCleanup(active);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderInactivePaintCleanup renderObject,
  ) {
    renderObject.active = active;
  }
}

class _RenderInactivePaintCleanup extends RenderProxyBox {
  _RenderInactivePaintCleanup(this._active);

  bool _active;
  bool _cleanupScheduled = false;
  int _activityGeneration = 0;

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    _activityGeneration++;
    if (!value) _scheduleCleanup();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _activityGeneration++;
    // GlobalKey 重新挂载可把已绘制的子树交给新建的不可见范围。
    if (!_active) _scheduleCleanup();
  }

  void _scheduleCleanup() {
    if (_cleanupScheduled) return;
    _cleanupScheduled = true;
    // 等当前帧完成合成，避免在构建或绘制过程中改动正在使用的层。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _cleanupScheduled = false;
      if (!attached || _active) return;
      _releasePictureContents();
      final generation = _activityGeneration;
      // PageView 可在下一帧才将旧页放入保活桶；首遍仍 attached 的
      // native 父层须等 detach 后再交还。每次停用仅补一遍，不循环。
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!attached || _active || generation != _activityGeneration) return;
        _releasePictureContents();
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    });
  }

  void _releasePictureContents() {
    final nodes = <RenderObject>[];
    final layers = <ContainerLayer>{};
    final detachedRoots = <ContainerLayer>{};
    final inspected = <Layer>{};
    var hasExternalContent = false;

    void inspect(Layer layer) {
      if (!inspected.add(layer)) return;
      if (layer.subtreeHasCompositionCallbacks ||
          layer is TextureLayer ||
          layer is PlatformViewLayer) {
        hasExternalContent = true;
        return;
      }
      if (layer is ContainerLayer) {
        var child = layer.firstChild;
        while (child != null) {
          inspect(child);
          child = child.nextSibling;
        }
      }
    }

    void collectLayers(ContainerLayer layer) {
      if (!layers.add(layer)) return;
      // Viewport 等组件会额外用 LayerHandle 保存内部裁剪层。旧卡片即使
      // 已销毁，这些层仍可持有其绘制记录，必须在摘下前收集整个层子树。
      var child = layer.firstChild;
      while (child != null) {
        if (child is ContainerLayer) collectLayers(child);
        child = child.nextSibling;
      }
    }

    void collect(RenderObject node) {
      if (node is TextureBox ||
          node is PlatformViewRenderBox ||
          node is RenderUiKitView ||
          node is RenderAppKitView) {
        hasExternalContent = true;
      }
      node.visitChildren(collect);
      nodes.add(node);
      if (node.layer case final layer?) {
        collectLayers(layer);
        if (!layer.attached) {
          var root = layer;
          while (root.parent != null) {
            root = root.parent!;
          }
          detachedRoots.add(root);
        }
      }
    }

    if (child case final child?) collect(child);
    for (final layer in {...layers, ...detachedRoots}) {
      inspect(layer);
    }
    // 播放器与平台视图的组合由各自生命周期管理。
    if (hasExternalContent || layers.isEmpty) return;
    final handles = <LayerHandle<ContainerLayer>>[];
    try {
      // 普通 Dart 引用不能阻止 Layer.dispose；只在本次操作中临时保活。
      for (final layer in {...layers, ...detachedRoots}) {
        handles.add(LayerHandle<ContainerLayer>(layer));
      }
      final orderedLayers = layers.toList()
        ..sort((a, b) => b.depth.compareTo(a.depth));
      for (final layer in orderedLayers) {
        layer.removeAllChildren();
      }
      for (final layer in orderedLayers) {
        // 原来 attached 的内部层也会在上一步摘下，按清理后的状态判断。
        if (layer.attached) continue;
        // 正常 Scene 构建会替换旧 engineLayer，交还其持有的 native 图片。
        layer.buildScene(ui.SceneBuilder()).dispose();
      }
      for (final root in detachedRoots) {
        // PageView 的边界可能位于范围外，只重建已脱离画面的根。
        if (!layers.contains(root)) {
          root.buildScene(ui.SceneBuilder()).dispose();
        }
      }
      for (final node in nodes) {
        node.markNeedsPaint();
      }
    } finally {
      for (final handle in handles) {
        handle.layer = null;
      }
    }
  }
}
