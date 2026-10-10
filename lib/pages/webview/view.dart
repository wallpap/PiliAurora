import 'dart:io' show Platform;

import 'package:pili_aurora/common/widgets/route_aware_mixin.dart'
    show routeObserver;
import 'package:pili_aurora/common/widgets/selection_text.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/services/webview_environment.dart';
import 'package:pili_aurora/models/common/webview_menu_type.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/login_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
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

  @override
  void initState() {
    super.initState();
    final parameters = Get.parameters;
    _currentUrl = (widget.url ?? parameters['url']!).http2https;
    _title = _currentUrl.obs;
    userAgent = switch (parameters['uaType']) {
      'pc' => BrowserUa.pc,
      'mob' => BrowserUa.mob,
      _ => BrowserUa.platform,
    };
    if (Get.arguments case final Map map) {
      _inApp = map['inApp'] ?? false;
      _off = map['off'] ?? false;
      _rewriteCopyrightReport = map['rewriteCopyrightReport'] == true;
    }

    if (Platform.isAndroid) {
      routeObserver.subscribe(this, Get.routing.route as GetPageRoute);
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) routeObserver.unsubscribe(this);
    _webViewController = null;
    super.dispose();
  }

  bool _isPop = false;
  @override
  void didPop() {
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
                (item) => PopupMenuItem(
                  value: item,
                  child: Text(item.title),
                ),
              ),
          const PopupMenuDivider(),
          PopupMenuItem(
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
    switch (item) {
      case WebviewMenuItem.refresh:
        _webViewController?.reload();
        break;
      case WebviewMenuItem.copy:
        final uri = await _webViewController?.getUrl();
        if (uri != null) Utils.copyText(uri.toString());
        break;
      case WebviewMenuItem.openInBrowser:
        final uri = await _webViewController?.getUrl();
        if (uri != null) PageUtils.launchURL(uri.toString());
        break;
      case WebviewMenuItem.clearCache:
        try {
          await InAppWebViewController.clearAllCache();
          await _webViewController?.clearHistory();
          SmartDialog.showToast('已清理');
        } catch (e) {
          SmartDialog.showToast(e.toString());
        }
        break;
      case WebviewMenuItem.goBack:
        if (await _webViewController?.canGoBack() == true) {
          _webViewController?.goBack();
        } else {
          Get.back();
        }
        break;
      case WebviewMenuItem.resetCookie:
        await LoginUtils.setWebCookie();
        SmartDialog.showToast('设置成功，刷新或重新打开网页');
        break;
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
              child: InAppWebView(
                webViewEnvironment: AppWebViewEnvironment.instance,
                initialSettings: InAppWebViewSettings(
                  clearCache: true,
                  javaScriptEnabled: true,
                  forceDark: ForceDark.AUTO,
                  useHybridComposition: true,
                  algorithmicDarkeningAllowed: true,
                  useShouldOverrideUrlLoading: true,
                  userAgent: userAgent,
                  mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                ),
                initialUrlRequest: URLRequest(
                  url: WebUri.uri(Uri.tryParse(_currentUrl) ?? Uri()),
                ),
                onWebViewCreated: (InAppWebViewController controller) {
                  _webViewController = controller
                    ..addJavaScriptHandler(
                      handlerName: 'finishButtonClicked',
                      callback: (args) {
                        Get.back();
                      },
                    )
                    ..addJavaScriptHandler(
                      handlerName: 'infoBarClicked',
                      callback: (args) async {
                        WebUri? uri = await controller.getUrl();
                        if (uri != null) {
                          String? oid = uri.queryParameters['oid'];
                          if (oid != null) {
                            PiliScheme.videoPush(int.parse(oid), null);
                          }
                        }
                      },
                    );
                },
                onProgressChanged: (controller, progress) {
                  _progress.value = progress / 100;
                },
                onTitleChanged: (controller, title) {
                  _title.value = title ?? '';
                },
                onCloseWindow: (controller) => Get.back(),
                onLoadStop: (controller, uri) {
                  final url = uri.toString();
                  if (url.startsWith('https://www.bilibili.com/h5/note-app')) {
                    controller
                      ..evaluateJavascript(
                        source: """
document.querySelector('.finish-btn').addEventListener('click', function() {
    window.flutter_inappwebview.callHandler('finishButtonClicked');
});
""",
                      )
                      ..evaluateJavascript(
                        source: """
document.querySelector('.info-bar').addEventListener('click', function() {
    window.flutter_inappwebview.callHandler('infoBarClicked');
});
""",
                      );
                  } else if (url.startsWith('https://live.bilibili.com')) {
                    controller.evaluateJavascript(
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
                onDownloadStartRequest: Platform.isAndroid
                    ? (controller, request) {
                        showDialog(
                          context: context,
                          builder: (context) {
                            String suggestedFilename = request.suggestedFilename
                                .toString();
                            final fileSize = CacheManager.formatSize(
                              request.contentLength,
                            );
                            try {
                              suggestedFilename = Uri.decodeComponent(
                                suggestedFilename,
                              );
                            } catch (e) {
                              logger.d(e.toString());
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
                                  onPressed: () {
                                    Get.back();
                                    PageUtils.launchURL(url);
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
                  String url = request.url.toString();
                  if (url.startsWith(
                    'https://passport.bilibili.com/x/passport-login/web',
                  )) {
                    _progress.value = 1;
                    return WebResourceResponse();
                  }
                  return null;
                },
                shouldOverrideUrlLoading: (controller, navigationAction) async {
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
                    // if (kDebugMode) debugPrint('webview: [$url], [$hasMatch]');
                    if (hasMatch) {
                      _progress.value = 1;
                      return .CANCEL;
                    }
                  }
                  final url = navigationAction.request.url.toString();
                  if (_prefixRegex.hasMatch(url)) {
                    if (context.mounted) {
                      final snackBar = SnackBar(
                        persist: false,
                        showCloseIcon: true,
                        content: const Text('当前网页将要打开外部链接，是否打开'),
                        action: SnackBarAction(
                          label: '打开',
                          onPressed: () => PageUtils.launchURL(url),
                        ),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(snackBar);
                    }
                    _progress.value = 1;
                    return .CANCEL;
                  }

                  return .ALLOW;
                },
              ),
            ),
    );
  }
}
