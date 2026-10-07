package com.github.rmtmckenzie.native_device_orientation;

import android.annotation.SuppressLint;
import android.annotation.TargetApi;
import android.app.Activity;
import android.content.Context;
import android.content.res.Configuration;
import android.hardware.SensorManager;
import android.os.Build;
import android.view.Surface;
import android.view.WindowManager;

import java.util.Objects;


public class SensorOrientationListener implements IOrientationListener {
    private final Activity activity;
    private final OrientationCallback callback;
    private OrientationEventListener orientationEventListener;
    private NativeOrientation lastOrientation = null;
    private int angleOffset = 0;
    private final int angleDegrees;

    public SensorOrientationListener(Activity activity, OrientationCallback callback, int angleDegrees) {
        this.activity = activity;
        this.callback = callback;
        this.angleDegrees = angleDegrees;
        checkOrientation();
    }

    @Override
    public void startOrientationListener() {
        if (orientationEventListener != null) {
            callback.receive(lastOrientation);
            return;
        }

        orientationEventListener = new OrientationEventListener(activity, SensorManager.SENSOR_DELAY_NORMAL, angleDegrees) {
            @Override
            public void onOrientationChanged(int angle) {
                NativeOrientation newOrientation = calculateSensorOrientation(angle);

                if (newOrientation != null && !newOrientation.equals(lastOrientation)) {
                    int lastAngleOffset = angleOffset;
                    checkOrientation();
                    if (lastAngleOffset != angleOffset) {
                        // correct angleOffset
//                        Log.i("NDOP", "correct angle offset");
                        onOrientationChanged(angle);
                    } else {
                        lastOrientation = newOrientation;
                        callback.receive(newOrientation);
                    }

                }
            }
        };
        if (orientationEventListener.canDetectOrientation()) {
            orientationEventListener.enable();
        }
    }

    private void checkOrientation() {
        // orientation is 0 in the default orientation mode. This is portait-mode for phones
        // and landscape for tablets. We have to compensate this by calculating the default orientation,
        // and applying an offset.
        int defaultDeviceOrientation = getDeviceDefaultOrientation();
        if (defaultDeviceOrientation == Configuration.ORIENTATION_LANDSCAPE) {
            // add offset to landscape
            angleOffset = 270;
        } else {
            angleOffset = 0;
        }
    }


    @Override
    public void stopOrientationListener() {
        if (orientationEventListener == null) return;
        orientationEventListener.disable();
        orientationEventListener = null;
    }

    public NativeOrientation calculateSensorOrientation(int angle) {
        if (angle == OrientationEventListener.ORIENTATION_UNKNOWN) {
            return null;
        }
        NativeOrientation returnOrientation = null;

        angle += angleOffset;
        angle = angle % 360;

        if (angle < 10 || angle > 350) {
            returnOrientation = NativeOrientation.portraitUp;
        } else if (angle > 80 && angle < 100) {
            returnOrientation = NativeOrientation.landscapeRight;
        } else if (angle > 170 && angle < 190) {
            returnOrientation = NativeOrientation.portraitDown;
        } else if (angle > 260 && angle < 280) {
            returnOrientation = NativeOrientation.landscapeLeft;
        }

        return returnOrientation;
    }

    public int getDeviceDefaultOrientation() {
        Configuration config = activity.getResources().getConfiguration();

        int rotation;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            rotation = Objects.requireNonNull(activity.getDisplay()).getRotation();
        } else {
            rotation = getRotationOld();
        }

        if (((rotation == Surface.ROTATION_0 || rotation == Surface.ROTATION_180) &&
                config.orientation == Configuration.ORIENTATION_LANDSCAPE)
                || ((rotation == Surface.ROTATION_90 || rotation == Surface.ROTATION_270) &&
                config.orientation == Configuration.ORIENTATION_PORTRAIT)) {
//            Log.i("NDOP", "LANDSCAPE");
            return Configuration.ORIENTATION_LANDSCAPE;
        } else {
//            Log.i("NDOP", "PORTRAIT");
            return Configuration.ORIENTATION_PORTRAIT;
        }
    }

    @TargetApi(Build.VERSION_CODES.N)
    @SuppressWarnings("deprecation")
    int getRotationOld() {
        WindowManager windowManager = (WindowManager) activity.getSystemService(Context.WINDOW_SERVICE);
        return windowManager.getDefaultDisplay().getRotation();
    }
}
