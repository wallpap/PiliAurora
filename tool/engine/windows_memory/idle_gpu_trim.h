// Copyright 2026 PiliAurora contributors.
// SPDX-License-Identifier: BSD-3-Clause
#ifndef FLUTTER_SHELL_PLATFORM_WINDOWS_IDLE_GPU_TRIM_H_
#define FLUTTER_SHELL_PLATFORM_WINDOWS_IDLE_GPU_TRIM_H_

#include <atomic>
#include <chrono>
#include <functional>
#include <memory>

namespace flutter {

// OnPresent/定时回调仅运行于 raster 线程；Cancel 允许在关闭线程调用。
class IdleGpuTrim final : public std::enable_shared_from_this<IdleGpuTrim> {
 public:
  using Time = std::chrono::milliseconds;
  using Task = std::function<void()>;
  using Now = std::function<Time()>;
  using Schedule = std::function<bool(Time, Task)>;
  using Trim = std::function<bool()>;
  struct Stats {
    uint64_t presents, attempts, issued;
    int64_t last_present_age_ms, last_trim_age_ms, last_duration_us;
    bool cancelled, timer_pending;
  };

  static std::shared_ptr<IdleGpuTrim> Create(Now now, Schedule schedule, Trim trim,
                                             Time delay = Time(10000)) {
    return std::shared_ptr<IdleGpuTrim>(
        new IdleGpuTrim(std::move(now), std::move(schedule), std::move(trim), delay));
  }
  void OnPresent() {
    if (cancelled_.load()) return;
    const auto now = now_();
    last_present_ms_.store(now.count());
    presents_.fetch_add(1);
    deadline_ = now + delay_;
    if (!pending_) {
      pending_ = true;
      ScheduleTimer(delay_);
    }
  }
  void Cancel() { cancelled_.store(true); }
  // 只读取独立原子字段；不触发回收，不更改原有 deadline 或重排 timer。
  Stats Sample() const {
    const auto present = last_present_ms_.load();
    const auto trim = last_trim_ms_.load();
    const auto now = now_().count();
    return {presents_.load(), attempts_.load(), issued_.load(),
            present < 0 ? -1 : now - present, trim < 0 ? -1 : now - trim,
            last_duration_us_.load(), cancelled_.load(), pending_.load()};
  }

 private:
  IdleGpuTrim(Now now, Schedule schedule, Trim trim, Time delay)
      : now_(std::move(now)), schedule_(std::move(schedule)),
        trim_(std::move(trim)), delay_(delay) {}
  void ScheduleTimer(Time delay) {
    const std::weak_ptr<IdleGpuTrim> weak = shared_from_this();
    if (!schedule_(delay, [weak] {
          if (auto state = weak.lock()) state->OnTimer();
        })) {
      pending_ = false;
      Cancel();
    }
  }
  void OnTimer() {
    if (cancelled_.load()) return;
    const auto now = now_();
    if (now < deadline_) {
      // 新帧只更新截止时刻；原定时器醒来后重排，不按帧追加任务。
      ScheduleTimer(deadline_ - now);
      return;
    }
    pending_ = false;
    attempts_.fetch_add(1);
    const auto started = std::chrono::steady_clock::now();
    const bool issued = trim_();
    last_duration_us_.store(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - started).count());
    if (issued) {
      issued_.fetch_add(1);
      last_trim_ms_.store(now_().count());
    } else {
      Cancel();
    }
  }
  Now now_;
  Schedule schedule_;
  Trim trim_;
  const Time delay_;
  Time deadline_{0};
  std::atomic_bool pending_{false};
  std::atomic_bool cancelled_{false};
  std::atomic_uint64_t presents_{0}, attempts_{0}, issued_{0};
  std::atomic_int64_t last_present_ms_{-1}, last_trim_ms_{-1}, last_duration_us_{-1};
};

}  // namespace flutter
#endif  // FLUTTER_SHELL_PLATFORM_WINDOWS_IDLE_GPU_TRIM_H_
