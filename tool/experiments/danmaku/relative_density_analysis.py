"""汇总各权重的实际显示分布；只处理聚合JSON，不读取弹幕正文。"""

import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path


def summarize(root: Path) -> dict:
    experiments = {}
    flat = []
    for report in sorted(root.glob("*/report.json")):
        rows = json.loads(report.read_text(encoding="utf-8-sig"))
        if not isinstance(rows, list):
            continue
        experiments[report.parent.name] = rows
        for row in rows:
            for weight, profile in row["weightProfile"].items():
                flat.append({
                    "experiment": report.parent.name,
                    **{key: row.get(key) for key in (
                        "name", "merge", "fps", "startMs", "cap", "perFrame"
                    )},
                    "weight": int(weight),
                    **profile,
                    "incompleteFrames": row["incompleteFrames"],
                    "bucketTopNMissingRate": row["bucketTopNMissingRate"],
                })

    # 三个不重叠真实范围；同输入、同合并配置共享分母，逐权重累计。
    aggregate = defaultdict(lambda: defaultdict(float))
    windows = defaultdict(set)
    for name, rows in experiments.items():
        if name not in {"matrix", "merged"} and not name.startswith("window"):
            continue
        for row in rows:
            if not row["name"].startswith("real") or row["perFrame"] != 8:
                continue
            key = (row["name"], row["merge"], row["cap"])
            windows[key].add(row["startMs"])
            values = aggregate[key]
            values["displayed"] += row["displayed"]
            values["missingSlots"] += row["bucketTopNMissingSlots"]
            for weight, profile in row["weightProfile"].items():
                for field in ("input", "visible", "halfVisible", "visibleAreaItemSeconds"):
                    values[f"{weight}:{field}"] += profile[field]

    aggregates = []
    for key, values in sorted(aggregate.items()):
        name, merge, cap = key
        weights = sorted({int(k.split(":")[0]) for k in values if ":" in k}, reverse=True)
        aggregates.append({
            "name": name, "merge": merge, "cap": cap,
            "windows": sorted(windows[key]),
            "displayed": int(values["displayed"]),
            "bucketTopNMissingRate": values["missingSlots"] / values["displayed"],
            "weights": {
                str(w): {
                    "input": int(values[f"{w}:input"]),
                    "visible": int(values[f"{w}:visible"]),
                    "visibleRate": values[f"{w}:visible"] / values[f"{w}:input"],
                    "halfVisible": int(values[f"{w}:halfVisible"]),
                    "visibleAreaItemSeconds": values[f"{w}:visibleAreaItemSeconds"],
                } for w in weights
            },
        })

    with (root / "weights.csv").open("w", encoding="utf-8-sig", newline="") as file:
        if flat:
            writer = csv.DictWriter(file, fieldnames=flat[0].keys())
            writer.writeheader()
            writer.writerows(flat)

    output = {"experiments": len(experiments), "cases": sum(map(len, experiments.values())),
              "aggregates": aggregates}
    (root / "summary.json").write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = ["# 相对权重实验汇总", "", "按已运行的不重叠真实范围逐权重累计；8/12/16条有三个范围，其余仅首个范围，不能直接比较累计总量。", "",
             "|素材|合并|桶上限|范围数|总可见|逐权重可见／输入（降序）|桶内理想Top-N缺项率|",
             "|---|---|---:|---:|---:|---|---:|"]
    for row in aggregates:
        profile = "；".join(f"{w}: {v['visible']}/{v['input']}" for w, v in row["weights"].items())
        lines.append(f"|{row['name']}|{row['merge']}|{row['cap']}|{len(row['windows'])}|{row['displayed']}|{profile}|{row['bucketTopNMissingRate']:.1%}|")
    lines += ["", "缺项率以同桶可见条数N对应的理想最高N项作上界。不同字宽、模式及已建立轨迹会使该上界无法达到；它不是排序错误率。",
              "完整显示率、可见面积时长、入场延迟和包围盒拥挤近似量见 weights.csv。不同输入的权重数值不直接汇总为一个平均分。", ""]
    (root / "summary.md").write_text("\n".join(lines), encoding="utf-8")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    result = summarize(args.root)
    print(f"{result['experiments']} experiment groups, {result['cases']} cases")
