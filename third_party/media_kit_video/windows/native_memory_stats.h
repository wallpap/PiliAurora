#ifndef MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_
#define MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace media_kit_memory {
enum class Resource { output, render_context, device, egl_context, egl_surface,
                      texture, software_buffer, texture_registration, count };
struct ResourceStats {
  int64_t count = 0, created = 0, released = 0, estimated_bytes = 0;
};
struct Snapshot {
  std::array<ResourceStats, static_cast<size_t>(Resource::count)> resources{};
  int64_t releasing_outputs = 0, pending_texture_unregistrations = 0;
};
struct OwnerSnapshot : Snapshot {
  int64_t id = 0, runtime_id = 0, load_id = 0;
};
struct OwnershipSnapshot {
  static constexpr size_t max_owners = 8;
  std::array<OwnerSnapshot, max_owners> owners{};
  int64_t omitted_owners = 0;
};
struct FullSnapshot {
  Snapshot totals;
  OwnershipSnapshot ownership;
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
  OwnershipSnapshot ReadOwners() {
    std::lock_guard<std::mutex> lock(mutex_);
    return ownership_;
  }
  FullSnapshot ReadAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    return {snapshot_, ownership_};
  }
  int64_t RegisterOwner() {
    std::lock_guard<std::mutex> lock(mutex_);
    const int64_t id = ++next_owner_;
    for (auto& owner : ownership_.owners) {
      if (!owner.id) {
        owner = OwnerSnapshot{};
        owner.id = id;
        return id;
      }
    }
    ++ownership_.omitted_owners;
    return id;
  }
  void UnregisterOwner(int64_t id) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (auto* owner = FindOwner(id)) {
      *owner = OwnerSnapshot{};
    } else {
      --ownership_.omitted_owners;
    }
  }
  void BindOwner(int64_t id, int64_t runtime, int64_t load) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (auto* owner = FindOwner(id)) {
      owner->runtime_id = runtime;
      owner->load_id = load;
    }
  }
  void Change(Resource resource, int64_t count, int64_t bytes, int64_t owner_id = 0) {
    std::lock_guard<std::mutex> lock(mutex_);
    Update(snapshot_.resources[static_cast<size_t>(resource)], count, bytes);
    if (auto* owner = FindOwner(owner_id)) {
      Update(owner->resources[static_cast<size_t>(resource)], count, bytes);
    }
  }
  void ReleasingOutput(int64_t delta, int64_t owner_id = 0) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_.releasing_outputs += delta;
    if (auto* owner = FindOwner(owner_id)) owner->releasing_outputs += delta;
  }
  void PendingTextureUnregistration(int64_t delta, int64_t owner_id = 0) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshot_.pending_texture_unregistrations += delta;
    if (auto* owner = FindOwner(owner_id)) owner->pending_texture_unregistrations += delta;
  }
 private:
  static void Update(ResourceStats& value, int64_t count, int64_t bytes) {
    value.count += count;
    value.estimated_bytes += bytes;
    if (count > 0) value.created += count;
    if (count < 0) value.released -= count;
  }
  OwnerSnapshot* FindOwner(int64_t id) {
    if (!id) return nullptr;
    for (auto& owner : ownership_.owners) {
      if (owner.id == id) return &owner;
    }
    return nullptr;
  }
  std::mutex mutex_;
  Snapshot snapshot_;
  OwnershipSnapshot ownership_;
  int64_t next_owner_ = 0;
};

// 与真实持有者共寿命，保证构造失败、部分创建及重复清理不会遗留计数。
class ResourceRecord {
 public:
  explicit ResourceRecord(Resource kind, int64_t owner_id = 0)
      : kind_(kind), owner_id_(owner_id) {}
  ~ResourceRecord() { Reset(); }
  ResourceRecord(const ResourceRecord&) = delete;
  ResourceRecord& operator=(const ResourceRecord&) = delete;
  void Set(int64_t count, int64_t bytes = 0) {
    Registry::Instance().Change(kind_, count - count_, bytes - bytes_, owner_id_);
    count_ = count;
    bytes_ = bytes;
  }
  void Reset() { Set(0); }
 private:
  const Resource kind_;
  const int64_t owner_id_;
  int64_t count_ = 0, bytes_ = 0;
};

class OutputLifetime {
 public:
  OutputLifetime() : id_(Registry::Instance().RegisterOwner()), output_(Resource::output, id_) {
    output_.Set(1);
  }
  ~OutputLifetime() {
    if (releasing_) Registry::Instance().ReleasingOutput(-1, id_);
    output_.Reset();
    Registry::Instance().UnregisterOwner(id_);
  }
  OutputLifetime(const OutputLifetime&) = delete;
  OutputLifetime& operator=(const OutputLifetime&) = delete;
  int64_t id() const { return id_; }
  void Bind(int64_t runtime, int64_t load) { Registry::Instance().BindOwner(id_, runtime, load); }
  void BeginRelease() {
    if (!releasing_) {
      releasing_ = true;
      Registry::Instance().ReleasingOutput(1, id_);
    }
  }
 private:
  const int64_t id_;
  ResourceRecord output_;
  bool releasing_ = false;
};
}  // namespace media_kit_memory
#endif
