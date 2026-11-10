import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/common/dial_prefix.dart';
import 'package:pili_aurora/common/widgets/custom_toast.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:pili_aurora/common/widgets/view_insets_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/login/controller.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:pili_aurora/utils/extension/widget_ext.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:url_launcher/url_launcher.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final LoginPageController _loginPageCtr = Get.put(LoginPageController());
  // 二维码生成时间
  bool showPassword = false;
  GlobalKey globalKey = GlobalKey();
  bool _savingQRCode = false;
  bool _openingQRCode = false;
  // 离开页面或扫码标签后，即使返回也不交付原操作的回执。
  int _qrTabRevision = 0;
  int _lastTabIndex = 0;
  Route<dynamic>? _pageRoute;

  @override
  void initState() {
    super.initState();
    _lastTabIndex = _loginPageCtr.tabController.index;
    _loginPageCtr.tabController.addListener(_onQrTabChanged);
    routeObserver.addNavigationListener(_onNavigation);
  }

  void _onNavigation() {
    if (!identical(routeObserver.currentRoute, _pageRoute)) _qrTabRevision++;
  }

  void _onQrTabChanged() {
    final index = _loginPageCtr.tabController.index;
    if (index == _lastTabIndex) return;
    _lastTabIndex = index;
    _qrTabRevision++;
  }

  @override
  void dispose() {
    routeObserver.removeNavigationListener(_onNavigation);
    if (!_loginPageCtr.isClosed) {
      _loginPageCtr.tabController.removeListener(_onQrTabChanged);
    }
    super.dispose();
  }

  bool get _qrReady =>
      !_loginPageCtr.isClosed &&
      _loginPageCtr.tabController.index == 2 &&
      _loginPageCtr.codeInfo.value is Success &&
      _loginPageCtr.qrCodeLeftTime.value > 0;

  Future<void> _openQRCode() async {
    if (_openingQRCode) return;
    final state = _loginPageCtr.codeInfo.value;
    final code = state.dataOrNull;
    if (!_qrReady || code == null) {
      SmartDialog.showToast('请先刷新二维码');
      return;
    }
    final revision = _qrTabRevision;
    final route = ModalRoute.of(context);
    bool current() =>
        mounted &&
        _qrReady &&
        revision == _qrTabRevision &&
        identical(state, _loginPageCtr.codeInfo.value) &&
        route?.isCurrent == true;
    _openingQRCode = true;
    try {
      final opened = await launchUrl(
        Uri.parse('bilibili://browser?url=${Uri.encodeComponent(code.url)}'),
        mode: LaunchMode.externalNonBrowserApplication,
      );
      if (!opened && current()) SmartDialog.showToast('无法打开二维码，请重试');
    } catch (error, stackTrace) {
      logger.w('打开登录二维码失败', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) SmartDialog.showToast('无法打开二维码，请重试');
    } finally {
      _openingQRCode = false;
    }
  }

  Future<void> _saveQRCode() async {
    if (_savingQRCode) return;
    final state = _loginPageCtr.codeInfo.value;
    final code = state.dataOrNull;
    if (!_qrReady || code == null) {
      SmartDialog.showToast('请先刷新二维码');
      return;
    }
    final route = ModalRoute.of(context);
    final revision = _qrTabRevision;
    bool cancelled = false;
    bool current() =>
        mounted &&
        !cancelled &&
        _qrReady &&
        revision == _qrTabRevision &&
        identical(state, _loginPageCtr.codeInfo.value) &&
        route?.isCurrent == true;
    _savingQRCode = true;
    final loadingTag = 'qr-screenshot-${UniqueKey()}';
    bool loadingShown = false;
    Future<void> closeLoading() async {
      if (!loadingShown) return;
      loadingShown = false;
      try {
        await SmartDialog.dismiss(tag: loadingTag);
      } catch (error, stackTrace) {
        logger.w(
          '关闭二维码截图提示失败',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
      }
    }

    try {
      loadingShown = true;
      SmartDialog.show<void>(
        tag: loadingTag,
        builder: (_) => const LoadingWidget('正在生成截图'),
        debounce: false,
        clickMaskDismiss: false,
        backType: SmartBackType.normal,
        onDismiss: () {
          if (loadingShown) cancelled = true;
        },
      );
      final boundary = globalKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('二维码截图尚未就绪');
      }
      final image = await boundary.toImage(pixelRatio: 3);
      late final Uint8List pngBytes;
      try {
        final byteData = await image.toByteData(format: .png);
        if (byteData == null) throw StateError('二维码截图编码未返回数据');
        pngBytes = byteData.buffer.asUint8List();
      } finally {
        image.dispose();
      }
      if (!current()) return;
      await closeLoading();
      if (!current()) return;
      final picName =
          '${Constants.appName}_loginQRCode_${code.authCode.hashCode.toUnsigned(32).toRadixString(16)}';
      final result = await ImageUtils.saveByteImg(
        bytes: pngBytes,
        fileName: picName,
        showLoading: false,
        needToast: false,
      );
      if (!current()) return;
      SmartDialog.showToast(
        result == null
            ? '取消保存'
            : result.isSuccess
            ? ' 已保存 '
            : '保存失败，请检查相册权限后重试',
      );
    } catch (error, stackTrace) {
      logger.w('二维码截图保存失败', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) SmartDialog.showToast('二维码截图保存失败，请重试');
    } finally {
      _savingQRCode = false;
      await closeLoading();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageRoute = ModalRoute.of(context);
    _loginPageCtr.didChangeDependencies(context);
  }

  Widget loginByQRCode(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 20),
        const Text('使用 bilibili 官方 App 扫码登录'),
        const SizedBox(height: 20),
        Obx(
          () => Text(
            '剩余有效时间: ${_loginPageCtr.qrCodeLeftTime} 秒',
            style: TextStyle(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: theme.colorScheme.primaryFixedDim,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: _loginPageCtr.refreshQRCode,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新二维码'),
            ),
            TextButton.icon(
              onPressed: _saveQRCode,
              icon: const Icon(Icons.save),
              label: const Text('保存至相册'),
            ),
            if (kDebugMode || PlatformUtils.isMobile)
              TextButton.icon(
                onPressed: _openQRCode,
                icon: const Icon(Icons.open_in_browser_outlined),
                label: const Text('其他应用打开'),
              ),
          ],
        ),
        RepaintBoundary(
          key: globalKey,
          child: Obx(
            () => switch (_loginPageCtr.codeInfo.value) {
              Loading() => const SizedBox(
                height: 200,
                width: 200,
                child: m3eLoading,
              ),
              Success(:final response) => Container(
                width: 200,
                height: 200,
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: PrettyQrView.data(
                  data: response.url,
                  decoration: const PrettyQrDecoration(
                    shape: PrettyQrSquaresSymbol(
                      color: Colors.black87,
                    ),
                  ),
                ),
              ),
              Error(:final errMsg) => HttpError(
                isSliver: false,
                errMsg: errMsg,
                onReload: _loginPageCtr.refreshQRCode,
              ),
            },
          ),
        ),
        const SizedBox(height: 10),
        Obx(
          () => Text(
            _loginPageCtr.statusQRCode.value,
            style: TextStyle(color: theme.colorScheme.secondaryFixedDim),
          ),
        ),
        Obx(
          () {
            final url = _loginPageCtr.codeInfo.value.dataOrNull?.url ?? '';
            return GestureDetector(
              onTap: () => Utils.copyText(
                url,
                toastText: '已复制到剪贴板，可粘贴至已登录的app私信处发送，然后点击已发送的链接打开',
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 20,
                ),
                child: Text(
                  url,
                  style: theme.textTheme.labelSmall!.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '请务必在 ${Constants.appName} 开源仓库等可信渠道下载安装。',
            style: theme.textTheme.labelSmall!.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ),
      ],
    );
  }

  Widget loginByCookie(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),
        const Text('使用Cookie登录'),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '使用App端Api实现的功能将不可用',
            style: theme.textTheme.labelMedium!.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: TextField(
            minLines: 1,
            maxLines: 10,
            controller: _loginPageCtr.cookieTextController,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r"\s"))],
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.cookie_outlined),
              border: const UnderlineInputBorder(),
              labelText: 'Cookie',
              suffixIcon: IconButton(
                onPressed: _loginPageCtr.cookieTextController.clear,
                icon: const Icon(Icons.clear),
              ),
            ),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _loginPageCtr.loginByCookie,
          icon: const Icon(Icons.login),
          label: const Text('登录'),
        ),
      ],
    );
  }

  Widget loginByPassword(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 20),
        const Text('使用账号密码登录'),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: TextField(
            controller: _loginPageCtr.usernameTextController,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r"\s"))],
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.account_box),
              border: const UnderlineInputBorder(),
              labelText: '账号',
              hintText: '邮箱/手机号',
              suffixIcon: IconButton(
                onPressed: _loginPageCtr.usernameTextController.clear,
                icon: const Icon(Icons.clear),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: TextField(
            obscureText: !showPassword,
            keyboardType: TextInputType.visiblePassword,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r"\s"))],
            controller: _loginPageCtr.passwordTextController,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.password),
              border: const UnderlineInputBorder(),
              labelText: '密码',
              suffixIcon: IconButton(
                onPressed: _loginPageCtr.passwordTextController.clear,
                icon: const Icon(Icons.clear),
              ),
            ),
          ),
        ),
        Row(
          children: [
            const SizedBox(width: 10),
            Checkbox(
              value: showPassword,
              onChanged: (value) => setState(() => showPassword = value!),
            ),
            const Text('显示密码'),
            const Spacer(),
            TextButton(
              onPressed: () {
                //https://passport.bilibili.com/h5-app/passport/login/findPassword
                //https://passport.bilibili.com/passport/findPassword
                showDialog(
                  context: context,
                  builder: (context) => SimpleDialog(
                    clipBehavior: Clip.hardEdge,
                    title: const Text('忘记密码？'),
                    contentPadding: const EdgeInsets.fromLTRB(
                      0.0,
                      2.0,
                      0.0,
                      16.0,
                    ),
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(25, 0, 25, 10),
                        child: Text("试试扫码、手机号登录，或选择"),
                      ),
                      ListTile(
                        title: const Text(
                          '找回密码（手机版）',
                        ),
                        leading: const Icon(Icons.smartphone_outlined),
                        subtitle: const Text(
                          'https://passport.bilibili.com/h5-app/passport/login/findPassword',
                        ),
                        dense: false,
                        onTap: () => Get
                          ..back()
                          ..toNamed(
                            '/webview',
                            parameters: {
                              'url': 'https://passport.bilibili.com/h5-app/passport/login/findPassword',
                              'type': 'url',
                              'pageTitle': '忘记密码',
                            },
                          ),
                      ),
                      ListTile(
                        title: const Text(
                          '找回密码（电脑版）',
                        ),
                        leading: const Icon(Icons.desktop_windows_outlined),
                        subtitle: const Text(
                          'https://passport.bilibili.com/pc/passport/findPassword',
                        ),
                        dense: false,
                        onTap: () => Get
                          ..back()
                          ..toNamed(
                            '/webview',
                            parameters: {
                              'url': 'https://passport.bilibili.com/pc/passport/findPassword',
                              'type': 'url',
                              'pageTitle': '忘记密码',
                              'uaType': 'pc',
                            },
                          ),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('忘记密码'),
            ),
            const SizedBox(width: 20),
          ],
        ),
        OutlinedButton.icon(
          onPressed: _loginPageCtr.loginByPassword,
          icon: const Icon(Icons.login),
          label: const Text('登录'),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '根据 bilibili 官方登录接口规范，密码将在本地加盐、加密后传输。\n'
            '盐与公钥均由官方提供；以 RSA/ECB/PKCS1Padding 方式加密。\n'
            '账号密码仅用于该登录接口，不予保存；本地仅存储登录凭证。\n'
            '请务必在 ${Constants.appName} 开源仓库等可信渠道下载安装。',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall!.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ),
      ],
    );
  }

  Widget loginBySmS(ThemeData theme) {
    return Column(
      children: [
        const SizedBox(height: 20),
        const Text('使用手机短信验证码登录'),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: DecoratedBox(
            decoration: UnderlineTabIndicator(
              borderSide: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Builder(
                  builder: (context) {
                    return PopupMenuButton(
                      padding: EdgeInsets.zero,
                      tooltip:
                          '选择国际冠码，'
                          '当前为${_loginPageCtr.selectedCountryCodeId.cname}，'
                          '+${_loginPageCtr.selectedCountryCodeId.countryId}',
                      onSelected: (item) {
                        _loginPageCtr.selectedCountryCodeId = item;
                        (context as Element).markNeedsBuild();
                      },
                      initialValue: _loginPageCtr.selectedCountryCodeId,
                      itemBuilder: (_) => Login.dialPrefix.map((item) {
                        return PopupMenuItem(
                          value: item,
                          child: Row(
                            children: [
                              Text(item.cname),
                              const Spacer(),
                              Text("+${item.countryId}"),
                            ],
                          ),
                        );
                      }).toList(),
                      child: Row(
                        children: [
                          Icon(
                            Icons.phone,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            "+${_loginPageCtr.selectedCountryCodeId.countryId}",
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(width: 6),
                SizedBox(
                  height: 24,
                  child: VerticalDivider(
                    color: theme.colorScheme.outline.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _loginPageCtr.telTextController,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      labelText: '手机号',
                      suffixIcon: IconButton(
                        onPressed: _loginPageCtr.telTextController.clear,
                        icon: const Icon(Icons.clear),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: DecoratedBox(
            decoration: UnderlineTabIndicator(
              borderSide: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _loginPageCtr.smsCodeTextController,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.sms_outlined),
                      border: InputBorder.none,
                      labelText: '验证码',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                  ),
                ),
                Obx(
                  () => TextButton.icon(
                    onPressed:
                        _loginPageCtr.smsSendCooldown > 0 ||
                            _loginPageCtr.smsSending.value
                        ? null
                        : _loginPageCtr.sendSmsCode,
                    icon: const Icon(Icons.send),
                    label: Text(
                      _loginPageCtr.smsSendCooldown > 0
                          ? '等待${_loginPageCtr.smsSendCooldown}秒'
                          : '获取验证码',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _loginPageCtr.loginBySmsCode,
          icon: const Icon(Icons.login),
          label: const Text('登录'),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '手机号仅用于 bilibili 官方发送验证码与登录接口，不予保存；\n'
            '本地仅存储登录凭证。\n'
            '请务必在 ${Constants.appName} 开源仓库等可信渠道下载安装。',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall!.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ),
      ],
    );
  }

  late EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    padding =
        MediaQuery.viewPaddingOf(context).copyWith(top: 0) +
        const EdgeInsets.only(bottom: 25);
    final isLandscape = !MediaQuery.sizeOf(context).isPortrait;
    return SimpleScaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close_outlined),
          onPressed: Get.back,
        ),
        title: Row(
          children: [
            const Text('登录'),
            if (isLandscape)
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TabBar(
                    isScrollable: true,
                    dividerHeight: 0,
                    tabs: const [
                      Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [Icon(Icons.password), Text(' 密码')],
                        ),
                      ),
                      Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [Icon(Icons.sms_outlined), Text(' 短信')],
                        ),
                      ),
                      Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [Icon(Icons.qr_code), Text(' 扫码')],
                        ),
                      ),
                      Tab(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.cookie_outlined),
                            Text(' Cookie'),
                          ],
                        ),
                      ),
                    ],
                    controller: _loginPageCtr.tabController,
                  ),
                ),
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (!isLandscape)
            TabBar(
              tabs: const [
                Tab(icon: Icon(Icons.password), text: '密码'),
                Tab(icon: Icon(Icons.sms_outlined), text: '短信'),
                Tab(icon: Icon(Icons.qr_code), text: '扫码'),
                Tab(icon: Icon(Icons.cookie_outlined), text: 'Cookie'),
              ],
              controller: _loginPageCtr.tabController,
            ),
          Expanded(
            child: NotificationListener<ScrollStartNotification>(
              onNotification: (notification) {
                if (notification.metrics.axis == Axis.horizontal) {
                  FocusScope.of(context).unfocus();
                }
                return false;
              },
              child: ViewInsetsSafeArea(
                child: tabBarView(
                  controller: _loginPageCtr.tabController,
                  children: [
                    tabViewOuter(loginByPassword(theme)),
                    tabViewOuter(loginBySmS(theme)),
                    tabViewOuter(loginByQRCode(theme)),
                    tabViewOuter(loginByCookie(theme)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget tabViewOuter(Widget child) {
    return SingleChildScrollView(
      padding: padding,
      child: child.constraintWidth(),
    );
  }
}
