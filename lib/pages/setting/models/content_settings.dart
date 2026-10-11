import 'dart:io' show Platform;

import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart' hide RefreshIndicator;
import 'package:pili_aurora/common/widgets/custom_icon.dart';
import 'package:pili_aurora/grpc/reply.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/dynamic/dynamics_type.dart';
import 'package:pili_aurora/models/common/member/tab_type.dart';
import 'package:pili_aurora/models/common/reply/reply_sort_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart'
    show DynamicsDataModel, ItemModulesModel;
import 'package:pili_aurora/pages/home/controller.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/widgets/select_dialog.dart';
import 'package:pili_aurora/pages/video/reply/widgets/reply_item_grpc.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

List<SettingsModel> get contentSettings => [
  SettingsGroup(
    title: '搜索与发现',
    subtitle: '搜索建议、历史与热门内容',
    leading: const Icon(Icons.search),
    children: [
      const SwitchModel(
        title: '显示热门推荐',
        subtitle: '热门页面显示每周必看等推荐内容入口',
        leading: Icon(Icons.local_fire_department_outlined),
        setKey: SettingBoxKey.showHotRcmd,
        defaultVal: false,
        needReboot: true,
      ),
      const SwitchModel(
        title: '搜索建议',
        leading: Icon(Icons.search),
        setKey: SettingBoxKey.searchSuggestion,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '记录搜索历史',
        leading: Icon(Icons.history),
        setKey: SettingBoxKey.recordSearchHistory,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '展示追番时间表',
        leading: Icon(MdiIcons.chartTimelineVariantShimmer),
        setKey: SettingBoxKey.showPgcTimeline,
        defaultVal: true,
        needReboot: true,
      ),
      const SwitchModel(
        title: '大家都在搜',
        subtitle: '是否展示「大家都在搜」',
        leading: Icon(Icons.data_thresholding_outlined),
        setKey: SettingBoxKey.enableHotKey,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '搜索发现',
        subtitle: '是否展示「搜索发现」',
        leading: Icon(Icons.search_outlined),
        setKey: SettingBoxKey.enableSearchRcmd,
        defaultVal: true,
      ),
      SwitchModel(
        title: '搜索默认词',
        subtitle: '是否展示搜索框默认词',
        leading: const Icon(Icons.whatshot_outlined),
        setKey: SettingBoxKey.enableSearchWord,
        defaultVal: false,
        onChanged: (val) {
          try {
            final controller = Get.find<HomeController>()
              ..enableSearchWord = val;
            if (val) {
              controller.querySearchDefault();
            } else {
              controller.defaultSearch.value = '';
            }
          } catch (_) {}
        },
      ),
    ],
  ),
  SettingsGroup(
    title: '评论与互动',
    subtitle: '评论排序、折叠、记录与发布检查',
    leading: const Icon(Icons.comment_outlined),
    children: [
      const SwitchModel(
        title: '显示视频评论',
        leading: Icon(MdiIcons.commentTextOutline),
        setKey: SettingBoxKey.showVideoReply,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '显示番剧评论',
        leading: Icon(MdiIcons.commentTextOutline),
        setKey: SettingBoxKey.showBangumiReply,
        defaultVal: true,
      ),
      NormalModel(
        title: '评论折叠行数',
        subtitle: '0行为不折叠',
        leading: const Icon(Icons.compress),
        getTrailing: (theme) => Text(
          '${ReplyItemGrpc.replyLengthLimit}行',
          style: theme.textTheme.titleSmall,
        ),
        onTap: _showReplyLengthDialog,
      ),
      const SwitchModel(
        title: '记录评论',
        leading: Icon(Icons.message_outlined),
        setKey: SettingBoxKey.saveReply,
        defaultVal: true,
        needReboot: true,
      ),
      const SwitchModel(
        title: '发评反诈',
        subtitle: '发送评论后检查评论是否可见',
        leading: Icon(CustomIcons.shield_reply),
        setKey: SettingBoxKey.enableCommAntifraud,
        defaultVal: false,
      ),
      if (Platform.isAndroid)
        SwitchModel(
          title: '使用「哔哩发评反诈」检查评论',
          leading: Icon(
            FontAwesomeIcons.b.data,
            size: 22,
          ),
          setKey: SettingBoxKey.biliSendCommAntifraud,
          defaultVal: false,
        ),
      const SwitchModel(
        title: '发布/转发动态反诈',
        subtitle: '发布/转发动态后检查动态是否可见',
        leading: Icon(CustomIcons.shield_published),
        setKey: SettingBoxKey.enableCreateDynAntifraud,
        defaultVal: false,
      ),
      const SwitchModel(
        title: '快速收藏',
        subtitle: '点击设置默认收藏夹\n点按收藏至默认，长按选择文件夹',
        leading: Icon(Icons.bookmark_add_outlined),
        setKey: SettingBoxKey.enableQuickFav,
        onTap: _showFavDialog,
        defaultVal: false,
      ),
      SwitchModel(
        title: '评论区搜索关键词',
        subtitle: '展示评论区搜索关键词',
        leading: const Icon(Icons.search_outlined),
        setKey: SettingBoxKey.enableWordRe,
        defaultVal: false,
        onChanged: (value) => ReplyItemGrpc.enableWordRe = value,
      ),
      const SwitchModel(
        title: '消息页禁用"收到的赞"功能',
        subtitle: '禁止打开入口，降低网络社交依赖',
        leading: Icon(Icons.beach_access_outlined),
        setKey: SettingBoxKey.disableLikeMsg,
        defaultVal: false,
      ),
      const SwitchModel(
        title: '默认展示评论区',
        subtitle: '在视频详情页默认切换至评论区页（仅Tab型布局）',
        leading: Icon(Icons.mode_comment_outlined),
        setKey: SettingBoxKey.defaultShowComment,
        defaultVal: false,
      ),
      PopupModel(
        title: '评论展示',
        leading: const Icon(Icons.whatshot_outlined),
        value: () => Pref.replySortType,
        items: ReplySortType.values.take(2),
        onSelected: (value, setState) => GStorage.setting
            .put(SettingBoxKey.replySortType, value.index)
            .whenComplete(setState),
      ),
      PopupModel(
        title: '楼中楼评论展示',
        leading: const Icon(Icons.subdirectory_arrow_right_outlined),
        value: () => Pref.reply2SortType,
        items: ReplySortType.values.take(2),
        onSelected: (value, setState) => GStorage.setting
            .put(SettingBoxKey.reply2SortType, value.index)
            .whenComplete(setState),
      ),
    ],
  ),
  SettingsGroup(
    title: '动态与用户主页',
    subtitle: '动态展示、未读检查与用户标签',
    leading: const Icon(Icons.dynamic_feed_outlined),
    children: [
      const SwitchModel(
        title: '订阅清理时隐藏失效视频',
        subtitle: '清理“我的订阅”时，本地隐藏仍有效订阅中的失效视频；关闭并刷新后恢复显示',
        leading: Icon(Icons.hide_source_outlined),
        setKey: SettingBoxKey.hideInvalidSubscriptionVideos,
        defaultVal: false,
      ),
      SplitModel(
        normalModel: const NormalModel.split(
          title: '检查未读动态',
          subtitle: '点击设置检查周期(min)',
          leading: Icon(Icons.notifications_none),
        ),
        switchModel: SwitchModel.split(
          defaultVal: true,
          setKey: SettingBoxKey.checkDynamic,
          onChanged: (value) => Get.find<MainController>().checkDynamic = value,
          onTap: _showDynDialog,
        ),
      ),
      const SwitchModel(
        title: '动态/专栏详情页展示底部操作栏',
        leading: Icon(Icons.more_horiz),
        setKey: SettingBoxKey.showDynActionBar,
        defaultVal: true,
      ),
      PopupModel(
        title: '动态展示',
        leading: const Icon(Icons.dynamic_feed_rounded),
        value: () => Pref.defaultDynamicType,
        items: DynamicsTabType.values.take(4),
        onSelected: (value, setState) => GStorage.setting
            .put(SettingBoxKey.defaultDynamicType, value.index)
            .whenComplete(setState),
      ),
      SwitchModel(
        title: '显示动态互动内容',
        subtitle: '开启后则在动态卡片底部显示互动内容（如关注的人点赞、热评等）',
        leading: const Icon(Icons.quickreply_outlined),
        setKey: SettingBoxKey.showDynInteraction,
        defaultVal: true,
        onChanged: (val) => ItemModulesModel.showDynInteraction = val,
      ),
      NormalModel(
        title: '用户页默认展示TAB',
        leading: const Icon(Icons.tab),
        getSubtitle: () => '当前优先展示「${Pref.memberTab.title}」',
        onTap: _showMemberTabDialog,
      ),
      SwitchModel(
        title: '显示UP主页小店TAB',
        leading: const Icon(Icons.shop_outlined),
        setKey: SettingBoxKey.showMemberShop,
        defaultVal: false,
        onChanged: (value) => MemberTabType.showMemberShop = value,
      ),
    ],
  ),
  SettingsGroup(
    title: '内容过滤',
    subtitle: '关键词、带货与争议信息',
    leading: const Icon(Icons.filter_alt_outlined),
    children: [
      const SwitchModel(
        title: '显示视频警告/争议信息',
        leading: Icon(Icons.warning_amber_rounded),
        setKey: SettingBoxKey.showArgueMsg,
        defaultVal: true,
      ),
      SwitchModel(
        title: '显示动态警告/争议信息',
        leading: const Icon(Icons.warning_amber_rounded),
        setKey: SettingBoxKey.showDynDispute,
        defaultVal: false,
        onChanged: (val) => ItemModulesModel.showDynDispute = val,
      ),
      getBanWordModel(
        title: '评论关键词过滤',
        key: SettingBoxKey.banWordForReply,
        onChanged: (value) {
          ReplyGrpc.replyRegExp = value;
          ReplyGrpc.enableFilter = value.pattern.isNotEmpty;
        },
      ),
      getBanWordModel(
        title: '动态关键词过滤',
        key: SettingBoxKey.banWordForDyn,
        onChanged: (value) {
          DynamicsDataModel.banWordForDyn = value;
          DynamicsDataModel.enableFilter = value.pattern.isNotEmpty;
        },
      ),
      SwitchModel(
        title: '屏蔽带货动态',
        leading: const Icon(CustomIcons.shopping_bag_not_interested),
        setKey: SettingBoxKey.antiGoodsDyn,
        defaultVal: false,
        onChanged: (value) => DynamicsDataModel.antiGoodsDyn = value,
      ),
      SwitchModel(
        title: '屏蔽带货评论',
        leading: const Icon(CustomIcons.shopping_bag_not_interested),
        setKey: SettingBoxKey.antiGoodsReply,
        defaultVal: false,
        onChanged: (value) => ReplyGrpc.antiGoodsReply = value,
      ),
    ],
  ),
  SettingsGroup(
    title: '视频详情',
    subtitle: '简介、相关视频、分段与总结',
    leading: const Icon(Icons.description_outlined),
    children: [
      const SwitchModel(
        title: '显示视频分段信息',
        leading: Icon(CustomIcons.view_headline_rotate_90),
        setKey: SettingBoxKey.showViewPoints,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '视频页显示相关视频',
        leading: Icon(MdiIcons.motionPlayOutline),
        setKey: SettingBoxKey.showRelatedVideo,
        defaultVal: true,
      ),
      const SwitchModel(
        title: '默认展开视频简介',
        leading: Icon(Icons.expand_more),
        setKey: SettingBoxKey.alwaysExpandIntroPanel,
        defaultVal: false,
      ),
      const SwitchModel(
        title: '横屏自动展开视频简介',
        leading: Icon(Icons.expand_more),
        setKey: SettingBoxKey.expandIntroPanelH,
        defaultVal: false,
      ),
      SwitchModel(
        title: '横屏分P/合集列表显示在Tab栏',
        leading: const Icon(Icons.format_list_numbered_rtl_sharp),
        setKey: SettingBoxKey.horizontalSeasonPanel,
        defaultVal: Pref.horizontalScreen,
      ),
      SwitchModel(
        title: '横屏播放页在侧栏打开UP主页',
        leading: const Icon(Icons.account_circle_outlined),
        setKey: SettingBoxKey.horizontalMemberPage,
        defaultVal: Pref.horizontalScreen,
      ),
      const SwitchModel(
        title: '启用AI总结',
        subtitle: '视频详情页开启AI总结',
        leading: Icon(Icons.engineering_outlined),
        setKey: SettingBoxKey.enableAi,
        defaultVal: false,
      ),
    ],
  ),
];

