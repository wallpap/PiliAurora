import 'dart:async';
import 'dart:math' as math;
import 'dart:math' show max;

import 'package:flutter/services.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show tabBarScrollPhysics;
import 'package:pili_aurora/pages/common/publish/publish_route.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:pili_aurora/utils/extension/widget_ext.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

typedef OnPayCoin = FutureOr<void> Function(int coin, bool coinWithLike);

class PayCoinsPage extends StatefulWidget {
  const PayCoinsPage({
    super.key,
    required this.onPayCoin,
    required this.hasCoin,
    required this.hasCopyright,
  });

  final OnPayCoin onPayCoin;
  final bool hasCoin;
  final bool hasCopyright;

  @override
  State<PayCoinsPage> createState() => _PayCoinsPageState();

  static void toPayCoinsPage({
    required OnPayCoin onPayCoin,
    required bool hasCoin,
    required bool hasCopyright,
  }) {
    Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          return PayCoinsPage(
            onPayCoin: onPayCoin,
            hasCoin: hasCoin,
            hasCopyright: hasCopyright,
          );
        },
        transitionDuration: const Duration(milliseconds: 225),
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
      ),
    );
  }
}

class _PayCoinsPageState extends State<PayCoinsPage>
    with SingleTickerProviderStateMixin {
  late final _key = GlobalKey();
  late final _hasCopyright = widget.hasCopyright;
  late bool _isPaying = false;
  PageController? _controller;
  late final RxBool _coinWithLike = Pref.coinWithLike.obs;
  late final RxInt _pageIndex = 0.obs;

  late final AnimationController _selectionScaleController;
  late final List<Future<ByteData>> _tossAssets;
  Uint8List? _tossBytes;
  Timer? _paymentTimer;
  VoidCallback? _completePayment;
  // 与导出脚本中的 24 帧 × 40ms 保持一致；从 GIF 首帧显示时开始计时。
  static const _tossDuration = Duration(milliseconds: 960);

  final num? _coins = GlobalData().coins;

  bool _canPay(int index) {
    if (index == 1 && widget.hasCoin) {
      return false;
    }
    if (_coins == null || _coins >= 1 + index) {
      return true;
    }
    return false;
  }

  String _getPayImage(int index, bool canPay) {
    if (!canPay) {
      return Assets.coinsEmpty;
    }
    return index == 0 ? Assets.coinsReadyOne : Assets.coinsReadyTwo;
  }

  Color _getPayFilter(int index) =>
      _canPay(index) ? Colors.transparent : const Color(0x66000000);

  @override
  void initState() {
    super.initState();
    if (_hasCopyright) {
      _controller = PageController(viewportFraction: 0.30);
    }

    _selectionScaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 50),
      lowerBound: 1.0,
      upperBound: 1.1,
    );
    _tossAssets = [
      rootBundle.load(Assets.coinTossOne),
      rootBundle.load(Assets.coinTossTwo),
    ];

    WidgetsBinding.instance.addPostFrameCallback(_scale);
  }

  @override
  void dispose() {
    _paymentTimer?.cancel();
    _selectionScaleController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  void _scale([_]) {
    _selectionScaleController.forward().then((_) {
      if (mounted) _selectionScaleController.reverse();
    });
  }

  void _onScroll(int index) {
    _controller?.animateToPage(
      index,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
    _scale();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isPortrait = size.isPortrait;
    return isPortrait
        ? _buildBody(isPortrait)
        : _buildBody(isPortrait).constraintWidth(
            constraints: BoxConstraints(
              maxWidth: math.min(525, size.width * 0.6),
            ),
          );
  }

  Widget _buildCoinWidget(int index, double factor) {
    final filter = _getPayFilter(index);
    final boxSize = 70 + (factor * 30);
    final coinSize = 35 + (factor * 15);
    return Stack(
      alignment: .center,
      children: [
        Image.asset(
          Assets.payBox,
          color: filter,
          width: boxSize,
          height: boxSize,
          cacheWidth: 100.cacheSize(context),
          colorBlendMode: .srcATop,
        ),
        Image.asset(
          index == 0 ? Assets.coinsOne : Assets.coinsTwo,
          height: coinSize,
          width: coinSize,
          cacheWidth: 50.cacheSize(context),
          color: filter,
          colorBlendMode: .srcATop,
        ),
      ],
    );
  }

  Widget _buildToss() {
    final index = _pageIndex.value;
    final canPay = _canPay(index) && !_isPaying;
    final payImg = _getPayImage(index, _canPay(index));
    return GestureDetector(
      onTap: canPay ? _onPayCoin : null,
      onVerticalDragStart: canPay
          ? (e) {
              _isHorizontal = false;
              _onDragDown(e);
            }
          : null,
      onVerticalDragUpdate: canPay ? _onDragUpdate : null,
      onVerticalDragEnd: canPay ? _onDragEnd : null,
      onVerticalDragCancel: canPay ? _onDragEnd : null,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        excludeSemantics: true,
        label: _isPaying
            ? '正在投币'
            : canPay
            ? '上滑投${index + 1}枚硬币'
            : '硬币不足或已达上限',
        button: canPay,
        child: ScaleTransition(
          scale: _selectionScaleController,
          child: SizedBox(
            width: 180,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 180,
                  height: 130,
                  child: _tossBytes == null
                      ? Image.asset(
                          payImg,
                          cacheWidth: 180.cacheSize(context),
                          excludeFromSemantics: true,
                        )
                      : Image.memory(
                          _tossBytes!,
                          excludeFromSemantics: true,
                          frameBuilder:
                              (context, child, frame, wasSynchronouslyLoaded) {
                                if (frame != null && _paymentTimer == null) {
                                  _paymentTimer = Timer(
                                    _tossDuration,
                                    _completePayment!,
                                  );
                                }
                                return child;
                              },
                        ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isPaying
                      ? '投币中'
                      : canPay
                      ? '上滑投币'
                      : '暂时无法投币',
                  style: const TextStyle(
                    color: Color(0xFFE8DDCB),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(bool isV) => Stack(
    key: _key,
    clipBehavior: Clip.none,
    alignment: Alignment.center,
    children: [
      Align(
        alignment: Alignment.bottomCenter,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_hasCopyright)
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: SizedBox(
                        height: 100,
                        child: PageView(
                          physics: _isPaying
                              ? const NeverScrollableScrollPhysics()
                              : tabBarScrollPhysics,
                          controller: _controller,
                          onPageChanged: (index) {
                            _scale();
                            _pageIndex.value = index;
                          },
                          children: List.generate(
                            2,
                            (index) {
                              return ListenableBuilder(
                                listenable: _controller!,
                                builder: (context, child) {
                                  double factor = index == 0 ? 1 : 0;
                                  if (_controller!
                                      .position
                                      .hasContentDimensions) {
                                    factor =
                                        1 - (_controller!.page! - index).abs();
                                  }
                                  return Obx(
                                    () {
                                      if (_pageIndex.value != index &&
                                          _isPaying) {
                                        return const SizedBox.shrink();
                                      }
                                      return _buildCoinWidget(index, factor);
                                    },
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Obx(
                        () {
                          final index = _pageIndex.value;
                          if (_isPaying) {
                            return const SizedBox.shrink();
                          }
                          return GestureDetector(
                            onTap: index == 0 ? null : () => _onScroll(0),
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Image.asset(
                                width: 16,
                                height: 28,
                                index == 0 ? Assets.leftDisable : Assets.left,
                                cacheWidth: 16.cacheSize(context),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Obx(() {
                        final index = _pageIndex.value;
                        if (_isPaying) {
                          return const SizedBox.shrink();
                        }
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: index == 1 ? null : () => _onScroll(1),
                          child: Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Image.asset(
                              width: 16,
                              height: 28,
                              index == 1 ? Assets.rightDisable : Assets.right,
                              cacheWidth: 16.cacheSize(context),
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                )
              else
                Center(
                  child: SizedBox(height: 100, child: _buildCoinWidget(0, 1)),
                ),
              if (isV)
                const SizedBox(height: 25)
              else
                const SizedBox(height: 10),
              if (_hasCopyright)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: _isPaying
                      ? null
                      : (e) {
                          _isHorizontal = true;
                          _onDragDown(e);
                        },
                  onHorizontalDragUpdate: _isPaying ? null : _onDragUpdate,
                  onHorizontalDragEnd: _onDragEnd,
                  onHorizontalDragCancel: _onDragEnd,
                  child: Center(child: Obx(_buildToss)),
                )
              else
                Center(child: _buildToss()),
              if (_coins != null || widget.hasCoin) ...[
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    '${_coins != null ? '硬币余额：${max(0.0, _coins.toDouble().toPrecision(1))}' : ''}${widget.hasCoin ? '${_coins != null ? '，' : ''}已投1枚硬币' : ''}',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  GestureDetector(
                    onTap: () {
                      final newVal = !_coinWithLike.value;
                      _coinWithLike.value = newVal;
                      GStorage.setting.put(SettingBoxKey.coinWithLike, newVal);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 12),
                        Obx(
                          () => Icon(
                            _coinWithLike.value
                                ? Icons.check_box_outlined
                                : Icons.check_box_outline_blank,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                        const Text(
                          ' 同时点赞',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                  Center(
                    child: GestureDetector(
                      onTap: Get.back,
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        width: 30,
                        height: 30,
                        child: Image.asset(
                          Assets.panelClose,
                          width: 30,
                          height: 30,
                          cacheWidth: 30.cacheSize(context),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(
                height:
                    (isV ? 50 : 10) + MediaQuery.viewPaddingOf(context).bottom,
              ),
            ],
          ),
        ),
      ),
    ],
  );

  late bool _isHorizontal = true;
  DragStartDetails? _downPos;
  void _onDragDown(DragStartDetails detail) => _downPos = detail;
  void _onDragEnd([_]) => _downPos = null;
  void _onDragUpdate(DragUpdateDetails e) {
    if (_isPaying || _downPos == null) {
      return;
    }
    final offset = _isHorizontal
        ? (e.localPosition.dx - _downPos!.localPosition.dx).abs()
        : (e.localPosition.dy - _downPos!.localPosition.dy).abs();
    if (offset < 20) {
      return;
    }
    _downPos = null;
    if (_isHorizontal) {
      if (e.delta.dx > 0) {
        if (_pageIndex.value == 1) {
          _onScroll(0);
        }
      } else {
        if (_pageIndex.value == 0) {
          _onScroll(1);
        }
      }
    } else {
      if (e.delta.dy < 0) {
        _onPayCoin();
      }
    }
  }

  Future<void> _onPayCoin() async {
    final index = _pageIndex.value;
    if (_isPaying || !_canPay(index)) return;
    setState(() => _isPaying = true);
    final coinWithLike = _coinWithLike.value;
    _completePayment = () {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      Get.back();
      unawaited(_submitCoin(index + 1, coinWithLike));
    };
    try {
      final data = await _tossAssets[index];
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      setState(() {
        // 每次创建独立 MemoryImage，单次 GIF 再次打开时从首帧开始。
        _tossBytes = Uint8List.fromList(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      });
    } catch (error, stackTrace) {
      logger.w('加载投币动画失败', error: error.runtimeType, stackTrace: stackTrace);
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      setState(() => _isPaying = false);
      SmartDialog.showToast('投币动画加载失败，请重新打开面板');
    }
  }

  Future<void> _submitCoin(int coin, bool withLike) async {
    try {
      await widget.onPayCoin(coin, withLike);
    } catch (error, stackTrace) {
      logger.w('投币回调未完成', error: error.runtimeType, stackTrace: stackTrace);
      SmartDialog.showToast('投币结果待确认，请先核对后再操作');
    }
  }
}
