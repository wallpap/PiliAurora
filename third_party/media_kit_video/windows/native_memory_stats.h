#ifndef MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_
#define MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace media_kit_memory {
enum class Resource { output, render_context, device, egl_context, egl_surface,
                      texture, software_buffer, count };
struct ResourceStats {
  int64_t count = 0, created = 0, released = 0, estimated_bytes = 0;
};
struct Snapshot {
  std::array<ResourceStats, static_cast<size_t>(Resource::count)> resources{};
  int64_t releasing_outputs = 0, pending_texture_unregistrations = 0;
};

// 只在资源生命周期边界更新；不挂钩分配器、不访问驱动，也不在逐帧路径计数。
class Registry {
 public:
  static Registry& Instance() {
    static Registry registry;
    return registry;
  }
  Snapshot Read() {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_;
  }
  void Change(Resource resource, int64_t count, int64_t bytes) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto& value = snapshot_.resources[static_cast<size_t>(resource)];
    value.count += count;
    value.estimated_bytes += bytes;
    if (count > 0) value.created += count;
    if (count < 0) value.released -= count;
  }
  void ReleasingOutput(int64_t delta) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_.releasing_outputs += delta;
  }
  void PendingTextureUnregistration(int64_t delta) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_.pending_texture_unregistrations += delta;
  }
 private:
  std::mutex mutex_;
  Snapshot snapshot_;
};

// 与真实持有者共寿命，保证构造失败、部分创建及重复清理不会遗留计数。
class ResourceRecord {
 public:
  explicit ResourceRecord(Resource kind) : kind_(kind) {}
  ~ResourceRecord() { Reset(); }
  ResourceRecord(const ResourceRecord&) = delete;
  ResourceRecord& operator=(const ResourceRecord&) = delete;
  void Set(int64_t count, int64_t bytes = 0) {
    Registry::Instance().Change(kind_, count - count_, bytes - bytes_);
    count_ = count;
    bytes_ = bytes;
  }
  void Reset() { Set(0); }
 private:
  const Resource kind_;
  int64_t count_ = 0, bytes_ = 0;
};

class OutputLifetime {
 public:
  OutputLifetime() { output_.Set(1); }
  ~OutputLifetime() {
    if (releasing_) Registry::Instance().ReleasingOutput(-1);
  }
  void BeginRelease() {
    if (!releasing_) {
      releasing_ = true;
      Registry::Instance().ReleasingOutput(1);
    }
  }
 private:
  ResourceRecord output_{Resource::output};
  bool releasing_ = false;
};
}  // namespace media_kit_memory
#endif
