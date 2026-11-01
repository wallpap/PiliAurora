#include "memory_metrics.h"

#include <Windows.h>

#include <algorithm>
#include <chrono>
#include <stdexcept>
#include <tuple>

namespace {
using Counters = MemoryMetrics::Counters;
using Allocation = MemoryMetrics::Allocation;

void AddRegion(Counters& out, const MEMORY_BASIC_INFORMATION& region) {
  const auto bytes = static_cast<uint64_t>(region.RegionSize);
  if (region.State == MEM_FREE) {
    out.free_bytes += bytes;
    return;
  }
  const bool committed = region.State == MEM_COMMIT;
  if (committed) {
    out.committed_bytes += bytes;
  } else if (region.State == MEM_RESERVE) {
    out.reserved_bytes += bytes;
  } else {
    return;
  }
  switch (region.Type) {
    case MEM_PRIVATE:
      if (committed) {
        out.private_committed_bytes += bytes;
        if ((region.Protect & PAGE_WRITECOMBINE) != 0) {
          out.private_write_combine_bytes += bytes;
        } else if ((region.Protect & 0xff) == PAGE_READWRITE) {
          out.private_read_write_bytes += bytes;
        } else {
          out.private_other_bytes += bytes;
        }
      } else {
        out.private_reserved_bytes += bytes;
      }
      break;
    case MEM_MAPPED:
      if (committed) {
        out.mapped_committed_bytes += bytes;
      } else {
        out.mapped_reserved_bytes += bytes;
      }
      break;
    case MEM_IMAGE:
      if (committed) {
        out.image_committed_bytes += bytes;
      } else {
        out.image_reserved_bytes += bytes;
      }
      break;
    default:
      if (committed) {
        out.other_committed_bytes += bytes;
      } else {
        out.other_reserved_bytes += bytes;
      }
  }
}

bool SameAllocation(const Allocation& a, const Allocation& b) {
  return a.bytes == b.bytes && a.region_count == b.region_count &&
         a.type_flags == b.type_flags &&
         a.protection_flags == b.protection_flags &&
         a.above_threshold == b.above_threshold;
}

bool Larger(const Allocation& a, const Allocation& b) {
  if (a.bytes.committed_bytes != b.bytes.committed_bytes) {
    return a.bytes.committed_bytes > b.bytes.committed_bytes;
  }
  return a.bytes.allocated_bytes() > b.bytes.allocated_bytes();
}
}  // namespace

bool MemoryMetrics::Counters::operator==(const Counters& other) const {
  return std::tie(committed_bytes, reserved_bytes, free_bytes,
                  private_committed_bytes, private_reserved_bytes,
                  mapped_committed_bytes, mapped_reserved_bytes,
                  image_committed_bytes, image_reserved_bytes,
                  other_committed_bytes, other_reserved_bytes,
                  private_read_write_bytes, private_write_combine_bytes,
                  private_other_bytes) ==
         std::tie(other.committed_bytes, other.reserved_bytes, other.free_bytes,
                  other.private_committed_bytes, other.private_reserved_bytes,
                  other.mapped_committed_bytes, other.mapped_reserved_bytes,
                  other.image_committed_bytes, other.image_reserved_bytes,
                  other.other_committed_bytes, other.other_reserved_bytes,
                  other.private_read_write_bytes, other.private_write_combine_bytes,
                  other.private_other_bytes);
}

MemoryMetrics::MemoryMetrics() : MemoryMetrics(Options{}) {}

MemoryMetrics::MemoryMetrics(Options options) : options_(options) {
  if (options_.interval_ms == 0 || options_.minimum_allocation_bytes == 0 ||
      options_.max_allocations == 0 || options_.max_allocations > 512 ||
      options_.max_changes == 0 || options_.max_changes > 512) {
    throw std::invalid_argument("Invalid memory metrics limits");
  }
  latest_.configured_interval_ms = options_.interval_ms;
}

MemoryMetrics::~MemoryMetrics() { Stop(); }

void MemoryMetrics::Start() {
  if (worker_.joinable()) return;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_.store(false, std::memory_order_release);
    latest_ = Snapshot{};
    latest_.status = "warmingUp";
    latest_.enabled = true;
    latest_.configured_interval_ms = options_.interval_ms;
  }
  worker_ = std::thread(&MemoryMetrics::Run, this);
}

void MemoryMetrics::Stop() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_.store(true, std::memory_order_release);
  }
  wake_.notify_all();
  if (worker_.joinable()) worker_.join();
  std::lock_guard<std::mutex> lock(mutex_);
  latest_.enabled = false;
  latest_.status = "disabled";
}

MemoryMetrics::Snapshot MemoryMetrics::ReadCachedSnapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return latest_;
}

void MemoryMetrics::Run() {
  tracked_.clear();
  uint64_t previous_tick = 0;
  while (!stopping_.load(std::memory_order_acquire)) {
    auto snapshot = Scan(previous_tick);
    previous_tick = snapshot.tick_ms;
    std::unique_lock<std::mutex> lock(mutex_);
    if (stopping_.load(std::memory_order_acquire)) break;
    latest_ = std::move(snapshot);
    if (wake_.wait_for(lock, std::chrono::milliseconds(options_.interval_ms),
                       [this] { return stopping_.load(std::memory_order_acquire); })) {
      break;
    }
  }
}

