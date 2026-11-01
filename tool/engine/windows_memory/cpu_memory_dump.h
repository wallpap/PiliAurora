// Copyright 2026 PiliAurora contributors.
// SPDX-License-Identifier: BSD-3-Clause
#ifndef FLUTTER_SHELL_COMMON_CPU_MEMORY_DUMP_H_
#define FLUTTER_SHELL_COMMON_CPU_MEMORY_DUMP_H_

#include <cstring>

#include "rapidjson/document.h"
#include "third_party/skia/include/core/SkGraphics.h"
#include "third_party/skia/include/core/SkTraceMemoryDump.h"

namespace flutter {

// CPU cache dump 的条目名含地址；只聚合数字，绝不保留或输出名字/backing。
class CpuResourceCacheCount final : public SkTraceMemoryDump {
 public:
  void dumpNumericValue(const char* name, const char* key, const char*,
                        uint64_t value) override {
    constexpr char prefix[] = "skia/sk_resource_cache/";
    if (std::strncmp(name, prefix, sizeof(prefix) - 1) != 0) return;
    if (std::strcmp(key, "size") != 0 &&
        std::strcmp(key, "discardable_size") != 0) return;
    ++count;
    bytes += value;
  }
  void setMemoryBacking(const char*, const char*, const char*) override {}
  void setDiscardableMemoryBacking(const char*, const SkDiscardableMemory&) override {}
  LevelOfDetail getRequestedDetails() const override { return kLight_LevelOfDetail; }
  uint64_t count = 0;
  uint64_t bytes = 0;
};

inline rapidjson::Value CpuMemoryCounters(
    rapidjson::Document::AllocatorType& allocator) {
  rapidjson::Value result(rapidjson::kObjectType);
  CpuResourceCacheCount dump;
  SkGraphics::DumpMemoryStatistics(&dump);
  rapidjson::Value resource(rapidjson::kObjectType);
  resource.AddMember("usedBytes", static_cast<uint64_t>(SkGraphics::GetResourceCacheTotalBytesUsed()), allocator);
  resource.AddMember("limitBytes", static_cast<uint64_t>(SkGraphics::GetResourceCacheTotalByteLimit()), allocator);
  resource.AddMember("count", dump.count, allocator);
  resource.AddMember("dumpUsedBytes", dump.bytes, allocator);
  resource.AddMember("singleAllocationLimitBytes", static_cast<uint64_t>(SkGraphics::GetResourceCacheSingleAllocationByteLimit()), allocator);
  result.AddMember("resource", resource, allocator);

  rapidjson::Value font(rapidjson::kObjectType);
  font.AddMember("usedBytes", static_cast<uint64_t>(SkGraphics::GetFontCacheUsed()), allocator);
  font.AddMember("limitBytes", static_cast<uint64_t>(SkGraphics::GetFontCacheLimit()), allocator);
  font.AddMember("count", SkGraphics::GetFontCacheCountUsed(), allocator);
  font.AddMember("limitCount", SkGraphics::GetFontCacheCountLimit(), allocator);
  font.AddMember("typefaceLimitCount", SkGraphics::GetTypefaceCacheCountLimit(), allocator);
  font.AddMember("coverage", "globalStrikeCache; typefaceBytesAndDWriteManagerCacheNotIncluded", allocator);
  result.AddMember("font", font, allocator);

  rapidjson::Value hb(rapidjson::kObjectType);
  hb.AddMember("usedBytes", rapidjson::Value(), allocator);
  hb.AddMember("limitBytes", rapidjson::Value(), allocator);
  hb.AddMember("count", rapidjson::Value(), allocator);
  hb.AddMember("limitCount", 100, allocator);
  hb.AddMember("metricsAvailable", false, allocator);
  hb.AddMember("limitSource", "fixedSkiaSource; notRuntimeGetter", allocator);
  hb.AddMember("reason", "SkiaPublicApiHasNoUsedOrCountGetter", allocator);
  result.AddMember("harfBuzz", hb, allocator);
  return result;
}

}  // namespace flutter
#endif  // FLUTTER_SHELL_COMMON_CPU_MEMORY_DUMP_H_
