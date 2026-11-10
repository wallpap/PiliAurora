import 'dart:io' show File;

import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/member/profile_type.dart';
import 'package:pili_aurora/models/remote/account_myinfo/data.dart';
import 'package:pili_aurora/pages/member_profile/controller.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:pili_aurora/utils/extension/file_ext.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mime/mime.dart';

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final _controller = MemberProfileController();
  final _imagePicker = ImagePicker();
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _getInfo();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('账号资料'),
        actions: [
          IconButton(
            tooltip: '刷新资料',
            onPressed: _controller.saving || _picking ? null : _getInfo,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(theme, _controller.state),
    );
  }

  Future<void> _getInfo() => _controller.load();

  Widget _buildBody(
    ThemeData theme,
    LoadingState<AccountMyInfoData> loadingState,
  ) {
    late final divider = Divider(
      height: 1,
      color: theme.dividerColor.withValues(alpha: 0.1),
    );

    late final divider1 = Divider(
      thickness: 16,
      color: theme.dividerColor.withValues(alpha: 0.1),
    );

    return switch (loadingState) {
      Loading() => m3eLoading,
      Success(:final response) => ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom + 25,
        ),
        children: [
          divider1,
          _item(
            theme: theme,
            title: '头像',
            widget: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: NetworkImgLayer(
                width: 55,
                height: 55,
                type: .avatar,
                src: response.face,
              ),
            ),
            onTap: () => _pickImg(theme),
          ),
          divider,
          _item(
            theme: theme,
            title: '昵称',
            text: response.name,
            onTap: () {
              if ((response.coins ?? 0) < 6) {
                SmartDialog.showToast('硬币不足');
              } else {
                _editDialog(
                  type: ProfileType.uname,
                  title: '昵称',
                  text: response.name ?? '',
                );
              }
            },
          ),
          divider,
          _item(
            theme: theme,
            title: '性别',
            text: _sex((response.sex ?? 0)),
            onTap: () => showDialog(
              context: context,
              builder: (context_) => _sexDialog((response.sex ?? 0)),
            ),
          ),
          divider,
          _item(
            theme: theme,
            title: '出生年月',
            text: response.birthday,
            onTap: () async {
              final owner = _controller.account;
              final source = response;
              final now = DateTime.now();
              final first = DateTime(1, 1, 1);
              final parsed = DateTime.tryParse(response.birthday ?? '');
              final date = await showDatePicker(
                context: context,
                initialDate:
                    parsed == null ||
                        parsed.isAfter(now) ||
                        parsed.isBefore(first)
                    ? now
                    : parsed,
                firstDate: first,
                lastDate: now,
              );
              if (!mounted ||
                  !_controller.owns(owner, source) ||
                  date == null) {
                return;
              }
              await _update(
                type: ProfileType.birthday,
                value: DateFormatUtils.longFormat.format(date),
              );
            },
          ),
          divider,
          _item(
            theme: theme,
            title: '个性签名',
            text: response.sign,
            onTap: () => _editDialog(
              type: ProfileType.sign,
              title: '个性签名',
              text: response.sign ?? '',
            ),
          ),
          divider1,
          _item(
            theme: theme,
            title: '头像挂件',
            onTap: () => PageUtils.inAppWebview(
              'https://www.bilibili.com/h5/mall/pendant/home',
            ),
          ),
          divider1,
          _item(
            theme: theme,
            title: 'UID',
            needIcon: false,
            text: response.mid.toString(),
            onTap: () => Utils.copyText(response.mid.toString()),
          ),
          divider1,
          _item(
            theme: theme,
            title: '哔哩哔哩认证',
            onTap: () => PageUtils.inAppWebview(
              'https://account.bilibili.com/official/mobile/home',
            ),
          ),
          divider1,
        ],
      ),
      Error(:final errMsg) => scrollErrorWidget(
        errMsg: errMsg,
        onReload: _getInfo,
      ),
    };
  }

  Widget _sexDialog(int current) {
    final owner = _controller.account;
    final source = _controller.state.dataOrNull;
    bool isCurrent() => mounted && _controller.owns(owner, source);
    return SimpleDialog(
      clipBehavior: Clip.hardEdge,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        _sexDialogItem(1, current, '男', isCurrent),
        _sexDialogItem(0, current, '保密', isCurrent),
        _sexDialogItem(2, current, '女', isCurrent),
      ],
    );
  }

  Widget _sexDialogItem(
    int sex,
    int current,
    String text,
    bool Function() isCurrent,
  ) {
    return ListTile(
      dense: true,
      enabled: current != sex,
      title: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Text(
          text,
          style: const TextStyle(fontSize: 14),
        ),
      ),
      trailing: current == sex ? const Icon(size: 22, Icons.check) : null,
      onTap: () {
        if (!isCurrent()) return;
        Get.back();
        _update(type: ProfileType.sex, value: sex.toString());
      },
    );
  }

  Future<void> _editDialog({
    required ProfileType type,
    required String title,
    required String text,
  }) async {
    final owner = _controller.account;
    var source = _controller.state.dataOrNull;
    if (_controller.saving || _picking || !_controller.owns(owner, source)) {
      return;
    }
    final input = TextEditingController(text: text);
    var saving = false;
    final dialogRoute = DialogRoute<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final theme = Theme.of(dialogContext);
          final lines = type == ProfileType.uname ? 1 : 4;
          return AlertDialog(
            title: Text('修改$title'),
            content: TextField(
              controller: input,
              minLines: lines,
              maxLines: lines,
              enabled: !saving,
              autofocus: true,
              style: const TextStyle(fontSize: 14),
              textInputAction: type == ProfileType.sign
                  ? TextInputAction.newline
                  : null,
              inputFormatters: [
                LengthLimitingTextInputFormatter(
                  type == ProfileType.uname ? 16 : 70,
                ),
              ],
              decoration: InputDecoration(
                hintText: text,
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (!mounted || !identical(owner, Accounts.main)) {
                          return;
                        }
                        if (_controller.needsVerification) {
                          setDialogState(() => saving = true);
                          await _getInfo();
                          if (!mounted ||
                              !dialogContext.mounted ||
                              !identical(owner, Accounts.main)) {
                            return;
                          }
                          source = _controller.state.dataOrNull;
                          if (_controller.state case final Error error) {
                            error.toast();
                          }
                          setDialogState(() => saving = false);
                          return;
                        }
                        if (!_controller.owns(owner, source)) return;
                        final submitted = input.text;
                        if (submitted == text) {
                          SmartDialog.showToast('与原$title相同');
                          return;
                        }
                        setDialogState(() => saving = true);
                        try {
                          final succeeded = await _update(
                            type: type,
                            value: submitted,
                            isCurrent: () =>
                                dialogContext.mounted &&
                                ModalRoute.of(dialogContext)?.isCurrent == true,
                          );
                          if (!mounted ||
                              !dialogContext.mounted ||
                              !_controller.owns(owner, source)) {
                            return;
                          }
                          if (succeeded &&
                              ModalRoute.of(dialogContext)?.isCurrent == true) {
                            Navigator.of(dialogContext).pop();
                          }
                        } finally {
                          if (dialogContext.mounted) {
                            setDialogState(() => saving = false);
                          }
                        }
                      },
                child: Text(
                  saving
                      ? '提交中'
                      : _controller.needsVerification
                      ? '刷新核对'
                      : '确定',
                ),
              ),
            ],
          );
        },
      ),
    );
    try {
      await Navigator.of(context).push(dialogRoute);
    } finally {
      await dialogRoute.completed;
      input.dispose();
    }
  }

  Future<bool> _update({
    required ProfileType type,
    required String value,
    bool Function()? isCurrent,
  }) async {
    final owner = _controller.account;
    final source = _controller.state.dataOrNull;
    final route = ModalRoute.of(context);
    if (_controller.saving || _picking || !_controller.owns(owner, source)) {
      return false;
    }
    final result = await _controller.update(type, value);
    if (!mounted ||
        !_controller.owns(owner, source) ||
        !(isCurrent?.call() ?? route?.isCurrent == true)) {
      return false;
    }
    if (result.isSuccess) {
      SmartDialog.showToast('修改成功');
      return true;
    }
    result.toast();
    return false;
  }

  String _sex(int sex) {
    return switch (sex) {
      0 => '保密',
      1 => '男',
      2 => '女',
      _ => '未知',
    };
  }

  Widget _item({
    required ThemeData theme,
    required String title,
    Widget? widget,
    String? text,
    GestureTapCallback? onTap,
    bool needIcon = true,
  }) {
    return ListTile(
      onTap: onTap,
      dense: title != '头像',
      leading: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.normal,
        ),
      ),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (text != null)
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: theme.colorScheme.outline,
                ),
              ),
            )
          else
            ?widget,
          if (needIcon)
            Icon(
              Icons.keyboard_arrow_right,
              color: theme.colorScheme.outline,
            )
          else
            const SizedBox(width: 24),
        ],
      ),
    );
  }

  Future<void> _pickImg(ThemeData theme) async {
    final owner = _controller.account;
    final source = _controller.state.dataOrNull;
    if (_picking || _controller.saving || !_controller.owns(owner, source)) {
      return;
    }
    setState(() => _picking = true);
    final route = ModalRoute.of(context);
    bool current() =>
        mounted && _controller.owns(owner, source) && route?.isCurrent == true;
    String? temporaryCrop;
    String? pickedPath;
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
        requestFullMetadata: false,
      );
      if (picked == null || !current()) return;
      var imagePath = picked.path;
      pickedPath = imagePath;
      final subtype = (picked.mimeType ?? lookupMimeType(imagePath))
          ?.split('/')
          .last;
      if (subtype == 'gif') {
        SmartDialog.showToast('不能选GIF');
        return;
      }
      if (PlatformUtils.isMobile) {
        final cropped = await ImageCropper.platform.cropImage(
          sourcePath: imagePath,
          uiSettings: [
            AndroidUiSettings(
              toolbarTitle: '裁剪',
              toolbarColor: theme.colorScheme.secondaryContainer,
              toolbarWidgetColor: theme.colorScheme.onSecondaryContainer,
              statusBarLight: theme.isLight,
              aspectRatioPresets: const [CropAspectRatioPresetCustom()],
              lockAspectRatio: true,
              hideBottomControls: true,
              cropStyle: CropStyle.circle,
              initAspectRatio: const CropAspectRatioPresetCustom(),
            ),
          ],
        );
        temporaryCrop = cropped?.path;
        if (cropped == null || !current()) return;
        imagePath = cropped.path;
      }
      final result = await _controller.avatar(imagePath);
      if (!current()) return;
      if (result.isSuccess) {
        SmartDialog.showToast('修改成功');
        await _getInfo();
      } else {
        result.toast();
        if (result is UnknownResult) await _getInfo();
      }
    } catch (error, stackTrace) {
      logger.w('头像选择或上传失败', error: error.runtimeType, stackTrace: stackTrace);
      if (current()) SmartDialog.showToast('头像处理失败，请重新选择后重试');
    } finally {
      // 选择器来源可能是用户原文件，只清理本次裁剪产生的独立产物。
      if (temporaryCrop != null && temporaryCrop != pickedPath) {
        await File(temporaryCrop).tryDel();
      }
      _picking = false;
      if (mounted) setState(() {});
    }
  }
}

class CropAspectRatioPresetCustom implements CropAspectRatioPresetData {
  const CropAspectRatioPresetCustom();

  @override
  (int, int) get data => const (1, 1);

  @override
  String get name => '1x1 (customized)';
}
