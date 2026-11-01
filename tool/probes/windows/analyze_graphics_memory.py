"""离线对齐图形探针与同目录 pages.jsonl；候选资源字节不是GPU总量。"""

import argparse
import csv
from datetime import datetime
import json
from pathlib import Path
import sys


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def stage_items(report):
    stages = report.get("stages", {})
    return list(stages.items()) if isinstance(stages, dict) else [
        (stage.get("stage", str(index)), stage) for index, stage in enumerate(stages)]


def nearest_page(pages, when, pid, start, end, tolerance=5):
    candidates = [(abs(timestamp(page["time"]) - when), page) for page in pages
                  if pid is not None and page.get("pid") == pid
                  and start <= timestamp(page["time"]) <= end]
    if not candidates:
        return None, None
    distance, page = min(candidates, key=lambda pair: pair[0])
    return (page, round(timestamp(page["time"]) - when, 3)) if distance <= tolerance else (None, None)


def deduplicate_candidates(contexts):
    candidates = {}
    coverage = {}
    for name in ("raster", "io"):
        context = contexts.get(name, {})
        entries = context.get("resources", [])
        coverage[name] = {
            "available": context.get("available", False), "listed": len(entries),
            "dumpEntryCount": context.get("dumpEntryCount"),
            "omittedEntries": context.get("omittedEntries"),
            "candidateLimitReached": context.get("candidateLimitReached"),
            "coverage": "boundedOrIncomplete" if context.get("omittedEntries", 0) > 0 or
                context.get("candidateLimitReached") else
                "reportedDumpCandidatesComplete" if "resources" in context and
                context.get("omittedEntries") == 0 else "unknown",
        }
        for index, entry in enumerate(entries):
            kind, backing = entry.get("backingType"), entry.get("backingId")
            shared = kind not in (None, "", "unknown") and backing not in (None, "", 0, "0")
            # 无backing/默认framebuffer不跨context误合并。
            key = (kind, str(backing)) if shared else (name, index)
            item = candidates.setdefault(key, {
                "backingType": kind, "backingId": backing, "bytes": 0,
                "contexts": [], "entries": 0, "crossContextIdentityKnown": shared,
            })
            item["bytes"] = max(item["bytes"], entry.get("bytes", 0))
            item["entries"] += 1
            if name not in item["contexts"]:
                item["contexts"].append(name)
    values = sorted(candidates.values(), key=lambda item: item["bytes"], reverse=True)
    return {"semantics": "nominalListedCandidatesOnly; maxPerBacking; notGpuTotalOrResidency",
            "candidateBytes": sum(item["bytes"] for item in values),
            "candidateCount": len(values), "coverage": coverage, "candidates": values}


def context_columns(native, name):
    context = native.get("contexts", {}).get(name, {})
    version = native.get("schemaVersion")
    # 旧schema1 getResourceCacheUsage实际返回budgeted，不能冒称所有resource总量。
    legacy = version == 1 and "budgetedBytes" not in context and "budgetedResourceBytes" not in context
    budgeted = context.get("budgetedBytes", context.get("budgetedResourceBytes"))
    if legacy:
        budgeted = context.get("resourceBytes")
    return {
        name + "Available": context.get("available"),
        name + "ReportedResourceBytes": context.get("resourceBytes"),
        name + "ResourceBytesSemantics": "legacySchema1BudgetedOnly" if legacy else
            "schema2AllDumpSubentriesNominalIncludesWrappedUnbudgeted" if version == 2 else
            context.get("resourceBytesSemantics", native.get("semantics", "unspecifiedNominal")),
        name + "BudgetedBytes": budgeted,
        name + "BudgetBytes": context.get("budgetBytes"),
        name + "PurgeableBytes": context.get("purgeableBytes"),
    }


