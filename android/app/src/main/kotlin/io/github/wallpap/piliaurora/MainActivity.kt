package io.github.wallpap.piliaurora

import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val appIconAliases = mapOf(
        "chibi" to "ChibiLauncher",
        "upright" to "UprightLauncher",
        "tilted" to "TiltedLauncher",
        "portrait" to "PortraitLauncher"
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "piliaurora/app_icon")
            .setMethodCallHandler { call, result ->
                val selectedAlias = (call.arguments as? String)?.let { appIconAliases[it] }
                if (call.method != "setIcon") {
                    result.notImplemented()
                } else if (selectedAlias == null) {
                    result.error("invalid_icon", "Unknown icon style", null)
                } else {
                    try {
                        setAppIcon(selectedAlias)
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("icon_failed", error.message, null)
                    }
                }
            }
    }

    private fun setAppIcon(selectedAlias: String) {
        val aliases = listOf(selectedAlias) + appIconAliases.values.filter { it != selectedAlias }
        val states = aliases.map { alias ->
            ComponentName(this, "io.github.wallpap.piliaurora.$alias") to
                if (alias == selectedAlias) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        if (states.all { (component, state) -> packageManager.getComponentEnabledSetting(component) == state }) return
        // 先启用目标入口；旧系统逐项更新时也始终保留可启动入口。
        if (Build.VERSION.SDK_INT >= 33) {
            packageManager.setComponentEnabledSettings(states.map { (component, state) ->
                PackageManager.ComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
            })
        } else {
            states.forEach { (component, state) ->
                packageManager.setComponentEnabledSetting(component, state, PackageManager.DONT_KILL_APP)
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
