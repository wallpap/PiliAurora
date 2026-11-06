import 'dart:async';
import 'dart:io' show File;

import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/widgets/dialog/report.dart';
import 'package:pili_aurora/common/widgets/flutter/chat_list_view.dart';
import 'package:pili_aurora/common/widgets/flutter/text_field/text_field.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show platformAlwaysClampingPhysics;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/pages/common/publish/common_rich_text_pub_page.dart';
import 'package:pili_aurora/pages/emote/view.dart';
import 'package:pili_aurora/pages/whisper_detail/widget/chat_item.dart';
import 'package:pili_aurora/pages/whisper_link_setting/view.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/conversation_providers.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/providers.dart';
import 'package:pili_aurora/utils/extension/file_ext.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart' hide TextField;

const _kMaxExtent = 625.0;
const _kConstraints = BoxConstraints(maxWidth: _kMaxExtent);

class WhisperDetailPage extends CommonRichTextPubPage {
  const WhisperDetailPage({super.key, super.autofocus = false});

  @override
  State<WhisperDetailPage> createState() => _WhisperDetailPageState();
}

class _WhisperDetailPageState
    extends CommonRichTextPubPageState<WhisperDetailPage> {
  final ScrollController _scrollController = ScrollController();
  late final int talkerId;
  late final String name;
  late final String face;
  late final int? mid;
  late final bool isLive;
  late final ConversationTarget _target;

  @override
  void initState() {
    super.initState();
    final args = Get.arguments is Map ? Get.arguments as Map : const {};
    talkerId =
        _asInt(args['talkerId']) ?? _asInt(Get.parameters['talkerId']) ?? 0;
    name = args['name'] as String? ?? '';
    face = args['face'] as String? ?? '';
    mid = _asInt(args['mid']);
    isLive = args['isLive'] as bool? ?? false;
    _target = ConversationTarget(talkerId: talkerId);
  }

  int? _asInt(Object? value) => switch (value) {
    int value => value,
    String value => int.tryParse(value),
    _ => null,
  };

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Consumer(
    builder: (context, ref, _) {
      final session = ref.watch(messagingSessionProvider);
      final conversation = ref.read(conversationProvider(_target));
      final timeline = ref.watch(conversationSnapshotProvider(_target));
      final padding = MediaQuery.viewPaddingOf(context);
      final containerColor = ElevationOverlay.colorWithOverlay(
        theme.colorScheme.surface,
        theme.hoverColor,
        1,
      );
      return SimpleScaffold(
        appBar: AppBar(
          title: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: mid == null
                ? null
                : () {
                    feedBack();
                    Get.toNamed('/member?mid=$mid');
                  },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                NetworkImgLayer(
                  width: 34,
                  height: 34,
                  type: ImageType.avatar,
                  src: face,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(height: 1, fontSize: 16),
                    strutStyle: const StrutStyle(
                      leading: 0,
                      height: 1,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (isLive) ...[
                  const SizedBox(width: 10),
                  Image.asset(
                    Assets.livingRect,
                    height: 16,
                    cacheHeight: 16.cacheSize(context),
                    filterQuality: FilterQuality.low,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            IconButton(
              tooltip: '设置',
              onPressed: () =>
                  Get.to(WhisperLinkSettingPage(talkerUid: talkerId)),
              icon: Icon(
                size: 22,
                Icons.settings,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.8,
                ),
              ),
            ),
            const SizedBox(width: 5),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.only(left: padding.left, right: padding.right),
          child: Column(
            children: [
              Expanded(
                child: Listener(
                  onPointerDown: hidePanel,
                  behavior: .opaque,
                  child: _buildBody(
                    timeline,
                    conversation,
                    session.account.mid,
                    session.isActive,
                  ),
                ),
              ),
              if (session.isActive && talkerId > 0) ...[
                ConstrainedBox(
                  constraints: _kConstraints,
                  child: _buildInputView(containerColor, conversation),
                ),
                ConstrainedBox(
                  constraints: _kConstraints,
                  child: buildPanelContainer(containerColor),
                ),
              ] else
                SizedBox(height: padding.bottom),
            ],
          ),
        ),
      );
    },
  );

  Widget _buildBody(
    AsyncValue<ConversationSnapshot> timeline,
    Conversation conversation,
    int ownerId,
    bool isActive,
  ) {
    if (!isActive) {
      return scrollErrorWidget(
        errMsg: '请先登录',
        onReload: conversation.refresh,
      );
    }
    return timeline.when(
      data: (snapshot) {
        if (snapshot.messages.isEmpty) {
          if (snapshot.phase == ConversationPhase.loading ||
              snapshot.phase == ConversationPhase.initial) {
            return m3eLoading;
          }
          return scrollErrorWidget(
            errMsg: snapshot.error,
            onReload: conversation.refresh,
          );
        }
        return ChatListView.separated(
          maxExtent: _kMaxExtent,
          itemCount: snapshot.messages.length,
          padding: const .all(kChatListPadding),
          physics: platformAlwaysClampingPhysics,
          controller: _scrollController,
          itemBuilder: (context, int index) {
            if (index == snapshot.messages.length - 1 && snapshot.hasOlder) {
              unawaited(conversation.loadOlder());
            }
            final message = snapshot.messages[index];
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) conversation.markRendered(message);
            });
            final isOwner = message.senderId == ownerId;
            return ChatItem(
              key: ValueKey(message.id),
              item: message,
              eInfos: snapshot.emotions,
              onLongPress: () => _showMessageActions(
                message,
                isOwner,
                conversation,
              ),
              onSecondaryTapUp: PlatformUtils.isDesktop
                  ? (event) => _showMenu(
                      event.globalPosition,
                      message,
                      isOwner,
                      conversation,
                    )
                  : null,
              isOwner: isOwner,
            );
          },
          separatorBuilder: (context, index) => const SizedBox(height: 12),
        );
      },
      error: (error, _) => scrollErrorWidget(
        errMsg: error.toString(),
        onReload: conversation.refresh,
      ),
      loading: () => m3eLoading,
    );
  }

  void _showMenu(
    Offset offset,
    Message message,
    bool isOwner,
    Conversation conversation,
  ) {
    showMenu(
      context: context,
      position: PageUtils.menuPosition(offset),
      items: [
        if (isOwner)
          AppPopupMenuItem(
            height: 42,
            onTap: () => _recall(message, conversation),
            child: const Text('撤回', style: TextStyle(fontSize: 14)),
          )
        else
          AppPopupMenuItem(
            height: 42,
            onTap: () => _onReport(message, conversation),
            child: const Text('举报', style: TextStyle(fontSize: 14)),
          ),
      ],
    );
  }

  void _showMessageActions(
    Message message,
    bool isOwner,
    Conversation conversation,
  ) {
    Feedback.forLongPress(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: isOwner
            ? ListTile(
                onTap: () {
                  Get.back();
                  _recall(message, conversation);
                },
                dense: true,
                title: const Text('撤回', style: TextStyle(fontSize: 14)),
              )
            : ListTile(
                onTap: () {
                  Get.back();
                  _onReport(message, conversation);
                },
                dense: true,
                title: const Text('举报', style: TextStyle(fontSize: 14)),
              ),
      ),
    );
  }

  Future<void> _recall(Message message, Conversation conversation) async {
    final result = await conversation.recall(message);
    if (!mounted || !conversation.session.isActive) return;
    if (!result.isSuccess) {
      SmartDialog.showToast(result.message ?? '撤回失败');
    } else {
      SmartDialog.showToast('撤回成功');
    }
  }

  void _onReport(Message message, Conversation conversation) {
    autoWrapReportDialog(
      context,
      ReportOptions.imMsgReport,
      (reasonType, reasonDescription, _) async {
        final result = await conversation.report(
          message,
          reasonType,
          reasonDescription ?? ReportOptions.imMsgReport['']![reasonType]!,
        );
        if (!mounted || !conversation.session.isActive) {
          if (mounted && context.mounted) Get.back();
          return const Error(null);
        }
        return switch (result.status) {
          OperationStatus.success => const Success(null),
          OperationStatus.unknown => Error(
            result.message ?? '举报结果待确认',
          ),
          _ => Error(result.message ?? '举报失败'),
        };
      },
      ban: false,
    );
  }

  Widget _buildInputView(Color containerColor, Conversation conversation) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            onPressed: () =>
                updatePanelType(panelType.value == .emoji ? .keyboard : .emoji),
            icon: const Icon(Icons.emoji_emotions),
            tooltip: '表情',
          ),
          Expanded(
            child: Obx(
              () => RichTextField(
                key: key,
                readOnly: readOnly.value,
                focusNode: focusNode,
                controller: editController,
                minLines: 1,
                maxLines: 4,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  filled: true,
                  hintText: '发个消息聊聊呗~',
                  fillColor: theme.colorScheme.surface,
                  border: const OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.all(Radius.circular(6)),
                    gapPadding: 0,
                  ),
                  contentPadding: const EdgeInsets.all(10),
                ),
              ),
            ),
          ),
          Obx(() {
            final enablePublish = this.enablePublish.value;
            return IconButton(
              onPressed: enablePublish
                  ? () => _sendText(conversation)
                  : () => _pickAndSendImage(conversation),
              icon: Icon(
                enablePublish ? Icons.send : Icons.add_photo_alternate_outlined,
              ),
              tooltip: enablePublish ? '发送' : '图片',
            );
          }),
        ],
      ),
    );
  }

  Future<void> _sendText(Conversation conversation) async {
    final submittedText = editController.rawText;
    if (submittedText.isEmpty) return;
    feedBack();
    SmartDialog.dismiss();
    final result = await conversation.sendText(submittedText);
    if (!mounted || !conversation.session.isActive) return;
    if (result.isSuccess) {
      if (editController.rawText == submittedText) {
        editController.clear();
        enablePublish.value = false;
      }
      SmartDialog.showToast('发送成功');
    } else if (result.status == OperationStatus.unknown) {
      SmartDialog.showToast('发送状态待确认，请核对聊天记录后再操作');
    } else {
      SmartDialog.showToast(result.message ?? '发送失败');
    }
  }

  Future<void> _pickAndSendImage(Conversation conversation) async {
    try {
      final pickedFile = await imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
        requestFullMetadata: false,
      );
      if (pickedFile == null) return;
      final path = pickedFile.path;
      if (!mounted || !conversation.session.isActive) {
        if (PlatformUtils.isMobile) File(path).tryDel();
        return;
      }
      SmartDialog.showLoading(msg: '正在上传并发送图片');
      OperationResult result;
      try {
        result = await conversation.sendImage(path);
      } finally {
        SmartDialog.dismiss();
        if (PlatformUtils.isMobile) File(path).tryDel();
      }
      if (!mounted || !conversation.session.isActive) return;
      if (result.isSuccess) {
        SmartDialog.showToast('发送成功');
      } else if (result.status == OperationStatus.unknown) {
        SmartDialog.showToast('发送状态待确认，请核对聊天记录后再操作');
      } else {
        SmartDialog.showToast(result.message ?? '图片发送失败');
      }
    } catch (error) {
      SmartDialog.dismiss();
      SmartDialog.showToast(error.toString());
    }
  }

  @override
  Widget? get customPanel => EmotePanel(onChoose: onChooseEmote);

  @override
  Future<void> onCustomPublish({List? pictures}) => throw UnimplementedError();

  @override
  Future<void>? onMention([bool fromClick = false]) => null;

  @override
  void onSave() {}
}
