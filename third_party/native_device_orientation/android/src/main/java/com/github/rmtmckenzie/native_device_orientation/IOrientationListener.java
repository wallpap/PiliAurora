package com.github.rmtmckenzie.native_device_orientation;

public interface IOrientationListener {

    void startOrientationListener();

    void stopOrientationListener();

    interface OrientationCallback {
        void receive(NativeOrientation orientation);
    }
}
