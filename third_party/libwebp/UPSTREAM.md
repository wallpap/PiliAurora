# libwebp 区域解码源码

Windows 图片 worker 静态链接本目录 decoder 子集，固定上游提交 `a53957a41ef2c01cc8b63f629c5712ccd303890c`。来源、归档及逐文件 SHA-256 见 [SOURCE.json](SOURCE.json)。上游文件保持原样，项目提供 CMake 装配并在配置时校验摘要。

该提交修复透明有损 WebP 在非零裁剪原点读取错误 alpha 行的问题。1.6.0 Windows SDK 在确定性夹具的同一像素返回 alpha 186，完整帧参照为 24，不能用于正式区域路径。`tool/probes/windows/image_region_probe_test.py` 和 Flutter 显示像素回归覆盖此问题。

子集按上游 Makefile.am 的 dec、dsp COMMON/decode、utils COMMON/decode 选取 C 源码，保留 src 引用头文件、BSD 许可、AUTHORS 和专利授权；不包含编码器、工具或独立 DLL。来源及许可安装到 `licenses/libwebp/`，作为原生构建材料登记，不计入 Dart 本地包数量。

更新时核对上游提交与来源，同步源码、摘要清单和构建列表，再运行原生裁剪回归、Flutter 像素/生命周期测试及 Windows Release 打包验证。
