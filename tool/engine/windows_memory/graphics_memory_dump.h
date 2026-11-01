// Copyright 2026 PiliAurora contributors.
// SPDX-License-Identifier: BSD-3-Clause
#ifndef FLUTTER_SHELL_COMMON_GRAPHICS_MEMORY_DUMP_H_
#define FLUTTER_SHELL_COMMON_GRAPHICS_MEMORY_DUMP_H_

#include <algorithm>
#include <chrono>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "rapidjson/document.h"
#include "rapidjson/stringbuffer.h"
#include "rapidjson/writer.h"
#include "third_party/skia/include/core/SkTraceMemoryDump.h"
#include "third_party/skia/include/gpu/ganesh/GrDirectContext.h"

namespace flutter {

// 仅在所属上下文线程调用；只记录 Skia 编号与 GL 整数名，不记录地址或 label。
class GraphicsMemoryDump final : public SkTraceMemoryDump {
 public:
  using Allocator = rapidjson::Document::AllocatorType;
  explicit GraphicsMemoryDump(bool collect_resources = true)
      : collect_resources_(collect_resources) {}
  struct Entry {
    std::string id, type, category, backing_type, backing_id;
    uint64_t bytes = 0, purgeable_bytes = 0;
    bool wrapped = false;
  };

  void dumpNumericValue(const char* name, const char* value_name,
                        const char* units, uint64_t value) override {
    // GrDirectContext 自身还有 cache 汇总行，不能把它重复算成资源子项。
    if (!ResourceName(name)) return;
    if (std::strcmp(value_name, "size") == 0) {
      ++entry_count_;
      entry_bytes_ += value;
    }
    if (std::strcmp(value_name, "purgeable_size") == 0) {
      purgeable_entry_bytes_ += value;
    }
    auto* entry = Find(name);
    if (!entry) return;
    if (std::strcmp(value_name, "size") == 0) entry->bytes = value;
    if (std::strcmp(value_name, "purgeable_size") == 0) {
      entry->purgeable_bytes = value;
    }
  }

  void dumpStringValue(const char* name, const char* key,
                       const char* value) override {
    auto* entry = Find(name);
    if (!entry) return;
    if (std::strcmp(key, "type") == 0) entry->type = value;
    if (std::strcmp(key, "category") == 0) entry->category = value;
  }

  void setMemoryBacking(const char* name, const char* type,
                        const char* id) override {
    auto* entry = Find(name);
    // GL 名字是共享组内整数；跨上下文看到同一 backing 时不能重复计账。
    if (entry && std::strncmp(type, "gl_", 3) == 0 && std::strlen(id) < 32) {
      entry->backing_type = type;
      entry->backing_id = id;
    }
  }

  void setDiscardableMemoryBacking(const char*, const SkDiscardableMemory&) override {}
  LevelOfDetail getRequestedDetails() const override {
    return kObjectsBreakdowns_LevelOfDetail;
  }
  void dumpWrappedState(const char* name, bool wrapped) override {
    if (auto* entry = Find(name)) entry->wrapped = wrapped;
  }

  void Append(rapidjson::Value& result, Allocator& allocator) const {
    result.AddMember("resourceCount", entry_count_, allocator);
    result.AddMember("resourceBytes", entry_bytes_, allocator);
    result.AddMember("dumpEntryCount", entry_count_, allocator);
    result.AddMember("dumpEntryBytes", entry_bytes_, allocator);
    result.AddMember("dumpPurgeableEntryBytes", purgeable_entry_bytes_, allocator);
    if (!collect_resources_) return;
    std::vector<const Entry*> ordered;
    for (const auto& pair : entries_) ordered.push_back(&pair.second);
    std::sort(ordered.begin(), ordered.end(), [](auto* a, auto* b) {
      return a->bytes > b->bytes;
    });
    rapidjson::Value resources(rapidjson::kArrayType);
    for (size_t i = 0; i < std::min(ordered.size(), size_t{64}); ++i) {
      const auto& entry = *ordered[i];
      rapidjson::Value row(rapidjson::kObjectType);
      AddString(row, "id", entry.id, allocator);
      AddString(row, "type", entry.type, allocator);
      AddString(row, "category", entry.category, allocator);
      row.AddMember("bytes", entry.bytes, allocator);
      row.AddMember("purgeableBytes", entry.purgeable_bytes, allocator);
      row.AddMember("wrapped", entry.wrapped, allocator);
      if (!entry.backing_id.empty()) {
        AddString(row, "backingType", entry.backing_type, allocator);
        AddString(row, "backingId", entry.backing_id, allocator);
      }
      resources.PushBack(row, allocator);
    }
    result.AddMember("resources", resources, allocator);
    result.AddMember("omittedEntries", entry_count_ - std::min(entry_count_, uint64_t{64}), allocator);
    result.AddMember("candidateLimitReached", entry_count_ > kMaxCandidates, allocator);
  }

