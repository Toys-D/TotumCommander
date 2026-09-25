#include <gtest/gtest.h>
#include "fcxl/common/error.h"

using namespace fcxl::common;

TEST(ErrorTest, should_create_error_with_make) {
    auto err = Error::make(ErrorCode::NotFound, "File not found", "/test/path");
    EXPECT_EQ(err.code, ErrorCode::NotFound);
    EXPECT_EQ(err.message, "File not found");
    EXPECT_EQ(err.path, "/test/path");
}

TEST(ErrorTest, should_return_code_name) {
    auto err = Error::make(ErrorCode::PermissionDenied, "denied");
    EXPECT_EQ(err.code_name(), "PermissionDenied");
}

TEST(ResultTest, should_hold_success_value) {
    Result<int> r(42);
    ASSERT_TRUE(r.has_value());
    EXPECT_EQ(r.value(), 42);
}

TEST(ResultTest, should_hold_error) {
    Result<int> r(Error::make(ErrorCode::IOError, "fail"));
    ASSERT_FALSE(r.has_value());
    EXPECT_EQ(r.error().code, ErrorCode::IOError);
}
