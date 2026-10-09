/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;
import android.view.View;
import android.widget.FrameLayout;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Locale;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.android.FlutterView;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterJNI;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;


public class VideoOutput {
    public long id = 0;
    public long wid = 0;

    private Surface surface;
    private final TextureRegistry.SurfaceTextureEntry surfaceTextureEntry;

    private boolean flutterJNIAPIAvailable;
    private final Method newGlobalObjectRef;
    private final Method deleteGlobalObjectRef;
    private boolean waitUntilFirstFrameRenderedNotify;

    private long handle;
    private MethodChannel channelReference;
    private TextureRegistry textureRegistryReference;

    private final Object lock = new Object();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private long surfaceGeneration;
    private int bufferWidth;
    private int bufferHeight;
    private long lastConsumedTimestamp;
    private boolean disposed;
    private SurfaceFrameFence frameFence;
    private MethodChannel.Result frameResult;

    VideoOutput(long handle, MethodChannel channelReference, TextureRegistry textureRegistryReference) {
        this.handle = handle;
        this.channelReference = channelReference;
        this.textureRegistryReference = textureRegistryReference;
        try {
            flutterJNIAPIAvailable = false;
            waitUntilFirstFrameRenderedNotify = false;
            // com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper is part of package:media_kit_libs_android_video & package:media_kit_libs_android_audio packages.
            // Use reflection to invoke methods of com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.
            Class<?> mediaKitAndroidHelperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (Throwable e) {
            Log.i("media_kit", "package:media_kit_libs_android_video missing. Make sure you have added it to pubspec.yaml.");
            throw new RuntimeException("Failed to initialize com.alexmercerind.media_kit_video.VideoOutput.");
        }

        surfaceTextureEntry = textureRegistryReference.createSurfaceTexture();
        // This listener runs after Flutter's raster thread calls updateTexImage.
        // Frame-available alone does not mean that Flutter acquired that buffer.
        surfaceTextureEntry.setOnFrameConsumedListener(() -> {
            synchronized (lock) {
                if (disposed) return;
                final long timestamp;
                try {
                    timestamp = surfaceTextureEntry.surfaceTexture().getTimestamp();
                } catch (RuntimeException e) {
                    return;
                }
                lastConsumedTimestamp = timestamp;
                final SurfaceFrameFence fence = frameFence;
                if (fence != null && fence.accepts(
                        timestamp, bufferWidth, bufferHeight, surfaceGeneration)) {
                    mainHandler.post(() -> {
                        synchronized (lock) {
                            if (frameFence == fence && !disposed) finishFrameWait(true);
                        }
                    });
                }
            }
        });

        // If we call setOnFrameAvailableListener after creating SurfaceTextureEntry, the texture won't be displayed inside Flutter UI, because callback set by us will override the Flutter engine's own registered callback:
        // https://github.com/flutter/engine/blob/f47e864f2dcb9c299a3a3ed22300a1dcacbdf1fe/shell/platform/android/io/flutter/view/FlutterView.java#L942-L958
        try {
            if (!flutterJNIAPIAvailable) {
                flutterJNIAPIAvailable = getFlutterJNIReference() != null;
            }
        } catch (Throwable e) {
            e.printStackTrace();
        }
        Log.i("media_kit", String.format(Locale.ENGLISH, "flutterJNIAPIAvailable = %b", flutterJNIAPIAvailable));
        if (flutterJNIAPIAvailable) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                surfaceTextureEntry.surfaceTexture().setOnFrameAvailableListener((texture) -> {
                    synchronized (lock) {
                        try {
                            if (!waitUntilFirstFrameRenderedNotify) {
                                waitUntilFirstFrameRenderedNotify = true;
                                final HashMap<String, Object> data = new HashMap<>();
                                data.put("handle", handle);
                                channelReference.invokeMethod("VideoOutput.WaitUntilFirstFrameRenderedNotify", data);
                                Log.i("media_kit", String.format(Locale.ENGLISH, "VideoOutput.WaitUntilFirstFrameRenderedNotify = %d", handle));
                            }

                            FlutterJNI flutterJNI = null;
                            while (flutterJNI == null) {
                                flutterJNI = getFlutterJNIReference();
                                flutterJNI.markTextureFrameAvailable(id);
                            }
                        } catch (Throwable e) {
                            e.printStackTrace();
                        }
                    }
                }, new Handler());
            } else {
                surfaceTextureEntry.surfaceTexture().setOnFrameAvailableListener((texture) -> {
                    synchronized (lock) {
                        try {
                            if (!waitUntilFirstFrameRenderedNotify) {
                                waitUntilFirstFrameRenderedNotify = true;
                                final HashMap<String, Object> data = new HashMap<>();
                                data.put("handle", handle);
                                channelReference.invokeMethod("VideoOutput.WaitUntilFirstFrameRenderedNotify", data);
                                Log.i("media_kit", String.format(Locale.ENGLISH, "VideoOutput.WaitUntilFirstFrameRenderedNotify = %d", handle));
                            }

                            FlutterJNI flutterJNI = null;
                            while (flutterJNI == null) {
                                flutterJNI = getFlutterJNIReference();
                                flutterJNI.markTextureFrameAvailable(id);
                            }
                        } catch (Throwable e) {
                            e.printStackTrace();
                        }
                    }
                });
            }
        } else {
            if (!waitUntilFirstFrameRenderedNotify) {
                waitUntilFirstFrameRenderedNotify = true;
                final HashMap<String, Object> data = new HashMap<>();
                data.put("id", id);
                data.put("wid", wid);
                data.put("handle", handle);
                channelReference.invokeMethod("VideoOutput.WaitUntilFirstFrameRenderedNotify", data);
            }
        }

