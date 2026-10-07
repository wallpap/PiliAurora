part of 'extended_nested_scroll_view.dart';

/// It may be include statusBarHeight ,pinned appbar height,pinned SliverPersistentHeader height
/// which are in NestedScrollViewHeaderSlivers
typedef NestedScrollViewPinnedHeaderSliverHeightBuilder = double Function();

class _ExtendedNestedScrollCoordinator extends _NestedScrollCoordinator {
  _ExtendedNestedScrollCoordinator(
    super.state,
    super.parent,
    super.onHasScrolledBodyChanged,
    super.floatHeaderSlivers,
    this.pinnedHeaderSliverHeightBuilder,
    this.onlyOneScrollInBody,
    this.scrollDirection,
  ) : bodyScrollDirection =
            scrollDirection == Axis.vertical ? Axis.horizontal : Axis.vertical {
    final double initialScrollOffset = _parent?.initialScrollOffset ?? 0.0;
    _outerController = ExtendedNestedScrollController(
      this,
      initialScrollOffset: initialScrollOffset,
      debugLabel: 'outer',
    );
    _innerController = ExtendedNestedScrollController(
      this,
      initialScrollOffset: 0.0,
      debugLabel: 'inner',
    );
  }

  /// Get the total height of pinned header in NestedScrollView header.
  final NestedScrollViewPinnedHeaderSliverHeightBuilder?
      pinnedHeaderSliverHeightBuilder;

  /// When [ExtendedNestedScrollView]'s body has [TabBarView]/[PageView] and
  /// their children have AutomaticKeepAliveClientMixin or PageStorageKey,
  /// [_innerController.nestedPositions] will have more one,
  /// will scroll all of scroll positions together.
  /// set [onlyOneScrollInBody] true to avoid it.
  final bool onlyOneScrollInBody;

  /// The axis along which the scroll view scrolls.
  ///
  /// Defaults to [Axis.vertical].
  final Axis scrollDirection;

  /// The [TabBarView]/[PageView] in body should perpendicular with The Axis of
  /// [ExtendedNestedScrollView].
  final Axis bodyScrollDirection;

  @override
  ExtendedNestedScrollController get _innerController =>
      super._innerController as ExtendedNestedScrollController;

  @override
  Iterable<_ExtendedNestedScrollPosition> get _innerPositions {
    final positions = _innerController.nestedPositions;

    if (positions.length <= 1 || !onlyOneScrollInBody) {
      return positions;
    }

    final actived =
        positions.where((_ExtendedNestedScrollPosition e) => e.isActived);
    if (actived.isNotEmpty) {
      return actived;
    }

    for (int i = positions.length - 1; i >= 0; i--) {
      final scrollPosition = positions.elementAt(i);
      // TODO(zmtzawqlp): throw exception even mounted is true
      // In order for an element to have a valid renderObject, it must be '
      //  'active, which means it is part of the tree.\n'
      //  'Instead, this element is in the $_lifecycleState state.\n'
      //  'If you called this method from a State object, consider guarding '
      //  'it with State.mounted.

      try {
        if (!(scrollPosition.context as ScrollableState).mounted) {
          continue;
        }

        final RenderObject? renderObject =
            scrollPosition.context.storageContext.findRenderObject();
        if (renderObject == null || !renderObject.attached) {
          continue;
        }

        if (renderObjectIsVisible(renderObject, bodyScrollDirection)) {
          return <_ExtendedNestedScrollPosition>[scrollPosition];
        }
      } catch (_) {
        // Silently ignore and continue
        continue;
      }
    }

    return positions;
  }

  /// Return whether renderObject is visible in parent
  bool childIsVisible(
    RenderObject parent,
    RenderObject renderObject,
  ) {
    bool visible = false;

    // The implementation has to return the children in paint order skipping all
    // children that are not semantically relevant (e.g. because they are
    // invisible).
    parent.visitChildrenForSemantics((RenderObject child) {
      if (renderObject == child) {
        visible = true;
      } else {
        visible = childIsVisible(child, renderObject);
      }
    });
    return visible;
  }

  bool renderObjectIsVisible(RenderObject renderObject, Axis axis) {
    final RenderViewport? parent = findParentRenderViewport(renderObject);
    if (parent != null && parent.axis == axis) {
      for (final RenderSliver childrenInPaint
          // ignore: invalid_use_of_protected_member
          in parent.childrenInHitTestOrder) {
        return childIsVisible(childrenInPaint, renderObject) &&
            renderObjectIsVisible(parent, axis);
      }
    }
    return true;
  }

