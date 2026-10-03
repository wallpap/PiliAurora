#pragma once
#include <windows.h>
// 只为真实 main.cpp 插入顺序探针；实现仍调用真实 CoUninitialize。
void WINAPI RecordCoUninitialize();
#define CoUninitialize RecordCoUninitialize
