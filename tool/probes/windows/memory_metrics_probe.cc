// 仓库根目录：g++ -std=c++17 -Wall -Wextra -pedantic -I windows/runner
// windows/runner/memory_metrics.cpp tool/probes/windows/memory_metrics_probe.cc
// -o build/probe-validation/memory-metrics/memory_metrics_probe.exe
#include "memory_metrics.h"

#include <Windows.h>

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <thread>

namespace {
void Require(bool value, const char* message) {
  if (!value) {
    std::cerr << "FAIL: " << message << std::endl;
    std::exit(1);
  }
}

MemoryMetrics::Snapshot WaitSample(MemoryMetrics& metrics, uint64_t after_id = 0) {
  for (int i = 0; i < 100; ++i) {
    auto snapshot = metrics.ReadCachedSnapshot();
    if (snapshot.status == "sampled" && snapshot.complete &&
        snapshot.sample_id > after_id)
      return snapshot;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  Require(false, "scanner did not produce a complete sample");
  return {};
}

const MemoryMetrics::Allocation* FindChanged(const MemoryMetrics::Snapshot& snapshot,
                                             uint64_t id) {
  for (const auto& allocation : snapshot.allocations) {
    if (allocation.id == id) return &allocation;
  }
  return nullptr;
}
}  // namespace

int main() {
  MemoryMetrics::Options options;
  options.interval_ms = 100;
  options.minimum_allocation_bytes = 1024 * 1024;
  options.max_allocations = 512;
  options.max_changes = 32;
  MemoryMetrics metrics(options);
  metrics.Start();
  auto initial = WaitSample(metrics);
  Require(initial.sample_id >= 1, "sample id");
  Require(initial.tick_ms != 0, "tick");
  Require(initial.scan_duration_us != 0, "scan duration");

  auto* allocation = static_cast<unsigned char*>(
      VirtualAlloc(nullptr, 4 * 1024 * 1024, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  Require(allocation != nullptr, "VirtualAlloc");
  allocation[0] = 1;
  auto created = WaitSample(metrics, initial.sample_id);
  bool saw_created = false;
  uint64_t created_id = 0;
  for (const auto& change : created.changes) {
    if (change.kind == "created" && change.after.bytes.private_read_write_bytes >=
                                      4 * 1024 * 1024) {
      saw_created = true;
      created_id = change.id;
    }
  }
  Require(saw_created, "created snapshot difference for private RW allocation");
  Require(created_id != 0 && FindChanged(created, created_id) != nullptr,
          "stable created id is listed");

  DWORD old_protection = 0;
  Require(VirtualProtect(allocation, 4 * 1024 * 1024, PAGE_READONLY,
                         &old_protection) != 0, "VirtualProtect");
  auto changed = WaitSample(metrics, created.sample_id);
  bool saw_changed = false;
  for (const auto& change : changed.changes) {
    if (change.kind == "changed" && change.id == created_id) saw_changed = true;
  }
  Require(saw_changed, "protection change snapshot difference");
  const auto* read_only = FindChanged(changed, created_id);
  Require(read_only != nullptr && read_only->bytes.private_other_bytes ==
                                      4 * 1024 * 1024 &&
              read_only->bytes.private_read_write_bytes == 0,
          "read-only classification changes while preserving identity");

  Require(VirtualFree(allocation, 0, MEM_RELEASE) != 0, "release allocation");
  auto released = WaitSample(metrics, changed.sample_id);
  bool saw_released = false;
  for (const auto& change : released.changes) {
    if (change.kind == "released" && change.id == created_id) saw_released = true;
  }
  Require(saw_released, "released snapshot difference");

  auto reused = static_cast<unsigned char*>(
      VirtualAlloc(allocation, 4 * 1024 * 1024, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
  Require(reused == allocation, "VirtualAlloc exact address reuse");
  auto recreated = WaitSample(metrics, released.sample_id);
  bool saw_new_id = false;
  for (const auto& change : recreated.changes) {
    if (change.kind == "created" && change.after.bytes.private_read_write_bytes >=
                                      4 * 1024 * 1024 && change.id != created_id) {
      saw_new_id = true;
    }
  }
  Require(saw_new_id, "address reuse receives a new id");
  Require(VirtualFree(reused, 0, MEM_RELEASE) != 0, "release reused allocation");

  auto stable = WaitSample(metrics, recreated.sample_id);
  const auto* stable_entry = FindChanged(stable, created_id);
  Require(stable_entry == nullptr, "old identity does not return after reuse");
  Require(stable.scan_interval_ms + 20 >= options.interval_ms,
          "observed scan interval includes configured delay");
  Require(stable.totals.committed_bytes ==
              stable.totals.private_committed_bytes +
                  stable.totals.mapped_committed_bytes +
                  stable.totals.image_committed_bytes +
                  stable.totals.other_committed_bytes,
          "committed classifications partition total");
  Require(stable.totals.private_committed_bytes ==
              stable.totals.private_read_write_bytes +
                  stable.totals.private_write_combine_bytes +
                  stable.totals.private_other_bytes,
          "private protection classifications partition private total");
  Require(stable.totals.image_committed_bytes > 0, "image regions counted");
  metrics.Stop();
  auto stopped = metrics.ReadCachedSnapshot();
  Require(!stopped.enabled && stopped.status == "disabled", "stop state");
  // 保留块的新提交和保护变化必须仍沿用同一个匿名身份。
  MemoryMetrics::Options large_options;
  large_options.interval_ms = 80;
  large_options.minimum_allocation_bytes = 64 * 1024 * 1024;
  MemoryMetrics large(large_options);
  large.Start();
  auto baseline = WaitSample(large);
  auto* reserved = static_cast<unsigned char*>(
      VirtualAlloc(nullptr, 80 * 1024 * 1024, MEM_RESERVE, PAGE_NOACCESS));
  Require(reserved != nullptr, "reserve 80 MiB");
  auto reserve_sample = WaitSample(large, baseline.sample_id);
  uint64_t reserve_id = 0;
  for (const auto& entry : reserve_sample.allocations) {
    if (entry.bytes.reserved_bytes == 80 * 1024 * 1024 &&
        entry.bytes.committed_bytes == 0) reserve_id = entry.id;
  }
  Require(reserve_id != 0, "reserved allocation listed");
  Require(VirtualAlloc(reserved, 2 * 1024 * 1024, MEM_COMMIT, PAGE_READWRITE) ==
              reserved, "commit within reserved allocation");
  auto committed = WaitSample(large, reserve_sample.sample_id);
  const auto* entry = FindChanged(committed, reserve_id);
  Require(entry != nullptr && entry->bytes.private_read_write_bytes ==
                                  2 * 1024 * 1024 &&
              entry->bytes.reserved_bytes == 78 * 1024 * 1024,
          "commit moves bytes from reserved to private RW with stable id");
  auto unchanged = WaitSample(large, committed.sample_id);
  Require(FindChanged(unchanged, reserve_id) != nullptr, "unchanged stable id");
  for (const auto& change : unchanged.changes) {
    Require(change.id != reserve_id, "unchanged allocation emits no difference");
  }
  Require(VirtualFree(reserved, 2 * 1024 * 1024, MEM_DECOMMIT) != 0,
          "decommit preserves allocation");
  auto decommitted = WaitSample(large, unchanged.sample_id);
  entry = FindChanged(decommitted, reserve_id);
  Require(entry != nullptr && entry->bytes.reserved_bytes == 80 * 1024 * 1024 &&
              entry->bytes.committed_bytes == 0,
          "decommit returns to reserve with stable id");
  Require(VirtualFree(reserved, 0, MEM_RELEASE) != 0, "free reserved allocation");
  large.Stop();

  // PAGE_WRITECOMBINE 是分配时缓存策略，不依赖 VirtualProtect 能否更改缓存类型。
  void* write_combine = VirtualAlloc(nullptr, 3 * 1024 * 1024,
      MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE | PAGE_WRITECOMBINE);
  Require(write_combine != nullptr, "allocate write-combine pages");
  MemoryMetrics wc_metrics;
  wc_metrics.Start();
  auto wc_sample = WaitSample(wc_metrics);
  bool wc_found = false;
  for (const auto& item : wc_sample.allocations) {
    if (item.bytes.private_write_combine_bytes == 3 * 1024 * 1024 &&
        item.bytes.private_read_write_bytes == 0) wc_found = true;
  }
  Require(wc_found, "write-combine exclusive classification");
  wc_metrics.Stop();
  VirtualFree(write_combine, 0, MEM_RELEASE);

  auto mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
                                     0, 3 * 1024 * 1024, nullptr);
  Require(mapping != nullptr, "create anonymous mapping");
  auto view = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0);
  Require(view != nullptr, "map anonymous view");
  MemoryMetrics mapped;
  mapped.Start();
  auto mapped_sample = WaitSample(mapped);
  bool mapped_found = false;
  for (const auto& item : mapped_sample.allocations) {
    if (item.bytes.mapped_committed_bytes == 3 * 1024 * 1024) mapped_found = true;
  }
  Require(mapped_found, "mapped committed allocation counted without filename");
  mapped.Stop();
  UnmapViewOfFile(view);
  CloseHandle(mapping);

  // 精确上限：3 个大 commit 块只能列出 1 个，遗漏字节仍完整计数。
  void* blocks[3]{};
  const uint64_t block_bytes = 96 * 1024 * 1024;
  for (auto& block : blocks) {
    block = VirtualAlloc(nullptr, block_bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    Require(block != nullptr, "limit fixture reserve");
  }
  auto limited_options = large_options;
  limited_options.max_allocations = 1;
  limited_options.max_changes = 1;
  MemoryMetrics limited(limited_options);
  limited.Start();
  auto limited_sample = WaitSample(limited);
  Require(limited_sample.allocations.size() == 1 &&
              limited_sample.omitted_allocation_count >= 2 &&
              limited_sample.omitted_allocation_bytes >= 2 * block_bytes &&
              limited_sample.omitted_committed_bytes >= 2 * block_bytes &&
              limited_sample.truncated,
          "allocation limit reports omitted counts and bytes");
  uint64_t listed_bytes = 0;
  for (const auto& item : limited_sample.allocations) {
    if (item.above_threshold) listed_bytes += item.bytes.allocated_bytes();
  }
  Require(limited_sample.eligible_allocation_bytes ==
              listed_bytes + limited_sample.omitted_allocation_bytes,
          "listed plus omitted equals eligible total");
  // 先预留不同地址的新块，避免两次扫描间释放重用同一地址不可辨识的边界。
  void* new_block = VirtualAlloc(nullptr, 112 * 1024 * 1024, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
  Require(new_block != nullptr, "new block for event limit");
  for (auto& block : blocks) {
    Require(VirtualFree(block, 0, MEM_RELEASE) != 0, "free limit fixture");
  }
  auto overflow = WaitSample(limited, limited_sample.sample_id);
  Require(overflow.released_count == 1 && overflow.created_count == 1 &&
              overflow.changes.size() == 1 && overflow.event_overflow == 1 &&
              overflow.truncated,
          "change limit reports omitted observed differences");
  limited.Stop();
  VirtualFree(new_block, 0, MEM_RELEASE);

  MemoryMetrics disabled;
  Require(disabled.ReadCachedSnapshot().sample_id == 0 &&
              !disabled.ReadCachedSnapshot().enabled, "disabled does not scan");
  disabled.Start();
  WaitSample(disabled);
  const auto stop_begin = std::chrono::steady_clock::now();
  disabled.Stop();
  Require(std::chrono::steady_clock::now() - stop_begin < std::chrono::milliseconds(500),
          "stop wakes default five-second wait immediately");
  const auto disabled_id = disabled.ReadCachedSnapshot().sample_id;
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  Require(disabled.ReadCachedSnapshot().sample_id == disabled_id,
          "no scans after stop");
  disabled.Start();
  auto restarted = WaitSample(disabled, disabled_id);
  Require(restarted.sample_id > disabled_id, "restart preserves increasing sample ids");
  disabled.Stop();
  std::cout << "memory_metrics_probe: PASS samples=" << recreated.sample_id
            << " tracked=" << recreated.allocations.size()
            << " regions=" << recreated.queried_region_count << std::endl;
  return 0;
}
