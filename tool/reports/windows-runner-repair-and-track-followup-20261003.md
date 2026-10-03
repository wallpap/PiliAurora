# Windows 退出修复与轨道拒绝接手记录（2026-10-03）

## 当前结论

接手两份聊天的现有成果，不重新合并、不重做已有预算与遥测实现。

- 分支仍为 `codex/windows-playback-experiments-20261003`，起点 HEAD 为 `68e8bd11e`。
- 修复了已隔离复现的 runner 生命周期缺陷，以及轨道转换违反 `hideScroll` 的缺陷。
- 原先完整插件集退出的 `0xE0464645` **尚未验证解决**。本轮没有重新启动完整播放器，也没有重复更换主动退出 API。
- 已完成用户指定第 1 项“轨道分配拒绝”的源码研究与小型回归。未开展第 2～4 项缓存预算、透明合成、长时间 Private Bytes 实验。
- 未修改生产依赖、共享 Pub 缓存、WER、注册表、系统权限或预算默认值。未暂存、提交、合并或推送。

研究详情见 [轨道分配拒绝研究](windows-track-allocation-research-20261003.md)。上一轮 [播放实验记录](windows-playback-experiment-20261003.md) 保留为历史记录，不覆盖其失败证据。

## 1. 原生退出：反馈回路与修复

### 方法

新增 `tool/windows-runner-lifecycle.ps1` 和 `test/windows/runner/`。

测试直接编译仓库的 `flutter_window.cpp`、`win32_window.cpp`、`main.cpp`，连接当前 Flutter SDK 的真实引擎与 Profile wrapper。只有生产插件注册、app_links 实例转发和入口参数工具被替换为最小测试替身。测试插件注册真实的 registrar destruction callback，并在其中向本测试线程的窗口发送真实 `WM_FONTCHANGE`。

测试不加载 WebView、媒体或其他生产插件 DLL，不打开完整播放器，不附加用户进程。Dart 使用空的测试入口 `tool/windows_runner_lifecycle_fixture.dart`，防止运行基准时缺少必填参数产生无关错误。

对可到达测试边界的访问冲突使用 SEH 捕获；Windows 回调内部的致命异常仍由退出码报告。失败后的强制结束仅用于半析构的测试进程，**不是生产退出修复，也不计为测试通过**。

### 红灯证据

| 用例 | 修复前信号 | 文件 |
| --- | --- | --- |
| 引擎销毁后、顶层 HWND 销毁前收到字体通知 | `FAIL font-after-destroy access violation 0xC0000005`，退出 1 | `build/runner-lifecycle-red.log` |
| 未先 WM_CLOSE，直接离开窗口作用域；插件析构回调重入窗口消息 | 进程退出 `0xC000041D` | 主代理隔离运行输出 |
| 真实 main 返回时，插件析构必须先于 runner 自己的 COM 引用释放 | `FAIL main-return COM released before plugin teardown`，退出 1 | `build/runner-lifecycle-main-red.log` |

第三个用例使用仅作用于测试构建中 main.cpp 的顺序探针，探针仍调用真实 `CoUninitialize`。它验证 runner 自身的初始化/释放边界，不假设该调用一定让线程最后一个 COM 引用消失；Flutter 内部可能还持有初始化引用。

最初搭建测试时遇到 SEH 临时对象限制与宽字符窄化编译告警，已经修复；测试目标采用项目相同的 `/W4 /WX /wd4100`，最终构建无这些错误或告警。

### 修复

`windows/runner/flutter_window.cpp`：

1. 在派生析构体执行 `OnDestroy()`，不等待控制器成员自动析构后再由基类销毁窗口。
2. 把控制器先 move 到局部，再 reset；析构回调重入时成员已为空，不向半析构的 Flutter view/controller 转发消息。
3. `WM_FONTCHANGE` 分支检查控制器是否仍存在。

`windows/runner/main.cpp`：

1. 添加只在本文件使用的 `ScopedCOM`，初始化失败时返回错误。
2. 按局部对象逆序析构，窗口与引擎插件先销毁，再配对释放 runner 的 COM 初始化引用。
3. 覆盖正常返回与窗口创建失败后的提前返回；没有新增生产依赖。

此 SDK 的真实 wrapper 析构调用 `FlutterDesktopViewControllerDestroy`，消息转发调用 `FlutterDesktopViewControllerHandleTopLevelWindowProc`。源码位于 `windows/flutter/ephemeral/cpp_client_wrapper/flutter_view_controller.cc`，支持测试覆盖的是实际边界而非 mock 控制器。

