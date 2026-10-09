#!/usr/bin/env python3
"""Compile the actual platform-thread dispatcher with a fake Windows registrar."""
import argparse
from pathlib import Path
import subprocess

FAKE = r"""
#pragma once
#include <functional>
#include <optional>
#include <cstdint>
using HWND=void*;using UINT=unsigned;using WPARAM=uintptr_t;using LPARAM=intptr_t;using LRESULT=intptr_t;
constexpr int GA_ROOT=2;
static UINT posted_message=0;
static HWND actual_root=nullptr,posted_window=nullptr;
inline HWND GetAncestor(HWND w,int) {return actual_root ? actual_root : w;}
inline UINT RegisterWindowMessageW(const wchar_t*) {return 0xc001;}
inline bool PostMessageW(HWND w,UINT msg,WPARAM,LPARAM) {posted_window=w;posted_message=msg;return true;}
namespace flutter {
struct FakeView {HWND GetNativeWindow() {return this;}};
struct PluginRegistrarWindows {
  using Delegate=std::function<std::optional<LRESULT>(HWND,UINT,WPARAM,LPARAM)>;
  FakeView view;Delegate delegate;
  FakeView* GetView() {return &view;}
  int RegisterTopLevelWindowProcDelegate(Delegate d) {delegate=std::move(d);return 1;}
  void UnregisterTopLevelWindowProcDelegate(int) {delegate=nullptr;}
  void Drain() {if(delegate&&posted_window==actual_root) delegate(nullptr,posted_message,0,0);}
};
}
"""
MAIN = r"""
#include "platform_thread_dispatcher.h"
#include <iostream>
#include <thread>
#include <vector>
int main() {
  flutter::PluginRegistrarWindows registrar;
  PlatformThreadDispatcher::PostTask retained;
  std::vector<int> events;
  const auto platform=std::this_thread::get_id();
  bool correct_thread=true;
  {
    PlatformThreadDispatcher dispatcher(&registrar);
    retained=dispatcher.post();
    // Flutter registers plugins before parenting its view into the runner.
    int runner=0;actual_root=&runner;
    std::thread worker([&] {
      retained([&]{correct_thread &= std::this_thread::get_id()==platform;events.push_back(1);});
      retained([&]{events.push_back(2);});
    });worker.join();
    if(!events.empty()) return 1;
    registrar.Drain();
    if(events!=std::vector<int>{1,2}||!correct_thread) {
      std::cout<<"FAIL callback targeted the unparented registration-time Flutter view\n";
      return 2;
    }
    std::cout<<"PASS callback follows the view's current runner after plugin registration\n";
    registrar.Drain();
    if(events.size()!=2) return 3;
    retained([&]{events.push_back(3);});
  }
  retained([&]{events.push_back(4);});
  registrar.Drain();
  if(events!=std::vector<int>{1,2}) return 4;
  std::cout<<"PASS worker callbacks run in order only on platform thread\n"
           <<"PASS duplicate messages cannot replay callbacks\n"
           <<"PASS shutdown discards queued and late tasks without dangling pointers\n";
}
"""

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler',default='g++')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    build=root/'build/windows-playback-diagnosis/dispatcher-probe'
    (build/'flutter').mkdir(parents=True,exist_ok=True)
    (build/'flutter/plugin_registrar_windows.h').write_text(FAKE,encoding='utf-8')
    fixture=build/'dispatcher_probe.cc';fixture.write_text(MAIN,encoding='utf-8')
    binary=build/'dispatcher_probe.exe'
    subprocess.run([args.compiler,'-std=c++17','-static-libgcc','-static-libstdc++','-I',str(build),'-I',str(root/'third_party/media_kit_video/windows'),str(fixture),'-o',str(binary)],check=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)

if __name__=='__main__':main()
