# PiliAurora

[简体中文](README.md) · [English](README.en.md)

[![GitHub Release](https://img.shields.io/github/v/release/wallpap/PiliAurora?display_name=tag)](https://github.com/wallpap/PiliAurora/releases/latest)
[![License](https://img.shields.io/github/license/wallpap/PiliAurora)](LICENSE)

PiliAurora is a third-party Bilibili client for Android and Windows x64, built with Flutter and based on [PiliPlus 2.1.5](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/2.1.5).

The project retains upstream browsing, playback, social features, and multi-account support. It also adjusts playback resource usage, Windows danmaku rendering, and video output, and adds separate video and live-stream windows, danmaku merging and frame-rate controls, and native sticker management. Danmaku are timed comments displayed over the video.

[Download](https://github.com/wallpap/PiliAurora/releases/latest) · [Changelog](doc/releases/v1.6.4.md) · [Report an issue](https://github.com/wallpap/PiliAurora/issues) · [License](LICENSE)

## Screenshots

### Windows

Pop out videos or live streams into separate windows while continuing to browse in the main window or watch other windows at the same time. The image shows several playback windows running side by side. Windows danmaku automatically follow the display refresh rate; their appearance can be adjusted in danmaku settings.

<p align="center">
  <img src="assets/display/windows-multiwindow-showcase.png" alt="Windows multi-window playback" width="800">
  <br>
  <em>Windows multi-window playback</em>
</p>

<p align="center">
  <img src="assets/display/windows-live-player.jpg" alt="Windows live-stream player" width="800">
  <br>
  <em>Windows live-stream player</em>
</p>

### Android

<p align="center">
  <img src="assets/display/android-playback-settings.jpg" alt="Android playback settings panel" width="800">
  <br>
  <img src="assets/display/android-home.jpg" alt="Android home screen" width="230">
  <img src="assets/display/android-danmaku-motion-settings.jpg" alt="Android danmaku density and frame-rate controls" width="230">
  <img src="assets/display/android-danmaku-filter-settings.jpg" alt="Android danmaku merging" width="230">
</p>

## Supported platforms and downloads

| Platform | Packages |
| --- | --- |
| Android | Separate APKs for `arm64-v8a`, `armeabi-v7a`, and `x86_64` |
| Windows x64 | Portable archive and installer |

Download the package for your platform from [GitHub Releases](https://github.com/wallpap/PiliAurora/releases/latest).

## Improvements over PiliPlus 2.1.5

### Multiple playback windows on Windows

Open videos and live streams in separate windows while continuing to browse in the main window. Playback windows support always-on-top mode, moving and resizing, grid and cascade arrangements, and saved positions and sizes. Adjust each window's volume independently or switch the audio source. See [Windows playback windows](doc/windows-playback-windows.md).

### Lower playback and danmaku overhead

Windows playback prefers D3D11 hardware decoding and shared-texture output. Video output dimensions are limited to the display area to reduce rendering surface and texture overhead. Player resources are reused during rapid source changes. Image decoding uses bounded concurrency, and hidden tabs unload images while preserving their scroll positions.

On Android and Windows, video and live-stream danmaku share a display implementation. Video danmaku follow media time, while live-stream danmaku follow accumulated display running time. Text layouts, trajectories, and raster images are reused to reduce repeated work per frame. Matching and merging run in the background, with limits on caches and active working sets. Live streams reuse a background message-parsing worker and limit chat history and unread backlogs to control resource accumulation during long sessions.

### Danmaku merging and frame-rate controls

Video danmaku can merge identical or similar comments within 20 seconds and enlarge text based on the number of duplicates. Windows danmaku automatically follow the display refresh rate. On Android, danmaku can follow the display or target 30, 60, 90, or 120 FPS; changes take effect immediately. Track spacing accounts for actual text height, and the comment-density progress bar supports custom colors. See [Danmaku merging and frame-rate settings](doc/danmaku-merge.md).

### Playback stability fixes

Videos and live streams share playback-session management that isolates old requests and callbacks when switching content. Android prepares the video Surface before decoding, and separate Windows playback windows wait for a stable texture before handing over output. Interrupted reads trigger recovery attempts based on media and buffer state. A fallback CDN can be enabled when needed, and hardware-decoding failures trigger attempts with alternative paths.

Android also has an experimental option to scale output to the screen resolution, disabled by default. Output-size limits reduce rendering overhead; the source video is still decoded at its original resolution. Resource usage and smoothness vary with the device, drivers, codec, video quality, danmaku settings, and number of windows.

### Reworked notifications and direct messages

The home page and message entry points share unread state. Replies, mentions, likes, system notifications, and direct messages follow the primary account. Switching accounts discards pending responses from the previous account. Conversation actions update shared state, chat history is deduplicated, and stale pagination results are discarded.

Direct messages support text, images, and share cards. Cards and accompanying text share a send lock and report their results separately. Drafts are retained when delivery is awaiting confirmation, with a prompt to check the conversation history.

### Blacklist filtering

Enhanced blacklist filtering is enabled by default under Settings → Account and privacy. It filters blocked authors from recommendations, popular content, search, feeds, and live-stream lists. Cooperative-author checks are also enabled by default: videos marked as collaborations are hidden if any author is blocked. These checks add requests and loading time and can be disabled separately. See [Blacklist filtering](doc/content-filtering.md) for coverage.

### Everyday additions

- Native sticker management with categories, adding and removing packs, content previews, enlarged individual stickers, and recently used stickers.
- User blocking from the comment long-press menu, plus a followers list with follow and unfollow actions.
- Audio-quality selection for downloads, subtitle preferences carried between episodes, and cleanup of unavailable series subscriptions.
- Emotes in live-stream danmaku and mouse-wheel support for sticker tabs and favorite folders.

## Relationship to upstream

PiliAurora has been maintained independently since PiliPlus 2.1.5 and currently releases Android and Windows x64 builds. The upstream baseline also lists iOS, tablet, and Linux support. PiliAurora uses its own application identifier and data directory, so it can be installed alongside PiliPlus. Accounts, settings, caches, and offline files are stored separately.

## Feature overview

- Browsing: recommendations, trending content, rankings, videos, series, articles, audio, live streams, and search.
- Playback: video and audio quality, playback speed, hardware-decoding settings, danmaku, subtitles, episode switching, and playback history. Subtitle preferences carry between episodes, and the comment-density progress bar supports custom colors.
- Social features: comments, activity feeds, following, followers, notifications, direct messages, and live chat with emotes.
- Comment and sticker tools: block users from the comment long-press menu and add, remove, or preview sticker packs by category. See [Comments and stickers](doc/comments-and-emotes.md).
- Account and content management: multiple accounts, favorites, watch history, watch later, series subscriptions, and offline downloads, including unavailable-subscription cleanup and download audio-quality selection.
- Extras: DLNA casting, WebDAV settings backup, SponsorBlock, and WebView.

Feature availability depends on Bilibili APIs, account permissions, the platform, and the media being played.

## Build from source

The Flutter version is pinned in [.fvmrc](.fvmrc). Android builds require the Android SDK and JDK 25. Windows builds require Visual Studio with the **Desktop development with C++** workload. Windows uses the repository's [prebuilt mpv packages](third_party/mpv/README.md), which are verified and extracted by local builds and Windows CI. Native libraries can be rebuilt from pinned sources when updated. See [Build and test](doc/build-and-test.md) for environment requirements and validation commands.

```powershell
git clone https://github.com/wallpap/PiliAurora.git
cd PiliAurora
fvm install
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

## Documentation

User guides, developer guides, and release notes are listed in the [documentation index](doc/README.md). The linked guides are currently in Chinese.

- Usage: [Danmaku settings](doc/danmaku-merge.md), [Windows playback windows](doc/windows-playback-windows.md).
- Development: [Build and test](doc/build-and-test.md), [Feature map](doc/features.md), [Architecture](doc/architecture.md).
- Troubleshooting: [Maintenance guide](doc/maintenance.md), [Windows video output](doc/windows-video-output.md).

## Contributing

Bug reports through GitHub Issues and pull requests are welcome. Before changing playback, danmaku, or platform code, read [Maintenance and troubleshooting](doc/maintenance.md) and [Build and test](doc/build-and-test.md). When changing third-party dependencies, record their sources and licenses following the [dependency maintenance guide](third_party/README.md).

## Reporting issues

Open a [GitHub issue](https://github.com/wallpap/PiliAurora/issues) with your operating system, device, app version, reproduction steps, and affected page. For playback issues, also include the video codec, quality, danmaku settings, and hardware-decoding state. Remove cookies, tokens, QR-code login information, and other account data before sharing logs.

## Disclaimer

PiliAurora is an independently maintained community client and is not affiliated with or endorsed by Bilibili. It uses public APIs and does not provide cracked content. Please comply with Bilibili's terms of service and applicable laws. The Bilibili name, trademarks, and related content belong to their respective rights holders.

## Acknowledgments

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus): this project directly builds on version 2.1.5.
- [PiliPalaX](https://github.com/orz12/PiliPalaX) and [PiliPala](https://github.com/guozhigq/pilipala): upstream projects in the PiliPlus lineage.
- [My-Responsitories](https://github.com/My-Responsitories) and everyone who has contributed to the upstream projects and PiliAurora.
- The authors and maintainers of Flutter, media_kit, Dio, and other open-source dependencies.

Upstream source files retain their original copyright and license notices. Sources, copyrights, and licenses for dependencies and ported components are listed in [third_party/README.md](third_party/README.md) and the corresponding component files.

## License

PiliAurora is licensed under the [GNU General Public License v3.0](LICENSE). Third-party components retain their respective licenses.
