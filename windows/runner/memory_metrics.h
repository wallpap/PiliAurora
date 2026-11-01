#ifndef RUNNER_MEMORY_METRICS_H_
#define RUNNER_MEMORY_METRICS_H_

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// 只读扫描当前进程的虚拟地址空间；不读页内容，不查询文件名，不输出地址。
// Start/Stop 由同一控制线程调用；ReadCachedSnapshot 可在任意线程调用。
class MemoryMetrics {
 public:
  struct Options {
    uint32_t interval_ms = 5000;
    uint64_t minimum_allocation_bytes = 1024 * 1024;
    size_t max_allocations = 512;
    size_t max_changes = 512;
  };

  struct Counters {
    uint64_t committed_bytes = 0;
    uint64_t reserved_bytes = 0;
    uint64_t free_bytes = 0;
    uint64_t private_committed_bytes = 0;
    uint64_t private_reserved_bytes = 0;
    uint64_t mapped_committed_bytes = 0;
    uint64_t mapped_reserved_bytes = 0;
    uint64_t image_committed_bytes = 0;
    uint64_t image_reserved_bytes = 0;
    uint64_t other_committed_bytes = 0;
    uint64_t other_reserved_bytes = 0;
    // 以下三项互斥，合计 private_committed_bytes。RW 不含 WRITECOMBINE；
    // 只按 PAGE_READWRITE 基础保护分类，PAGE_GUARD 等修饰位另见 protection_flags。
    uint64_t private_read_write_bytes = 0;
    uint64_t private_write_combine_bytes = 0;
    uint64_t private_other_bytes = 0;

    uint64_t allocated_bytes() const { return committed_bytes + reserved_bytes; }
    bool operator==(const Counters& other) const;
  };

  struct Allocation {
    uint64_t id = 0;
    Counters bytes;
    uint64_t region_count = 0;
    uint32_t type_flags = 0;
    uint32_t protection_flags = 0;
    bool above_threshold = false;
  };

  // observed snapshot difference，不是分配事件轨迹；两次扫描间的短命分配不可见。
  // VirtualQuery 扫描也不是原子快照，期间的地址变化只能在后续完整扫描反映。
  struct Change {
    std::string kind;  // created / changed / released
    uint64_t id = 0;
    Allocation before;
    Allocation after;
  };

  struct Snapshot {
    std::string status = "disabled";  // disabled / warmingUp / sampled / error
    bool enabled = false;
    bool complete = false;
    uint64_t sample_id = 0;
    uint64_t tick_ms = 0;  // GetTickCount64，扫描开始时刻
    uint64_t scan_duration_us = 0;
    uint64_t scan_interval_ms = 0;  // 相邻扫描开始间隔；首扫为 0
    uint32_t configured_interval_ms = 5000;
    uint32_t error_code = 0;
    uint64_t queried_region_count = 0;
    uint64_t allocation_count = 0;
    uint64_t eligible_allocation_count = 0;
    uint64_t eligible_allocation_bytes = 0;
    uint64_t eligible_committed_bytes = 0;
    uint64_t eligible_reserved_bytes = 0;
    uint64_t omitted_allocation_count = 0;
    uint64_t omitted_allocation_bytes = 0;
    uint64_t omitted_committed_bytes = 0;
    uint64_t omitted_reserved_bytes = 0;
    uint64_t created_count = 0;
    uint64_t changed_count = 0;
    uint64_t released_count = 0;
    uint64_t event_overflow = 0;  // changes 未列出的快照差分数量
    bool truncated = false;
    Counters totals;
    // 已跟踪项直到观测到消失才释放 ID；新候选按块大小选取。
    // 小于阈值的既有项仍保留，以上标志区分；按 committed、总大小降序排列。
    std::vector<Allocation> allocations;
    // 仅当前 sample_id 的差分，不累计；消费者按 sample_id 去重。
    std::vector<Change> changes;
  };

  MemoryMetrics();
  explicit MemoryMetrics(Options options);
  ~MemoryMetrics();
  MemoryMetrics(const MemoryMetrics&) = delete;
  MemoryMetrics& operator=(const MemoryMetrics&) = delete;

  void Start();
  void Stop();
  Snapshot ReadCachedSnapshot() const;

 private:
  struct Observed {
    uintptr_t base = 0;  // 只在扫描器内部使用，永不进入公开快照。
    Allocation allocation;
  };
  struct Tracked {
    Allocation allocation;
  };

  void Run();
  Snapshot Scan(uint64_t previous_tick);
  void ApplyObservation(Snapshot& snapshot,
                        const std::map<uintptr_t, Allocation>& existing,
                        std::vector<Observed>& candidates);

  const Options options_;
  std::atomic<bool> stopping_{true};
  std::thread worker_;
  mutable std::mutex mutex_;
  std::condition_variable wake_;
  Snapshot latest_;
  // 以下状态仅由 worker 访问。Start 新一轮清空身份映射，但不复用数值 ID。
  std::map<uintptr_t, Tracked> tracked_;
  uint64_t next_id_ = 1;
  uint64_t sample_id_ = 0;
};

#endif  // RUNNER_MEMORY_METRICS_H_
