package com.alexmercerind.media_kit_video;

/** Host-JVM regression for the frame receipt predicate (not GPU pixels). */
public final class SurfaceFrameFenceProbe {
    public static void main(String[] args) {
        final SurfaceFrameFence fence = new SurfaceFrameFence("7", 1156, 650, 2, 10_000);
        check(!fence.accepts(9_999, 1156, 650, 2), "queued old frame");
        check(!fence.accepts(10_000, 1156, 650, 2), "boundary frame");
        check(!fence.accepts(10_001, 1920, 1080, 2), "other dimensions");
        check(!fence.accepts(10_001, 1156, 650, 3), "new surface generation");
        check(fence.accepts(10_001, 1156, 650, 2), "new acquired EGL frame");
        check(!SurfaceFrameFence.hasAutomaticEglClock(0, 10_000), "missing clock");
        check(!SurfaceFrameFence.hasAutomaticEglClock(10_001, 10_000), "future presentation time");
        check(!SurfaceFrameFence.hasAutomaticEglClock(1, 6_000_000_001L), "unrelated PTS clock");
        check(SurfaceFrameFence.hasAutomaticEglClock(9_999, 10_000), "automatic EGL clock");
        System.out.println("PASS: 9 production frame-fence predicates (not a pixel verdict)");
    }
    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
}
