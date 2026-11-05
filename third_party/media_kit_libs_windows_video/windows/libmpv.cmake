# 直接使用官网列出的标准上游构建，不应用项目 mpv 补丁。
cmake_minimum_required(VERSION 3.19)
get_filename_component(LIBMPV_PACKAGE_DIR "${CMAKE_CURRENT_LIST_DIR}" REALPATH)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${LIBMPV_PACKAGE_DIR}/libmpv.json")
file(READ "${LIBMPV_PACKAGE_DIR}/libmpv.json" metadata)
string(JSON upstream_url GET "${metadata}" url)
string(JSON upstream_sha GET "${metadata}" sha256)
set(upstream_archive "${CMAKE_BINARY_DIR}/libmpv-${upstream_sha}.7z")
if(EXISTS "${upstream_archive}")
  file(SHA256 "${upstream_archive}" actual_sha)
  if(NOT actual_sha STREQUAL upstream_sha)
    message(FATAL_ERROR "libmpv archive SHA256 mismatch: ${upstream_archive}")
  endif()
else()
  file(DOWNLOAD "${upstream_url}" "${upstream_archive}.part"
    EXPECTED_HASH "SHA256=${upstream_sha}" TLS_VERIFY ON STATUS download_status)
  list(GET download_status 0 download_code)
  if(NOT download_code EQUAL 0)
    message(FATAL_ERROR "libmpv download failed: ${download_status}")
  endif()
  file(RENAME "${upstream_archive}.part" "${upstream_archive}")
endif()
# 每次配置都从已校验归档提取，避免复用被修改的解压缓存。
set(upstream_dir "${CMAKE_BINARY_DIR}/libmpv-upstream-${upstream_sha}")
file(MAKE_DIRECTORY "${upstream_dir}")
execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${upstream_archive}"
  WORKING_DIRECTORY "${upstream_dir}" RESULT_VARIABLE extract_result)
if(NOT extract_result EQUAL 0)
  message(FATAL_ERROR "libmpv extraction failed: ${extract_result}")
endif()
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")
file(MAKE_DIRECTORY "${LIBMPV_SRC}/include")
foreach(name libmpv-2.dll libmpv.dll.a)
  configure_file("${upstream_dir}/${name}" "${LIBMPV_SRC}/${name}" COPYONLY)
endforeach()
file(COPY "${upstream_dir}/include/mpv/" DESTINATION "${LIBMPV_SRC}/include/mpv")
file(TOUCH_NOCREATE "${LIBMPV_SRC}/libmpv-2.dll")
install(FILES
  "${LIBMPV_PACKAGE_DIR}/libmpv.json"
  "${LIBMPV_PACKAGE_DIR}/THIRD_PARTY_NOTICES.txt"
  "${LIBMPV_PACKAGE_DIR}/NOTICE_SOURCES.json"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/mpv-licenses" COMPONENT Runtime)
message(STATUS "Using verified upstream libmpv: ${upstream_url}")
