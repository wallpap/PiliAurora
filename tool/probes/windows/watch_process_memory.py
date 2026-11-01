"""只读 Windows x64 页分类采样；不读取/输出目标地址或内存内容。"""

import argparse
import ctypes as C
from ctypes import wintypes as W
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time


class MBI(C.Structure):
    _fields_ = [("BaseAddress", C.c_void_p), ("AllocationBase", C.c_void_p),
                ("AllocationProtect", W.DWORD), ("PartitionId", W.WORD),
                ("RegionSize", C.c_size_t), ("State", W.DWORD),
                ("Protect", W.DWORD), ("Type", W.DWORD)]


class PMC_EX(C.Structure):
    _fields_ = [("cb", W.DWORD), ("PageFaultCount", W.DWORD)] + [
        (name, C.c_size_t) for name in (
            "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
            "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
            "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage", "PrivateUsage")]


class SYSTEM_INFO(C.Structure):
    _fields_ = [("architecture", W.DWORD), ("pageSize", W.DWORD),
                ("minimum", C.c_void_p), ("maximum", C.c_void_p),
                ("processorMask", C.c_size_t), ("processors", W.DWORD),
                ("processorType", W.DWORD), ("allocationGranularity", W.DWORD),
                ("processorLevel", W.WORD), ("processorRevision", W.WORD)]


def api():
    if os.name != "nt" or C.sizeof(C.c_void_p) != 8:
        raise RuntimeError("Windows x64 Python required")
    assert C.sizeof(MBI) == 48 and MBI.PartitionId.offset == 20
    assert MBI.RegionSize.offset == 24 and C.sizeof(PMC_EX) == 80
    kernel = C.WinDLL("kernel32", use_last_error=True)
    declarations = {
        "OpenProcess": ([W.DWORD, W.BOOL, W.DWORD], W.HANDLE),
        "CloseHandle": ([W.HANDLE], W.BOOL),
        "GetExitCodeProcess": ([W.HANDLE, C.POINTER(W.DWORD)], W.BOOL),
        "GetSystemInfo": ([C.POINTER(SYSTEM_INFO)], None),
        "VirtualQueryEx": ([W.HANDLE, C.c_void_p, C.POINTER(MBI), C.c_size_t], C.c_size_t),
        "K32GetProcessMemoryInfo": ([W.HANDLE, C.POINTER(PMC_EX), W.DWORD], W.BOOL),
    }
    for name, (args, result) in declarations.items():
        function = getattr(kernel, name)
        function.argtypes, function.restype = args, result
    return kernel


class Watcher:
    def __init__(self, pid):
        self.kernel = api()
        # PROCESS_QUERY_INFORMATION only: no VM_READ/WRITE/OPERATION/debug rights.
        self.handle = self.kernel.OpenProcess(0x0400, False, pid)
        if not self.handle:
            raise C.WinError(C.get_last_error())
        self.pid = pid
        self.info = SYSTEM_INFO()
        self.kernel.GetSystemInfo(C.byref(self.info))

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None

    def alive(self):
        code = W.DWORD()
        if not self.kernel.GetExitCodeProcess(self.handle, C.byref(code)):
            raise C.WinError(C.get_last_error())
        return code.value == 259  # STILL_ACTIVE

    def sample(self):
        started = time.perf_counter()
        result = {"time": datetime.now(timezone.utc).isoformat(), "pid": self.pid,
                  "rssBytes": None, "privateBytes": None, "complete": False,
                  "errorCode": 0, "regionCount": 0,
                  "privateCommittedWriteCombineBytes": 0,
                  "privateCommittedReadWriteBytes": 0, "privateCommittedOtherBytes": 0,
                  "mappedCommittedBytes": 0, "imageCommittedBytes": 0,
                  "otherCommittedBytes": 0}
        counters = PMC_EX()
        counters.cb = C.sizeof(counters)
        if self.kernel.K32GetProcessMemoryInfo(self.handle, C.byref(counters), counters.cb):
            result.update(rssBytes=counters.WorkingSetSize, privateBytes=counters.PrivateUsage)
        else:
            result["memoryInfoErrorCode"] = C.get_last_error()
        cursor, maximum = 0, self.info.maximum
        while cursor <= maximum:
            region = MBI()
            size = self.kernel.VirtualQueryEx(self.handle, cursor, C.byref(region), C.sizeof(region))
            if not size:
                error = C.get_last_error()
                # 系统上界的最后一页可能不可查询；仅这里接受 INVALID_PARAMETER。
                if error == 87 and cursor >= maximum - self.info.pageSize + 1:
                    result["complete"] = True
                else:
                    result["errorCode"] = error
                break
            if size != C.sizeof(region):
                result["errorCode"] = 24  # ERROR_BAD_LENGTH
                break
            result["regionCount"] += 1
            next_cursor = (region.BaseAddress or 0) + region.RegionSize
            if next_cursor <= cursor:
                result["errorCode"] = 13  # ERROR_INVALID_DATA
                break
            if region.State == 0x1000:  # MEM_COMMIT
                if region.Type == 0x20000:  # MEM_PRIVATE: WC/RW/other互斥
                    if region.Protect & 0x400:
                        key = "privateCommittedWriteCombineBytes"
                    elif region.Protect & 0xff == 0x04:
                        key = "privateCommittedReadWriteBytes"
                    else:
                        key = "privateCommittedOtherBytes"
                elif region.Type == 0x40000:
                    key = "mappedCommittedBytes"
                elif region.Type == 0x1000000:
                    key = "imageCommittedBytes"
                else:
                    key = "otherCommittedBytes"
                result[key] += region.RegionSize
            if next_cursor > maximum:
                result["complete"] = True
                break
            cursor = next_cursor
        result["scanMs"] = round((time.perf_counter() - started) * 1000, 3)
        return result


