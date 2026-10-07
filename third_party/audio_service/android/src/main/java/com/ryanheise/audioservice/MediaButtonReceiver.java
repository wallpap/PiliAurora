package com.ryanheise.audioservice;

import static com.ryanheise.audioservice.AudioService.NOTIFICATION_CUSTOM_ACTION;
import static com.ryanheise.audioservice.AudioService.NOTIFICATION_CUSTOM_ACTION_NAME;

import android.content.Context;
import android.content.Intent;

@SuppressWarnings("deprecation")
public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
    public static final String ACTION_NOTIFICATION_DELETE = "com.ryanheise.audioservice.intent.action.ACTION_NOTIFICATION_DELETE";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        if (AudioService.instance != null) {
            if (ACTION_NOTIFICATION_DELETE.equals(intent.getAction())) {
                AudioService.instance.handleDeleteNotification();
                return;
            } else if (NOTIFICATION_CUSTOM_ACTION.equals(intent.getAction())) {
                String customAction = intent.getStringExtra(NOTIFICATION_CUSTOM_ACTION_NAME);
                if (customAction != null) {
                    AudioService.onCustomAction(customAction);
                }
                return;
            }
        }

        super.onReceive(context, intent);
    }
}
