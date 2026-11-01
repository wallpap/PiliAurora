#include "memory_metrics_channel.h"

#include <Windows.h>

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using V = flutter::EncodableValue;
V Number(uint64_t value) { return V(static_cast<int64_t>(value)); }

EncodableMap Bytes(const MemoryMetrics::Counters& b) {
  return {
      {V("committedBytes"), Number(b.committed_bytes)},
      {V("reservedBytes"), Number(b.reserved_bytes)},
      {V("privateCommittedBytes"), Number(b.private_committed_bytes)},
      {V("privateReservedBytes"), Number(b.private_reserved_bytes)},
      {V("mappedCommittedBytes"), Number(b.mapped_committed_bytes)},
      {V("imageCommittedBytes"), Number(b.image_committed_bytes)},
      {V("privateReadWriteBytes"), Number(b.private_read_write_bytes)},
      {V("privateWriteCombineBytes"), Number(b.private_write_combine_bytes)},
      {V("privateOtherBytes"), Number(b.private_other_bytes)},
  };
}

EncodableMap Allocation(const MemoryMetrics::Allocation& a) {
  auto result = Bytes(a.bytes);
  result.emplace(V("id"), Number(a.id));
  result.emplace(V("regionCount"), Number(a.region_count));
  result.emplace(V("typeFlags"), Number(a.type_flags));
  result.emplace(V("protectionFlags"), Number(a.protection_flags));
  result.emplace(V("aboveThreshold"), V(a.above_threshold));
  return result;
}

EncodableMap Encode(const MemoryMetrics::Snapshot& s) {
  auto totals = Bytes(s.totals);
  totals.emplace(V("mappedReservedBytes"), Number(s.totals.mapped_reserved_bytes));
  totals.emplace(V("imageReservedBytes"), Number(s.totals.image_reserved_bytes));
  totals.emplace(V("otherCommittedBytes"), Number(s.totals.other_committed_bytes));
  totals.emplace(V("otherReservedBytes"), Number(s.totals.other_reserved_bytes));
  totals.emplace(V("freeBytes"), Number(s.totals.free_bytes));
  EncodableList changes, allocations;
  for (const auto& a : s.allocations) allocations.emplace_back(Allocation(a));
  for (const auto& c : s.changes) {
    EncodableMap change{{V("kind"), V(c.kind)}, {V("id"), Number(c.id)}};
    if (c.kind != "created") change.emplace(V("before"), V(Allocation(c.before)));
    if (c.kind != "released") change.emplace(V("after"), V(Allocation(c.after)));
    changes.emplace_back(change);
  }
  return {
      {V("status"), V(s.status)}, {V("enabled"), V(s.enabled)},
      {V("complete"), V(s.complete)}, {V("sampleId"), Number(s.sample_id)},
      {V("tickMs"), Number(s.tick_ms)},
      {V("readTickMs"), Number(GetTickCount64())},
      {V("scanDurationUs"), Number(s.scan_duration_us)},
      {V("scanIntervalMs"), Number(s.scan_interval_ms)},
      {V("configuredIntervalMs"), Number(s.configured_interval_ms)},
      {V("errorCode"), Number(s.error_code)},
      {V("queriedRegionCount"), Number(s.queried_region_count)},
      {V("allocationCount"), Number(s.allocation_count)},
      {V("eligibleAllocationCount"), Number(s.eligible_allocation_count)},
      {V("eligibleAllocationBytes"), Number(s.eligible_allocation_bytes)},
      {V("eligibleCommittedBytes"), Number(s.eligible_committed_bytes)},
      {V("eligibleReservedBytes"), Number(s.eligible_reserved_bytes)},
      {V("omittedAllocationCount"), Number(s.omitted_allocation_count)},
      {V("omittedAllocationBytes"), Number(s.omitted_allocation_bytes)},
      {V("omittedCommittedBytes"), Number(s.omitted_committed_bytes)},
      {V("omittedReservedBytes"), Number(s.omitted_reserved_bytes)},
      {V("createdCount"), Number(s.created_count)},
      {V("changedCount"), Number(s.changed_count)},
      {V("releasedCount"), Number(s.released_count)},
      {V("eventOverflow"), Number(s.event_overflow)},
      {V("truncated"), V(s.truncated)},
      {V("totals"), V(totals)}, {V("allocations"), V(allocations)},
      {V("changes"), V(changes)},
  };
}
}  // namespace

MemoryMetricsChannel::MemoryMetricsChannel(flutter::FlutterEngine* engine) {
  channel_ = std::make_unique<flutter::MethodChannel<V>>(
      engine->messenger(), "pili_aurora/windows_memory",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "start") {
      metrics_.Start();
      result->Success();
    } else if (call.method_name() == "stop") {
      metrics_.Stop();
      result->Success();
    } else if (call.method_name() == "sample") {
      const auto snapshot = metrics_.ReadCachedSnapshot();
      const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      if (args) {
        const auto found = args->find(V("afterSampleId"));
        if (found != args->end()) {
          const auto* previous = std::get_if<int64_t>(&found->second);
          // StandardMessageCodec 使用 int32 编码小整数。
          const auto* previous32 = std::get_if<int32_t>(&found->second);
          if ((previous && *previous == static_cast<int64_t>(snapshot.sample_id)) ||
              (previous32 && *previous32 == static_cast<int64_t>(snapshot.sample_id))) {
            result->Success(V(EncodableMap{{V("unchanged"), V(true)}}));
            return;
          }
        }
      }
      result->Success(V(Encode(snapshot)));
    } else {
      result->NotImplemented();
    }
  });
}

MemoryMetricsChannel::~MemoryMetricsChannel() { metrics_.Stop(); }
