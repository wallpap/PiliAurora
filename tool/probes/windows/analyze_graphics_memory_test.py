import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("graphics_analysis", Path(__file__).with_name("analyze_graphics_memory.py"))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class GraphicsAnalysisTest(unittest.TestCase):
    def test_time_match_rejects_other_pid_and_out_of_run(self):
        pages = [{"time": "2026-11-01T00:00:01Z", "pid": 5},
                 {"time": "2026-11-01T00:00:02Z", "pid": 6}]
        now = analysis.timestamp("2026-11-01T00:00:02Z")
        page, offset = analysis.nearest_page(pages, now, 5, now - 5, now + 5)
        self.assertEqual(page["pid"], 5)
        self.assertEqual(offset, -1)
        self.assertEqual(analysis.nearest_page(pages, now, 5, now, now + 5), (None, None))

    def test_backing_dedup_preserves_types_and_reports_truncation_and_legacy(self):
        contexts = {"raster": {"resources": [
            {"backingType": "gl_texture", "backingId": "7", "bytes": 100},
            {"backingType": "gl_buffer", "backingId": "7", "bytes": 10}],
            "omittedEntries": 2, "candidateLimitReached": True},
            "io": {"resources": [{"backingType": "gl_texture", "backingId": "7", "bytes": 120}],
                   "omittedEntries": 0}}
        result = analysis.deduplicate_candidates(contexts)
        self.assertEqual(result["candidateBytes"], 130)
        self.assertEqual(result["candidateCount"], 2)
        self.assertEqual(result["coverage"]["raster"]["coverage"], "boundedOrIncomplete")
        legacy = analysis.context_columns({"schemaVersion": 1, "contexts": {
            "io": {"resourceBytes": 42}}}, "io")
        self.assertEqual(legacy["ioBudgetedBytes"], 42)
        self.assertEqual(legacy["ioResourceBytesSemantics"], "legacySchema1BudgetedOnly")


if __name__ == "__main__":
    unittest.main()
