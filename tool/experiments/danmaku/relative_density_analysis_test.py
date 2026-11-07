"""检查没有可见弹幕时的聚合报告。"""

import json
from pathlib import Path
import tempfile
import unittest

from relative_density_analysis import summarize


class RelativeDensityAnalysisTest(unittest.TestCase):
    def test_zero_visible_items_preserve_weight_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "matrix"
            report.mkdir()
            (report / "report.json").write_text(json.dumps([{
                "name": "real1", "merge": False, "cap": 12, "perFrame": 8,
                "fps": 60, "startMs": 0, "displayed": 0,
                "incompleteFrames": 0, "bucketTopNMissingRate": 0,
                "bucketTopNMissingSlots": 0,
                "weightProfile": {"3": {
                    "input": 10, "visible": 0, "halfVisible": 0,
                    "visibleAreaItemSeconds": 0,
                }},
            }]), encoding="utf-8")
            row = summarize(root)["aggregates"][0]
            self.assertEqual(row["displayed"], 0)
            self.assertEqual(row["bucketTopNMissingRate"], 0)
            self.assertEqual(row["weights"]["3"]["input"], 10)
            self.assertEqual(row["weights"]["3"]["visibleRate"], 0)
            self.assertIn("0.0%", (root / "summary.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
