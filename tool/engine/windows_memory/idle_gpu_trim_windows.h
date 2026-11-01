// Copyright 2026 PiliAurora contributors.
// SPDX-License-Identifier: BSD-3-Clause
#ifndef FLUTTER_SHELL_PLATFORM_WINDOWS_IDLE_GPU_TRIM_WINDOWS_H_
#define FLUTTER_SHELL_PLATFORM_WINDOWS_IDLE_GPU_TRIM_WINDOWS_H_

#include <d3d11.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

#include "flutter/fml/message_loop.h"
#include "flutter/fml/message_loop_task_queues.h"
#include "flutter/shell/platform/windows/idle_gpu_trim.h"

#define PILIAURORA_HAS_IDLE_GPU_TRIM 1

namespace flutter {

// 从 platform 线程取得真实设备；任务只持有 COM 设备引用，不持有 engine。
inline std::shared_ptr<IdleGpuTrim> CreateWindowsIdleGpuTrim(ID3D11Device* device) {
  if (!device || (device->GetCreationFlags() & D3D11_CREATE_DEVICE_SINGLETHREADED)) {
    return nullptr;
  }
  Microsoft::WRL::ComPtr<IDXGIDevice3> dxgi;
  if (FAILED(device->QueryInterface(IID_PPV_ARGS(&dxgi)))) return nullptr;
  Microsoft::WRL::ComPtr<ID3D11Device> retained_device(device);
  return IdleGpuTrim::Create(
      [] {
        return std::chrono::duration_cast<IdleGpuTrim::Time>(
            std::chrono::steady_clock::now().time_since_epoch());
      },
      [](IdleGpuTrim::Time delay, IdleGpuTrim::Task callback) {
        if (!fml::MessageLoop::IsInitializedForCurrentThread()) return false;
        // 不在自己的任务闭包中捕获 runner，以免关闭阶段形成循环引用。
        fml::MessageLoopTaskQueues::GetInstance()->RegisterTask(
            fml::MessageLoop::GetCurrentTaskQueueId(), std::move(callback),
            fml::TimePoint::Now() + fml::TimeDelta::FromMilliseconds(delay.count()));
        return true;
      },
      [device = std::move(retained_device), dxgi = std::move(dxgi)] {
        if (FAILED(device->GetDeviceRemovedReason())) return false;
        dxgi->Trim();
        return true;
      });
}

}  // namespace flutter
#endif  // FLUTTER_SHELL_PLATFORM_WINDOWS_IDLE_GPU_TRIM_WINDOWS_H_