def allocation_child():
    """仅self-test新建子进程会分配/释放自己的内存，采样器不写目标进程。"""
    kernel = api()
    kernel.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, W.DWORD, W.DWORD]
    kernel.VirtualAlloc.restype = C.c_void_p
    kernel.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, W.DWORD]
    kernel.VirtualFree.restype = W.BOOL
    pointers = []
    size = 32 << 20
    try:
        print("ready", flush=True)
        for command in sys.stdin:
            if command.strip() == "allocate":
                for protect in (0x04, 0x04 | 0x400):
                    pointer = kernel.VirtualAlloc(None, size, 0x3000, protect)
                    if not pointer:
                        raise C.WinError(C.get_last_error())
                    pointers.append(pointer)
                    C.memset(pointer, 0x5a, size)
                print("allocated", flush=True)
            elif command.strip() == "free":
                while pointers:
                    if not kernel.VirtualFree(pointers[-1], 0, 0x8000):
                        raise C.WinError(C.get_last_error())
                    pointers.pop()
                print("freed", flush=True)
            elif command.strip() == "quit":
                break
    finally:
        for pointer in pointers:
            kernel.VirtualFree(pointer, 0, 0x8000)


def self_test():
    child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--allocation-child"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                             creationflags=subprocess.CREATE_NO_WINDOW)
    watcher = None
    try:
        if child.stdout.readline().strip() != "ready":
            raise RuntimeError("child startup failed")
        watcher = Watcher(child.pid)
        samples = {"baseline": watcher.sample()}
        for command, response in (("allocate", "allocated"), ("free", "freed")):
            child.stdin.write(command + "\n")
            child.stdin.flush()
            if child.stdout.readline().strip() != response:
                raise RuntimeError("child allocation protocol failed")
            samples[response] = watcher.sample()
        checks = {"complete": all(s["complete"] for s in samples.values())}
        for kind in ("ReadWrite", "WriteCombine"):
            key = "privateCommitted" + kind + "Bytes"
            checks[kind + "Growth"] = samples["allocated"][key] - samples["baseline"][key] >= 28 << 20
            checks[kind + "Released"] = samples["allocated"][key] - samples["freed"][key] >= 28 << 20
        child.stdin.write("quit\n")
        child.stdin.flush()
        child.wait(timeout=10)
        checks["normalChildExit"] = child.returncode == 0
        print(json.dumps({"passed": all(checks.values()), "checks": checks, "samples": samples}, indent=2))
        return 0 if all(checks.values()) else 1
    finally:
        if watcher:
            watcher.close()
        if child.poll() is None:
            # 仅终止本函数自己创建的测试子进程。
            child.kill()
            child.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--seconds", type=float, default=300)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--allocation-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.allocation_child:
        allocation_child()
        return 0
    if args.self_test:
        return self_test()
    if not args.pid or args.output is None or args.seconds <= 0 or args.interval <= 0:
        parser.error("--pid and --output required; seconds/interval must be positive")
    watcher = Watcher(args.pid)
    try:
        # x模式独占创建：路径已存在即失败，不覆盖已有采样。
        with args.output.open("x", encoding="utf-8") as output:
            deadline = time.monotonic() + args.seconds
            while time.monotonic() < deadline and watcher.alive():
                started = time.monotonic()
                output.write(json.dumps(watcher.sample(), separators=(",", ":")) + "\n")
                output.flush()
                time.sleep(max(0, min(args.interval - (time.monotonic() - started),
                                      deadline - time.monotonic())))
    finally:
        watcher.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
