package com.alexmercerind.media_kit_video;

/** A post-configure EGL frame fence, independent of Flutter and Android UI. */
final class SurfaceFrameFence {
    final String request;
    final int width;
    final int height;
    final long generation;
    final long notBefore;

    SurfaceFrameFence(String request, int width, int height, long generation, long notBefore) {
        this.request = request;
        this.width = width;
        this.height = height;
        this.generation = generation;
        this.notBefore = notBefore;
    }

    boolean accepts(long consumedTimestamp, int width, int height, long generation) {
        return consumedTimestamp > notBefore
                && this.width == width
                && this.height == height
                && this.generation == generation;
    }

    // mpv's Android/EGL output does not set presentation-time explicitly. Its
    // BufferQueue auto timestamps are in CLOCK_MONOTONIC, as is System.nanoTime.
    // Refuse clocks such as media PTS or future presentation times instead of
    // mistaking an old queued buffer for a post-resize frame.
    static boolean hasAutomaticEglClock(long timestamp, long now) {
        return timestamp > 0 && timestamp <= now && now - timestamp < 5_000_000_000L;
    }
}