 private:
  static constexpr size_t kMaxCandidates = 4096;
  static bool ResourceName(const char* name) {
    constexpr char prefix[] = "skia/gpu_resources/resource_";
    return std::strncmp(name, prefix, sizeof(prefix) - 1) == 0;
  }
  Entry* Find(const char* name) {
    if (!collect_resources_ || !ResourceName(name)) return nullptr;
    constexpr char prefix[] = "skia/gpu_resources/";
    if (std::strncmp(name, prefix, sizeof(prefix) - 1) != 0) return nullptr;
    const std::string id(name + sizeof(prefix) - 1);
    auto found = entries_.find(id);
    if (found != entries_.end()) return &found->second;
    if (entries_.size() >= kMaxCandidates) return nullptr;
    auto& entry = entries_[id];
    entry.id = id;
    return &entry;
  }
  static void AddString(rapidjson::Value& object, const char* key,
                        const std::string& value, Allocator& allocator) {
    rapidjson::Value field(value.c_str(), static_cast<rapidjson::SizeType>(value.size()), allocator);
    object.AddMember(rapidjson::StringRef(key), field, allocator);
  }
  std::map<std::string, Entry> entries_;
  uint64_t entry_count_ = 0, entry_bytes_ = 0;
  uint64_t purgeable_entry_bytes_ = 0;
  const bool collect_resources_;
};

inline std::string GraphicsMemoryJson(const rapidjson::Value& value) {
  rapidjson::StringBuffer buffer;
  rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
  value.Accept(writer);
  return {buffer.GetString(), buffer.GetSize()};
}

inline rapidjson::Value GraphicsMemoryCounters(
    GrDirectContext* context, rapidjson::Document::AllocatorType& allocator,
    bool resources = false) {
  rapidjson::Value value(rapidjson::kObjectType);
  value.AddMember("available", context && !context->abandoned(), allocator);
  if (!context || context->abandoned()) return value;
  int count = 0;
  size_t bytes = 0;
  context->getResourceCacheUsage(&count, &bytes);
  // getResourceCacheUsage 在本引擎版本只计 budgeted，不能代表全部资源。
  value.AddMember("budgetedResourceCount", count, allocator);
  value.AddMember("budgetedResourceBytes", static_cast<uint64_t>(bytes), allocator);
  value.AddMember("budgetBytes", static_cast<uint64_t>(context->getResourceCacheLimit()), allocator);
  value.AddMember("purgeableBytes", static_cast<uint64_t>(context->getResourceCachePurgeableBytes()), allocator);
  GraphicsMemoryDump dump(resources);
  context->dumpMemoryStatistics(&dump);
  dump.Append(value, allocator);
  return value;
}

inline rapidjson::Document CaptureGraphicsMemory(GrDirectContext* context,
                                                bool resources, bool purge,
                                                bool flush = false,
                                                bool free_gpu = false,
                                                const char* context_name = "") {
  rapidjson::Document result;
  result.SetObject();
  auto& allocator = result.GetAllocator();
  if ((purge || flush || free_gpu) && context && !context->abandoned()) {
    auto before = GraphicsMemoryCounters(context, allocator);
    result.AddMember("before", before, allocator);
    const auto started = std::chrono::steady_clock::now();
    if (free_gpu) context->freeGpuResources();
    if (purge) context->purgeUnlockedResources(GrPurgeResourceOptions::kAllResources);
    if (flush) context->flushAndSubmit(GrSyncCpu::kYes);
    result.AddMember("actionDurationUs", static_cast<int64_t>(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - started).count()), allocator);
    if (free_gpu) {
      auto after = GraphicsMemoryCounters(context, allocator, resources);
      result.AddMember("after", after, allocator);
      result.AddMember("context", rapidjson::Value(context_name, allocator), allocator);
      result.AddMember("internalFlushAndSubmit", true, allocator);
      result.AddMember("cpuSyncRequested", false, allocator);
    }
    result.AddMember("action", rapidjson::StringRef(free_gpu ? "freeGpuResources" : flush ? "flushAndSubmitSyncCpu" : "purgeUnlockedResources"), allocator);
  }
  auto counters = GraphicsMemoryCounters(context, allocator, resources);
  for (auto it = counters.MemberBegin(); it != counters.MemberEnd(); ++it) {
    result.AddMember(it->name, it->value, allocator);
  }
  return result;
}

}  // namespace flutter
#endif  // FLUTTER_SHELL_COMMON_GRAPHICS_MEMORY_DUMP_H_
