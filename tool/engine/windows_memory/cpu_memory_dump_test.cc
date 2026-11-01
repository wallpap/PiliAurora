// SPDX-License-Identifier: BSD-3-Clause
#include "cpu_memory_dump.h"

#include <cstdlib>
#include <iostream>

int main() {
  flutter::CpuResourceCacheCount dump;
  dump.dumpNumericValue("skia/sk_glyph_cache", "size", "bytes", 9000);
  dump.dumpNumericValue("skia/sk_resource_cache/bitmap_0x123", "size", "bytes", 16);
  dump.dumpNumericValue("skia/sk_resource_cache/bitmap_0x123", "budget_size", "bytes", 99);
  dump.dumpNumericValue("skia/sk_resource_cache/bitmap_0x456", "discardable_size", "bytes", 32);
  dump.dumpNumericValue("skia/gpu_resources/resource_1", "size", "bytes", 1000);
  if (dump.count != 2 || dump.bytes != 48) {
    std::cerr << "CPU resource totals must exclude glyph/GPU rows and extra value columns\n";
    return 1;
  }
  std::cout << "cpu_memory_dump: resource counting regression passed\n";
}
