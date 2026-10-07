package com.github.rmtmckenzie.native_device_orientation;

import android.app.Activity;
import android.provider.Settings;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.Log;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * NativeDeviceOrientationPlugin
 */
public class NativeDeviceOrientationPlugin implements FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    private MethodChannel channel;
    private EventChannel eventChannel;
    private Activity activity;
    private IOrientationListener listener;
    private boolean checkIsAutoRotate = true;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "native_device_orientation");
        channel.setMethodCallHandler(this);

        eventChannel = new EventChannel(flutterPluginBinding.getBinaryMessenger(), "native_device_orientation_events");
        eventChannel.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (listener != null) {
            listener.stopOrientationListener();
            listener = null;
        }
        channel.setMethodCallHandler(null);
        eventChannel.setStreamHandler(null);
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        this.activity = binding.getActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        if (listener != null) {
            listener.stopOrientationListener();
            listener = null;
        }
        this.activity = null;
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        this.onAttachedToActivity(binding);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull final Result result) {
        switch (call.method) {
            case "pause":
                // if a listener is currently active, stop listening. The app is going to the background
                if (listener != null) {
                    listener.stopOrientationListener();
                }
                result.success(null);
                break;

            case "resume":
                // start listening for orientation changes again. The app is in the foreground.
                if (listener != null) {
                    listener.startOrientationListener();
                }
                result.success(null);
                break;
            default:
                result.notImplemented();
        }
    }

    @Override
    public void onListen(Object parameters, final EventChannel.EventSink eventSink) {
        if (activity == null) {
            throw new IllegalStateException("Cannot start listening while activity is detached");
        }

        int angleDegrees = 30;
        // used hashMap to send parameters to this method. This makes it easier in the future to add new parameters if needed.
        if (parameters instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> params = (Map<String, Object>) parameters;

            if (params.containsKey("checkIsAutoRotate")) {
                Boolean checkIsAutoRotateNullable = (Boolean) params.get("checkIsAutoRotate");
                checkIsAutoRotate = checkIsAutoRotateNullable != null && checkIsAutoRotateNullable;
            }

            if (params.containsKey("angleDegrees")) {
                Integer angleDegreesNullable = (Integer) params.get("angleDegrees");
                if (angleDegreesNullable != null) {
                    angleDegrees = angleDegreesNullable;
                }
            }
        }

        // initialize the callback. It is the same for both listeners.
        IOrientationListener.OrientationCallback callback = orientation -> {
            if (checkIsAutoRotate) {
                Map<String, Object> map = new HashMap<>();
                map.put("orientation", orientation.name());
                map.put("isAutoRotate", Settings.System.getInt(activity.getContentResolver(), Settings.System.ACCELEROMETER_ROTATION, 0) == 1);
                eventSink.success(map);
                return;
            }
            eventSink.success(orientation.name());
        };

        listener = new SensorOrientationListener(activity, callback, angleDegrees);
        listener.startOrientationListener();
    }

    @Override
    public void onCancel(Object arguments) {
        if (listener != null) {
            listener.stopOrientationListener();
            listener = null;
        }
    }
}
