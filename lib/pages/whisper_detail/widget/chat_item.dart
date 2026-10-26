import 'dart:math' as math;

import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/emote_tooltip.dart';
import 'package:pili_aurora/common/widgets/gesture/tap_gesture_recognizer.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/image_viewer/hero.dart';
import 'package:pili_aurora/common/widgets/selection_text.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/common/image_preview_type.dart';
import 'package:pili_aurora/pages/whisper_detail/widget/message_content_card.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:pili_aurora/utils/duration_utils.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class ChatItem extends StatelessWidget {
  const ChatItem({
    super.key,
    required this.item,
    required this.eInfos,
    required this.onLongPress,
    required this.onSecondaryTapUp,
    required this.isOwner,
  });

  final Message item;
  final List<EmotionSticker>? eInfos;
  final VoidCallback onLongPress;
  final GestureTapUpCallback? onSecondaryTapUp;
  final bool isOwner;

  // 消息来源
  // enum MsgSource {
  //     EN_MSG_SOURCE_AUTOREPLY_BY_FOLLOWED    = 8;  //
  //     EN_MSG_SOURCE_AUTOREPLY_BY_RECEIVE_MSG = 9;  //
  //     EN_MSG_SOURCE_AUTOREPLY_BY_KEYWORDS    = 10; //
  //     EN_MSG_SOURCE_AUTOREPLY_BY_VOYAGE      = 11; //
  // };
  @override
  Widget build(BuildContext context) {
    late final ThemeData theme = Theme.of(context);
    late final Color textColor = isOwner
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurface;
    Widget child = messageContent(
      context: context,
      theme: theme,
      textColor: textColor,
    );

    final isSystem = switch (item.content.kind) {
      MessageContentKind.notify ||
      MessageContentKind.pictureCard ||
      MessageContentKind.tip ||
      MessageContentKind.videoCard ||
      MessageContentKind.articleCard ||
      MessageContentKind.commonShareCard ||
      MessageContentKind.legacyCard => true,
      _ => false,
    };

    if (!isSystem) {
      final isPic = item.content is ImageMessageContent;
      child = Row(
        mainAxisAlignment: isOwner ? .end : .start,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 300.0),
            decoration: BoxDecoration(
              color: isOwner
                  ? theme.colorScheme.secondaryContainer
                  : theme.colorScheme.onInverseSurface,
              borderRadius: isOwner
                  ? const .only(
                      topLeft: .circular(16),
                      topRight: .circular(16),
                      bottomLeft: .circular(16),
                      bottomRight: .circular(6),
                    )
                  : const .only(
                      topLeft: .circular(16),
                      topRight: .circular(16),
                      bottomLeft: .circular(6),
                      bottomRight: .circular(16),
                    ),
            ),
            padding: isPic
                ? const .only(top: 8, bottom: 6, left: 8, right: 8)
                : const .only(top: 8, bottom: 6, left: 12, right: 12),
            child: Column(
              crossAxisAlignment: isOwner ? .end : .start,
              children: [
                child,
                isPic ? const SizedBox(height: 7) : const SizedBox(height: 2),
                if (item.recalled)
                  Text(
                    '  已撤回',
                    style: theme.textTheme.labelSmall!.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                if (item.source >= 8 && item.source <= 11) ...[
                  Divider(
                    height: 10,
                    thickness: 1,
                    color: theme.colorScheme.outline.withValues(alpha: 0.2),
                  ),
                  Text(
                    '此条消息为自动回复',
                    style: theme.textTheme.labelMedium!.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 18),
          child: Text(
            DateFormatUtils.chatFormat(item.timestamp),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ),
        GestureDetector(
          behavior: .opaque,
          onLongPress: onLongPress,
          onSecondaryTapUp: onSecondaryTapUp,
          child: child,
        ),
      ],
    );
  }

  Widget messageContent({
    required BuildContext context,
    required ThemeData theme,
    required Color textColor,
  }) {
    try {
      return switch (item.content) {
        TextMessageContent(:final text) => msgTypeText_1(
          theme,
          content: {'content': text},
          textColor: textColor,
        ),
        ImageMessageContent content => msgTypePic_2({
          'url': content.url,
          'width': content.width,
          'height': content.height,
        }),
        StructuredMessageContent(:final kind, :final payload) => switch (kind) {
          MessageContentKind.notify => msgTypeNotifyMsg_10(theme, payload),
          MessageContentKind.pictureCard => msgTypePictureCard_13(payload),
          MessageContentKind.tip => msgTypeTipMessage_18(theme, payload),
          MessageContentKind.shareV2 => msgTypeShareV2_7(payload, textColor),
          MessageContentKind.videoCard => msgTypeVideoCard_11(theme, payload),
          MessageContentKind.articleCard => msgTypeArticleCard_12(payload),
          MessageContentKind.commonShareCard => msgTypeCommonShareCard_14(
            payload,
            textColor,
          ),
          MessageContentKind.legacyCard => msgType_16(
            theme,
            payload,
            textColor,
          ),
          _ => def(textColor),
        },
        UnknownMessageContent() => def(textColor),
      };
    } catch (err) {
      return def(textColor, err: err);
    }
  }

  Widget msgTypeCommonShareCard_14(dynamic content, Color textColor) {
    if (content['source'] == '直播') {
      return GestureDetector(
        behavior: .opaque,
        onTap: () {
          dynamic roomId = content['sourceID'];
          if (roomId is String) {
            roomId = int.parse(roomId);
          }
          PageUtils.toLiveRoom(roomId);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NetworkImgLayer(
              width: 220,
              height: 123.75,
              src: content['cover'],
            ),
            const SizedBox(height: 6),
            Text(
              content['title'] ?? "",
              style: TextStyle(
                letterSpacing: 0.6,
                height: 1.5,
                color: textColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              '${content['author']} · 直播',
              style: TextStyle(
                letterSpacing: 0.6,
                height: 1.5,
                color: textColor.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    } else {
      return def(textColor);
    }
  }

  Widget msgTypeArticleCard_12(dynamic content) {
    return MessageContentCard(
      coverUrls: (content['image_urls'] as List?)?.cast<String>() ?? const [],
      title: content['title'] ?? '',
      summary: content['summary'],
      onTap: () => Get.toNamed(
        '/articlePage',
        parameters: {
          'id': '${content['rid']}',
          'type': 'read',
        },
      ),
    );
  }

  Widget msgType_16(ThemeData theme, content, Color textColor) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: theme.colorScheme.onInverseSurface,
          borderRadius: const BorderRadius.all(Radius.circular(16)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 6,
          children: [
            Text(
              content['main_title'],
              style: TextStyle(
                letterSpacing: 0.6,
                height: 1.5,
                color: textColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            for (final i in content['sub_cards'])
              GestureDetector(
                onTap: () async {
                  String? bvid = IdUtils.bvRegex
                      .firstMatch(i['jump_url'])
                      ?.group(0);
                  if (bvid != null) {
                    try {
                      SmartDialog.showLoading();
                      final res = await SearchHttp.ab2cWithDimension(
                        bvid: bvid,
                      );
                      final cid = res?.cid;
                      SmartDialog.dismiss();
                      if (cid != null) {
                        PageUtils.toVideoPage(
                          bvid: bvid,
                          cid: cid,
                          cover: i['cover_url'],
                          dimension: res!.dimension,
                          // 接口提供标题时可同时传入。
                        );
                      }
                    } catch (err) {
                      SmartDialog.dismiss();
                      SmartDialog.showToast(err.toString());
                    }
                  } else {
                    SmartDialog.showToast('未匹配到 BV 号');
                    PageUtils.handleWebview(i['jump_url']);
                  }
                },
                child: Row(
                  spacing: 6,
                  children: [
                    NetworkImgLayer(
                      width: 130,
                      height: 73.125,
                      src: i['cover_url'],
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            i['field1'],
                            maxLines: 2,
                            style: TextStyle(
                              letterSpacing: 0.6,
                              height: 1.5,
                              color: textColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            i['field2'],
                            style: TextStyle(
                              letterSpacing: 0.6,
                              height: 1.5,
                              color: textColor.withValues(alpha: 0.6),
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            i['field3'],
                            style: TextStyle(
                              letterSpacing: 0.6,
                              height: 1.5,
                              color: textColor.withValues(alpha: 0.6),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget msgTypeVideoCard_11(ThemeData theme, content) {
    String? attachMsg;
    try {
      attachMsg = content['attach_msg']?['content'];
    } catch (_) {}

    return MessageContentCard(
      coverUrls: [if (content['cover'] != null) content['cover']],
      title: content['times'] == 0 ? '内容已失效' : content['title'],
      coverLabel: content['times'] == 0
          ? '--:--'
          : DurationUtils.formatDuration(content['times']),
      footer: attachMsg?.isNotEmpty == true
          ? msgTypeText_1(
              theme,
              content: content['attach_msg'],
              textColor: theme.colorScheme.onSurface,
            )
          : null,
      onTap: () async {
        try {
          SmartDialog.showLoading();
          final bvid = content['bvid'];
          final res = await SearchHttp.ab2cWithDimension(bvid: bvid);
          final cid = res?.cid;
          SmartDialog.dismiss();
          if (cid != null) {
            PageUtils.toVideoPage(
              bvid: bvid,
              cid: cid,
              cover: content['cover'],
              dimension: res!.dimension,
              // 接口提供标题时可同时传入。
            );
          }
        } catch (err) {
          SmartDialog.dismiss();
          SmartDialog.showToast(err.toString());
        }
      },
    );
  }

  Widget msgTypeShareV2_7(dynamic content, Color textColor) {
    String? type;
    GestureTapCallback onTap;
    switch (content['source']) {
      // 相簿。
      case 2:
        type = '相簿';
        onTap = () => PageUtils.pushDynFromId(rid: content['id']);
        break;

      // 视频。
      case 5:
        type = '视频';
        onTap = () async {
          dynamic aid = content['id'];
          if (aid is String) {
            aid = int.tryParse(aid);
          }
          dynamic bvid = content["bvid"];
          if (aid == null && bvid == null) {
            SmartDialog.showToast('null');
          }
          bvid ??= IdUtils.av2bv(aid);
          SmartDialog.showLoading();
          final res = await SearchHttp.ab2cWithDimension(
            bvid: bvid,
          );
          final cid = res?.cid;
          SmartDialog.dismiss();
          if (cid != null) {
            PageUtils.toVideoPage(
              aid: aid,
              bvid: bvid,
              cid: cid,
              cover: content['thumb'],
              dimension: res!.dimension,
              // 查询接口支持时可同时展示视频标题。
            );
          }
        };
        break;

      // 专栏。
      case 6:
        type = '专栏';
        onTap = () => Get.toNamed(
          '/articlePage',
          parameters: {
            'id': '${content['id']}',
            'type': 'read',
          },
        );
        break;

      // 动态。
      case 11:
        type = '动态';
        onTap = () => PageUtils.pushDynFromId(id: content['id']);
        break;

      // 番剧。
      case 16:
        onTap = () => PageUtils.viewPgc(epId: content['id']);
        break;

      default:
        onTap = () => SmartDialog.showToast(
          'unsupported source type: ${content['source']}',
        );
    }
    return GestureDetector(
      onTap: onTap,
      behavior: .opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NetworkImgLayer(
            width: 220,
            height: 123.75,
            src: content['thumb'],
          ),
          const SizedBox(height: 6),
          Text(
            content['title'] ?? "",
            style: TextStyle(
              letterSpacing: 0.6,
              height: 1.5,
              color: textColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (content['source'] == 6 &&
              (content['headline'] as String?)?.isNotEmpty == true) ...[
            const SizedBox(height: 1),
            Text(
              content['headline'],
              style: TextStyle(
                letterSpacing: 0.6,
                height: 1.5,
                color: textColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
          if (content['author'] != null) ...[
            const SizedBox(height: 1),
            Text(
              '${content['author']}${type != null ? ' · $type' : ''}',
              style: TextStyle(
                letterSpacing: 0.6,
                height: 1.5,
                color: textColor.withValues(alpha: 0.6),
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget msgTypePic_2(Map content) {
    final url = content['url'];
    final imgWidth = (content['width'] as num).toDouble();
    final imgHeight = (content['height'] as num).toDouble();
    final width = math.min(220.0, imgWidth);
    final ratio = imgHeight / imgWidth;
    Widget child = NetworkImgLayer(
      width: width,
      height: width * ratio,
      src: url,
    );
    if (ratio <= Style.imgMaxRatio) {
      child = fromHero(
        tag: url,
        child: child,
      );
    }
    return GestureDetector(
      onTap: () => PageUtils.imageView(imgList: [SourceModel(url: url)]),
      child: child,
    );
  }

  Widget msgTypeTipMessage_18(ThemeData theme, content) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        (content['content'] as List).map((e) => e['text']).join("\n"),
        textAlign: TextAlign.center,
        style: TextStyle(
          height: 1.5,
          letterSpacing: 0.6,
          color: theme.colorScheme.outline.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  Widget msgTypeText_1(
    ThemeData theme, {
    required dynamic content,
    required Color textColor,
  }) {
    final style = TextStyle(color: textColor, letterSpacing: 0.6, height: 1.5);
    final List<InlineSpan> children = [];
    late final Map<String, Map> emojiMap = {};
    final List<String> patterns = [Constants.urlRegex.pattern];
    if (eInfos != null) {
      for (final e in eInfos!) {
        emojiMap[e.text] ??= {
          'url': e.url,
          'size': e.size,
        };
      }
      patterns.addAll(emojiMap.keys.map(RegExp.escape));
    }
    final regex = RegExp(patterns.join('|'));
    content['content'].splitMapJoin(
      regex,
      onMatch: (Match match) {
        final matchStr = match[0]!;
        if (matchStr.startsWith('[')) {
          final emoji = emojiMap[matchStr];
          if (emoji != null) {
            final size = emoji['size'];
            final url = emoji['url'];
            children.add(
              WidgetSpan(
                rawText: matchStr,
                child: emoteTooltipBuilder(
                  url: url,
                  emote: matchStr,
                  triggerMode: .tap,
                  colorScheme: theme.colorScheme,
                  child: NetworkImgLayer(
                    width: size,
                    height: size,
                    src: url,
                    type: .emote,
                  ),
                ),
              ),
            );
          } else {
            children.add(TextSpan(text: matchStr, style: style));
          }
        } else {
          children.add(
            TextSpan(
              text: matchStr,
              style: style.copyWith(color: theme.colorScheme.primary),
              recognizer: NoDeadlineTapGestureRecognizer()
                ..onTap = () => PiliScheme.routePushFromUrl(matchStr),
            ),
          );
        }
        return '';
      },
      onNonMatch: (String text) {
        children.add(TextSpan(text: text, style: style));
        return '';
      },
    );
    return SelectionText.rich(TextSpan(children: children));
  }

  Widget msgTypeNotifyMsg_10(ThemeData theme, content) {
    List? modules = content['modules'] as List?;
    List<Widget>? jumpItem([String index = '']) {
      final String? uri = content['jump_uri$index'];
      if (uri != null && uri.isNotEmpty) {
        final String? text = content['jump_text$index'];
        return [
          Divider(color: theme.colorScheme.primary.withValues(alpha: 0.05)),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => PiliScheme.routePushFromUrl(uri),
            child: Text(
              text != null && text.isNotEmpty ? text : '查看详情',
            ),
          ),
        ];
      }
      return null;
    }

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: theme.colorScheme.onInverseSurface,
          borderRadius: const BorderRadius.all(Radius.circular(16)),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              content['title'],
              style: theme.textTheme.titleMedium!.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Divider(color: theme.colorScheme.primary.withValues(alpha: 0.05)),
            if ((content['text'] as String?)?.isNotEmpty == true)
              Text(content['text']),
            if (modules != null && modules.isNotEmpty) ...[
              const SizedBox(height: 4),
              ...modules.map(
                (e) => Row(
                  spacing: 10,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 80,
                      child: Text(
                        e['title'],
                        style: TextStyle(color: theme.colorScheme.outline),
                      ),
                    ),
                    Expanded(child: Text(e['detail'])),
                  ],
                ),
              ),
            ],
            ...?jumpItem(),
            ...?jumpItem('_2'),
            ...?jumpItem('_3'),
          ],
        ),
      ),
    );
  }

  Widget msgTypePictureCard_13(dynamic content) {
    final String? url = content['jump_url'];
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = math.max(400.0, constraints.maxWidth);
        Widget child = ClipRRect(
          borderRadius: Style.mdRadius,
          child: CachedImage(
            width: maxWidth,
            memCacheWidth: maxWidth.cacheSize(context),
            imageUrl: ImageUtils.thumbnailUrl(content['pic_url']),
            placeholder: (_, _) => const SizedBox.shrink(),
          ),
        );
        if (url != null && url.isNotEmpty) {
          child = GestureDetector(
            onTap: () => PiliScheme.routePushFromUrl(url),
            child: child,
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: maxWidth,
            child: child,
          ),
        );
      },
    );
  }

  Widget def(Color textColor, {err}) {
    final raw = switch (item.content) {
      UnknownMessageContent(:final raw) => raw,
      TextMessageContent(:final text) => text,
      ImageMessageContent(:final url) => url,
      StructuredMessageContent(:final payload) => payload.toString(),
    };
    return Text(
      '$raw${err != null ? '\n\ntype: ${item.type}\nerr: $err' : ''}',
      style: TextStyle(
        letterSpacing: 0.6,
        height: 1.5,
        color: textColor,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
