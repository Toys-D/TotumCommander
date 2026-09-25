#include "fcxl/compare/sync.h"

#include <filesystem>
#include <string>

namespace fcxl::compare {

auto Sync::preview(std::string_view dir_a, std::string_view dir_b, SyncDirection direction)
    -> common::Result<std::vector<DirDiffEntry>> {
    DirDiff diff;
    auto result = diff.compare(dir_a, dir_b, true);
    if (!result.has_value()) return result.error();

    auto& entries = result.value();

    // Filter by direction
    if (direction == SyncDirection::LeftToRight) {
        entries.erase(
            std::remove_if(entries.begin(), entries.end(),
                           [](const DirDiffEntry& e) {
                               return e.status == DirEntryStatus::RightOnly;
                           }),
            entries.end());
    } else if (direction == SyncDirection::RightToLeft) {
        entries.erase(
            std::remove_if(entries.begin(), entries.end(),
                           [](const DirDiffEntry& e) {
                               return e.status == DirEntryStatus::LeftOnly;
                           }),
            entries.end());
    }

    // Remove entries that are already the same
    entries.erase(
        std::remove_if(entries.begin(), entries.end(),
                       [](const DirDiffEntry& e) {
                           return e.status == DirEntryStatus::Same;
                       }),
        entries.end());

    return entries;
}

auto Sync::synchronize(std::string_view dir_a, std::string_view dir_b, SyncDirection direction)
    -> common::Result<void> {
    auto preview_result = preview(dir_a, dir_b, direction);
    if (!preview_result.has_value()) return preview_result.error();

    const std::filesystem::path root_a(dir_a);
    const std::filesystem::path root_b(dir_b);

    for (const auto& entry : preview_result.value()) {
        std::error_code ec;
        const auto full_a = root_a / entry.relative_path;
        const auto full_b = root_b / entry.relative_path;

        switch (entry.status) {
            case DirEntryStatus::LeftOnly:
                // Copy A → B
                if (entry.is_directory) {
                    std::filesystem::create_directories(full_b, ec);
                } else {
                    std::filesystem::create_directories(full_b.parent_path(), ec);
                    std::filesystem::copy_file(full_a, full_b,
                                               std::filesystem::copy_options::overwrite_existing, ec);
                }
                if (ec) {
                    return common::Error::make(common::ErrorCode::IOError,
                                               "Sync copy failed: " + ec.message(),
                                               full_a.string());
                }
                break;

            case DirEntryStatus::RightOnly:
                // Copy B → A
                if (entry.is_directory) {
                    std::filesystem::create_directories(full_a, ec);
                } else {
                    std::filesystem::create_directories(full_a.parent_path(), ec);
                    std::filesystem::copy_file(full_b, full_a,
                                               std::filesystem::copy_options::overwrite_existing, ec);
                }
                if (ec) {
                    return common::Error::make(common::ErrorCode::IOError,
                                               "Sync copy failed: " + ec.message(),
                                               full_b.string());
                }
                break;

            case DirEntryStatus::Different:
                // Direction determines which side wins
                if (direction == SyncDirection::LeftToRight || direction == SyncDirection::Both) {
                    std::filesystem::copy_file(full_a, full_b,
                                               std::filesystem::copy_options::overwrite_existing, ec);
                } else {
                    std::filesystem::copy_file(full_b, full_a,
                                               std::filesystem::copy_options::overwrite_existing, ec);
                }
                if (ec) {
                    return common::Error::make(common::ErrorCode::IOError,
                                               "Sync overwrite failed: " + ec.message(),
                                               full_a.string());
                }
                break;

            case DirEntryStatus::Same:
                break;
        }
    }

    return common::Result<void>();
}

}  // namespace fcxl::compare
