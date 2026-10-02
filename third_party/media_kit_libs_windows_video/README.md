# Windows 原生库绑定

源自 `My-Responsitories/media-kit` 的 `73771ec38176be2d984a3049c28177bce23b54a0`，
路径为 `libs/windows/media_kit_libs_windows_video`。保留原插件源码和 MIT 许可证。
本地副本只用于固定 Windows libmpv，不升级其他 media_kit 包或 ANGLE。

libmpv 固定为同源 `20260819` 构建，mpv `e7191f2a65`、FFmpeg `3bdd89583`。
FFmpeg 包含 `bcd2c69e`，修复 D3D12 reference-only 参考帧资源池耗尽。
下载地址和归档、DLL、导入库 SHA256 固定在 `windows/libmpv.cmake`。
每次 CMake 配置校验归档，并同步新版 DLL、导入库和头文件到构建目录，避免沿用旧缓存。

此更新不增加 AMF 或 D3D12 非 copy 模式的渲染互操作支持。
短 AV1 样本已验证 D3D12 copy 持续解码；4K60 吞吐量须使用实际视频复测。

上游包支持配置固定版本和缓存校验后，可移除此本地副本并恢复 Git override。
