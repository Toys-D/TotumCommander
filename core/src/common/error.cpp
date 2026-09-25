#include "fcxl/common/error.h"

namespace fcxl::common {

auto Error::code_name() const -> std::string {
    switch (code) {
        case ErrorCode::Ok: return "Ok";
        case ErrorCode::NotFound: return "NotFound";
        case ErrorCode::PermissionDenied: return "PermissionDenied";
        case ErrorCode::AlreadyExists: return "AlreadyExists";
        case ErrorCode::IOError: return "IOError";
        case ErrorCode::InvalidArgument: return "InvalidArgument";
        case ErrorCode::NotSupported: return "NotSupported";
        case ErrorCode::Cancelled: return "Cancelled";
        case ErrorCode::Timeout: return "Timeout";
        case ErrorCode::ArchiveError: return "ArchiveError";
        case ErrorCode::NetworkError: return "NetworkError";
        case ErrorCode::NotADirectory: return "NotADirectory";
        case ErrorCode::NotAFile: return "NotAFile";
        case ErrorCode::DiskFull: return "DiskFull";
        case ErrorCode::NameTooLong: return "NameTooLong";
        case ErrorCode::Unknown: return "Unknown";
    }
    return "Unknown";
}

} // namespace fcxl::common
