import 'dart:io' show Platform;

import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart'
    show routeObserver;
import 'package:pili_aurora/common/widgets/selection_text.dart';
import 'package:pili_aurora/common/widgets/webview_ready.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/services/webview_environment.dart';
import 'package:pili_aurora/models/common/webview_menu_type.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/login_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

final _prefixRegex = RegExp(r'^(?!(https?://))\S+://', caseSensitive: false);

class WebviewPage extends StatefulWidget {
  const WebviewPage({
    super.key,
    this.url,
    this.oid,
    this.title,
  });

  // note
  final int? oid;
  final String? title;
  final String? url;

  @override
  State<WebviewPage> createState() => _WebviewPageState();
}

class _WebviewPageState extends State<WebviewPage> with RouteAware {
  late String _currentUrl;
  late final String userAgent;
  late final RxString _title;
  final RxDouble _progress = 1.0.obs;
  bool _inApp = false;
  bool _off = false;
  bool _rewriteCopyrightReport = false;

  InAppWebViewController? _webViewController;
  ModalRoute<dynamic>? _pageRoute;
  int _generation = 0;
  int? _menuGeneration;

  @override
  void initState() {
    super.initState();
    final parameters = Get.parameters;
    _currentUrl = (widget.url ?? parameters['url'] ?? 'about:blank').http2https;
    _title = _currentUrl.obs;
    userAgent = switch (parameters['uaType']) {
      'pc' => BrowserUa.pc,
      'mob' => BrowserUa.mob,
      _ => BrowserUa.platform,
    };
    if (Get.arguments case final Map map) {
      _inApp = map['inApp'] == true;
      _off = map['off'] == true;
      _rewriteCopyrightReport = map['rewriteCopyrightReport'] == true;
    }

    if (Get.routing.route case final GetPageRoute route) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageRoute = ModalRoute.of(context);
  }

  bool _ownsController(InAppWebViewController controller, int generation) =>
      mounted &&
      !_isPop &&
      generation == _generation &&
      identical(controller, _webViewController);

  bool _currentController(InAppWebViewController controller, int generation) =>
      _ownsController(controller, generation) &&
      (_pageRoute?.isCurrent ?? true);

