#include "gpu_metrics.h"
#include <Windows.h>
#include <dxgi1_4.h>
#include <pdh.h>
#include <pdhmsg.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdio>
#include <vector>
using flutter::EncodableValue;
using flutter::EncodableMap;
using flutter::EncodableList;
using Microsoft::WRL::ComPtr;
namespace {
std::string Luid(LUID id) {
  char value[32];
  sprintf_s(value, "0x%08x_0x%08x", static_cast<unsigned>(id.HighPart), id.LowPart);
  return value;
}
std::string Utf8(const wchar_t* text) {
  int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), size, nullptr, nullptr);
  result.pop_back();
  return result;
}
void Memory(EncodableMap& out, IDXGIAdapter3* adapter,
            DXGI_MEMORY_SEGMENT_GROUP group, const char* key) {
  DXGI_QUERY_VIDEO_MEMORY_INFO info{};
  HRESULT hr = adapter->QueryVideoMemoryInfo(0, group, &info);
  EncodableMap data{{EncodableValue("status"), EncodableValue(static_cast<int64_t>(hr))}};
  if (SUCCEEDED(hr)) {
    data[EncodableValue("usageBytes")] = EncodableValue(static_cast<int64_t>(info.CurrentUsage));
    data[EncodableValue("budgetBytes")] = EncodableValue(static_cast<int64_t>(info.Budget));
  }
  out[EncodableValue(key)] = EncodableValue(data);
}
}
GpuMetrics::GpuMetrics(flutter::FlutterEngine* engine) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), "pili_aurora/windows_gpu", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this, engine](const auto& call, auto result) {
    if (call.method_name() == "start") {
      Stop();
      ComPtr<IDXGIAdapter> adapter;
      flutter_luid_.clear();
      if (engine->GetGraphicsAdapter(adapter.GetAddressOf())) {
        DXGI_ADAPTER_DESC desc{};
        if (SUCCEEDED(adapter->GetDesc(&desc))) flutter_luid_ = Luid(desc.AdapterLuid);
      }
      { std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = false;
        latest_ = {{EncodableValue("status"), EncodableValue("warmingUp")}};
      }
      worker_ = std::thread(&GpuMetrics::Run, this);
      result->Success();
    } else if (call.method_name() == "stop") {
      Stop();
      result->Success();
    } else if (call.method_name() == "sample") {
      std::lock_guard<std::mutex> lock(mutex_);
      auto sample = latest_;
      sample[EncodableValue("readTickMs")] = EncodableValue(static_cast<int64_t>(GetTickCount64()));
      result->Success(EncodableValue(sample));
    } else {
      result->NotImplemented();
    }
  });
}
GpuMetrics::~GpuMetrics() { Stop(); }
void GpuMetrics::Stop() {
  { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; }
  wake_.notify_all();
  if (worker_.joinable()) worker_.join();
}
void GpuMetrics::Run() {
  PDH_HQUERY query = nullptr;
  PDH_HCOUNTER counter = nullptr;
  // 在PDH端限定本进程，避免为最终会被丢弃的其它进程格式化整个GPU数组。
  const std::wstring counter_path =
      L"\\GPU Engine(pid_" + std::to_wstring(GetCurrentProcessId()) +
      L"_*)\\Utilization Percentage";
  PDH_STATUS status = PdhOpenQueryW(nullptr, 0, &query);
  if (status == ERROR_SUCCESS)
    status = PdhAddEnglishCounterW(query, counter_path.c_str(), 0, &counter);
  if (status == ERROR_SUCCESS) status = PdhCollectQueryData(query);
  bool baseline = false;
  auto previous = GetTickCount64();
  const std::string prefix = "pid_" + std::to_string(GetCurrentProcessId()) + "_";
  for (;;) {
    { std::unique_lock<std::mutex> lock(mutex_);
      if (wake_.wait_for(lock, std::chrono::seconds(1), [this] { return stopping_; })) break;
    }
    auto now = GetTickCount64();
    EncodableMap engines;
    PDH_STATUS collected = counter ? PdhCollectQueryData(query) : status;
    DWORD bytes = 0, count = 0;
    PDH_STATUS formatted = collected;
    if (collected == ERROR_SUCCESS && baseline) {
      formatted = PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE, &bytes, &count, nullptr);
      if (formatted == PDH_MORE_DATA && bytes > 0) {
        std::vector<unsigned char> buffer(bytes);
        auto items = reinterpret_cast<PDH_FMT_COUNTERVALUE_ITEM_W*>(buffer.data());
        formatted = PdhGetFormattedCounterArrayW(counter, PDH_FMT_DOUBLE, &bytes, &count, items);
        if (formatted == ERROR_SUCCESS) {
          for (DWORD i = 0; i < count; ++i) {
            auto name = Utf8(items[i].szName);
            const auto& value = items[i].FmtValue;
            if (name.rfind(prefix, 0) != 0 ||
                (value.CStatus != PDH_CSTATUS_VALID_DATA && value.CStatus != PDH_CSTATUS_NEW_DATA) ||
                !std::isfinite(value.doubleValue)) continue;
            auto pos = name.find("luid_");
            if (pos == std::string::npos) continue;
            auto end = name.find("_phys_", pos);
            if (end == std::string::npos) continue;
            auto id = name.substr(pos + 5, end - pos - 5);
            // PDH 的十六进制字母通常大写，统一为 DXGI 标识的格式。
            std::transform(id.begin(), id.end(), id.begin(),
                           [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
            auto key = EncodableValue(id);
            if (engines.find(key) == engines.end()) engines[key] = EncodableValue(EncodableMap{});
            auto& values = std::get<EncodableMap>(engines[key]);
            values[EncodableValue(name.substr(end + 1))] =
                EncodableValue(std::clamp(value.doubleValue, 0.0, 100.0));
          }
        }
      }
    }
    EncodableList adapters;
    ComPtr<IDXGIFactory1> factory;
    HRESULT factory_status = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (SUCCEEDED(factory_status)) {
      for (UINT i = 0; ; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        HRESULT hr = factory->EnumAdapters1(i, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) break;
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(adapter->GetDesc1(&desc))) continue;
        auto id = Luid(desc.AdapterLuid);
        EncodableMap data{
          {EncodableValue("luid"), EncodableValue(id)},
          {EncodableValue("name"), EncodableValue(Utf8(desc.Description))},
          {EncodableValue("flutterUi"), EncodableValue(id == flutter_luid_)},
          {EncodableValue("vendorId"), EncodableValue(static_cast<int64_t>(desc.VendorId))},
          {EncodableValue("deviceId"), EncodableValue(static_cast<int64_t>(desc.DeviceId))}
        };
        ComPtr<IDXGIAdapter3> memory;
        if (SUCCEEDED(adapter.As(&memory))) {
          Memory(data, memory.Get(), DXGI_MEMORY_SEGMENT_GROUP_LOCAL, "local");
          Memory(data, memory.Get(), DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL, "nonLocal");
        } else {
          data[EncodableValue("memoryStatus")] = EncodableValue("unsupported");
        }
        auto engine = engines.find(EncodableValue(id));
        if (engine != engines.end()) data[EncodableValue("engines")] = engine->second;
        double busiest = 0;
        if (engine != engines.end()) {
          for (const auto& entry : std::get<EncodableMap>(engine->second))
            busiest = std::max(busiest, std::get<double>(entry.second));
          data[EncodableValue("busiestEnginePercent")] = EncodableValue(busiest);
        }
        bool used = id == flutter_luid_ || busiest > 0;
        for (const char* group : {"local", "nonLocal"}) {
          auto found = data.find(EncodableValue(group));
          if (found == data.end()) continue;
          const auto& values = std::get<EncodableMap>(found->second);
          auto usage = values.find(EncodableValue("usageBytes"));
          if (usage != values.end() && std::get<int64_t>(usage->second) > 0) used = true;
        }
        data[EncodableValue("usedByProcess")] = EncodableValue(used);
        adapters.emplace_back(data);
      }
    }
    EncodableMap sample{
      {EncodableValue("pid"), EncodableValue(static_cast<int64_t>(GetCurrentProcessId()))},
      {EncodableValue("status"), EncodableValue(collected != ERROR_SUCCESS ? "unavailable" : (baseline ? "sampled" : "warmingUp"))},
      {EncodableValue("pdhStatus"), EncodableValue(static_cast<int64_t>(formatted))},
      {EncodableValue("dxgiStatus"), EncodableValue(static_cast<int64_t>(factory_status))},
      {EncodableValue("sampleTickMs"), EncodableValue(static_cast<int64_t>(now))},
      {EncodableValue("windowMs"), EncodableValue(static_cast<int64_t>(now - previous))},
      {EncodableValue("adapters"), EncodableValue(adapters)}
    };
    { std::lock_guard<std::mutex> lock(mutex_); latest_ = std::move(sample); }
    baseline = collected == ERROR_SUCCESS;
    previous = now;
  }
  if (query) PdhCloseQuery(query);
}

