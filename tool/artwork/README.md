# 应用视觉资源

2026-11-03 更新。应用图标提供三款银白发角色 Q 版和原版头像。默认使用“星光斜向”，另可选择“星光竖向”“星光侧倾”或“原版头像”。三款 Q 版采用蓝紫背景与两颗浅色星星，保留额前菱形、左侧星形垂饰，以及右侧独立银色枝叶、蓝紫双宝石和紫白蝴蝶结。浅色原稿由内置 imagegen 生成，实际提示词及来源记录见 [`chibi-icon-prompt.json`](chibi-icon-prompt.json)。四款暗色资源统一由浅色原稿叠加黑色遮罩导出。

在外观设置的“主题与文字 → 应用图标”中切换，偏好按下表标识保存到 `appIconStyle`。`chibi` 沿用之前的默认项标识，更新其图片不影响已有选择。Windows 窗口、托盘和关于页即时更新；已打开的独立播放进程在下次启动时读取偏好。EXE、静态快捷方式和启动图使用默认 A 加星版。Android 使用四个指向 MainActivity 的 launcher alias，切换时仅启用所选入口，保留 MainActivity 的深链接；Android 13 起批量更新，旧系统先启用目标再逐项禁用其余入口。桌面刷新和固定快捷方式行为需要目标启动器验证。

| 标识 / 选项 | 选定图稿 | 维护源稿 | 应用内 PNG / Windows ICO |
| --- | --- | --- | --- |
| `chibi` / 星光斜向（默认） | 斜向贴脸与背景星光 | `raster/app-icon-chibi.png` | `logo/logo_chibi.png` / `logo/ico/app_icon_chibi.ico` |
| `upright` / 星光竖向 | 正面竖向与背景星光 | `raster/app-icon-upright.png` | `logo/logo_upright.png` / `logo/ico/app_icon_upright.ico` |
| `tilted` / 星光侧倾 | 侧倾构图与背景星光 | `raster/app-icon-tilted.png` | `logo/logo_tilted.png` / `logo/ico/app_icon_tilted.ico` |
| `portrait` / 原版头像 | 原版与遮罩派生暗色版 | `raster/app-icon.png` | `logo/logo.png`、`logo/logo_dark.png` / `logo/ico/app_icon.ico`、`logo/ico/app_icon_dark.ico` |

