cmake_minimum_required(VERSION 3.14)
project(piliaurora_image_worker LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../third_party/libwebp"
  "${CMAKE_CURRENT_BINARY_DIR}/libwebp")
add_executable(piliaurora_image_worker WIN32 image_worker.cc)
target_compile_features(piliaurora_image_worker PRIVATE cxx_std_17)
target_compile_options(piliaurora_image_worker PRIVATE /W4 /WX /EHsc /utf-8)
target_link_options(piliaurora_image_worker PRIVATE /ENTRY:wmainCRTStartup)
target_link_libraries(piliaurora_image_worker PRIVATE piliaurora_webp
  windowscodecs ole32 propsys psapi)
install(TARGETS piliaurora_image_worker RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_LIST_DIR}/../../third_party/libwebp/LICENSE"
  "${CMAKE_CURRENT_LIST_DIR}/../../third_party/libwebp/PATENTS"
  "${CMAKE_CURRENT_LIST_DIR}/../../third_party/libwebp/AUTHORS"
  "${CMAKE_CURRENT_LIST_DIR}/../../third_party/libwebp/SOURCE.json"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/licenses/libwebp" COMPONENT Runtime)
