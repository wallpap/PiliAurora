# catcher_2 本地版本

- 本地版本：`2.1.9+piliaurora.2`；来源包版本：`2.1.9`。
- 来源仓库：https://github.com/My-Responsitories/catcher_2.git
- 来源提交：`0a9f6fd4ee2ac13ab75591ea70530e245ddb4366`。
- 来源子目录：`.`。
- 许可证：LICENSE。
- 保留原因：保留精简的异常捕获、日志接口和 Windows 设备信息。

仅收录生产源码、构建配置、资源及许可说明；不复制上游示例、测试、缓存或 Git 元数据。
导入时除包版本、禁止发布声明及必要依赖声明外，不重写来源实现。
这些包不是 pub.dev 同名版本的镜像，不可仅修改根版本号宣称已升级。
更新流程见 `../README.md`，来源登记见 `../dependencies.json`。

## 本地修订 .2

宿主通过 `ReportLog` 接收捕获器日志，统一使用自身诊断的过滤和脱敏，不再注入第三方 `Logger`。删除 logger 依赖与未使用的彩色/边框打印实现，堆栈过滤算法保留为 `ReportStackFormatter`；异常捕获、Report 数据格式及设备信息收集不变。无日志回调时捕获器不自行打印潜在敏感事件。来源提交和许可证保持不变。
