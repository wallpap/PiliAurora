cmake_minimum_required(VERSION 3.14)
project(runner_lifecycle_tests LANGUAGES CXX)
get_filename_component(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(EPHEMERAL "${ROOT}/windows/flutter/ephemeral")
add_executable(runner_lifecycle_test runner_lifecycle_test.cpp
  "${ROOT}/windows/runner/flutter_window.cpp"
  "${ROOT}/windows/runner/win32_window.cpp"
  "${ROOT}/windows/runner/main.cpp")
target_compile_features(runner_lifecycle_test PRIVATE cxx_std_17)
target_compile_definitions(runner_lifecycle_test PRIVATE NOMINMAX UNICODE _UNICODE wWinMain=RunnerEntryPoint)
target_compile_options(runner_lifecycle_test PRIVATE /W4 /WX /wd4100 /EHsc)
target_include_directories(runner_lifecycle_test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/stubs" "${ROOT}/windows"
  "${ROOT}/windows/runner" "${EPHEMERAL}" "${EPHEMERAL}/cpp_client_wrapper/include")
target_link_libraries(runner_lifecycle_test PRIVATE
  "${ROOT}/build/windows/x64/flutter/Profile/flutter_wrapper_app.lib"
  "${EPHEMERAL}/flutter_windows.dll.lib" dwmapi ole32)

set_source_files_properties("${ROOT}/windows/runner/main.cpp" PROPERTIES
  COMPILE_OPTIONS "/FI${CMAKE_CURRENT_SOURCE_DIR}/com_lifetime_probe.h")
