# 空降助手

在“设置 → 播放 → 空降助手”开启功能并配置分类行为。接口适配以 [BilibiliSponsorBlock 0.17.1](https://github.com/hanydd/BilibiliSponsorBlock/releases/tag/0.17.1) 和其[官方 API](https://github.com/hanydd/BilibiliSponsorBlock/wiki/API) 为依据。

## 片段处理

- 自动处理和处理一次会遵循片段提供的动作：`skip` 跳过，`mute` 静音；整片标记和精彩时刻只展示，不自动跳转。
- 静音不修改系统音量或用户保存的音量。重叠静音片段全部结束、跳出片段、停止片段监听或切换媒体后解除静音；用户自己开启的静音和期间调整的音量继续保留。
- “手动跳过”显示操作提示，由用户选择是否跳过该片段。它也适用于不想自动静音的惊吓片段。
- 新安装默认自动处理惊吓片段；已有分类设置升级时保留原选择，新增分类默认禁用，可以自行启用。
- 分类行为和颜色按名称保存，兼容旧版数组。新增分类不再重置已有分类的行为和颜色。

服务地址可以在空降助手设置中修改。网页扩展的 DOM、网页画中画界面和灰度分组不属于本客户端的播放协议。

## 开发验证

```powershell
fvm flutter test --no-pub test/pages/sponsor_block/block_mixin_test.dart test/utils/sponsor_block_settings_test.dart
```

片段回归覆盖静音与跳过、重叠、拖动、一次处理、重置、手动提示、标记、未知动作和不完整数据。播放会话与原生运行时的相关测试另覆盖独立音量、加载期间配置合并、旧所有者失效和新媒体解除静音。

测试使用模拟响应和播放器；Android、Windows 的真实声音输出与实际服务仍需设备验证。
