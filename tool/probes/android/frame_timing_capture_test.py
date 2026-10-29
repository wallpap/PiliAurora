import json
import shlex
import unittest
from unittest.mock import patch

from frame_timing_capture import Device, WindowRows, capture, choose_layer, parse_gfxinfo, parse_latency


class FrameTimingCaptureTest(unittest.TestCase):
    def test_latency_rejects_text_and_incomplete_fences(self):
        period, rows = parse_latency(
            "secret=do-not-export\n8333333\n10 20 15\n0 0 0\n"
            "10 9223372036854775807 15\n10 private 20\n"
        )
        self.assertEqual(period, 8333333)
        self.assertEqual(rows, [(10, 20, 15)])

    def test_gfxinfo_uses_header_order_and_numeric_rows(self):
        rows = parse_gfxinfo(
            "Window: private\nVsync,FrameCompleted,Flags,IntendedVsync,Extra,\n"
            "21,30,0,20,8,\n41,0,0,40,8,\nsecret,30,0,20,8,\n"
        )
        self.assertEqual(rows, [(0, 20, 21, 30)])

    def test_window_excludes_baseline_and_duplicates_and_bounds_memory(self):
        window = WindowRows([(1, 2, 3)], limit=1)
        window.add([(1, 2, 3), (4, 5, 6), (4, 5, 6), (7, 8, 9)])
        self.assertEqual(window.rows, [(4, 5, 6)])
        self.assertEqual(len(window.seen), 2)
        self.assertTrue(window.truncated)

    def test_layer_ambiguity_requires_explicit_selection(self):
        first = "SurfaceView[io.example.app/Main]#1"
        second = "SurfaceView[io.example.app/Main]#2"
        self.assertEqual(choose_layer(first, "io.example.app", None), first)
        with self.assertRaises(ValueError):
            choose_layer(first + "\n" + second, "io.example.app", None)
        with self.assertRaises(ValueError):
            choose_layer("other.private.layer", "io.example.app", "other.private.layer")

    def test_requested_layer_state_selects_blast_buffer_layer(self):
        buffer = "abc SurfaceView[io.example.app/Main](BLAST)#42"
        listing = (
            "RequestedLayerState{Background for abc SurfaceView[io.example.app/Main]#43 parentId=41 z=-1}\n"
            f"RequestedLayerState{{{buffer} parentId=41}}\n"
            "RequestedLayerState{abc SurfaceView[io.example.app/Main]#41 parentId=40 relativeParentId=39 z=-2}"
        )
        self.assertEqual(choose_layer(listing, "io.example.app", None), buffer)
        self.assertEqual(choose_layer(listing, "io.example.app", buffer), buffer)
        self.assertEqual(
            choose_layer(listing, "io.example.app", f"RequestedLayerState{{{buffer} parentId=41}}"),
            buffer,
        )

    def test_multiple_blast_layers_still_require_selection(self):
        first = "SurfaceView[io.example.app/First](BLAST)#1"
        second = "SurfaceView[io.example.app/Second](BLAST)#2"
        with self.assertRaises(ValueError):
            choose_layer(first + "\n" + second, "io.example.app", None)

    def test_retired_blast_layer_does_not_hide_active_layer(self):
        active = "abc SurfaceView[io.example.app/Main](BLAST)#52"
        retired = "abc SurfaceView[io.example.app/Main](BLAST)#42"
        listing = (
            f"RequestedLayerState{{{retired} parentId=41 !handle}}\n"
            f"RequestedLayerState{{{active} parentId=51}}"
        )
        self.assertEqual(choose_layer(listing, "io.example.app", None), active)

    def test_retired_blast_layer_is_not_selected_automatically(self):
        listing = "RequestedLayerState{abc SurfaceView[io.example.app/Main](BLAST)#42 parentId=41 !handle}"
        with self.assertRaises(ValueError):
            choose_layer(listing, "io.example.app", None)

    @patch("frame_timing_capture.subprocess.run")
    def test_device_shell_quotes_layer_and_does_not_emit_raw_error(self, run):
        layer = "SurfaceView[io.example.app/Main]#1;$(private)"
        device = Device("adb", "private-serial")
        device.read("dumpsys", "SurfaceFlinger", "--latency", layer)
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["adb", "-s", "private-serial", "shell"])
        self.assertEqual(shlex.split(command[4]), ["dumpsys", "SurfaceFlinger", "--latency", layer])
        run.side_effect = OSError("private-serial")
        with self.assertRaisesRegex(RuntimeError, "adb 读取失败") as error:
            device.read("dumpsys", "SurfaceFlinger", "--list")
        self.assertNotIn("private", str(error.exception))

    def test_capture_reads_without_reset_and_exports_new_numeric_rows(self):
        class FakeDevice:
            commands = []
            samples = iter([
                "8333333\n10 20 15", "Flags,IntendedVsync,Vsync,FrameCompleted\n0,10,11,20",
                "8333333\n10 20 15\n30 40 35", "Flags,IntendedVsync,Vsync,FrameCompleted\n0,10,11,20\n0,30,31,40\nsecret=private",
                "8333333\n30 40 35", "Flags,IntendedVsync,Vsync,FrameCompleted\n0,30,31,40",
            ])

            def read(self, *args):
                self.commands.append(args)
                return next(self.samples)

        now = [0.0]

        def sleep(seconds):
            now[0] += seconds

        device = FakeDevice()
        result = capture(device, "io.example.app", "private-layer", 1, clock=lambda: now[0], sleep=sleep)
        self.assertEqual(result["surfaceFlinger"]["rows"], [(30, 40, 35)])
        self.assertEqual(result["gfxinfo"]["rows"], [(0, 30, 31, 40)])
        self.assertNotIn("private", json.dumps(result))
        allowed = {
            ("dumpsys", "SurfaceFlinger", "--latency", "private-layer"),
            ("dumpsys", "gfxinfo", "io.example.app", "framestats"),
        }
        self.assertTrue(all(command in allowed for command in device.commands))


if __name__ == "__main__":
    unittest.main()
