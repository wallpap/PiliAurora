"""只连接明确指定、PID匹配的本地测试VM；认证URI不写入输出。"""

import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse
import urllib.request


def service_uri(text):
    match = re.search(r"(?:http|ws)://[^\s\"<>]+", text.strip())
    if not match:
        raise ValueError("VM service URI missing")
    parsed = urllib.parse.urlsplit(match.group(0))
    if parsed.hostname not in ("127.0.0.1", "localhost", "::1") or parsed.username or parsed.password:
        raise ValueError("Only explicit loopback VM service allowed")
    path = parsed.path.removesuffix("/ws").rstrip("/") + "/"
    return urllib.parse.urlunsplit(("http", parsed.netloc, path, "", ""))


def allocation_rows(profile):
    if profile.get("type") != "AllocationProfile":
        raise ValueError("AllocationProfile unavailable")
    rows = []
    for member in profile.get("members", []):
        cls = member.get("class", {})
        rows.append({"class": cls.get("name", "<unnamed>"), "classId": cls.get("id"),
                     "instancesCurrent": member.get("instancesCurrent"),
                     "bytesCurrent": member.get("bytesCurrent"),
                     "instancesAccumulated": member.get("instancesAccumulated"),
                     "accumulatedSize": member.get("accumulatedSize")})
    return sorted(rows, key=lambda row: row["bytesCurrent"] or 0, reverse=True)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("VM service redirect rejected")


def rpc(base, method, **params):
    query = urllib.parse.urlencode({key: str(value).lower() if isinstance(value, bool)
                                   else value for key, value in params.items()})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    with opener.open(base + method + ("?" + query if query else ""), timeout=60) as response:
        payload = json.load(response)
    if "error" in payload:
        # 消息/URL可能包含认证内容；只输出协议错误码。
        raise RuntimeError("VM RPC error code " + str(payload["error"].get("code")))
    result = payload.get("result", payload)
    if result.get("type") == "Sentinel":
        raise RuntimeError("VM isolate unavailable")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--uri")
    source.add_argument("--uri-file", type=Path)
    parser.add_argument("--pid", type=int, required=True, help="独立测试实例的预期PID，必须匹配")
    parser.add_argument("--isolate-id", help="默认选择名为main的唯一isolate")
    parser.add_argument("--output", type=Path, required=True, help="必须为新目录")
    parser.add_argument("--heap-snapshot", action="store_true", help="用项目现有vm_service/Dart收二进制事件")
    parser.add_argument("--dart", type=Path, help="Dart SDK二进制路径；Windows建议显式dart.exe避免.bat启动")
    parser.add_argument("--top", type=int, default=30)
    args = parser.parse_args()
    base = service_uri(args.uri if args.uri else args.uri_file.read_text(encoding="utf-8-sig"))
    vm = rpc(base, "getVM")
    if vm.get("pid") != args.pid:
        raise ValueError("VM PID does not match requested test process")
    isolates = [isolate for isolate in vm.get("isolates", []) if
                isolate.get("id") == args.isolate_id] if args.isolate_id else [
                isolate for isolate in vm.get("isolates", []) if isolate.get("name") == "main"]
    if len(isolates) != 1:
        raise ValueError("Specify isolate-id; main isolate is not unique or absent")
    isolate = rpc(base, "getIsolate", isolateId=isolates[0]["id"])
    profile = rpc(base, "getAllocationProfile", isolateId=isolate["id"], gc=True)
    rows = allocation_rows(profile)
    args.output.mkdir(parents=True, exist_ok=False)
    summary = {"time": datetime.now(timezone.utc).isoformat(), "pid": args.pid,
               "isolate": {"id": isolate["id"], "name": isolate.get("name")},
               "vmVersion": vm.get("version"), "gcRequested": True, "gcGuaranteed": False,
               "memoryUsage": profile.get("memoryUsage"),
               "totalClassBytes": sum(row["bytesCurrent"] or 0 for row in rows),
               "classes": rows,
               "heapSnapshot": {"status": "notRequested", "requires": "WebSocket binary events"}}
    if args.heap_snapshot:
        root = Path(__file__).resolve().parents[3]
        try:
            command = [str(args.dart.resolve())] if args.dart else ["fvm", "dart"]
            result = subprocess.run([*command, "--packages=.dart_tool/package_config.json",
                                     str(Path(__file__).with_name("capture_vm_heap.dart").resolve())],
                                    input=json.dumps({"uri": base, "pid": args.pid,
                                        "isolateId": isolate["id"],
                                        "output": str((args.output / "heap.heapsnapshot").resolve())}),
                                    text=True, capture_output=True, cwd=root, timeout=180)
            summary["heapSnapshot"] = json.loads(result.stdout.strip())
        except ValueError:
            summary["heapSnapshot"] = {"status": "failed", "returnCode": result.returncode}
        except (OSError, subprocess.TimeoutExpired) as error:
            summary["heapSnapshot"] = {"status": "failed", "errorType": type(error).__name__}
    (args.output / "allocation.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    fields = list(rows[0]) if rows else ["class", "instancesCurrent", "bytesCurrent"]
    with (args.output / "classes.csv").open("w", encoding="utf-8-sig", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    # stdout只展示类名/计数/大小，不展示认证URI、对象值或原始服务响应。
    for row in rows[:max(0, args.top)]:
        print(json.dumps({key: row[key] for key in ("class", "instancesCurrent", "bytesCurrent")}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # 禁止默认traceback泄露含认证token的HTTP URL。
        print(json.dumps({"status": "failed", "errorType": type(error).__name__}), file=sys.stderr)
        sys.exit(1)
