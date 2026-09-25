cmake_minimum_required(VERSION 3.25)

set(FCXL_CORE_SOURCES
    src/filesystem/navigator.cpp
    src/filesystem/operations.cpp
    src/filesystem/watcher.cpp
    src/filesystem/attributes.cpp
    src/filesystem/volume_info.cpp
    src/filesystem/symlinks.cpp
    src/search/exclusions.cpp
    src/search/file_search.cpp
    src/search/name_match.cpp
    src/search/content_search.cpp
    src/search/duplicate_finder.cpp
    src/search/spotlight.cpp
    src/archive/archive_reader.cpp
    src/archive/archive_writer.cpp
    src/archive/archive_ops.cpp
    src/network/ftp_client.cpp
    src/network/sftp_client.cpp
    src/terminal/pty_handler.cpp
    src/viewer/text_viewer.cpp
    src/viewer/hex_viewer.cpp
    src/viewer/image_info.cpp
    src/compare/file_diff.cpp
    src/compare/dir_diff.cpp
    src/compare/sync.cpp
    src/tools/multi_rename.cpp
    src/tools/checksum.cpp
    src/tools/file_splitter.cpp
    src/queue/operation_queue.cpp
    src/common/error.cpp
    src/common/logger.cpp
    src/common/config.cpp
)

set(MINIZIP_NG_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/minizip-ng)
set(MINIZIP_NG_SOURCES
    ${MINIZIP_NG_DIR}/mz_crypt.c
    ${MINIZIP_NG_DIR}/mz_crypt_apple.c
    ${MINIZIP_NG_DIR}/mz_strm_pkcrypt.c
    ${MINIZIP_NG_DIR}/mz_strm_wzaes.c
    ${MINIZIP_NG_DIR}/mz_os.c
    ${MINIZIP_NG_DIR}/mz_os_posix.c
    ${MINIZIP_NG_DIR}/mz_strm.c
    ${MINIZIP_NG_DIR}/mz_strm_buf.c
    ${MINIZIP_NG_DIR}/mz_strm_mem.c
    ${MINIZIP_NG_DIR}/mz_strm_os_posix.c
    ${MINIZIP_NG_DIR}/mz_strm_split.c
    ${MINIZIP_NG_DIR}/mz_strm_zlib.c
    ${MINIZIP_NG_DIR}/mz_zip.c
    ${MINIZIP_NG_DIR}/mz_zip_rw.c
)

add_library(fcxl_core STATIC ${FCXL_CORE_SOURCES})
target_sources(fcxl_core PRIVATE ${MINIZIP_NG_SOURCES})

target_include_directories(fcxl_core
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
    PRIVATE ${MINIZIP_NG_DIR}
)

target_compile_features(fcxl_core PUBLIC cxx_std_20)
target_compile_options(fcxl_core PRIVATE
    $<$<COMPILE_LANGUAGE:C>:-Wno-variadic-macro-arguments-omitted>
    $<$<COMPILE_LANGUAGE:C>:-Wno-unused-parameter>
)
target_compile_definitions(fcxl_core PRIVATE
    HAVE_STDINT_H
    HAVE_INTTYPES_H
    HAVE_ZLIB
    ZLIB_COMPAT
    HAVE_WZAES
    HAVE_PKCRYPT
    _POSIX_C_SOURCE=200809L
    _BSD_SOURCE
    _DEFAULT_SOURCE
    _DARWIN_C_SOURCE
)

if(APPLE)
    set(_LIBARCHIVE_PKGCONFIG_CANDIDATES
        "/opt/homebrew/opt/libarchive/lib/pkgconfig"
        "/usr/local/opt/libarchive/lib/pkgconfig"
    )
    foreach(_pc_path IN LISTS _LIBARCHIVE_PKGCONFIG_CANDIDATES)
        if(EXISTS "${_pc_path}/libarchive.pc")
            if(DEFINED ENV{PKG_CONFIG_PATH} AND NOT "$ENV{PKG_CONFIG_PATH}" STREQUAL "")
                set(ENV{PKG_CONFIG_PATH} "$ENV{PKG_CONFIG_PATH}:${_pc_path}")
            else()
                set(ENV{PKG_CONFIG_PATH} "${_pc_path}")
            endif()
            break()
        endif()
    endforeach()
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBARCHIVE REQUIRED libarchive)
target_include_directories(fcxl_core PRIVATE ${LIBARCHIVE_INCLUDE_DIRS})

pkg_check_modules(LIBLZMA liblzma)
if(LIBLZMA_FOUND)
    target_link_libraries(fcxl_core PUBLIC ${LIBLZMA_LIBRARIES})
    target_include_directories(fcxl_core PRIVATE ${LIBLZMA_INCLUDE_DIRS})
endif()

# libssh2 (SFTP) + libcurl (FTP/WebDAV) — used by core/src/network/*. The SwiftPM build
# passes these via -I/-l flags; mirror that here so the CMake/ctest build compiles too
# (Homebrew keg-only libssh2 isn't on the default header search path).
find_path(LIBSSH2_INCLUDE_DIR libssh2.h
    PATHS /opt/homebrew/opt/libssh2/include /usr/local/opt/libssh2/include)
find_library(LIBSSH2_LIBRARY ssh2
    PATHS /opt/homebrew/opt/libssh2/lib /usr/local/opt/libssh2/lib)
if(LIBSSH2_INCLUDE_DIR)
    target_include_directories(fcxl_core PRIVATE ${LIBSSH2_INCLUDE_DIR})
endif()
find_library(CURL_LIBRARY curl)

find_library(CORE_SERVICES_FRAMEWORK CoreServices)
find_library(CORE_FOUNDATION_FRAMEWORK CoreFoundation)
find_library(SECURITY_FRAMEWORK Security)
find_library(ZLIB_SYSTEM_LIBRARY z)
target_link_libraries(fcxl_core PUBLIC
    ${CORE_SERVICES_FRAMEWORK}
    ${CORE_FOUNDATION_FRAMEWORK}
    ${SECURITY_FRAMEWORK}
    ${LIBARCHIVE_LIBRARIES}
    ${ZLIB_SYSTEM_LIBRARY}
    ${LIBSSH2_LIBRARY}
    ${CURL_LIBRARY}
)
