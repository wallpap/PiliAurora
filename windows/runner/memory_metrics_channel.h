#ifndef RUNNER_MEMORY_METRICS_CHANNEL_H_
#define RUNNER_MEMORY_METRICS_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "memory_metrics.h"

class MemoryMetricsChannel {
 public:
  explicit MemoryMetricsChannel(flutter::FlutterEngine* engine);
  ~MemoryMetricsChannel();
 private:
  MemoryMetrics metrics_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