  @override
  void didPushNext() => _generation++;

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _generation++;
    _webViewController = null;
    super.dispose();
  }

  bool _isPop = false;
  @override
  void didPop() {
    _generation++;
    setState(() {
      _webViewController = null;
      _isPop = true;
    });
    super.didPop();
  }

  List<Widget> get _actions {
    return [
      PopupMenuButton<WebviewMenuItem>(
        onSelected: _handleMenuItem,
        itemBuilder: (context) => <PopupMenuEntry<WebviewMenuItem>>[
          ...WebviewMenuItem.values
              .take(WebviewMenuItem.values.length - 1)
              .map(
                (item) => AppPopupMenuItem(
                  value: item,
                  child: Text(item.title),
                ),
              ),
          const PopupMenuDivider(),
          AppPopupMenuItem(
            value: WebviewMenuItem.goBack,
            child: Text(
              WebviewMenuItem.goBack.title,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Future<void> _handleMenuItem(WebviewMenuItem item) async {
    if (_menuGeneration == _generation ||
        !mounted ||
        !(_pageRoute?.isCurrent ?? true)) {
      return;
    }
    final controller = _webViewController;
    if (controller == null) {
      SmartDialog.showToast('网页尚未准备好，请稍后重试');
      return;
    }
    final generation = _generation;
    bool current() => _currentController(controller, generation);
    _menuGeneration = generation;
    try {
      switch (item) {
        case WebviewMenuItem.refresh:
          await controller.reload();
          break;
        case WebviewMenuItem.copy:
          final uri = await controller.getUrl();
          if (!current()) return;
          if (uri == null) {
            SmartDialog.showToast('暂无可用的网页链接');
            return;
          }
          await Clipboard.setData(ClipboardData(text: uri.toString()));
          if (current()) SmartDialog.showToast('已复制');
          break;
        case WebviewMenuItem.openInBrowser:
          final uri = await controller.getUrl();
          if (!current()) return;
          if (uri == null) {
            SmartDialog.showToast('暂无可用的网页链接');
            return;
          }
          await PageUtils.launchURL(uri.toString());
          break;
        case WebviewMenuItem.clearCache:
          await InAppWebViewController.clearAllCache();
          if (!current()) return;
          await controller.clearHistory();
          if (current()) SmartDialog.showToast('已清理');
          break;
        case WebviewMenuItem.goBack:
          final canGoBack = await controller.canGoBack();
          if (!current()) return;
          if (canGoBack) {
            await controller.goBack();
          } else {
            Get.back();
          }
          break;
        case WebviewMenuItem.resetCookie:
          final account = Accounts.main;
          bool isCurrent() =>
              current() &&
              identical(account, Accounts.main) &&
              (_pageRoute?.isCurrent ?? true);
          try {
            if (await LoginUtils.setWebCookie(account) && isCurrent()) {
              SmartDialog.showToast('设置成功，刷新或重新打开网页');
            }
          } catch (error, stackTrace) {
            logger.w(
              '网页 Cookie 同步失败',
              error: error.runtimeType,
              stackTrace: stackTrace,
            );
            if (isCurrent()) SmartDialog.showToast('网页 Cookie 同步失败，请重试');
          }
          break;
      }
    } catch (error, stackTrace) {
      logger.w(
        '网页菜单操作失败: ${item.name}',
        error: error.runtimeType,
        stackTrace: stackTrace,
      );
      if (current()) {
        SmartDialog.showToast(switch (item) {
          WebviewMenuItem.clearCache => '缓存或浏览历史清理失败，请重试',
          WebviewMenuItem.copy => '链接复制失败，请重试',
          WebviewMenuItem.goBack => '网页返回失败，请重试',
          _ => '网页操作失败，请重试',
        });
      }
    } finally {
      if (_menuGeneration == generation) _menuGeneration = null;
    }
  }

  Future<void> _runWebOperation(
    InAppWebViewController controller,
    Future<void> Function(bool Function() current) operation,
  ) async {
    final generation = _generation;
    bool current() => _currentController(controller, generation);
    if (!current()) return;
    try {
      await operation(current);
    } catch (error, stackTrace) {
      logger.w('网页插件操作失败', error: error.runtimeType, stackTrace: stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.url != null
          ? null
          : AppBar(
              title: Obx(
                () => Text(
                  _title.value.isNotEmpty ? _title.value : _currentUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              bottom: PreferredSize(
                preferredSize: Size.zero,
                child: Obx(
                  () => _progress.value < 1
                      ? LinearProgressIndicator(value: _progress.value)
                      : const SizedBox.shrink(),
                ),
              ),
              actions: _isPop ? null : _actions,
            ),
      body: _isPop
          ? null
          : SafeArea(
              child: WebViewReady(
                prepare: () async {
                  if (AppWebViewEnvironment.isConfigured &&
                      !await LoginUtils.setWebCookie()) {
                    throw StateError(
                      'Web account changed during initialization',
                    );
                  }
                },
                builder: (_) => InAppWebView(
                  webViewEnvironment: AppWebViewEnvironment.instance,
                  initialSettings: InAppWebViewSettings(
                    clearCache: true,
                    javaScriptEnabled: true,
                    forceDark: ForceDark.AUTO,
                    useHybridComposition: true,
                    algorithmicDarkeningAllowed: true,
                    useShouldOverrideUrlLoading: true,
                    userAgent: userAgent,
                    mixedContentMode:
                        MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                  ),
                  initialUrlRequest: URLRequest(
                    url: WebUri.uri(Uri.tryParse(_currentUrl) ?? Uri()),
                  ),
                  onWebViewCreated: (InAppWebViewController controller) {
                    if (!mounted || _isPop) return;
                    _generation++;
                    _webViewController = controller
                      ..addJavaScriptHandler(
                        handlerName: 'finishButtonClicked',
                        callback: (args) {
                          if (_currentController(controller, _generation)) {
                            Get.back();
                          }
                        },
                      )
                      ..addJavaScriptHandler(
                        handlerName: 'infoBarClicked',
                        callback: (args) =>
                            _runWebOperation(controller, (current) async {
                              WebUri? uri = await controller.getUrl();
                              if (current() && uri != null) {
                                String? oid = uri.queryParameters['oid'];
                                final aid = int.tryParse(oid ?? '');
                                if (aid != null && aid > 0) {
                                  await PiliScheme.videoPush(aid, null);
                                }
                              }
                            }),
                      );
                  },
                  onLoadStart: (controller, uri) {
                    if (!mounted ||
                        !identical(controller, _webViewController)) {
                      return;
                    }
                    _generation++;
                  },
                  onProgressChanged: (controller, progress) {
                    if (_currentController(controller, _generation)) {
                      _progress.value = progress.clamp(0, 100) / 100;
                    }
                  },
                  onTitleChanged: (controller, title) {
                    if (_currentController(controller, _generation)) {
                      _title.value = title ?? '';
                    }
                  },
                  onCloseWindow: (controller) {
                    if (_currentController(controller, _generation)) Get.back();
                  },
                  onLoadStop: (controller, uri) => _runWebOperation(
                    controller,
                    (
                      current,
                    ) async {
                      final url = uri.toString();
                      if (url.startsWith(
                        'https://www.bilibili.com/h5/note-app',
                      )) {
                        await controller.evaluateJavascript(
                          source: """
document.querySelector('.finish-btn').addEventListener('click', function() {
    window.flutter_inappwebview.callHandler('finishButtonClicked');
});
""",
                        );
                        if (!current()) return;
                        await controller.evaluateJavascript(
                          source: """
document.querySelector('.info-bar').addEventListener('click', function() {
    window.flutter_inappwebview.callHandler('infoBarClicked');
});
""",
                        );
                      } else if (url.startsWith('https://live.bilibili.com')) {
                        await controller.evaluateJavascript(
                          source: '''
document.styleSheets[0].insertRule('div.open-app-btn.bili-btn-warp {display:none;}', 0);
document.styleSheets[0].insertRule('#app__display-area > div.control-panel {display:none;}', 0);
                  ''',
                        );
                      }
                      // _webViewController?.evaluateJavascript(
                      //   source: '''
                      //     document.querySelector('#internationalHeader').remove();
                      //     document.querySelector('#message-navbar').remove();
                      //   ''',
                      // );
                    },
                  ),
                  onDownloadStartRequest: Platform.isAndroid
                      ? (controller, request) {
                          final generation = _generation;
                          if (!_currentController(controller, generation)) {
                            return;
                          }
                          showDialog(
                            context: context,
                            builder: (context) {
                              String suggestedFilename = request
                                  .suggestedFilename
                                  .toString();
                              final fileSize = CacheManager.formatSize(
                                request.contentLength,
                              );
                              try {
                                suggestedFilename = Uri.decodeComponent(
                                  suggestedFilename,
                                );
                              } catch (e, stackTrace) {
                                logger.w(
                                  '下载文件名解码失败',
                                  error: e.runtimeType,
                                  stackTrace: stackTrace,
                                );
                              }
                              final url = request.url.toString();
                              return AlertDialog(
                                title: Text(
                                  '下载文件: $suggestedFilename ?',
                                  style: const TextStyle(fontSize: 18),
                                ),
                                content: SelectionText(url),
                                actions: [
                                  TextButton(
                                    onPressed: Get.back,
                                    child: Text(
                                      '取消',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      if (!_ownsController(
                                            controller,
                                            generation,
                                          ) ||
                                          ModalRoute.of(context)?.isCurrent !=
                                              true) {
                                        return;
                                      }
                                      Navigator.of(context).pop();
                                      await PageUtils.launchURL(url);
                                    },
                                    child: Text('确定 ($fileSize)'),
                                  ),
                                ],
                              );
                            },
                          );
                          _progress.value = 1;
                        }
                      : null,
                  shouldInterceptAjaxRequest: (controller, ajaxRequest) async {
                    if (!_currentController(controller, _generation)) {
                      return null;
                    }
                    String url = ajaxRequest.url.toString();
                    if (url.startsWith('//api.bilibili.com/x/note/add') &&
                        widget.title != null) {
                      return ajaxRequest
                        ..data = ajaxRequest.data.toString().replaceFirst(
                          '&title=--&',
                          '&title=${widget.title}&',
                        );
                    }
                    return null;
                  },
                  shouldInterceptRequest: (controller, request) async {
                    if (!_currentController(controller, _generation)) {
                      return null;
                    }
                    String url = request.url.toString();
                    if (url.startsWith(
                      'https://passport.bilibili.com/x/passport-login/web',
                    )) {
                      _progress.value = 1;
                      return WebResourceResponse();
                    }
                    return null;
                  },
                  shouldOverrideUrlLoading:
                      (controller, navigationAction) async {
                        final generation = _generation;
                        bool current() =>
                            _currentController(controller, generation);
                        if (!current()) return .CANCEL;
                        try {
                          final uri = navigationAction.request.url?.uriValue;
                          if (_rewriteCopyrightReport &&
                              uri?.host == 'www.bilibili.com' &&
                              uri?.path == '/h5/community/copyright/init') {
                            final queryParameters = Map<String, String>.of(
                              uri!.queryParameters,
                            )..remove('navhide');
                            final pcUrl = uri.replace(
                              path: '/pc/community/copyright/role',
                              queryParameters: queryParameters,
                            );
                            _progress.value = 0;
                            await controller.loadUrl(
                              urlRequest: URLRequest(url: WebUri.uri(pcUrl)),
                            );
                            return .CANCEL;
                          }
                          if (!_inApp) {
                            final hasMatch = await PiliScheme.routePush(
                              navigationAction.request.url?.uriValue ?? Uri(),
                              selfHandle: true,
                              off: _off,
                            );
                            if (!current()) return .CANCEL;
                            // if (kDebugMode) debugPrint('webview: [$url], [$hasMatch]');
                            if (hasMatch) {
                              _progress.value = 1;
                              return .CANCEL;
                            }
                          }
                          final url = navigationAction.request.url.toString();
                          if (_prefixRegex.hasMatch(url)) {
                            if (current() && context.mounted) {
                              final snackBar = SnackBar(
                                persist: false,
                                showCloseIcon: true,
                                content: const Text('当前网页将要打开外部链接，是否打开'),
                                action: SnackBarAction(
                                  label: '打开',
                                  onPressed: () {
                                    if (current()) PageUtils.launchURL(url);
                                  },
                                ),
                              );
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(snackBar);
                            }
                            _progress.value = 1;
                            return .CANCEL;
                          }

                          return .ALLOW;
                        } catch (error, stackTrace) {
                          logger.w(
                            '网页导航失败',
                            error: error.runtimeType,
                            stackTrace: stackTrace,
                          );
                          if (current()) SmartDialog.showToast('链接暂时无法打开，请重试');
                          return .CANCEL;
                        }
                      },
                ),
              ),
            ),
    );
  }
}
