The project uses the Flutter version declared in `.fvmrc`. After installing FVM and the Android SDK or Visual Studio, use these commands to fetch Dart packages, apply the Flutter source patches, and build:

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

The Android entry point uses a short project-local temporary directory to avoid Gradle loopback failures on some Windows setups. HTTP(S) proxy settings are passed from `HTTP_PROXY`/`HTTPS_PROXY` to Gradle.

Regenerate the JNI bindings with:

```powershell
fvm dart run tool/jnigen.dart
```

Trace a running Windows debug build during a danmaku stress test:

```powershell
pwsh -File tool/trace-windows.ps1 -ProcessId 12345 -DurationSeconds 180
```

The script prints peak process memory and writes a CSV with CPU and GPU process memory samples to the Windows temporary directory. GPU fields stay empty when Windows does not provide those counters.