void _showDynDialog(BuildContext context) {
  String dynamicPeriod = Pref.dynamicPeriod.toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('检查周期'),
      content: TextFormField(
        autofocus: true,
        initialValue: dynamicPeriod,
        keyboardType: TextInputType.number,
        onChanged: (value) => dynamicPeriod = value,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(suffixText: 'min'),
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () {
            try {
              final val = int.parse(dynamicPeriod);
              Get.back();
              GStorage.setting.put(SettingBoxKey.dynamicPeriod, val);
              Get.find<MainController>().dynamicPeriod = val * 60 * 1000;
            } catch (e) {
              SmartDialog.showToast(e.toString());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

void _showReplyLengthDialog(BuildContext context, VoidCallback setState) {
  String replyLengthLimit = ReplyItemGrpc.replyLengthLimit.toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('评论折叠行数'),
      content: TextFormField(
        autofocus: true,
        initialValue: replyLengthLimit,
        keyboardType: TextInputType.number,
        onChanged: (value) => replyLengthLimit = value,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(suffixText: '行'),
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () async {
            try {
              final val = int.parse(replyLengthLimit);
              Get.back();
              ReplyItemGrpc.replyLengthLimit = val == 0 ? null : val;
              await GStorage.setting.put(SettingBoxKey.replyLengthLimit, val);
              setState();
            } catch (e) {
              SmartDialog.showToast(e.toString());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

Future<void> _showFavDialog(BuildContext context) async {
  if (Accounts.main.isLogin) {
    final res = await FavHttp.allFavFolders(Accounts.main.mid);
    if (res case Success(:final response)) {
      final list = response.list;
      if (list == null || list.isEmpty) {
        return;
      }
      final quickFavId = Pref.quickFavId;
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          clipBehavior: Clip.hardEdge,
          title: const Text('选择默认收藏夹'),
          contentPadding: const EdgeInsets.only(top: 5, bottom: 18),
          content: SingleChildScrollView(
            child: RadioGroup(
              onChanged: (value) {
                Get.back();
                GStorage.setting.put(SettingBoxKey.quickFavId, value);
                SmartDialog.showToast('设置成功');
              },
              groupValue: quickFavId,
              child: Column(
                children: list
                    .map(
                      (item) => RadioListTile(
                        toggleable: true,
                        dense: true,
                        title: Text(item.title),
                        value: item.id,
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ),
      );
    } else {
      res.toast();
    }
  }
}

Future<void> _showMemberTabDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<MemberTabType>(
    context: context,
    builder: (context) => SelectDialog<MemberTabType>(
      title: '用户页默认展示TAB',
      value: Pref.memberTab,
      values: MemberTabType.values.map((e) => (e, e.title)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.memberTab, res.index);
    setState();
  }
}
