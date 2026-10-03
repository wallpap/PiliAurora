# 构建工具

项目使用 `.fvmrc` 声明的 Flutter 版本。准备好 Android SDK 或 Visual Studio 后，在仓库根目录运行：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

重新生成 Android JNI bindings：

```powershell
fvm dart run tool/jnigen.dart
```

`tool/` 只维护项目构建和代码生成入口。