仅重新导出图标及启动图：`python tool/artwork/export.py --icons-only`。修改对应源稿后运行该命令即可同步资源。四款暗色资源在导出时从浅色原稿叠加 18% 黑色遮罩生成，PNG 与 ICO 使用 `_dark` 后缀；不保存额外的暗色源稿。Android 默认入口使用 `ic_launcher` 与 `app_icon_artwork.png`；其余入口使用 `ic_launcher_{标识}` 与 `app_icon_{标识}_artwork.png`，分别生成传统和自适应图标。单色主题图标继续共用蝴蝶结与菱形标记。切换机制依据 Android [activity-alias](https://developer.android.com/guide/topics/manifest/activity-alias-element) 与 [PackageManager](https://developer.android.google.cn/reference/android/content/pm/PackageManager) API。

| 资源 | 应用路径 | 源稿 / 导出 |
| --- | --- | --- |
| 图片占位 / 头像 / AI 总结 | `assets/images/loading.png`、`noface.jpeg`、`ai.png` | `loading.svg`、`avatar.svg`、`ai.svg` |
| 空状态 / 话题背景 | `assets/images/error.svg`、`topic-header-bg.png` | `error.svg`、`topic-header.svg` |
| 热搜横幅 | `assets/images/trending_banner.png` | 内置 imagegen，1125 × 528，PNG |
| 直播默认背景 | `assets/images/live/default_bg.webp` | 内置 imagegen，1125 × 2436，WebP |
| 应用图标 / 单色标记 | `assets/images/logo/logo_chibi.png`（默认）、`logo_upright.png`、`logo_tilted.png`、`logo.png`（原版）、`logo_2.png`（单色） | 源稿见上表；单色标记为 `logo-mark.svg`，导出 512 × 512 |
| 会员标识 | `assets/images/big-vip.svg` | `vip.svg`，64 × 64 |
| 播放图标 | `assets/images/play.png` 及 2× / 3× / 4× 变体 | `tool/generate_play_icon.dart` |
| 播放中指示 | `assets/images/live.gif`、`live.png` | `export.py`，36 × 36 |
| 直播徽章 | `assets/images/live/live.gif` | `export.py`，135 × 42 |
| 播放器缓冲 | `assets/images/loading.webp` | `export.py`，72 × 72 |
| 投币静态预览与空箱 | `assets/images/paycoins/ic_22_*.png` | `coin_motion.py`，360 × 260；沿用历史文件名 |
| 单币 / 双币抛投 | `assets/images/paycoins/coin_toss_one.gif`、`coin_toss_two.gif` | `raster/coin.png`、`raster/coin-box.png` + `coin_motion.py`，360 × 260 |
| 选择硬币、投币盒、箭头、关闭 | `assets/images/paycoins/*.png` | `raster/coin.png`、`raster/coin-box.png`、`paycoins/*.svg` |
| Android 快捷方式 | `android/app/src/main/res/drawable/ic_shortcut_*.png` | `shortcut-search.svg`、`shortcut-download.svg` |
| Android 桌面图标、启动图 | `android/app/src/main/res/mipmap-*/ic_launcher.png`、`drawable-*/splash.png` | `export.py` |
| Windows 应用及托盘图标 | `windows/runner/resources/app_icon.ico`、`assets/images/logo/ico/app_icon_chibi.ico`（默认）、`app_icon.ico`（原版） | `export.py`，16 至 256 px 共 7 档 |

投币区使用硬币与投币箱，去掉角色。静态预览和 GIF 共用 `raster/coin-box.png` 的箱子原稿。点击或上滑播放一次抛投 GIF：硬币从箱外上抛、翻转后落入顶盖槽口；前沿逐步遮住硬币，入箱后箱子轻微下沉回弹。双币版错开 100ms 出手。24 个采样帧间隔 40ms，GIF 编码合并相同的起始停留帧，总时长 960ms。省略循环扩展，完成后停在落币帧。页面从首帧显示开始计时，随后关闭并调用原投币回调；播放中锁定金额，每次打开使用独立 MemoryImage 重播，中途关闭取消提交。余额限制、原创视频的金额范围和同时点赞设置沿用现有规则。

热搜标题由 Flutter 文本叠加；横幅高度随标题排版调整，避免系统大字号与顶部导航重叠。话题背景是透明装饰，适配明暗主题表面。播放图标继续采用 60px 逻辑尺寸、四周 12px 阴影边距的约定；恢复播放三角的完整不透明度及底板原有 36% 不透明度，保留浅灰蓝配色。边缘增加亮边与轻微内轮廓，柔和反光和阴影预渲染出亚克力磨砂质感。

Android 普通自适应前景使用 `drawable-nodpi/app_icon_artwork.png`，108dp 前景中心 72dp 放入完整头像，其余区域保留遮罩与视差余量；系统负责圆形或方圆裁切。`ic_launcher_monochrome.xml` 使用角色蝴蝶结与菱形饰件构成的单色标记，供系统主题图标着色；应用内需要颜色滤镜的 `logo_2.png` 共用该标记。Windows ICO、传统 Android 图标和明暗启动图使用圆角头像版本。

## 明暗主题

应用内通过 `Assets.themed(asset, brightness)` 选择资源，跟随当前 Flutter 主题及系统主题模式；图标还读取 `Assets.iconStyle`。四款图标均根据当前主题选择独立明暗 PNG 和 ICO。四款暗色版统一从对应浅色原稿叠加 18% 黑色遮罩，保持原本色相、构图、发饰位置和透明度。遮罩参数为 [`export.py`](export.py) 中的 `ICON_DARK_OVERLAY_OPACITY`；运行导出命令即可重建，替换浅色原稿后也会自动更新暗色资源。仅维护四款浅色原稿。

| 资源 | 暗色版本 |
| --- | --- |
| Q 版 Logo / Windows 窗口和托盘 | `logo/logo_{chibi,upright,tilted}_dark.png`、`logo/ico/app_icon_{chibi,upright,tilted}_dark.ico` |
| 原头像 Logo / Windows 窗口和托盘 | `logo/logo_dark.png`、`logo/ico/app_icon_dark.ico` |
| 图片占位 / 默认头像 / AI 总结 | `loading_dark.png`、`noface_dark.jpeg`、`ai_dark.png` |
| 空状态 / 会员标识 / 话题装饰 | `error_dark.svg`、`big-vip_dark.svg`、`topic-header-bg_dark.png` |
| Android 自适应图标 | `drawable-night-nodpi/app_icon_artwork.png` |
| Android 传统图标 / 启动图 / 快捷方式 | `mipmap-night-*/ic_launcher.png`、`drawable-night-*/splash.png`、`drawable-night/ic_shortcut_*.png` |

暗色 SVG / PNG 复用源稿几何，调色映射保存在 `tool/generate_app_artwork.dart`；应用图标的暗色遮罩在 `export.py` 内存中生成，成品位于上表路径。Android 夜间资源跟随系统配置。`lib/app/desktop_theme.dart` 在应用根节点同步 Windows 窗口外观，覆盖主窗口和独立播放窗口；托盘由主页同步并释放替换后的图片。EXE 文件和静态快捷方式保留通用彩色图标。单色标记由调用方按 `ColorScheme` 着色。封面播放、缓冲、直播背景和投币弹窗的通用资源按其自身内容背景设计，明暗主题共用。

`test/services/app_icon_test.dart` 检查默认回退、选择持久化与重载恢复。`test/common/widgets/themed_assets_test.dart` 检查四款明暗 PNG 解码和 Windows ICO bundle 加载，以及通用资源的主题切换。`test/app/desktop_theme_test.dart` 用模拟通道验证四款窗口图标跟随选择和主题更新且不依赖主页。Android 桌面刷新、系统启动动画、Windows 任务栏和托盘的实际显示在对应平台上验证。

`assets/screenshots/` 是已有产品截图，未作为应用插画重绘。数字字体和 shader 是运行资源，未纳入本次视觉替换。

## 界面图标字体

2026-10-15：32 个按功能语义重新绘制的 SVG 集中存放于 [`icons/`](icons/README.md)，与字形映射、生成脚本和版权声明一起维护。源稿未提取、描摹或转换旧字体字形。版权署名为 `Copyright (c) 2026 wallpap`，随项目按 GPL-3.0-only 分发，见 [`icons/NOTICE`](icons/NOTICE)。

`uv run tool/artwork/icons/build_font.py` 将源稿生成单个 `assets/fonts/piliaurora_icons.ttf`，同步生成 `lib/common/widgets/custom_icon.dart`。应用继续使用 `Icon(CustomIcons.xxx)`，继承 Flutter 的图标尺寸、明暗色、选中和禁用主题。字体内嵌作者、版权和许可信息；SVG 源稿保留在工具目录，应用打包字体。

数字字体 `digital_id_num.ttf` 与系统/用户导入字体保持现状。图标渲染及映射检查见 `test/common/widgets/custom_icon_test.dart`。

## 重新导出

在仓库根目录使用项目固定 Flutter 和已有 Python / Pillow：

```powershell
fvm flutter test --no-pub tool/generate_app_artwork.dart tool/generate_play_icon.dart
python tool/artwork/export.py
```

第一条命令从 SVG / Dart 源稿生成明暗位图、空状态与会员 SVG，以及 Android 单色 Vector。头像中间 PNG 放在 `build/asset-refresh/avatar.png` 和 `avatar_dark.png`。第二条命令导出明暗 Logo、头像 JPEG、投币与直播动画、Android 桌面与启动资源、Windows ICO。需要先执行第一条命令；导出完成后可删除 `build/asset-refresh/`。

直播徽章文字默认由本机微软雅黑 `C:/Windows/Fonts/msyh.ttc` 渲染；其他开发环境通过 `--font <中文字体路径>` 指定字体。直播指示与缓冲动画为 24 帧、每帧 50ms。GIF 使用统一透明索引并逐帧替换，缓冲 WebP 保留半透明边缘。

重新生成背景后，传入内置 imagegen 返回的原稿：

```powershell
python tool/artwork/export.py --live <直播原稿.png> --trending <热搜原稿.png>
```

背景按原资源比例缩放并居中裁剪，直播 WebP quality=85。省略背景参数时保留当前背景。最终资源均已保存在项目中，应用运行不依赖生成工具。

## imagegen 提示词

应用图标以用户给定的角色图为参考，当前暗色图标由导出脚本叠加黑色遮罩生成，硬币与投币盒沿用前一轮生成原稿；实际提示词见 [`imagegen-prompts.json`](imagegen-prompts.json)。角色浅色及投币原稿使用内置 imagegen，暗色图标由脚本叠加黑色遮罩派生。以下两张背景未传入参考图，保留其完整提示词。

### 直播默认背景

```text
Use case: stylized-concept
Asset type: understated production background for PiliAurora Flutter live room, portrait aspect 1125:2436.
Primary request: a calm, almost monochrome abstract night background with soft aurora-like folds, a substantial revision of an overly green visual system. Restrained and plain colors are the goal.
Scene/backdrop: charcoal and ink grey, with a quiet slate-blue veil and one faint warm stone-grey ribbon drifting through the lower half. Large smooth tonal areas, very little texture, a few tiny stars at most.
Composition/framing: tall 9:19.5, full bleed. Top 40 percent very dark and empty for video and navigation. Center quiet for chat. Soft folds run along edges and lower third, no bright focal point.
Style/medium: subtle atmospheric abstract artwork, matte and soft. No glossy sci-fi effects.
Color palette: #10151D, #202934, #394553, #697483; a very small warm-grey #9B9184 accent. Low saturation throughout. No green, purple or vivid cyan.
Constraints: background asset only, no device, no text, no logos, no watermarks, no landscape, no human figures, no border. Chat overlay readability matters. Avoid strong glow and complicated detail.
```

### 热搜横幅

```text
Use case: stylized-concept
Asset type: actual background artwork for PiliAurora trending-search page, landscape 1125:528 (2.13:1).
Primary request: a quiet neutral editorial banner with a simple magnifying glass on the right, warm grey and slate tones, spacious composition. Revise an excessively green glossy banner into restrained, plain, low-saturation artwork.
Scene/backdrop: left half is dark warm charcoal with a smooth matte gradient, subtly lighter towards the right. One gentle paper-like curve in pale stone grey passes low on the right. One large magnifying glass with a smoked glass lens and brushed warm-silver rim occupies the right third. Very simple object, soft diffused studio lighting, a restrained tiny beige dot nearby.
Composition/framing: horizontal 2.13:1. Left 55 percent quiet and dark enough for a white title, top 25 percent quiet for navigation. Complete magnifying glass on the right, no cropped handle. Only a few shapes.
Style/medium: elegant minimal abstract still life, matte surfaces, very restrained depth. Avoid shiny liquid chrome, blinding glints, starbursts and ornament.
Color palette: #2C2E33, #4B4B4D, #7C7B78, #BCB6AC, #DED8CF. Small slate-grey glass reflection. No green, no purple, no saturated colors.
Constraints: background asset only, absolutely no text, letters, numbers, logos, border, watermark, device or mockup. The app adds actual text on top.
```
