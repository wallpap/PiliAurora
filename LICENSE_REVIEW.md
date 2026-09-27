# PiliAurora 许可证核查

核查日期：2026-09-27。核查范围：本仓库的根许可证、源码中可见的第三方声明、上游项目声明，以及 GNU GPL v3 对改名、修改和再分发的要求。本次未对全部依赖、原生二进制和素材逐项审计。

## 结论

- 已确认：根 [LICENSE](LICENSE) 为 GNU GPL 第 3 版文本。GPL v3 允许修改及按条件分发修改版本，因此可以将项目改名为 PiliAurora 并重写 README。应显著说明派生来源、修改事实和相关日期，保留原有版权、许可证和无担保声明，派生作品整体继续遵守 GPL。依据：[GPL v3 第 4、5 条](https://www.gnu.org/licenses/gpl-3.0.html#section5)。
- 已确认：GPL 允许商业使用和收费分发；不能把“仅限学习测试”作为限制 GPL 权利的许可条件。依据：[GPL v3 第 4 条](https://www.gnu.org/licenses/gpl-3.0.html#section4)、[GNU FAQ：收费销售](https://www.gnu.org/licenses/gpl-faq.html#DoesTheGPLAllowMoney)。
- 核查判断：上游 README 的“下载后 24 小时内删除”不属于 GPL v3 要求；若将其解释为 GPL 覆盖程序的强制使用条件，则属于限制 GPL 权利的额外条款，可依据第 7 条删除。可以移除原作者第一人称开发宣言、上游徽章和 Star History，改为清楚的上游引用；仍须保留适用的版权及合理作者归属声明。依据：[PiliPlus README](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/README.md)、[GPL v3 第 7 条](https://www.gnu.org/licenses/gpl-3.0.html#section7)、[第 10 条](https://www.gnu.org/licenses/gpl-3.0.html#section10)。
- 本次未发现阻止以 PiliAurora 名称维护 GPL 派生代码的条件。但这不代表所有素材、商标和随包原生库均已获得可分发授权。下文的第三方声明缺口应在发布前处理。

## 上游来源与许可

| 项目 | 已确认事实 | 主要来源 |
| --- | --- | --- |
| bggRGjQaUbCoE/PiliPlus | 根 LICENSE 为 GPL v3；README 引用 PiliPalaX 和 PiliPala。 | [LICENSE](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/LICENSE)、[README](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/main/README.md) |
| orz12/PiliPalaX | 根 LICENSE 为 GPL v3；README 引用 guozhigq/pilipala。 | [LICENSE](https://github.com/orz12/PiliPalaX/blob/main/LICENSE)、[README](https://github.com/orz12/PiliPalaX/blob/main/README.md) |
| guozhigq/pilipala | 根 LICENSE 为 GPL v3；README 将项目命名为 PiliPala。 | [LICENSE](https://github.com/guozhigq/pilipala/blob/main/LICENSE)、[README](https://github.com/guozhigq/pilipala/blob/main/README.md) |

上述关系依据项目自身的来源声明；本次没有逐提交验证全部代码的创作归属。保留 Git 历史和源码中的第三方声明有助于追溯来源，README 的项目链接不能替代具体文件所要求的版权声明。

### 来源与维护记录

PiliAurora 以 PiliPlus `2.1.5`（提交 [`a30fcc310`](https://github.com/bggRGjQaUbCoE/PiliPlus/commit/a30fcc310)）为开发起点，由本仓库独立维护。以下日期和范围记录本项目的维护工作，不代表全部历史代码的创作日期。

- 2026-09-25 至 2026-09-26：收敛为 Android 和 Windows 平台，补齐构建工具，调整播放、弹幕和评论处理。具体修改及归属见保留的 [提交历史](https://github.com/wallpap/PiliAurora/commits/main)。
- 2026-09-27：重写 README，以项目功能、下载和构建为主体，保留上游引用，并补充许可证检查记录。

### GPL 版本表述

根 LICENSE 末尾的“How to Apply These Terms to Your New Programs”是许可应用示例，其中“or any later version”本身不等于全仓项目作者已选择该版本选项。部分源码，例如 [player_bar.dart](lib/common/widgets/player_bar.dart)，确实有“either version 3 ... any later version”的授权头；该授权应继续保留。依据：[本地 LICENSE](LICENSE)、[GPL v3 第 14 条](https://www.gnu.org/licenses/gpl-3.0.html#section14)。

因此 README 使用“GNU GPL v3；具体文件的独立许可证及版本选项以文件声明为准”较为准确。本次未确认全仓统一为 `GPL-3.0-or-later`，也不应通过新 README 缩减现有文件的 `or-later` 选项。

根 LICENSE 开头的“Copyright (C) 2007 Free Software Foundation, Inc.”属于 GPL **许可文本**的版权。它不表示 FSF 拥有本项目源码，也不能直接替换成 wallpap 的项目版权声明。依据：[GNU GPL v3 许可文本及应用说明](https://www.gnu.org/licenses/gpl-3.0.html)。

## 修改与发布时的要求

1. 保留上游及第三方适用的版权、许可证、无担保声明。README 应明确“PiliAurora 基于 PiliPlus 修改”，并记录相关修改日期；不能将保留的上游代码整体宣称为新维护者原创。依据：[GPL v3 第 4、5 条](https://www.gnu.org/licenses/gpl-3.0.html#section4)、[GNU FAQ：作者署名](https://www.gnu.org/licenses/gpl-faq.html#IWantCredit)。
2. 分发修改后的源码时，派生作品整体按 GPL 分发并附许可证全文；其中独立的 MIT、BSD、Apache 等组件仍须满足各自的声明保留条件。依据：[GPL v3 第 5 条](https://www.gnu.org/licenses/gpl-3.0.html#section5)。
3. 发布 APK、EXE 或其他二进制时，应提供该版本的对应源码，包括修改和必要的构建脚本，并满足第 6 条的分发方式。常见做法是在每个 Release 中标明对应源码版本和下载入口；单独链接随时变化的上游 `main` 不能保证提供的是该二进制的对应源码。源码可以放在另一服务器，但二进制旁必须有清楚的取得说明，发布者仍负责确保源码可取得。依据：[GPL v3 第 1、6 条](https://www.gnu.org/licenses/gpl-3.0.html#section6)、[GNU FAQ：源码和二进制分站点](https://www.gnu.org/licenses/gpl-faq.html#SourceAndBinaryOnDifferentSites)。
4. GPL 不要求公开从未对外分发的私人修改；分发修改版本才产生相应义务。依据：[GNU FAQ：是否必须公开修改源码](https://www.gnu.org/licenses/gpl-faq.html#GPLRequireSourcePostedPublic)。
5. 不移除上游界面已有的适当法律声明。GPL 第 5(d) 条对原程序没有此类声明的界面设有例外；本次没有以运行方式核查所有界面和安装包的实际声明展示。依据：[GPL v3 第 5 条](https://www.gnu.org/licenses/gpl-3.0.html#section5)。

## 独立第三方声明和可见缺口

| 内容 | 本地证据 | 核查结果与处理要求 |
| --- | --- | --- |
| Anime4K 着色器 | [assets/shaders/LICENSE](assets/shaders/LICENSE)、[Restore_CNN_S](assets/shaders/Anime4K_Restore_CNN_S.glsl) 等源码头 | 已确认 MIT，分别保留 `bloc97` 的 2019 及 2019–2021 版权与许可文本。独立来源：[Anime4K LICENSE](https://github.com/bloc97/Anime4K/blob/master/LICENSE)。不能用根 GPL 替换这些通知。 |
| Anime4K AutoDownscalePre x2/x4 | [x2 源码头](assets/shaders/Anime4K_AutoDownscalePre_x2.glsl)、[x4 源码头](assets/shaders/Anime4K_AutoDownscalePre_x4.glsl) | 文件自带 Unlicense 公有领域声明及许可、无担保文本；应按文件自身声明记录，不能一概标作 MIT。 |
| account_manager 中的 cookie manager | [独立 LICENSE](lib/utils/accounts/account_manager/LICENSE)、[README](lib/utils/accounts/account_manager/README.md) | 已确认 MIT，版权为 2018 Wen Du (wendux) 和 2022 The CFUG Team。保留完整版权、许可和无担保文本。上游：[dio cookie_manager LICENSE](https://github.com/cfug/dio/blob/main/plugins/cookie_manager/LICENSE)。 |
| 复制或修改的 Flutter 组件 | [refresh_indicator.dart](lib/common/widgets/flutter/refresh_indicator.dart) 等 `lib/common/widgets/flutter/` 文件，以及 [floating_navigation_bar.dart](lib/common/widgets/floating_navigation_bar.dart)、[mouse_interactive_viewer.dart](lib/common/widgets/gesture/mouse_interactive_viewer.dart)、[image.dart](lib/common/widgets/image_viewer/image.dart) | 已确认含 Flutter Authors 版权及 BSD-style 授权头。仓库受跟踪的独立 LICENSE 文件中未发现对应 BSD 全文，且根 LICENSE 为 GPL，与源码头的引用不匹配。应补充对应 Flutter BSD 许可文本；源码保留通知，二进制附带版权、条件和免责声明。来源：[Flutter LICENSE](https://github.com/flutter/flutter/blob/master/LICENSE)。具体代码基于哪个 Flutter 提交未逐项核对。 |
| Android MediaHelper.java | [源码头](android/app/src/main/java/com/example/piliplus/MediaHelper.java) | 已确认 `Copyright 2018 The Android Open Source Project` 和 Apache-2.0 头。仓库未发现独立 Apache-2.0 全文；应随分发补充全文，保留原声明，并在修改该文件时加显著修改说明。若来源包含适用 NOTICE，也应保留；本次未确认原始文件来源及其 NOTICE。依据：[Apache-2.0 第 4 条](https://www.apache.org/licenses/LICENSE-2.0.txt)。 |
| TeX 转 Unicode 代码与数据 | [latex_to_unicode.dart](lib/utils/latex_to_unicode.dart)、[latex_unicode_data.dart](lib/utils/latex_unicode_data.dart) | 前者注明参考 `pylatexenc (MIT)`。仅看到参考链接，尚未确认是否复制或改编其有版权的实质代码/数据；不能据此直接认定侵权。若存在复制或改编，应补其 MIT 版权和许可全文。来源：[pylatexenc LICENSE](https://github.com/phfaist/pylatexenc/blob/main/LICENSE.txt)，版权为 2015–2023 Philippe Faist。 |

本次扫描受跟踪的 `LICENSE`、`COPYING`、`NOTICE` 类文件发现：根 LICENSE、shaders/LICENSE 和 account_manager/LICENSE。以上缺口是在本次 README 重写前已存在的声明情况；本核查文档没有修补第三方许可文件。

## 未确认的素材、商标和二进制范围

- [assets/images/](assets/images/) 下的图标、Logo、表情和图片，以及 [assets/screenshots/](assets/screenshots/) 的截图，未发现逐项来源和明确的独立授权。公开仓库中的素材不能仅凭根 GPL 文件就认定第三方著作权、肖像或商标权已全部授权。README 移除上游 Logo/截图的展示不会同时移除它们在安装包中的使用；[pubspec.yaml](pubspec.yaml) 仍声明应用图标及启动图 `logo_2.png`。
- [digital_id_num.ttf](assets/fonts/digital_id_num.ttf) 与 [custom_icon.ttf](assets/fonts/custom_icon.ttf) 在 pubspec 中被打包，但本次未确认字体来源、独立许可或其内嵌许可信息；应核对来源后保留相应文本。
- 根 GPL 不能代表取得 Bilibili 或上游项目名称、Logo 等商标使用许可。改名为 PiliAurora 后应避免声称获得上游或平台的官方授权、认可或背书。GPL 对商标权保留有所说明，但本次没有检索各主体的商标登记或品牌政策。依据：[GPL v3 第 7(e) 条](https://www.gnu.org/licenses/gpl-3.0.html#section7)。
- [pubspec.yaml](pubspec.yaml) 使用多个 Git 分支依赖和 `media_kit` 原生视频库覆盖；本次未审计锁定提交、mpv/FFmpeg 等实际随包组成、编译选项及其 GPL/LGPL/其他许可义务，也未核查所有 Dart、Flutter、Android 和 Windows 的传递依赖。根许可证核查不能替代最终安装包审计。
- 使用第三方 API、缓存媒体或播放平台内容所涉及的服务规则和内容权利不由 GPL 自动授予。本次未核查这些范围。

## 可用于 README 的措辞

> PiliAurora 基于 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 修改并独立维护。上游项目还引用了 [PiliPalaX](https://github.com/orz12/PiliPalaX) 和 [PiliPala](https://github.com/guozhigq/pilipala)。原有代码版权和贡献归属保留给各作者及贡献者。
>
> 本项目沿用上游的 GNU GPL v3，完整文本见 LICENSE。具体文件的独立许可证及 GPL 版本选项以对应文件声明为准。修改和分发时须保留适用的版权、许可和无担保声明；发布二进制时须按许可证提供对应源码。本软件按现状提供，无担保。

README 的“致谢与来源”说明派生关系，“许可证”链接到本记录。此次维护和文档修改的日期、范围记录于上文“来源与维护记录”，不作为所有历史源码的统一修改日期。

## 核查方法与限制

本地读取根及独立 LICENSE，扫描源码版权/许可头，并读取上游仓库原始 LICENSE、README，以及 GNU 官方 GPL v3 与 FAQ、第三方项目许可原文。GitHub API 返回公开请求速率限制 `403`，因此来源链依据上游 README，未取得 API 的 fork 元数据。远程引用指向核查时的分支，后续内容可能变化；完整版权链、每一项素材及发布二进制的许可符合性仍未验证。
