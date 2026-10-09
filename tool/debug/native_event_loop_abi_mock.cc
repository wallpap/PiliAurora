// Host-only fixture. No real mpv, Flutter, ANGLE, or player library is linked.
#include <client.h>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>

#if defined(_WIN32)
#define EXPORT extern "C" __declspec(dllexport)
#else
#define EXPORT extern "C" __attribute__((visibility("default")))
#endif

struct MockHandle {
  std::mutex mutex;
  std::condition_variable ready;
  bool first = true;
  bool woken = false;
  bool destroyed = false;
  mpv_event event{};
};
static std::atomic<int> state[16]{};
EXPORT int MockState(int field) { return state[field].load(); }
EXPORT mpv_handle* mpv_create() {
  state[8]++;
  return reinterpret_cast<mpv_handle*>(new MockHandle());
}
EXPORT int mpv_set_option_string(mpv_handle*, const char*, const char*) { return 0; }
EXPORT int mpv_initialize(mpv_handle*) { return 0; }
EXPORT mpv_event* mpv_wait_event(mpv_handle* handle, double) {
  auto mock = reinterpret_cast<MockHandle*>(handle);
  std::unique_lock<std::mutex> lock(mock->mutex);
  state[10]++;
  if (mock->destroyed) { state[12]++; return &mock->event; }
  if (mock->first) {
    mock->first = false;
    mock->event.event_id = MPV_EVENT_LOG_MESSAGE;
    mock->event.reply_userdata = 123;
    return &mock->event;
  }
  mock->ready.wait(lock, [&]() { return mock->woken; });
  mock->woken = false;
  mock->event = {};
  return &mock->event;
}
EXPORT void mpv_wakeup(mpv_handle* handle) {
  auto mock = reinterpret_cast<MockHandle*>(handle);
  std::lock_guard<std::mutex> lock(mock->mutex);
  state[11]++;
  mock->woken = true;
  mock->ready.notify_all();
}
EXPORT void mpv_terminate_destroy(mpv_handle* handle) {
  auto mock = reinterpret_cast<MockHandle*>(handle);
  std::lock_guard<std::mutex> lock(mock->mutex);
  state[9]++;
  mock->destroyed = true;
  // Intentionally retain this tiny fixture so a stale read can be counted,
  // without reproducing a real use-after-free or showing a CRT assertion UI.
}
EXPORT void mpv_set_wakeup_callback(mpv_handle*, void (*callback)(void*), void*) {
  state[4] += callback ? 1 : 0;
  state[5] += callback ? 0 : 1;
}
#if defined(MOCK_LEGACY_ABI)
EXPORT void MediaKitEventLoopHandlerInitialize(void* post, int64_t port) {
  state[0]++;
  state[1] = post && port == 123;
}
EXPORT void MediaKitEventLoopHandlerCallback(void*) {}
#else
EXPORT void MediaKitEventLoopHandlerInitialize() { state[0]++; }
EXPORT void MediaKitEventLoopHandlerRegister(int64_t handle, void* post, int64_t port) {
  state[2]++;
  state[3] = handle == 42 && post && port == 123;
}
EXPORT void MediaKitEventLoopHandlerNotify(int64_t handle) { if (handle == 42) state[6]++; }
EXPORT void MediaKitEventLoopHandlerDispose(int64_t handle) { if (handle == 42) state[7]++; }
#endif
