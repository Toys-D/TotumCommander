#pragma once

/// @file error.h
/// @brief Error handling with Result<T, Error> pattern

#include <optional>
#include <string>
#include <variant>

namespace fcxl::common {

enum class ErrorCode {
    Ok, NotFound, PermissionDenied, AlreadyExists, IOError,
    InvalidArgument, NotSupported, Cancelled, Timeout,
    ArchiveError, NetworkError, NotADirectory, NotAFile,
    DiskFull, NameTooLong, Unknown
};

struct Error {
    ErrorCode code = ErrorCode::Unknown;
    std::string message;
    std::string path;
    static auto make(ErrorCode code, std::string message, std::string path = "") -> Error {
        return Error{code, std::move(message), std::move(path)};
    }
    [[nodiscard]] auto code_name() const -> std::string;
};

template<typename T>
class Result {
public:
    Result(T value) : data_(std::move(value)) {}
    Result(Error error) : data_(std::move(error)) {}
    [[nodiscard]] auto has_value() const -> bool { return std::holds_alternative<T>(data_); }
    explicit operator bool() const { return has_value(); }
    [[nodiscard]] auto value() -> T& { return std::get<T>(data_); }
    [[nodiscard]] auto value() const -> const T& { return std::get<T>(data_); }
    [[nodiscard]] auto error() const -> const Error& { return std::get<Error>(data_); }
private:
    std::variant<T, Error> data_;
};

template<>
class Result<void> {
public:
    Result() : error_(std::nullopt) {}
    Result(Error error) : error_(std::move(error)) {}
    [[nodiscard]] auto has_value() const -> bool { return !error_.has_value(); }
    explicit operator bool() const { return has_value(); }
    [[nodiscard]] auto error() const -> const Error& { return error_.value(); }
private:
    std::optional<Error> error_;
};

} // namespace fcxl::common