### 绿灯及边界

同一测试命令下三个用例均打印 PASS 并正常退出。最终无无关 Dart 启动异常。日志：`build/runner-lifecycle-final-green.log`。

```powershell
pwsh -File tool/windows-runner-lifecycle.ps1
# 测试 fixture 已构建且没有更换 Profile 入口时，可跳过 Flutter 重建：
pwsh -File tool/windows-runner-lifecycle.ps1 -SkipFlutterBuild
```

脚本自动从已有 CMakeCache 找本机 CMake，也接受 `-CMake` 绝对路径。首次运行需已有项目依赖与 Windows Flutter 工具链；不安装依赖。fixture 构建会暂时把标准 Profile 输出替换为测试入口。完成测试后应重新构建正常入口；脚本拒绝对非 fixture 的 Profile 资产使用 `-SkipFlutterBuild`。

**不能推论：** 完整 WebView/媒体插件退出已经安全，或此前 `0xE0464645` 根因已经确认。静态 Compositor/DispatcherQueue 生命周期仍是单独待隔离对象。对该依赖的本地补丁及依赖覆盖配置需要用户确认后再做；不改共享 Pub 缓存。

## 2. 轨道拒绝：研究与修复

### 已确认的行为

- 顶部与底部共享静态池；`massiveMode` 不使静态池无限容量。
- 正常滚动入口未清空、后项会追赶前项时，拒绝是碰撞保护。尚无证据支持放宽该规则。
- `rejectedByTrack` 是累计的选轨失败，不是总拒绝；`clear` 不重置它。
- 旧短样本的轨道拒绝测量差分为 `359 - 172 = 187`。不能把累计 359 或总拒绝 243 都归为轨道拒绝。旧外层拒绝与该差分尚不能对账，不能据此归因当前实现。

### 发现并修复的设置错误

开启 `static2Scroll` 后，静态满轨或静态文本超宽时会进入转换分支。此前直接令 `scrolling=true`，忽略 `hideScroll`。

新增测试先确认：`hideScroll=true` 的满轨与超宽两项均 `Expected false / Actual true`；`hideScroll=false` 两项通过。红灯日志为 `build/track-rejection-red-20261003.log`。

最小修改：转换分支改为 `scrolling = !_option.hideScroll`。禁止滚动时仍保留 track=-1，拒绝此次转换。没有把超宽弹幕重新放回静态池，以保持锁定上游的 `static2Scroll` 语义。没有改变普通滚动追赶判据、海量叠加条件、selfSend 策略或资源预算。

新增六个测试覆盖：

1. 海量模式下顶部/底部共享静态容量、999/1000 ms 释放边界与 clear 累计计数。
2. 静态满轨 × hideScroll 两个取值。
3. 静态超宽 × hideScroll 两个取值。
4. 普通滚动同 tick 突发拒绝、入口清空后接受与拒绝原因分类。

这项修复是消除“漏拒绝、违反隐藏设置”，不是降低正常容量拒绝率。保留合理拒绝有助于维持视觉与内存保护。

## 3. 验证

- Dart 相关回归：57 项通过，`build/takeover-tests-final-20261003.log`。
- 相关静态分析：No issues found，`build/takeover-analysis-final-20261003.log`。
- 原生 runner：三个用例通过；MSVC 严格告警构建通过。
- PowerShell 脚本解析：通过。
- Dart 与改动 C++ 已格式化。
- `git diff --check`：通过。
- 正常应用 Windows Profile 重建：`flutter build windows --profile --no-pub --target lib/main.dart` 成功（106.1 秒），日志 `build/takeover-main-profile-20261003.log`。Profile 输出已恢复应用入口；未启动完整应用。

以上不覆盖跨设备、真实显示、音画同步、WebView 静态退出或长时间内存。

## 4. 建议下一步

先确认是否允许在本实验分支以仓库内副本修复 Windows WebView 依赖，不升级版本、不改变共享缓存。获得确认后，先做插件隔离和正确线程上的资源释放测试，验证完整进程正常退出，再恢复真实播放实验。

轨道侧优先补充按滚动/顶部/底部拆分的窗口差分统计及完整配置快照。静态 selfSend 与上游的策略差异需先明确产品意图，不默认开启强制重叠。不要以扩大内存预算、缓存或放宽碰撞规则代替研究结论。
