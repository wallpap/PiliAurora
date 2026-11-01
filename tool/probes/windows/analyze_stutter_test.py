import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("stutter", Path(__file__).with_name("analyze_stutter.py"))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class StutterAnalysisTest(unittest.TestCase):
    def test_frame_start_and_half_open_stage_boundaries(self):
        report = {"state": "completed", "validWorkload": True,
                  "stages": [{"name": "a", "startUtcUs": 100, "endUtcUs": 200},
                             {"name": "b", "startUtcUs": 200, "endUtcUs": 300}],
                  "timerGaps": [], "frames": [
                      {"startUtcUs": 199, "buildMs": 40, "rasterMs": 1, "totalMs": 60},
                      {"startUtcUs": 200, "buildMs": 2, "rasterMs": 1, "totalMs": 70}]}
        rows = analysis.summarize(report)["stages"]
        self.assertEqual([r["frames"] for r in rows], [1, 1])
        self.assertEqual([r["over33ms"] for r in rows], [1, 0])
        self.assertEqual(rows[1]["totalMs"]["max"], 70)

    def test_qpc_alignment_and_missing_display_measurements(self):
        report = {"stages": [{"name": "a", "startUtcUs": 1_000_000, "endUtcUs": 2_000_000}]}
        rows = [{"TimeInQPC": "15000", "MsBetweenPresents": "18", "MsUntilDisplayed": "NA"}]
        result = analysis.present_stages(
            report, rows, {"utcNs": 1_000_000_000, "qpcNs": 1_000_000_000}, 10000)[0]
        self.assertEqual(result["presents"], 1)
        self.assertEqual(result["submissionGapsOver12ms"], 1)
        self.assertEqual(result["displayLatencyMs"]["count"], 0)
        self.assertIsNone(result["displayLatencyMs"]["max"])


if __name__ == "__main__":
    unittest.main()
