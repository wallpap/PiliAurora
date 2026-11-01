// SPDX-License-Identifier: BSD-3-Clause
#include "idle_gpu_trim.h"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
void Check(bool value, const char* message) {
  if (!value) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}
struct Harness {
  using Time = flutter::IdleGpuTrim::Time;
  struct Job { Time at; flutter::IdleGpuTrim::Task callback; };
  Time now{0};
  std::vector<Job> jobs;
  size_t max_queued = 0;
  int trims = 0;
  bool device_alive = true;
  std::shared_ptr<flutter::IdleGpuTrim> Create() {
    return flutter::IdleGpuTrim::Create(
        [this] { return now; },
        [this](Time delay, flutter::IdleGpuTrim::Task task) {
          jobs.push_back({now + delay, std::move(task)});
          max_queued = std::max(max_queued, jobs.size());
          return true;
        },
        [this] { ++trims; return device_alive; });
  }
  void Advance(int milliseconds) {
    const auto target = now + Time(milliseconds);
    while (!jobs.empty()) {
      const auto next = std::min_element(jobs.begin(), jobs.end(),
          [](const auto& a, const auto& b) { return a.at < b.at; });
      if (next->at > target) break;
      now = next->at;
      auto callback = std::move(next->callback);
      jobs.erase(next);
      callback();
    }
    now = target;
  }
};

void ContinuousFramesThenIdleAndResume() {
  Harness h;
  auto state = h.Create();
  for (int i = 0; i < 1800; ++i) {
    state->OnPresent();
    h.Advance(16);
  }
  Check(h.trims == 0, "active video/animation must not trim");
  Check(state->Sample().presents == 1800 && state->Sample().issued == 0,
        "read-only counters must observe real presents without issuing Trim");
  Check(h.max_queued <= 1, "must keep only one timer, not one per frame");
  h.Advance(9983); // Last frame was at 28784ms; deadline is 38784ms.
  Check(h.trims == 0, "must wait full ten seconds after final present");
  h.Advance(1);
  Check(h.trims == 1, "idle ten seconds must trim exactly once");
  const auto idle_stats = state->Sample();
  Check(idle_stats.attempts == 1 && idle_stats.issued == 1 &&
        idle_stats.last_present_age_ms == 10000 && !idle_stats.timer_pending,
        "issued accounting and ten-second age must match actual callback");
  h.Advance(60000);
  Check(h.trims == 1 && h.jobs.empty(), "idle must not periodically retrim");
  state->OnPresent();
  h.Advance(10000);
  Check(h.trims == 2, "new successful frame must arm a new idle interval");
  Check(state->Sample().issued == 2, "resumed cycle must increment issued count");
}

void SharedViewsAndCancellation() {
  Harness h;
  auto state = h.Create();
  const auto view_a_present = [&] { state->OnPresent(); };
  const auto view_b_present = [&] { state->OnPresent(); };
  view_a_present();
  h.Advance(9000);
  view_b_present();
  h.Advance(9000);
  Check(h.trims == 0, "second view activity must defer engine-wide trimming");
  h.Advance(1000);
  Check(h.trims == 1, "all views idle must trim once");
  view_a_present();
  state->Cancel();
  h.Advance(20000);
  state->OnPresent();
  h.Advance(10000);
  Check(h.trims == 1, "Stop must cancel both pending and future callbacks");
  Check(state->Sample().cancelled && state->Sample().issued == 1,
        "Stop observation must report cancelled and retain issued history");
  auto restarted = h.Create();
  restarted->OnPresent();
  h.Advance(10000);
  Check(h.trims == 2, "restart must use independent active state");
  restarted->OnPresent();
  restarted.reset();
  h.Advance(10000);
  Check(h.trims == 2, "delayed tasks must not extend engine/state lifetime");
}

void DeviceLossStopsFurtherRequests() {
  Harness h;
  auto state = h.Create();
  h.device_alive = false;
  state->OnPresent();
  h.Advance(10000);
  state->OnPresent();
  h.Advance(10000);
  Check(h.trims == 1, "failed device must disable future trim attempts");
  Check(state->Sample().attempts == 1 && state->Sample().issued == 0,
        "failed device check is an attempt, not an issued Trim");
}
}  // namespace

int main() {
  ContinuousFramesThenIdleAndResume();
  SharedViewsAndCancellation();
  DeviceLossStopsFurtherRequests();
  std::cout << "idle_gpu_trim: 3 regression scenarios passed\n";
}
