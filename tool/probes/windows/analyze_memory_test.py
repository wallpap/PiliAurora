import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("memory_analysis", Path(__file__).with_name("analyze_memory.py"))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class MemoryAnalysisTest(unittest.TestCase):
    def test_zip_deduplication_missing_batches_and_old_version_fields(self):
        context = {"runId": "run", "session": "session", "processId": 42, "time": "2026-10-31T00:00:00Z"}
        snapshot = {**context, "category": "memory.snapshot", "details": {
            "sampleId": 1, "checkpoint": True, "trackedAllocationCount": 2,
            "eventOverflow": 0, "complete": True, "totals": {"privateCommittedBytes": 3145728},
        }}
        batch = {**context, "category": "memory.regions.checkpoint", "details": {
            "sampleId": 1, "offset": 0, "total": 2,
            "regions": [{"id": 1, "committedBytes": 1048576}],
        }}
        sample = {**context, "type": "sample", "sequence": 1, "process": {"privateBytes": 123}}
        text = "\n".join(map(json.dumps, [snapshot, batch, sample]))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "diagnostics.zip"
            with zipfile.ZipFile(archive, "w") as target:
                target.writestr("runtime.jsonl", text)
                target.writestr("window-1-runtime.jsonl", text)  # 转发副本。
                target.writestr("player.jsonl", "not parsed as memory data")
            summary = analysis.analyze(archive, root / "analysis")
            self.assertEqual(summary["performanceSamples"], 1)
            self.assertEqual(summary["memorySnapshots"], 1)
            self.assertEqual(summary["regionRows"], 1)
            self.assertEqual(summary["snapshotsWithMissingLoggedEntries"], 1)
            with (root / "analysis/performance.csv").open(encoding="utf-8-sig", newline="") as stream:
                row = next(csv.DictReader(stream))
            self.assertEqual(row["privateBytes"], "123")
            self.assertEqual(row["videoOutputCount"], "")
            self.assertEqual(row["privateWriteCombineBytes"], "")

    def test_diff_entries_keep_explicit_release_and_before_size(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = [
                {"category": "memory.snapshot", "details": {"sampleId": 2, "checkpoint": False,
                    "createdCount": 0, "changedCount": 0, "releasedCount": 1, "eventOverflow": 0}},
                {"category": "memory.regions.diff", "details": {"sampleId": 2, "offset": 0,
                    "total": 1, "changes": [{"kind": "released", "id": 7,
                    "before": {"committedBytes": 2097152}}]}},
            ]
            (root / "runtime.jsonl").write_text("\n".join(map(json.dumps, records)), encoding="utf-8")
            summary = analysis.analyze(root, root / "analysis")
            self.assertEqual(summary["snapshotsWithMissingLoggedEntries"], 0)
            with (root / "analysis/region-changes.csv").open(encoding="utf-8-sig", newline="") as stream:
                row = next(csv.DictReader(stream))
            self.assertEqual(row["kind"], "released")
            self.assertEqual(row["beforeCommittedBytes"], "2097152")
            self.assertEqual(row["afterCommittedBytes"], "")


if __name__ == "__main__":
    unittest.main()
