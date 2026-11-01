"""Stream diagnostic directories/ZIPs into bounded memory observation tables.

Only performance and memory.* runtime records are retained. Player trace files
are skipped; snapshots are observations, not allocator events or exact causes.
"""
import argparse
import csv
import io
import json
from pathlib import Path
import zipfile


def records(source):
    def wanted(name):
        base = Path(name).name
        return ("runtime.jsonl" in base or "performance.jsonl" in base)

    def lines(stream):
        for line in stream:
            try:
                value = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if isinstance(value, dict):
                yield value

    if source.is_dir():
        for file in source.rglob("*jsonl*"):
            if file.is_file() and wanted(file.name):
                with file.open(encoding="utf-8-sig", errors="replace") as stream:
                    yield from lines(stream)
    else:
        with zipfile.ZipFile(source) as archive:
            for name in archive.namelist():
                if wanted(name):
                    with archive.open(name) as raw:
                        yield from lines(io.TextIOWrapper(raw, encoding="utf-8-sig", errors="replace"))


def write_csv(path, rows, fields):
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def analyze(source, output):
    samples, memory, batches = {}, {}, {}
    for record in records(source):
        run = record.get("runId")
        session = record.get("session")
        if record.get("type") == "sample":
            key = (run, session, record.get("sequence"), record.get("processId"))
            process = record.get("process", {})
            native = record.get("nativeMemory", {})
            regions = record.get("memory", {})
            samples[key] = {
                "time": record.get("time"), "runId": run, "session": session,
                "processId": record.get("processId"), "route": record.get("route"),
                "rssBytes": process.get("rssBytes"), "privateBytes": process.get("privateBytes"),
                "privateWorkingSetBytes": process.get("privateWorkingSetBytes"),
                "sharedCommitBytes": process.get("sharedCommitBytes"),
                "memorySampleId": regions.get("sampleId"), "memoryStatus": regions.get("status"),
                "memoryCacheAgeMs": regions.get("cacheAgeMs"),
                "privateWriteCombineBytes": regions.get("totals", {}).get("privateWriteCombineBytes"),
                "privateReadWriteBytes": regions.get("totals", {}).get("privateReadWriteBytes"),
                "videoOutputCount": native.get("resources", {}).get("videoOutput", {}).get("count"),
                "d3dTextureCount": native.get("resources", {}).get("d3dTexture", {}).get("count"),
                "d3dTextureEstimatedBytes": native.get("resources", {}).get("d3dTexture", {}).get("estimatedBytes"),
                "pendingTextureUnregistrations": native.get("pendingTextureUnregistrations"),
            }
        category = record.get("category", "")
        if not category.startswith("memory."):
            continue
        details = record.get("details", {})
        key = (run, session, record.get("processId"), details.get("sampleId"))
        context = {"runId": run, "session": session, "processId": record.get("processId"),
                   "sampleId": details.get("sampleId"), "time": record.get("time"),
                   "route": record.get("route")}
        if category == "memory.snapshot":
            memory[key] = {**context, **details}
        elif category in ("memory.regions.checkpoint", "memory.regions.diff"):
            batches.setdefault(key, {})[(category, details.get("offset"))] = (context, details)

    region_rows, snapshot_rows = [], []
    incomplete = 0
    orphan_batches = sum(key not in memory for key in batches)
    for key, snapshot in sorted(memory.items(), key=lambda item: item[1].get("time", "")):
        checkpoint = snapshot.get("checkpoint") is True
        expected = snapshot.get("trackedAllocationCount", 0) if checkpoint else (
            snapshot.get("createdCount", 0) + snapshot.get("changedCount", 0) + snapshot.get("releasedCount", 0)
            - snapshot.get("eventOverflow", 0))
        covered = set()
        expected_category = "memory.regions.checkpoint" if checkpoint else "memory.regions.diff"
        for (category, offset), (context, batch) in batches.get(key, {}).items():
            if category != expected_category:
                continue
            entries = batch.get("regions" if checkpoint else "changes", [])
            for index, item in enumerate(entries):
                if not isinstance(item, dict) or not isinstance(offset, int):
                    continue
                covered.add(offset + index)
                before = {} if checkpoint else item.get("before", {})
                after = item if checkpoint else item.get("after", {})
                region_rows.append({
                    **context, "kind": "checkpoint" if checkpoint else item.get("kind"),
                    "regionId": item.get("id"), "tickMs": batch.get("tickMs"),
                    "beforeCommittedBytes": before.get("committedBytes"),
                    "afterCommittedBytes": after.get("committedBytes"),
                    "beforeReservedBytes": before.get("reservedBytes"),
                    "afterReservedBytes": after.get("reservedBytes"),
                    "privateWriteCombineBytes": after.get("privateWriteCombineBytes"),
                    "typeFlags": after.get("typeFlags", before.get("typeFlags")),
                    "protectionFlags": after.get("protectionFlags", before.get("protectionFlags")),
                })
        missing = len(set(range(expected)) - covered)
        incomplete += missing != 0
        snapshot_rows.append({**{k: v for k, v in snapshot.items() if k != "totals"},
                              **snapshot.get("totals", {}), "missingLoggedEntries": missing})

    output.mkdir(parents=True, exist_ok=True)
    sample_rows = sorted(samples.values(), key=lambda row: row.get("time", ""))
    write_csv(output / "performance.csv", sample_rows, [
        "time", "runId", "session", "processId", "route", "rssBytes", "privateBytes",
        "privateWorkingSetBytes", "sharedCommitBytes",
        "memorySampleId", "memoryStatus", "memoryCacheAgeMs", "privateWriteCombineBytes",
        "privateReadWriteBytes", "videoOutputCount", "d3dTextureCount", "d3dTextureEstimatedBytes",
        "pendingTextureUnregistrations"])
    write_csv(output / "memory-snapshots.csv", snapshot_rows, [
        "time", "runId", "session", "processId", "sampleId", "route", "tickMs", "status", "complete",
        "scanDurationUs", "scanIntervalMs", "checkpoint", "skippedSnapshots", "eventOverflow",
        "omittedAllocationCount", "omittedAllocationBytes", "missingLoggedEntries",
        "privateCommittedBytes", "privateReadWriteBytes", "privateWriteCombineBytes", "mappedCommittedBytes",
        "imageCommittedBytes", "committedBytes", "reservedBytes"])
    write_csv(output / "region-changes.csv", region_rows, [
        "time", "runId", "session", "processId", "sampleId", "route", "tickMs", "kind", "regionId",
        "beforeCommittedBytes", "afterCommittedBytes", "beforeReservedBytes", "afterReservedBytes",
        "privateWriteCombineBytes", "typeFlags", "protectionFlags"])
    summary = {"performanceSamples": len(samples), "memorySnapshots": len(memory),
               "regionRows": len(region_rows), "snapshotsWithMissingLoggedEntries": incomplete,
               "orphanSnapshotBatches": orphan_batches,
               "notes": "IDs are scoped to run/process/session. Observed snapshot differences are not allocator events. Missing old-version fields remain blank. RSS/Private/GPU/nominal texture bytes overlap; do not add."}
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(analyze(args.source, args.output), ensure_ascii=False))