MemoryMetrics::Snapshot MemoryMetrics::Scan(uint64_t previous_tick) {
  Snapshot out;
  out.enabled = true;
  out.status = "sampled";
  out.sample_id = ++sample_id_;
  out.tick_ms = GetTickCount64();
  out.scan_interval_ms = previous_tick == 0 ? 0 : out.tick_ms - previous_tick;
  out.configured_interval_ms = options_.interval_ms;
  const auto started = std::chrono::steady_clock::now();
  SYSTEM_INFO info{};
  GetSystemInfo(&info);
  const auto maximum = reinterpret_cast<uintptr_t>(info.lpMaximumApplicationAddress);
  std::map<uintptr_t, Allocation> existing;
  std::vector<Observed> candidates;
  candidates.reserve(options_.max_allocations);
  Observed current;
  bool have_current = false;
  auto finish_allocation = [&] {
    if (!have_current) return;
    ++out.allocation_count;
    auto& a = current.allocation;
    a.above_threshold = a.bytes.allocated_bytes() >= options_.minimum_allocation_bytes;
    if (a.above_threshold) {
      ++out.eligible_allocation_count;
      out.eligible_allocation_bytes += a.bytes.allocated_bytes();
      out.eligible_committed_bytes += a.bytes.committed_bytes;
      out.eligible_reserved_bytes += a.bytes.reserved_bytes;
    }
    if (tracked_.find(current.base) != tracked_.end()) {
      existing.emplace(current.base, a);
    } else if (a.above_threshold) {
      // 固定大小候选集合；既有身份优先，新候选保留最大块。
      if (candidates.size() < options_.max_allocations) {
        candidates.push_back(current);
      } else {
        auto smallest = std::min_element(
            candidates.begin(), candidates.end(), [](const auto& x, const auto& y) {
              return Larger(y.allocation, x.allocation);
            });
        if (Larger(a, smallest->allocation)) *smallest = current;
      }
    }
    have_current = false;
  };

  uintptr_t cursor = 0;
  while (cursor <= maximum) {
    if (stopping_.load(std::memory_order_acquire)) {
      out.status = "error";
      out.error_code = ERROR_OPERATION_ABORTED;
      break;
    }
    MEMORY_BASIC_INFORMATION region{};
    if (VirtualQuery(reinterpret_cast<const void*>(cursor), &region,
                     sizeof(region)) == 0) {
      out.status = "error";
      out.error_code = GetLastError();
      break;
    }
    ++out.queried_region_count;
    const auto start = reinterpret_cast<uintptr_t>(region.BaseAddress);
    const auto next = start + region.RegionSize;
    if (region.RegionSize == 0 || next <= cursor) {
      out.status = "error";
      out.error_code = ERROR_INVALID_DATA;
      break;
    }
    AddRegion(out.totals, region);
    if (region.State == MEM_COMMIT || region.State == MEM_RESERVE) {
      const auto base = reinterpret_cast<uintptr_t>(region.AllocationBase);
      if (have_current && base != current.base) finish_allocation();
      if (!have_current) {
        current = Observed{};
        current.base = base;
        have_current = true;
      }
      AddRegion(current.allocation.bytes, region);
      ++current.allocation.region_count;
      current.allocation.type_flags |= region.Type;
      if (region.State == MEM_COMMIT) {
        current.allocation.protection_flags |= region.Protect;
      }
    } else {
      finish_allocation();
    }
    if (next > maximum) {
      out.complete = true;
      break;
    }
    cursor = next;
  }
  finish_allocation();
  // 扫描中途失败不得把尚未遍历的旧项误报为 released。
  if (out.complete) ApplyObservation(out, existing, candidates);
  out.scan_duration_us = static_cast<uint64_t>(
      std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::steady_clock::now() - started).count());
  return out;
}

void MemoryMetrics::ApplyObservation(
    Snapshot& out, const std::map<uintptr_t, Allocation>& existing,
    std::vector<Observed>& candidates) {
  auto emit = [&](const char* kind, const Allocation& before,
                   const Allocation& after) {
    if (out.changes.size() < options_.max_changes) {
      out.changes.push_back({kind, after.id != 0 ? after.id : before.id, before, after});
    } else {
      ++out.event_overflow;
    }
  };
  for (auto it = tracked_.begin(); it != tracked_.end();) {
    const auto found = existing.find(it->first);
    if (found == existing.end()) {
      ++out.released_count;
      emit("released", it->second.allocation, Allocation{});
      it = tracked_.erase(it);
    } else {
      auto after = found->second;
      after.id = it->second.allocation.id;
      if (!SameAllocation(after, it->second.allocation)) {
        ++out.changed_count;
        emit("changed", it->second.allocation, after);
      }
      it->second.allocation = after;
      ++it;
    }
  }
  std::sort(candidates.begin(), candidates.end(), [](const auto& a, const auto& b) {
    return Larger(a.allocation, b.allocation);
  });
  for (auto& candidate : candidates) {
    if (tracked_.size() >= options_.max_allocations) break;
    candidate.allocation.id = next_id_++;
    tracked_.emplace(candidate.base, Tracked{candidate.allocation});
    ++out.created_count;
    emit("created", Allocation{}, candidate.allocation);
  }
  out.omitted_allocation_count = out.eligible_allocation_count;
  out.omitted_allocation_bytes = out.eligible_allocation_bytes;
  out.omitted_committed_bytes = out.eligible_committed_bytes;
  out.omitted_reserved_bytes = out.eligible_reserved_bytes;
  for (const auto& entry : tracked_) {
    const auto& allocation = entry.second.allocation;
    out.allocations.push_back(allocation);
    if (allocation.above_threshold) {
      --out.omitted_allocation_count;
      out.omitted_allocation_bytes -= allocation.bytes.allocated_bytes();
      out.omitted_committed_bytes -= allocation.bytes.committed_bytes;
      out.omitted_reserved_bytes -= allocation.bytes.reserved_bytes;
    }
  }
  std::sort(out.allocations.begin(), out.allocations.end(), Larger);
  out.truncated = out.omitted_allocation_count != 0 || out.event_overflow != 0;
}
