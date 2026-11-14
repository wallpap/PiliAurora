# 引擎与框架源码差异

项目当前维护的引擎改动由对应构建脚本应用：

- [Windows 帧节奏补丁](windows-frame-pacing.patch)：DirectComposition 呈现和帧调度，见[构建说明](../../../tool/engine/windows_frame_pacing/README.md)。
- [Windows ANGLE 图片上传补丁](../../../tool/engine/windows_frame_pacing/angle-image-upload.patch)：固定 ANGLE 独立检出内的 AMD staging 默认策略，由同一 Windows 构建入口应用并纳入引擎身份。
- [Android 帧计划补丁](android-frame-plan.patch)：FrameTimeline、纹理更新和 EGL 呈现，见[构建说明](../../../tool/engine/frame_plan/README.md)。
- [Windows 内存诊断补丁](windows-memory.patch)和[空闲回收补丁](windows-idle-trim.patch)：图形及 CPU 内存诊断和空闲回收实验，见[构建说明](../../../tool/engine/windows_memory/README.md)。

这些引擎补丁以 Flutter 引擎提交 `af7e796e161ae0bb1ff0758c71a7105418bd9ded` 为基准；按各自说明准备依赖和构建。

## Flutter 框架

[flutter-framework-3.47.5.patch](flutter-framework-3.47.5.patch) 保存当前 FVM Flutter 3.47.5 的项目修改，包括应用使用的组件接口和行为调整。补丁基准是 Flutter 框架提交 `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`。在该基准的干净检出根目录应用：

```powershell
git apply --check <补丁文件的绝对路径>
git apply <补丁文件的绝对路径>
```

该补丁已在基准上正向应用，35 个修改文件与当前 FVM 源码逐项一致。构建和测试命令见[构建与测试](../build-and-test.md)。
