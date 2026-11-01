# 本地 Windows WebView 补丁

- 来源包：flutter_inappwebview_windows 0.6.0。
- 本地版本：`0.6.0+piliaurora.4`，登记见 `../dependencies.json`。
- 来源：bggRGjQaUbCoE/flutter_inappwebview。
- 固定提交：0bfa46dfff87f0d9e9d5e13cbd5c4a7c7310f8c9。
- 仅复制该包的 lib、windows、pubspec、analysis_options 与许可/版本说明；不复制 example、开发缓存或 Git 仓库。
- 不升级 Dart/WebView2/WIL 版本，不修改共享 Pub 缓存。
- 补丁目的：在最后一个 manager 销毁时释放静态图形资源，不留到 DLL 静态析构阶段。
- Dart 维护修正：方法通道异常使用 Flutter 日志输出；补充本地 HTML 资源与 JavaScript 纯文本回退的说明。
- 本机顺序重建、DOM/容器清理与短播放退出的验证记录对应 2026-10-03；多 engine 和异步队列关闭的边界见下文。

## 补丁范围与边界

- `0.6.0+piliaurora.4`：插件注册只注册窗口类；首次创建嵌入式 WebView 时才初始化
  RoHelper、DispatcherQueue、D3D 设备及 compositor，Cookie、Environment、headless 和
  独立浏览器不提前持有这套纹理捕获资源。保留最后一个 manager 销毁时的释放顺序；
  补齐 compositor 有效性检查，并配对释放捕获支持查询的 COM 接口。
- 同版修正 Environment 新实例的通道 id，避免 dispose 发到静态工厂通道而失败；
  显式释放/创建失败时注销捕获实例的原生 handler，并在析构时显式关闭本环境的隐藏
  controller。引擎整体销毁会先关闭 messenger，delegate 析构不再调用注销接口。

- `0.6.0+piliaurora.3`：NuGet 包按名称和固定版本分目录保存；完整包存在时跳过恢复命令。Windows CI 缓存该目录，版本或 CMake 配置变化时使用新缓存键。

- plugin 析构先清理 headless/browser 容器，再释放普通 manager 和 environment。
- manager_count_ 归零时释放 compositor、graphics_context、dispatcher_queue_controller、rohelper。
- 引用计数保留同进程多个顺序 engine 的共享资源寿命；不改变已有静态资源设计，不提供跨线程支持。
- 未新增异步队列 drain，当前验证覆盖本机顺序重建、DOM/容器清理和短播放退出。
- 移除仅用于上游 example 的可选 GoogleTest target 和测试夹具；不属于应用生产插件目标。
- 保留既有补丁与上游尾空白清理；本版另修改 manager 初始化、Environment 通道和确定性清理。
  NuGet 版本及原许可证保持不变。
