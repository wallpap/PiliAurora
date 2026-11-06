import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 仅供内存实验：使用正常 addToScene 路径替换离屏树的旧 engine layer。
class RetainedLayerCleanupPrototype extends SingleChildRenderObjectWidget {
  const RetainedLayerCleanupPrototype({super.key, required super.child});

  @override
  RenderRetainedLayerCleanupPrototype createRenderObject(
    BuildContext context,
  ) => RenderRetainedLayerCleanupPrototype();
}

class RenderRetainedLayerCleanupPrototype extends RenderProxyBox {
  bool release({
    VoidCallback? afterDartRelease,
    bool recomposeAttachedScopes = false,
    bool recomposeAttachedRoots = false,
    bool recursiveScopeContainers = false,
  }) {
    final nodes = <RenderObject>[];
    final scopedLayers = <ContainerLayer>{};
    final detachedRoots = <ContainerLayer>{};
    final attachedRoots = <ContainerLayer>{};
    final originallyDetached = <ContainerLayer>{};
    final inspected = <Layer>{};
    final handles = <LayerHandle<ContainerLayer>>[];
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
        scopedLayers.add(layer);
        if (!layer.attached) {
          originallyDetached.add(layer);
        }
        if (!layer.attached || recomposeAttachedRoots) {
          var root = layer;
          while (root.parent != null) {
            root = root.parent!;
          }
          if (!root.attached) detachedRoots.add(root);
          if (root.attached && recomposeAttachedRoots) attachedRoots.add(root);
        }
      }
    }

    if (child case final child?) collect(child);
    if (recursiveScopeContainers) {
      final collected = <Layer>{};
      void collectContainers(Layer layer) {
        if (!collected.add(layer) || layer is! ContainerLayer) return;
        var child = layer.firstChild;
        while (child != null) {
          collectContainers(child);
          child = child.nextSibling;
        }
        scopedLayers.add(layer);
      }

      for (final layer in scopedLayers.toList()) {
        collectContainers(layer);
      }
    }
    for (final layer in {
      ...scopedLayers,
      ...detachedRoots,
      ...attachedRoots,
    }) {
      inspect(layer);
    }
    if (hasExternalContent || scopedLayers.isEmpty) return false;

    try {
      // 不依赖普通 Dart 引用阻止 Layer.dispose；计数引用只持续本次同步操作。
      for (final layer in {
        ...scopedLayers,
        ...detachedRoots,
        ...attachedRoots,
      }) {
        handles.add(LayerHandle<ContainerLayer>(layer));
      }
      for (final layer in scopedLayers) {
        layer.removeAllChildren();
      }
      afterDartRelease?.call();

      final recomposableLayers = recursiveScopeContainers
          ? (scopedLayers.toList()..sort((a, b) => b.depth.compareTo(a.depth)))
          : recomposeAttachedScopes
          ? scopedLayers
          : originallyDetached;
      for (final layer in recomposableLayers) {
        if (recursiveScopeContainers && layer.attached) continue;
        layer.buildScene(ui.SceneBuilder()).dispose();
      }
      // PageView 自动创建的边界可能位于范围外，仍可持有旧 native 子层。
      // 仅允许重建原来已 detached 的根，且保留其余 Dart 子树。
      for (final root in detachedRoots) {
        if (!originallyDetached.contains(root)) {
          root.buildScene(ui.SceneBuilder()).dispose();
        }
      }
      for (final root in attachedRoots) {
        if (!recomposeAttachedScopes || !scopedLayers.contains(root)) {
          root.buildScene(ui.SceneBuilder()).dispose();
        }
      }
      for (final node in nodes) {
        node.markNeedsPaint();
      }
      return true;
    } finally {
      for (final handle in handles) {
        handle.layer = null;
      }
    }
  }
}
