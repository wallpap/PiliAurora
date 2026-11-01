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
    bool recomposeHiddenAncestors = false,
    bool nearestHiddenBoundaryOnly = false,
    bool recursiveScopeContainers = false,
  }) {
    final nodes = <RenderObject>[];
    final scopedLayers = <ContainerLayer>{};
    final detachedRoots = <ContainerLayer>{};
    final attachedRoots = <ContainerLayer>{};
    final originallyDetached = <ContainerLayer>{};
    final hiddenAncestorLayers = <ContainerLayer>{};
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
    if (recomposeHiddenAncestors) {
      final ancestors = <RenderObject>[];
      int? hiddenBoundaryIndex;
      for (RenderObject? node = this; node != null; node = node.parent) {
        ancestors.add(node);
        final data = node.parentData;
        if ((node is RenderOffstage && node.offstage) ||
            (data is SliverMultiBoxAdaptorParentData && data.keptAlive)) {
          hiddenBoundaryIndex = ancestors.length - 1;
          if (nearestHiddenBoundaryOnly) break;
        }
      }
      if (hiddenBoundaryIndex != null) {
        for (final node in ancestors.take(hiddenBoundaryIndex + 1)) {
          if (node.layer case final layer?) hiddenAncestorLayers.add(layer);
        }
        // 只纳入连接到已确认隐藏祖先的中间层，绝不越过该边界去找全局根。
        final intermediateLayers = <ContainerLayer>{};
        for (final layer in {...scopedLayers, ...hiddenAncestorLayers}) {
          final chain = <ContainerLayer>[];
          var parent = layer.parent;
          while (parent != null && !hiddenAncestorLayers.contains(parent)) {
            chain.add(parent);
            parent = parent.parent;
          }
          if (parent != null) intermediateLayers.addAll(chain);
        }
        hiddenAncestorLayers.addAll(intermediateLayers);
      }
    }
    for (final layer in {
      ...scopedLayers,
      ...detachedRoots,
      ...attachedRoots,
      ...hiddenAncestorLayers,
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
        ...hiddenAncestorLayers,
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
      // scoped layers 可能已从当前 Dart 父链分离，但隐藏 route 的旧 native
      // 层仍引用它们。按由深到浅的顺序更新，保留隐藏祖先其余绘制内容。
      if (hiddenAncestorLayers.isNotEmpty) {
        final hiddenLayers = {...scopedLayers, ...hiddenAncestorLayers}.toList()
          ..sort((a, b) => b.depth.compareTo(a.depth));
        for (final layer in hiddenLayers) {
          layer.buildScene(ui.SceneBuilder()).dispose();
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
