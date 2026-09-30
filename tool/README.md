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

For short memory spikes, use `-IntervalMilliseconds 250 -SkipGpuCounters`.
`ProcessPeakWorkingMiB` records the Windows working-set peak since process startup,
including spikes between samples.

For built-in release diagnostics, open **About → Performance tracing**.

## Hardware decoder fallback

Windows and Android hardware decoding uses an ordered candidate list. Automatic
settings first let mpv select a decoder, then try platform-specific decoders in
efficiency order. Explicit decoder settings keep their configured order.

When an AV1 hardware decoder reports an initialization failure, the player
records that backend as unavailable for the current process, reopens the media
at the current position, and tries the next candidate. Software decoding
(`hwdec=no`) is the final fallback. A normal AV1 packet or sequence-header
error does not trigger this path by itself.
