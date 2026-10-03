# 本地 Windows WebView 补丁

- 包：flutter_inappwebview_windows 0.6.0。
- 来源：bggRGjQaUbCoE/flutter_inappwebview。
- 固定提交：0bfa46dfff87f0d9e9d5e13cbd5c4a7c7310f8c9。
- 仅复制该包的 lib、windows、pubspec、analysis_options 与许可/版本说明；不复制 example、开发缓存或 Git 仓库。
- 不升级 Dart/WebView2/WIL 版本，不修改共享 Pub 缓存。
- 补丁目的：在最后一个 manager 销毁时释放静态图形资源，不留到 DLL 静态析构阶段。
- 实验结果和多 engine/队列关闭边界由 tool/reports 的 20261003 跟进报告记录。

## 补丁范围与边界

- plugin 析构先清理 headless/browser 容器，再释放普通 manager 和 environment。
- manager_count_ 归零时释放 compositor、graphics_context、dispatcher_queue_controller、rohelper。
- 引用计数保留同进程多个顺序 engine 的共享资源寿命；不改变已有静态资源设计，不提供跨线程支持。
- 未新增异步队列 drain，当前验证覆盖本机顺序重建、DOM/容器清理和短播放退出。
- 功能补丁仅修改 3 个生产 C++ 文件；另清理 4 个上游文件中的 5 行尾空白（空行或注释）。Dart 业务逻辑、NuGet 版本及原许可证保持不变。
- 完整结果：tool/reports/windows-webview-cache-experiment-20261003.md。
