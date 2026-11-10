import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/utils/desktop_window_background.dart';
import 'package:window_manager/window_manager.dart';

/// 标题栏置于路由之外，换页、主题切换和弹窗期间保持统一的窗口入口。
class DesktopWindowFrame extends StatelessWidget {
  const DesktopWindowFrame({
    super.key,
    required this.child,
    this.showTitleBar = true,
  });

  final Widget child;
  final bool showTitleBar;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: DesktopWindowBackground.fullscreen,
    child: child,
    // 浮层覆盖整个窗口，标题栏提示越过栏底时仍在页面内容上方绘制。
    builder: (context, fullscreen, child) => Overlay.wrap(
      child: Column(
        children: [
          if (showTitleBar && !fullscreen) const DesktopTitleBar(),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(size: constraints.biggest),
                child: child!,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _maximized = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    final revision = _revision;
    windowManager.isMaximized().then((value) {
      if (mounted && revision == _revision) setState(() => _maximized = value);
    });
  }

  @override
  void onWindowMaximize() {
    _revision++;
    setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    _revision++;
    setState(() => _maximized = false);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(
              child: DragToMoveArea(
                child: SizedBox.expand(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        ValueListenableBuilder(
                          valueListenable: Assets.iconStyle,
                          builder: (_, style, _) => Image.asset(
                            Assets.iconImage(style, theme.brightness),
                            width: 22,
                            height: 22,
                            excludeFromSemantics: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            Constants.appName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _button('最小化', Icons.remove, windowManager.minimize),
            _button(
              _maximized ? '还原' : '最大化',
              _maximized ? Icons.filter_none : Icons.crop_square,
              _maximized ? windowManager.unmaximize : windowManager.maximize,
            ),
            // 发送普通关闭事件，沿用主窗口的托盘驻留与播放器释放逻辑。
            _button('关闭', Icons.close, windowManager.close, close: true),
          ],
        ),
      ),
    );
  }

  Widget _button(
    String label,
    IconData icon,
    VoidCallback onPressed, {
    bool close = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 46,
      height: 36,
      child: Tooltip(
        message: label,
        child: TextButton(
          onPressed: onPressed,
          style: ButtonStyle(
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
            shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) =>
                  close &&
                      (states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.pressed))
                  ? Colors.white
                  : colors.onSurface,
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) =>
                  close &&
                      (states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.pressed))
                  ? const Color(0xFFC42B1C)
                  : Colors.transparent,
            ),
          ),
          child: Icon(icon, size: 18, semanticLabel: label),
        ),
      ),
    );
  }
}
