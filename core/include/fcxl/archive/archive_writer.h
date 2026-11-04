#pragma once
/// @file archive_writer.h
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>
#include <vector>
#include "fcxl/common/error.h"
#include "fcxl/archive/archive_types.h"
namespace fcxl::archive {
/// Что класть в архив на месте символической ссылки.
enum class SymlinkMode {
    /// Саму ссылку — как tar и zip -y.
    Keep,
    /// То, на что ведёт, если ведёт наружу: по полному пути или за пределы упакованного
    /// (rsync --copy-unsafe-links). Ссылки внутри упакованного остаются ссылками.
    FollowOutside,
    /// Всегда то, на что ведёт — как zip без -y и tar -h.
    FollowAll,
};

/// Сколько ляжет в архив — для хода упаковки.
struct SourceTotals {
    int64_t bytes = 0;
    int files = 0;
};

class ArchiveWriter {
public:
    using ArchiveProgressCallback =
        std::function<void(const std::string& current_file,
                           int64_t bytes_read,
                           int64_t bytes_total,
                           int files_done,
                           int files_total,
                           int64_t compressed_bytes)>;

    ~ArchiveWriter();
    [[nodiscard]] auto create(std::string_view path,
                              ArchiveFormat format,
                              std::string_view password = "",
                              int compression_level = -1,
                              bool preserve_paths = true,
                              ArchiveProgressCallback progress_callback = nullptr,
                              int64_t total_uncompressed_bytes = 0,
                              int total_files = 0) -> common::Result<void>;
    [[nodiscard]] auto add_file(std::string_view file_path, std::string_view archive_path = "") -> common::Result<void>;
    [[nodiscard]] auto add_directory(std::string_view dir_path, std::string_view archive_path = "") -> common::Result<void>;
    /// Символическая ссылка — ссылкой, с тем же путём внутри, как её хранят zip и tar. Цель не
    /// читается: битая ссылка упаковывается так же, как целая.
    [[nodiscard]] auto add_symlink(std::string_view link_path, std::string_view archive_path = "") -> common::Result<void>;
    /// Выбранное целиком, как упаковка из панели: каждый путь — под своим именем, папки — с
    /// вложенным или только верхний уровень, ссылки — по `links`. Наружу ведёт ссылка по
    /// полному пути или за пределы всего `sources`.
    [[nodiscard]] auto add_sources(const std::vector<std::string>& sources,
                                   bool include_subfolders,
                                   SymlinkMode links = SymlinkMode::Keep) -> common::Result<void>;
    /// Итоги для хода — тем же обходом, что `add_sources`, без записи.
    [[nodiscard]] static auto measure_sources(const std::vector<std::string>& sources,
                                              bool include_subfolders,
                                              SymlinkMode links = SymlinkMode::Keep)
        -> common::Result<SourceTotals>;
    [[nodiscard]] auto finalize() -> common::Result<void>;
    static void cancel_current_operation();
    static void reset_cancelled();
};
} // namespace fcxl::archive
