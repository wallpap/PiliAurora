import 'package:pili_aurora/pages/setting/models/play_settings.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/widgets/switch_item.dart';
import 'package:pili_aurora/common/widgets/button/icon_button.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/utils/danmaku_options.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

mixin HeaderMixin<T extends StatefulWidget> on State<T> {
  PlPlayerController get plPlayerController;

  bool get isFullScreen => plPlayerController.isFullScreen.value;

  ThemeData? get theme {
    if (plPlayerController.darkVideoPage) {
      return ThemeUtils.darkTheme;
    }
    return null;
  }

  Future<void>? showBottomSheet(
    StatefulWidgetBuilder builder, {
    ValueGetter<EdgeInsets>? padding,
  }) {
    final theme = this.theme;
    return PageUtils.showVideoBottomSheet(
      context,
      maxWidth: 512,
      padding: padding,
      child: theme != null
          ? Theme(
              data: theme,
              child: StatefulBuilder(builder: builder),
            )
          : StatefulBuilder(builder: builder),
    );
  }

  Widget resetBtn(ThemeData theme, Object def, VoidCallback onPressed) {
    return iconButton(
      tooltip: '默认值: $def',
      icon: const Icon(Icons.refresh),
      onPressed: onPressed,
      iconColor: theme.colorScheme.outline,
      size: 24,
      iconSize: 24,
    );
  }

  /// 弹幕功能
  void showSetDanmaku({bool isLive = false}) {
    // 屏蔽类型
    const blockTypesList = [
      (value: 2, label: '滚动'),
      (value: 5, label: '顶部'),
      (value: 4, label: '底部'),
      (value: 6, label: '彩色'),
      (value: 7, label: '高级'),
    ];

    final isFullScreen = this.isFullScreen;

    showBottomSheet(
      (context, setState) {
        final baseTheme = Theme.of(context);
        final colors = baseTheme.colorScheme;
        final theme = baseTheme.copyWith(
          textTheme: baseTheme.textTheme.copyWith(
            titleMedium: baseTheme.textTheme.titleMedium?.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
            labelMedium: baseTheme.textTheme.labelMedium?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              height: 1.5,
            ),
          ),
          listTileTheme: baseTheme.listTileTheme.copyWith(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 4,
            ),
            minLeadingWidth: 20,
            horizontalTitleGap: 12,
            minVerticalPadding: 10,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );

        void setOptions() => plPlayerController.notifyDanmakuOptionsChanged();

        final sliderTheme = SliderThemeData(
          trackHeight: 3,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          thumbColor: colors.primary,
          activeTrackColor: colors.primary,
          inactiveTrackColor: colors.outlineVariant.withValues(alpha: .5),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 0),
        );

        Widget sliderSetting(
          String title, {
          required String valueText,
          required double value,
          required double min,
          required double max,
          required ValueChanged<double> onChanged,
          int? divisions,
          String? hint,
          String? defaultText,
          VoidCallback? onReset,
        }) => Padding(
          key: ValueKey('danmaku-$title'),
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    valueText,
                    style: TextStyle(fontSize: 13, color: colors.primary),
                  ),
                  if (onReset != null)
                    IconButton(
                      tooltip: '恢复默认值：$defaultText',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      color: colors.onSurfaceVariant,
                      onPressed: onReset,
                      icon: const Icon(Icons.restart_alt),
                    ),
                ],
              ),
              if (hint != null)
                Text(
                  hint,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              SizedBox(
                height: 36,
                child: Slider(
                  min: min,
                  max: max,
                  value: value,
                  divisions: divisions,
                  label: valueText,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        );

        Widget optionChip(String label, bool selected, VoidCallback onTap) =>
            FilterChip(
              label: Text(label, style: const TextStyle(fontSize: 13)),
              selected: selected,
              onSelected: (_) {
                feedBack();
                onTap();
              },
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.padded,
            );
        void updateLineHeight(double val) {
          DanmakuOptions.danmakuLineHeight = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateDuration(double val) {
          DanmakuOptions.danmakuDuration = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateStaticDuration(double val) {
          DanmakuOptions.danmakuStaticDuration = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateFontSizeFS(double val) {
          DanmakuOptions.danmakuFontScaleFS = val.toPrecision(2);
          setState(() {});
          if (isFullScreen) {
            setOptions();
          }
        }

        void updateFontSize(double val) {
          DanmakuOptions.danmakuFontScale = val.toPrecision(2);
          setState(() {});
          if (!isFullScreen) {
            setOptions();
          }
        }

        void updateStrokeWidth(double val) {
          DanmakuOptions.danmakuStrokeWidth = val;
          setState(() {});
          setOptions();
        }

        void updateFontWeight(double val) {
          DanmakuOptions.danmakuFontWeight = val.toInt();
          setState(() {});
          setOptions();
        }

        void updateOpacity(double val) {
          plPlayerController.danmakuOpacity.value = val.toPrecision(2);
          setState(() {});
        }

        void updateShowArea(double val) {
          DanmakuOptions.danmakuShowArea = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateDanmakuWeight(double val) {
          DanmakuOptions.danmakuWeight = val.toInt();
          plPlayerController.refreshDanmakuRules();
          setState(() {});
        }

        void onUpdateBlockType(int blockType, bool blocked) {
          if (blocked) {
            DanmakuOptions.blockTypes.remove(blockType);
          } else {
            DanmakuOptions.blockTypes.add(blockType);
          }
          DanmakuOptions.blockColorful = DanmakuOptions.blockTypes.contains(6);
          setState(() {});
          setOptions();
        }

        Future<void> updatePreference(String key, Object value) async {
          await GStorage.setting.put(key, value);
          if (context.mounted) setState(() {});
        }

        Widget blockTypes() => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '按类型屏蔽',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < blockTypesList.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: FilterChip(
                      label: Center(
                        child: Text(
                          blockTypesList[i].label,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      labelPadding: EdgeInsets.zero,
                      padding: EdgeInsets.zero,
                      showCheckmark: false,
                      selected: DanmakuOptions.blockTypes.contains(
                        blockTypesList[i].value,
                      ),
                      onSelected: (_) {
                        feedBack();
                        final type = blockTypesList[i].value;
                        onUpdateBlockType(
                          type,
                          DanmakuOptions.blockTypes.contains(type),
                        );
                      },
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
          ],
        );

        Widget frameRate() => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('弹幕帧率（实验性）', style: TextStyle(fontSize: 14)),
            Text(
              '立即生效',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final fps in [0, 60, 90, 120])
                  ChoiceChip(
                    label: Text(
                      fps == 0 ? '跟随屏幕' : '$fps FPS',
                      style: const TextStyle(fontSize: 12),
                    ),
                    showCheckmark: false,
                    selected: Pref.danmakuFrameRate == fps,
                    onSelected: (_) =>
                        updatePreference(SettingBoxKey.danmakuFrameRate, fps),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        );

        List<Widget> appearance() => [
          if (isLive) blockTypes(),
          sliderSetting(
            '显示区域',
            valueText:
                '${(DanmakuOptions.danmakuShowArea * 100).toStringAsFixed(1)}%',
            value: DanmakuOptions.danmakuShowArea,
            min: .1,
            max: 1,
            divisions: 9,
            onChanged: updateShowArea,
            defaultText: '50.0%',
            onReset: () => updateShowArea(.5),
          ),
          sliderSetting(
            '不透明度',
            valueText:
                '${(plPlayerController.danmakuOpacity.value * 100).toStringAsFixed(1)}%',
            value: plPlayerController.danmakuOpacity.value,
            min: 0,
            max: 1,
            divisions: 100,
            onChanged: updateOpacity,
            defaultText: '100.0%',
            onReset: () => updateOpacity(1),
          ),
          sliderSetting(
            '字体大小',
            valueText:
                '${(DanmakuOptions.danmakuFontScale * 100).toStringAsFixed(1)}%',
            value: DanmakuOptions.danmakuFontScale,
            min: .5,
            max: 2.5,
            divisions: 200,
            onChanged: updateFontSize,
            defaultText: '100.0%',
            onReset: () => updateFontSize(1),
          ),
          sliderSetting(
            '全屏字体大小',
            valueText:
                '${(DanmakuOptions.danmakuFontScaleFS * 100).toStringAsFixed(1)}%',
            value: DanmakuOptions.danmakuFontScaleFS,
            min: .5,
            max: 2.5,
            divisions: 200,
            onChanged: updateFontSizeFS,
            defaultText: '120.0%',
            onReset: () => updateFontSizeFS(1.2),
          ),
          sliderSetting(
            '字体粗细',
            valueText: '${DanmakuOptions.danmakuFontWeight + 1}',
            hint: '部分字体可能无法精确调节',
            value: DanmakuOptions.danmakuFontWeight.toDouble(),
            min: 0,
            max: 8,
            divisions: 8,
            onChanged: updateFontWeight,
            defaultText: '6',
            onReset: () => updateFontWeight(5),
          ),
          sliderSetting(
            '描边粗细',
            valueText: '${DanmakuOptions.danmakuStrokeWidth}',
            value: DanmakuOptions.danmakuStrokeWidth,
            min: 0,
            max: 5,
            divisions: 10,
            onChanged: updateStrokeWidth,
            defaultText: '1.5',
            onReset: () => updateStrokeWidth(1.5),
          ),
        ];

        List<Widget> motion() => [
          if (!isLive && !PlatformUtils.isDesktop) ...[
            frameRate(),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              optionChip('海量弹幕', DanmakuOptions.danmakuMassiveMode, () {
                DanmakuOptions.danmakuMassiveMode =
                    !DanmakuOptions.danmakuMassiveMode;
                setState(() {});
                setOptions();
              }),
              optionChip('固定转滚动', DanmakuOptions.danmakuStatic2Scroll, () {
                DanmakuOptions.danmakuStatic2Scroll =
                    !DanmakuOptions.danmakuStatic2Scroll;
                setState(() {});
                setOptions();
              }),
              optionChip('滚动弹幕固定速度', DanmakuOptions.danmakuFixedV, () {
                DanmakuOptions.danmakuFixedV = !DanmakuOptions.danmakuFixedV;
                setState(() {});
                setOptions();
              }),
            ],
          ),
          const SizedBox(height: 12),
          sliderSetting(
            '滚动弹幕时长',
            valueText: '${DanmakuOptions.danmakuDuration} 秒',
            value: DanmakuOptions.danmakuDuration,
            min: 1,
            max: 50,
            divisions: 49,
            onChanged: updateDuration,
            defaultText: '7.0 秒',
            onReset: () => updateDuration(7),
          ),
          sliderSetting(
            '静态弹幕时长',
            valueText: '${DanmakuOptions.danmakuStaticDuration} 秒',
            value: DanmakuOptions.danmakuStaticDuration,
            min: 1,
            max: 50,
            divisions: 49,
            onChanged: updateStaticDuration,
            defaultText: '4.0 秒',
            onReset: () => updateStaticDuration(4),
          ),
          sliderSetting(
            '轨道间距',
            valueText: '${DanmakuOptions.danmakuLineHeight} 倍',
            value: DanmakuOptions.danmakuLineHeight,
            min: 1,
            max: 3,
            divisions: 20,
            onChanged: updateLineHeight,
            defaultText: '1.6 倍',
            onReset: () => updateLineHeight(1.6),
          ),
        ];

        List<Widget> filtering() => [
          blockTypes(),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Get
                ..back()
                ..toNamed('/danmakuBlock', arguments: plPlayerController),
              child: Text('屏蔽管理 (${plPlayerController.filters.count})'),
            ),
          ),
          sliderSetting(
            '智能云屏蔽',
            valueText: '${DanmakuOptions.danmakuWeight} 级',
            value: DanmakuOptions.danmakuWeight.toDouble(),
            min: 0,
            max: 11,
            divisions: 11,
            onChanged: updateDanmakuWeight,
          ),
          for (final setting in danmakuMergeSettings.whereType<SwitchModel>())
            SetSwitchItem(
              title: setting.setKey == SettingBoxKey.mergeDanmaku
                  ? '合并弹幕'
                  : '重复弹幕放大',
              subtitle: setting.setKey == SettingBoxKey.mergeDanmaku
                  ? '合并 20 秒内相同或相似的弹幕'
                  : '按重复数量放大，最高两倍',
              setKey: setting.setKey,
              defaultVal: setting.defaultVal,
              onChanged: setting.onChanged,
              needReboot: setting.needReboot,
              contentPadding: EdgeInsets.zero,
            ),
          const SizedBox(height: 12),
          sliderSetting(
            '放大阈值',
            valueText: '${Pref.mergeDanmakuThreshold} 条',
            value: Pref.mergeDanmakuThreshold.toDouble(),
            min: 2,
            max: 50,
            divisions: 48,
            onChanged: (value) => updatePreference(
              SettingBoxKey.mergeDanmakuThreshold,
              value.round(),
            ),
          ),
          sliderSetting(
            '放大速度（对数底数）',
            valueText: Pref.mergeDanmakuLogBase.toStringAsFixed(1),
            value: Pref.mergeDanmakuLogBase,
            min: 2,
            max: 20,
            divisions: 36,
            onChanged: (value) =>
                updatePreference(SettingBoxKey.mergeDanmakuLogBase, value),
          ),
          Text(
            '重复数量超过阈值时放大；对数底数越小，放大越快。设置立即生效。',
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ];

        Widget page(String name, List<Widget> children) => ListView(
          key: ValueKey('danmaku-$name'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: children,
        );

        return Padding(
          padding: const EdgeInsets.all(12),
          child: Theme(
            data: theme,
            child: DefaultTabController(
              length: isLive && PlatformUtils.isDesktop ? 2 : 3,
              child: Material(
                clipBehavior: Clip.antiAlias,
                color: colors.surface,
                borderRadius: BorderRadius.circular(12),
                child: SliderTheme(
                  data: sliderTheme,
                  child: Column(
                    children: [
                      SizedBox(
                        key: const ValueKey('danmaku-toolbar'),
                        height: 48,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              const Text(
                                '弹幕设置',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TabBar(
                                  labelStyle: const TextStyle(fontSize: 12),
                                  labelPadding: EdgeInsets.zero,
                                  dividerColor: Colors.transparent,
                                  tabs: [
                                    const Tab(text: '外观'),
                                    const Tab(text: '运动'),
                                    if (!isLive || !PlatformUtils.isDesktop)
                                      Tab(text: isLive ? '性能' : '屏蔽'),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 36,
                                child: IconButton(
                                  tooltip: '关闭',
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(Icons.close, size: 20),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.outlineVariant.withValues(alpha: .5),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            page('appearance', appearance()),
                            page('motion', motion()),
                            if (!isLive || !PlatformUtils.isDesktop)
                              page(
                                'filtering',
                                isLive ? [frameRate()] : filtering(),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    )?.whenComplete(
      () => DanmakuOptions.save(plPlayerController.danmakuOpacity.value),
    );
  }
}

class MSliderTrackShape extends RoundedRectSliderTrackShape {
  const MSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    SliderThemeData? sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const double trackHeight = 3;
    final double trackLeft = offset.dx;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}
