# 同源固定版本包含 FFmpeg bcd2c69e，修复 D3D12 参考帧资源池耗尽。
set(LIBMPV "mpv-dev-x86_64-20260819-git-e7191f2a65.7z")
set(LIBMPV_URL "https://github.com/bggRGjQaUbCoE/mpv-winbuild-cmake/releases/download/20260819/${LIBMPV}")
set(LIBMPV_SHA256 "b3352cd5825674d75e71131ca34c42a3fb40ed58db207ae2a4f42ed8a9e4f861")
set(LIBMPV_DLL_SHA256 "7bda2cee77f00bd9be104c590055b44d2f9c5074de3a6b92f7f1e763fe2b3a6e")
set(LIBMPV_IMPORT_SHA256 "032c8ce0a79867761983b7d6959fa07e3c0e8c889f103130edfc9f8a2dcc7684")
set(LIBMPV_ARCHIVE "${CMAKE_BINARY_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")

function(verify_libmpv_file path expected)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "Missing libmpv file: ${path}")
  endif()
  file(SHA256 "${path}" actual)
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "libmpv SHA256 mismatch: ${path}")
  endif()
endfunction()

if(NOT EXISTS "${LIBMPV_ARCHIVE}")
  message(STATUS "Downloading pinned libmpv ${LIBMPV}")
  file(DOWNLOAD "${LIBMPV_URL}" "${LIBMPV_ARCHIVE}.download"
    EXPECTED_HASH "SHA256=${LIBMPV_SHA256}" STATUS download_status
    TLS_VERIFY ON TIMEOUT 300)
  list(GET download_status 0 download_code)
  if(NOT download_code EQUAL 0)
    message(FATAL_ERROR "libmpv download failed: ${download_status}")
  endif()
  file(RENAME "${LIBMPV_ARCHIVE}.download" "${LIBMPV_ARCHIVE}")
endif()
verify_libmpv_file("${LIBMPV_ARCHIVE}" "${LIBMPV_SHA256}")

# 每次配置校验归档并同步产物，不能用“目录非空”跳过旧版缓存。
# 只写入构建目录，不改 Pub 缓存；保持 media_kit_video 现有链接路径。
set(LIBMPV_STAGE "${CMAKE_BINARY_DIR}/libmpv-20260819")
file(MAKE_DIRECTORY "${LIBMPV_STAGE}")
execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${LIBMPV_ARCHIVE}"
  WORKING_DIRECTORY "${LIBMPV_STAGE}" RESULT_VARIABLE extract_result)
if(NOT extract_result EQUAL 0)
  message(FATAL_ERROR "libmpv extraction failed: ${extract_result}")
endif()
verify_libmpv_file("${LIBMPV_STAGE}/libmpv-2.dll" "${LIBMPV_DLL_SHA256}")
verify_libmpv_file("${LIBMPV_STAGE}/libmpv.dll.a" "${LIBMPV_IMPORT_SHA256}")

file(MAKE_DIRECTORY "${LIBMPV_SRC}/include")
configure_file("${LIBMPV_STAGE}/libmpv-2.dll" "${LIBMPV_SRC}/libmpv-2.dll" COPYONLY)
configure_file("${LIBMPV_STAGE}/libmpv.dll.a" "${LIBMPV_SRC}/libmpv.dll.a" COPYONLY)
file(COPY "${LIBMPV_STAGE}/include/mpv/" DESTINATION "${LIBMPV_SRC}/include")
verify_libmpv_file("${LIBMPV_SRC}/libmpv-2.dll" "${LIBMPV_DLL_SHA256}")
message(STATUS "libmpv 20260819 verified (FFmpeg D3D12 reference-pool fix)")