  RenderViewport? findParentRenderViewport(RenderObject? object) {
    if (object == null) {
      return null;
    }
    object = object.parent;
    while (object != null) {
      // only find in body
      if (object is _ExtendedRenderSliverFillRemainingWithScrollable) {
        return null;
      }
      if (object is RenderViewport) {
        return object;
      }
      object = object.parent;
    }
    return null;
  }

  @override
  void updateCanDrag({_NestedScrollPosition? position}) {
    if (onlyOneScrollInBody &&
        position != null &&
        position.debugLabel == 'inner') {
      double maxInnerExtent = 0.0;
      if (position.haveDimensions) {
        maxInnerExtent = math.max(
          maxInnerExtent,
          position.maxScrollExtent - position.minScrollExtent,
        );

        position.updateCanDrag(maxInnerExtent >
                (position.viewportDimension - position.maxScrollExtent) ||
            position.minScrollExtent != position.maxScrollExtent);
      }
    }

    super.updateCanDrag();
  }
}

class ExtendedNestedScrollController extends _NestedScrollController {
  ExtendedNestedScrollController(
    // ignore: library_private_types_in_public_api
    _ExtendedNestedScrollCoordinator super.coordinator, {
    super.initialScrollOffset,
    super.debugLabel,
  });
  @override
  // ignore: library_private_types_in_public_api
  _ExtendedNestedScrollCoordinator get coordinator =>
      super.coordinator as _ExtendedNestedScrollCoordinator;

  @override
  // ignore: library_private_types_in_public_api
  Iterable<_ExtendedNestedScrollPosition> get nestedPositions =>
      kDebugMode ? _debugNestedPositions : _releaseNestedPositions;

  Iterable<_ExtendedNestedScrollPosition> get _debugNestedPositions {
    return positions.cast<_ExtendedNestedScrollPosition>();
  }

  Iterable<_ExtendedNestedScrollPosition> get _releaseNestedPositions sync* {
    yield* positions.cast<_ExtendedNestedScrollPosition>();
  }

  @override
  void attach(ScrollPosition position) {
    assert(position is _NestedScrollPosition);
    super.attach(position);
    coordinator
      ..updateParent()
      ..updateCanDrag(position: position as _NestedScrollPosition);
    position.addListener(_scheduleUpdateShadow);
    _scheduleUpdateShadow();
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _ExtendedNestedScrollPosition(
      coordinator: coordinator,
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _ExtendedNestedScrollPosition extends _NestedScrollPosition {
  _ExtendedNestedScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.oldPosition,
    super.debugLabel,
    required _ExtendedNestedScrollCoordinator super.coordinator,
  });
  @override
  _ExtendedNestedScrollCoordinator get coordinator =>
      super.coordinator as _ExtendedNestedScrollCoordinator;

  @override
  void applyNewDimensions() {
    super.applyNewDimensions();
    coordinator.updateCanDrag(position: this);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    if (debugLabel == 'outer' &&
        coordinator.pinnedHeaderSliverHeightBuilder != null) {
      maxScrollExtent =
          maxScrollExtent - coordinator.pinnedHeaderSliverHeightBuilder!();
      maxScrollExtent = math.max(0.0, maxScrollExtent);
    }

    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }

  bool _isActived = false;
  @override
  Drag drag(DragStartDetails details, VoidCallback dragCancelCallback) {
    // print('drag--$debugLabel');
    _isActived = true;
    return coordinator.drag(details, () {
      dragCancelCallback();
      _isActived = false;
      //print('dragCancel--$debugLabel');
    });
  }

  /// Whether is actived now
  bool get isActived => _isActived;
}

class _ExtendedSliverFillRemainingWithScrollable
    extends SingleChildRenderObjectWidget {
  const _ExtendedSliverFillRemainingWithScrollable({
    super.child,
  });

  @override
  _ExtendedRenderSliverFillRemainingWithScrollable createRenderObject(
          BuildContext context) =>
      _ExtendedRenderSliverFillRemainingWithScrollable();
}

class _ExtendedRenderSliverFillRemainingWithScrollable
    extends RenderSliverFillRemainingWithScrollable {}

// this is a bug that the out postion is not overscroll actually and it get minimal value
// do under code will scroll inner positions
// igore minimal value here(value like following data)
// I/flutter (14963): 5.684341886080802e-14
// I/flutter (14963): -5.684341886080802e-14
// I/flutter (14963): -5.684341886080802e-14
// I/flutter (14963): 5.684341886080802e-14
// I/flutter (14963): -5.684341886080802e-14
// I/flutter (14963): -5.684341886080802e-14
// I/flutter (14963): -5.684341886080802e-14
extension DoubleEx on double {
  bool get notZero => abs() > precisionErrorTolerance;
  bool get isZero => abs() < precisionErrorTolerance;
}
