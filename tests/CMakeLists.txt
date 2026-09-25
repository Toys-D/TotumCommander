cmake_minimum_required(VERSION 3.25)

find_package(GTest REQUIRED)

set(TEST_SOURCES
    filesystem/navigator_test.cpp
    filesystem/operations_test.cpp
    filesystem/watcher_test.cpp
    filesystem/volume_info_test.cpp
    filesystem/attributes_test.cpp
    filesystem/symlinks_test.cpp
    search/file_search_test.cpp
    search/content_search_test.cpp
    search/duplicate_finder_test.cpp
    archive/archive_reader_test.cpp
    archive/archive_writer_test.cpp
    archive/archive_ops_test.cpp
    compare/file_diff_test.cpp
    compare/dir_diff_test.cpp
    tools/multi_rename_test.cpp
    tools/checksum_test.cpp
    tools/file_splitter_test.cpp
    network/ftp_login_test.cpp
    queue/operation_queue_test.cpp
    viewer/text_viewer_test.cpp
    viewer/hex_viewer_test.cpp
    common/error_test.cpp
)

add_executable(fcxl_tests ${TEST_SOURCES})
target_link_libraries(fcxl_tests PRIVATE fcxl_core GTest::gtest GTest::gtest_main)
include(GoogleTest)
gtest_discover_tests(fcxl_tests)
