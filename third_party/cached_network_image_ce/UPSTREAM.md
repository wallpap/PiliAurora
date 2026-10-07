# cached_network_image_ce 本地版本

- 本地版本：`4.6.4+piliaurora.2`；来源包版本：`4.6.4`。
- 来源仓库：https://github.com/My-Responsitories/flutter_cached_network_image_ce.git
- 来源提交：`dacec4de669b4c52c59576509db069e3194408ac`。
- 来源子目录：`cached_network_image`。
- 许可证：LICENSE、upstream/platform_interface/LICENSE。
- 保留原因：保留独立 material_ui 类型、容量缓存接口和当前图片生命周期行为。

仅收录生产源码、构建配置、资源及许可说明；不复制上游示例、测试、缓存或 Git 元数据。
导入时除包版本、禁止发布声明及必要依赖声明外，不重写来源实现。
这些包不是 pub.dev 同名版本的镜像，不可仅修改根版本号宣称已升级。
更新流程见 `../README.md`，来源登记见 `../dependencies.json`。

## piliaurora.2：接口包合并

原 `cached_network_image_platform_interface_ce 5.2.0` 的同提交来源子目录 `cached_network_image_platform_interface` 合并至 `lib/src/cache_api` 与 `lib/src/cache_api.dart`。缓存模型、IO 加载契约和主包公开导出保持不变，不再维护一个单独的 Pub 包。原来源元数据及 MIT 许可证保留在 `upstream/platform_interface`；其中 `*.upstream.yaml` 为历史记录，不参与依赖解析或分析配置。完整来源登记在 `dependencies.json` 的 `merged_sources`。