        try {
            id = surfaceTextureEntry.id();
            Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutput: id = %d", id));
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    public void dispose() {
        synchronized (lock) {
            disposed = true;
            surfaceGeneration++;
            finishFrameWait(false);
        }
        try {
            surfaceTextureEntry.release();
        } catch (Throwable e) {
            e.printStackTrace();
        }
        try {
            surface.release();
        } catch (Throwable e) {
            e.printStackTrace();
        }
        try {
            final Handler handler = new Handler(Looper.getMainLooper());
            handler.postDelayed(() -> {
                try {
                    // Invoke DeleteGlobalRef after a voluntary delay to eliminate possibility of libmpv referencing it sometime in the near future.
                    deleteGlobalObjectRef.invoke(null, wid);
                    Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.deleteGlobalObjectRef: %d", wid));
                } catch (Throwable e) {
                    e.printStackTrace();
                }
            }, 5000);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    public long createSurface() {
        synchronized (lock) {
            surfaceGeneration++;
            lastConsumedTimestamp = 0;
            finishFrameWait(false);
            // Delete previous android.view.Surface & object reference.
            try {
                if (surface != null) {
                    clearSurface();
                    surface.release();
                    surface = null;
                }
                if (wid != 0) {
                    deleteGlobalObjectRef.invoke(null, wid);
                    wid = 0;
                }
            } catch (Throwable e) {
                e.printStackTrace();
            }
            // Create new android.view.Surface & object reference.
            try {
                surface = new Surface(surfaceTextureEntry.surfaceTexture());
                wid = (long) newGlobalObjectRef.invoke(null, surface);
            } catch (Throwable e) {
                e.printStackTrace();
            }
            return wid;
        }
    }

    public void setSurfaceTextureSize(int width, int height) {
        synchronized (lock) {
            if (disposed || width <= 0 || height <= 0) {
                throw new IllegalStateException("Invalid or disposed video surface");
            }
            finishFrameWait(false);
            surfaceTextureEntry.surfaceTexture().setDefaultBufferSize(width, height);
            bufferWidth = width;
            bufferHeight = height;
        }
    }

    public boolean canWaitForSurfaceFrame() {
        synchronized (lock) {
            return !disposed && SurfaceFrameFence.hasAutomaticEglClock(
                    lastConsumedTimestamp, System.nanoTime());
        }
    }

    public void waitForSurfaceFrame(String request, int width, int height,
                                    MethodChannel.Result result) {
        synchronized (lock) {
            if (disposed || bufferWidth != width || bufferHeight != height) {
                result.error("surface-invalidated", "Video surface changed before frame wait", null);
                return;
            }
            finishFrameWait(false);
            // Dart calls this only after synchronous mpv EXTERNAL_RESIZE has
            // returned. Queued pre-configure EGL frames have older timestamps.
            frameFence = new SurfaceFrameFence(
                    request, width, height, surfaceGeneration, System.nanoTime());
            frameResult = result;
        }
    }

    public void cancelSurfaceFrameWait(String request) {
        synchronized (lock) {
            if (frameFence != null && frameFence.request.equals(request)) finishFrameWait(false);
        }
    }

    private void finishFrameWait(boolean consumed) {
        final MethodChannel.Result result = frameResult;
        frameResult = null;
        frameFence = null;
        if (result != null) result.success(consumed);
    }

    private void clearSurface() {
        try {
            final Canvas canvas = surface.lockCanvas(null);
            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR);
            surface.unlockCanvasAndPost(canvas);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    private FlutterJNI getFlutterJNIReference() {
        try {
            FlutterView view = null;
            // io.flutter.embedding.android.FlutterActivity
            if (view == null) {
                view = MediaKitVideoPlugin.activity.findViewById(FlutterActivity.FLUTTER_VIEW_ID);
            }
            // io.flutter.embedding.android.FlutterFragmentActivity
            if (view == null) {
                final FrameLayout layout = (FrameLayout) MediaKitVideoPlugin.activity.findViewById(FlutterFragmentActivity.FRAGMENT_CONTAINER_ID);
                for (int i = 0; i < layout.getChildCount(); i++) {
                    final View child = layout.getChildAt(i);
                    if (child instanceof FlutterView) {
                        view = (FlutterView) child;
                        break;
                    }
                }
            }
            final FlutterEngine engine = view.getAttachedFlutterEngine();
            final Field field = engine.getClass().getDeclaredField("flutterJNI");
            field.setAccessible(true);
            return (FlutterJNI) field.get(engine);
        } catch (Throwable e) {
            e.printStackTrace();
            return null;
        }
    }
}
