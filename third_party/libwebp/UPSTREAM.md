# libwebp 区域解码源码

Windows 图片 worker 静态链接本目录的 decoder 子集。固定上游提交
`a53957a41ef2c01cc8b63f629c5712ccd303890c`，来源、归档摘要和逐文件 SHA-256
见 [SOURCE.json](SOURCE.json)。上游源码保持原样，项目仅提供 decoder 的 CMake 装配。

该提交修复透明有损 WebP 在非零裁剪原点取错 alpha 行的问题。1.6.0 Windows SDK
曾在确定性夹具的同一像素返回 alpha 186，而完整帧参照为 24；不能将该 SDK 直接用于正式区域路径。
回归见 `tool/probes/windows/image_region_probe_test.py`，并与 Flutter 实际绘制像素比较。

生产子集按上游 Makefile.am 的 dec、dsp COMMON/decode、utils COMMON/decode 选择 C 源码，
保留 src 内引用头文件、BSD 许可、AUTHORS 和专利授权。未引入编码器、工具或独立 DLL。
CMake 配置时逐文件核对摘要。更新时重新核对上游提交和来源，替换源码、清单及构建列表，
执行原生裁剪回归、Flutter 显示像素/生命周期测试与 Windows Release 打包验证。

许可材料随应用安装到 `licenses/libwebp/`。本目录属于原生构建材料，不计入 Dart 本地包登记数。