def analyze(path):
    report = json.loads(path.read_text(encoding="utf-8-sig"))
    stages = stage_items(report)
    kind = "realBrowsing" if "visits" in report else "syntheticGraphics"
    pid = next((stage.get("diagnostics", {}).get("processId") for _, stage in stages
                if isinstance(stage.get("diagnostics"), dict) and stage["diagnostics"].get("processId")), None)
    if pid is None and path.with_name("process.id").exists():
        pid = int(path.with_name("process.id").read_text(encoding="utf-8-sig").strip())
    timed = [stage for _, stage in stages if stage.get("time")]
    start = min((timestamp(stage["time"]) - stage.get("elapsedMs", 0) / 1000 for stage in timed), default=0)
    end = max((timestamp(stage["time"]) for stage in timed), default=0) + 2
    pages_path = path.with_name("pages.jsonl")
    pages = [json.loads(line) for line in pages_path.read_text(encoding="utf-8-sig").splitlines()
             if line.strip()] if pages_path.exists() else []
    rows, details = [], []
    baseline_index = next((index for index, (name, _) in enumerate(stages) if name == "baselineSettingIdle"), None)
    for index, (name, stage) in enumerate(stages):
        diagnostics = stage.get("diagnostics") or {}
        process = stage.get("process", diagnostics.get("process", {}))
        handles = stage.get("flutterGraphics", diagnostics.get("graphicsHandles", {}))
        native = stage.get("native", diagnostics.get("graphicsMemory", {}))
        totals = diagnostics.get("memory", {}).get("totals", {})
        page, offset = nearest_page(pages, timestamp(stage["time"]), pid, start, end) if stage.get("time") else (None, None)
        phase = "synthetic" if kind == "syntheticGraphics" else "baselineTarget" if name == "baselineSettingIdle" else (
            "postBaselineControl" if baseline_index is not None and index > baseline_index else "browsingLoad")
        row = {"run": path.parent.name, "kind": kind, "stage": name, "phase": phase,
               "time": stage.get("time"), "action": stage.get("action"), "pid": pid,
               "privateBytes": process.get("privateBytes"), "rssBytes": process.get("rssBytes"),
               "writeCombineBytes": page.get("privateCommittedWriteCombineBytes") if page else totals.get("privateWriteCombineBytes"),
               "readWriteBytes": page.get("privateCommittedReadWriteBytes") if page else totals.get("privateReadWriteBytes"),
               "pageSource": "externalWatcher" if page else "diagnosticsCached" if totals else "unavailable",
               "pageMatchOffsetSeconds": offset,
               "diagnosticsPageCacheAgeMs": diagnostics.get("memory", {}).get("cacheAgeMs") if not page else None,
               "pageComplete": page.get("complete") if page else diagnostics.get("memory", {}).get("complete"),
               "pageErrorCode": page.get("errorCode") if page else diagnostics.get("memory", {}).get("errorCode"),
               "pagePrivateBytes": page.get("privateBytes") if page else None,
               "pageRssBytes": page.get("rssBytes") if page else None,
               "imageHandles": handles.get("image", {}).get("currentHandles"),
               "imageHandleEstimatedBytes": handles.get("image", {}).get("currentBytes"),
               "imageCacheBytes": diagnostics.get("images", {}).get("cacheBytes"),
               "nativeStatus": native.get("status"), "nativeSchemaVersion": native.get("schemaVersion"),
               **context_columns(native, "raster"), **context_columns(native, "io")}
        candidates = deduplicate_candidates(native.get("contexts", {}))
        row["listedDeduplicatedCandidateBytes"] = candidates["candidateBytes"] if any(
            context.get("available") for context in native.get("contexts", {}).values()) else None
        previous = rows[-1] if rows else None
        for field in ("privateBytes", "rssBytes", "writeCombineBytes", "readWriteBytes", "imageCacheBytes"):
            row[field + "DeltaPrevious"] = row[field] - previous[field] if previous and isinstance(
                row[field], (int, float)) and isinstance(previous[field], (int, float)) else None
        rows.append(row)
        details.append({"stage": name, "resources": candidates,
                        "receipt": stage.get("receipt", stage.get("purgeReceipt"))})
    baseline = next((row for row in rows if row["phase"] == "baselineTarget"), None)
    valid = report.get("validWorkload") is True if kind == "realBrowsing" else (
        report.get("passed") is True and report.get("checks", {}).get("ownImagesExplicitlyDisposed") is True)
    valid = valid and report.get("state", "completed") == "completed" and report.get("finalReport", True)
    limit = 500 << 20
    target = {"applicable": kind == "realBrowsing", "validWorkload": valid,
              "baselineSettingIdle": baseline, "limitBytes": limit,
              "passed": bool(kind == "realBrowsing" and valid and baseline and
                  all(isinstance(baseline[field], (int, float)) and baseline[field] < limit
                      for field in ("privateBytes", "rssBytes")))}
    return {"input": str(path.resolve()), "kind": kind, "probeSchemaVersion": report.get("schemaVersion"),
            "target": target, "rows": rows, "resourceDetails": details,
            "scope": "stage-local nominal sizes; page snapshots approximate in time; no cross-run backing dedup",
            "pageMatch": {"path": str(pages_path), "pid": pid, "maximumOffsetSeconds": 5},
            "postBaselineControls": [row for row in rows if row["phase"] == "postBaselineControl"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", nargs="+", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    runs = [analyze(path) for path in args.input]
    args.output.mkdir(parents=True, exist_ok=False)
    summary = {"schemaVersion": 1, "runs": runs,
               "warning": "baselineSettingIdle target and diagnostic interventions are separate; synthetic is not real-app success"}
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    rows = [row for run in runs for row in run["rows"]]
    fields = list(dict.fromkeys(key for row in rows for key in row))
    with (args.output / "stages.csv").open("w", newline="", encoding="utf-8-sig") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    # stdout同样是CSV，可重定向；详细候选只保存在JSON中。
    writer = csv.DictWriter(sys.stdout, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    print(json.dumps({"output": str(args.output.resolve()), "runs": [
        {"run": run["rows"][0]["run"] if run["rows"] else run["input"],
         "kind": run["kind"], "validWorkload": run["target"]["validWorkload"],
         "baselineTargetPassed": run["target"]["passed"]} for run in runs]},
        ensure_ascii=False), file=sys.stderr)


if __name__ == "__main__":
    main()
