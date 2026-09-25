#import "FCXLArchiveBridge.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <optional>
#include <vector>

#include "fcxl/archive/archive_reader.h"
#include "fcxl/archive/archive_ops.h"
#include "fcxl/archive/archive_writer.h"

@implementation FCXLArchiveBridge

namespace {

namespace stdfs = std::filesystem;

auto string_from_utf8_or_fallback(const std::string& value, NSString* fallback) -> NSString* {
    NSString* converted = [NSString stringWithUTF8String:value.c_str()];
    if (converted != nil) {
        return converted;
    }

    converted = [[NSString alloc] initWithBytes:value.data()
                                         length:value.size()
                                       encoding:NSISOLatin1StringEncoding];
    return converted != nil ? converted : fallback;
}

auto string_from_utf8_or_empty(const std::string& value) -> NSString* {
    return string_from_utf8_or_fallback(value, @"");
}

auto make_nserror(const fcxl::common::Error& core_error) -> NSError* {
    NSString* message = string_from_utf8_or_fallback(core_error.message, @"Unknown error");
    NSString* path = string_from_utf8_or_empty(core_error.path);
    if (core_error.code == fcxl::common::ErrorCode::Cancelled) {
        return [NSError errorWithDomain:NSCocoaErrorDomain
                                   code:NSUserCancelledError
                               userInfo:@{
                                   NSLocalizedDescriptionKey : message,
                                   @"path" : path
                               }];
    }
    return [NSError errorWithDomain:@"com.fcxl.error"
                               code:static_cast<NSInteger>(core_error.code)
                           userInfo:@{
                               NSLocalizedDescriptionKey : message,
                               @"path" : path
                           }];
}

auto assign_void_result(const fcxl::common::Result<void>& result, NSError** error) -> BOOL {
    if (result.has_value()) {
        return YES;
    }
    if (error != nullptr) {
        *error = make_nserror(result.error());
    }
    return NO;
}

auto archive_format_from_string(NSString* format, fcxl::archive::ArchiveFormat* out_format) -> bool {
    if (format == nil) {
        return false;
    }

    NSString* normalized = [format uppercaseString];
    if ([normalized isEqualToString:@"ZIP"]) {
        *out_format = fcxl::archive::ArchiveFormat::ZIP;
        return true;
    }
    if ([normalized isEqualToString:@"TAR"]) {
        *out_format = fcxl::archive::ArchiveFormat::TAR;
        return true;
    }
    if ([normalized isEqualToString:@"TAR.GZ"] || [normalized isEqualToString:@"TAR_GZ"]) {
        *out_format = fcxl::archive::ArchiveFormat::TAR_GZ;
        return true;
    }
    if ([normalized isEqualToString:@"7Z"] || [normalized isEqualToString:@"SEVENZIP"]) {
        *out_format = fcxl::archive::ArchiveFormat::SevenZip;
        return true;
    }
    if ([normalized isEqualToString:@"TAR.BZ2"] || [normalized isEqualToString:@"TAR_BZ2"]) {
        *out_format = fcxl::archive::ArchiveFormat::TAR_BZ2;
        return true;
    }
    if ([normalized isEqualToString:@"TAR.XZ"] || [normalized isEqualToString:@"TAR_XZ"]) {
        *out_format = fcxl::archive::ArchiveFormat::TAR_XZ;
        return true;
    }
    if ([normalized isEqualToString:@"TAR.ZST"] || [normalized isEqualToString:@"TAR_ZST"]) {
        *out_format = fcxl::archive::ArchiveFormat::TAR_ZST;
        return true;
    }
    if ([normalized isEqualToString:@"TAR.LZ"] || [normalized isEqualToString:@"TAR_LZ"]) {
        *out_format = fcxl::archive::ArchiveFormat::TAR_LZ;
        return true;
    }
    if ([normalized isEqualToString:@"TAR.LZ4"] || [normalized isEqualToString:@"TAR_LZ4"]) {
        *out_format = fcxl::archive::ArchiveFormat::TAR_LZ4;
        return true;
    }
    if ([normalized isEqualToString:@"ISO"]) {
        *out_format = fcxl::archive::ArchiveFormat::ISO;
        return true;
    }

    return false;
}

struct ArchiveSourceTotals {
    int64_t bytes_total = 0;
    int files_total = 0;
};

auto accumulate_file_totals(const stdfs::path& file_path,
                            ArchiveSourceTotals* totals,
                            NSError** error) -> bool {
    if (totals == nullptr) {
        return false;
    }

    std::error_code ec;
    const uintmax_t raw_size = stdfs::file_size(file_path, ec);
    if (ec) {
        if (error != nullptr) {
            fcxl::common::Error core_error = fcxl::common::Error::make(
                fcxl::common::ErrorCode::IOError,
                "Failed to read source file size",
                file_path.string()
            );
            *error = make_nserror(core_error);
        }
        return false;
    }

    if (raw_size > static_cast<uintmax_t>(std::numeric_limits<int64_t>::max())) {
        if (error != nullptr) {
            fcxl::common::Error core_error = fcxl::common::Error::make(
                fcxl::common::ErrorCode::InvalidArgument,
                "Source file is too large",
                file_path.string()
            );
            *error = make_nserror(core_error);
        }
        return false;
    }

    totals->bytes_total += static_cast<int64_t>(raw_size);
    totals->files_total += 1;
    return true;
}

auto calculate_archive_source_totals(NSArray<NSString*>* sources,
                                     bool include_subfolders,
                                     NSError** error) -> std::optional<ArchiveSourceTotals> {
    ArchiveSourceTotals totals;

    for (NSString* source in sources) {
        const std::string source_path = source.UTF8String;
        const stdfs::path source_fs_path(source_path);

        std::error_code ec;
        const bool is_directory = stdfs::is_directory(source_fs_path, ec);
        if (ec) {
            if (error != nullptr) {
                fcxl::common::Error core_error = fcxl::common::Error::make(
                    fcxl::common::ErrorCode::IOError,
                    "Failed to inspect source entry",
                    source_path
                );
                *error = make_nserror(core_error);
            }
            return std::nullopt;
        }

        if (!is_directory) {
            if (!accumulate_file_totals(source_fs_path, &totals, error)) {
                return std::nullopt;
            }
            continue;
        }

        if (include_subfolders) {
            stdfs::recursive_directory_iterator it(
                source_fs_path,
                stdfs::directory_options::skip_permission_denied,
                ec);
            if (ec) {
                if (error != nullptr) {
                    fcxl::common::Error core_error = fcxl::common::Error::make(
                        fcxl::common::ErrorCode::IOError,
                        "Failed to iterate source directory",
                        source_path
                    );
                    *error = make_nserror(core_error);
                }
                return std::nullopt;
            }

            const stdfs::recursive_directory_iterator end;
            while (it != end) {
                const stdfs::directory_entry& entry = *it;
                const bool is_regular_file = entry.is_regular_file(ec);
                if (ec) {
                    if (error != nullptr) {
                        fcxl::common::Error core_error = fcxl::common::Error::make(
                            fcxl::common::ErrorCode::IOError,
                            "Failed to inspect directory child",
                            entry.path().string()
                        );
                        *error = make_nserror(core_error);
                    }
                    return std::nullopt;
                }

                if (is_regular_file &&
                    !accumulate_file_totals(entry.path(), &totals, error)) {
                    return std::nullopt;
                }

                it.increment(ec);
                if (ec) {
                    if (error != nullptr) {
                        fcxl::common::Error core_error = fcxl::common::Error::make(
                            fcxl::common::ErrorCode::IOError,
                            "Failed to advance directory iterator",
                            source_path
                        );
                        *error = make_nserror(core_error);
                    }
                    return std::nullopt;
                }
            }
            continue;
        }

        stdfs::directory_iterator it(
            source_fs_path,
            stdfs::directory_options::skip_permission_denied,
            ec);
        if (ec) {
            if (error != nullptr) {
                fcxl::common::Error core_error = fcxl::common::Error::make(
                    fcxl::common::ErrorCode::IOError,
                    "Failed to iterate source directory",
                    source_path
                );
                *error = make_nserror(core_error);
            }
            return std::nullopt;
        }

        const stdfs::directory_iterator end;
        while (it != end) {
            const stdfs::directory_entry& entry = *it;
            const bool is_regular_file = entry.is_regular_file(ec);
            if (ec) {
                if (error != nullptr) {
                    fcxl::common::Error core_error = fcxl::common::Error::make(
                        fcxl::common::ErrorCode::IOError,
                        "Failed to inspect directory child",
                        entry.path().string()
                    );
                    *error = make_nserror(core_error);
                }
                return std::nullopt;
            }

            if (is_regular_file &&
                !accumulate_file_totals(entry.path(), &totals, error)) {
                return std::nullopt;
            }

            it.increment(ec);
            if (ec) {
                if (error != nullptr) {
                    fcxl::common::Error core_error = fcxl::common::Error::make(
                        fcxl::common::ErrorCode::IOError,
                        "Failed to advance directory iterator",
                        source_path
                    );
                    *error = make_nserror(core_error);
                }
                return std::nullopt;
            }
        }
    }

    return totals;
}

auto add_sources_to_archive(fcxl::archive::ArchiveWriter* writer,
                            NSArray<NSString*>* sources,
                            bool include_subfolders,
                            bool preserve_paths,
                            NSError** error) -> bool {
    for (NSString* source in sources) {
        const std::string source_path = source.UTF8String;
        const stdfs::path source_fs_path(source_path);

        std::error_code ec;
        const bool is_directory = stdfs::is_directory(source_fs_path, ec);
        if (ec) {
            if (error != nullptr) {
                fcxl::common::Error core_error = fcxl::common::Error::make(
                    fcxl::common::ErrorCode::IOError,
                    "Failed to inspect source entry",
                    source_path
                );
                *error = make_nserror(core_error);
            }
            return false;
        }

        const std::string archive_base_name = source_fs_path.filename().string();
        if (is_directory) {
            if (include_subfolders) {
                const auto result = writer->add_directory(source_path, archive_base_name);
                if (!assign_void_result(result, error)) {
                    return false;
                }
                continue;
            }

            stdfs::directory_iterator it(source_fs_path, stdfs::directory_options::skip_permission_denied, ec);
            if (ec) {
                if (error != nullptr) {
                    fcxl::common::Error core_error = fcxl::common::Error::make(
                        fcxl::common::ErrorCode::IOError,
                        "Failed to iterate source directory",
                        source_path
                    );
                    *error = make_nserror(core_error);
                }
                return false;
            }

            const stdfs::directory_iterator end;
            while (it != end) {
                const stdfs::directory_entry& entry = *it;
                const stdfs::path child_path = entry.path();

                const bool is_regular_file = entry.is_regular_file(ec);
                if (ec) {
                    if (error != nullptr) {
                        fcxl::common::Error core_error = fcxl::common::Error::make(
                            fcxl::common::ErrorCode::IOError,
                            "Failed to inspect directory child",
                            child_path.string()
                        );
                        *error = make_nserror(core_error);
                    }
                    return false;
                }

                if (is_regular_file) {
                    const std::string archive_child = preserve_paths
                        ? (stdfs::path(archive_base_name) / child_path.filename()).generic_string()
                        : child_path.filename().string();
                    const auto add_result = writer->add_file(child_path.string(), archive_child);
                    if (!assign_void_result(add_result, error)) {
                        return false;
                    }
                }

                it.increment(ec);
                if (ec) {
                    if (error != nullptr) {
                        fcxl::common::Error core_error = fcxl::common::Error::make(
                            fcxl::common::ErrorCode::IOError,
                            "Failed to advance directory iterator",
                            source_path
                        );
                        *error = make_nserror(core_error);
                    }
                    return false;
                }
            }

            continue;
        }

        const auto result = writer->add_file(source_path, archive_base_name);
        if (!assign_void_result(result, error)) {
            return false;
        }
    }

    return true;
}

auto make_archive_modify_progress_callback(
    FCXLArchiveCreateProgressCallback progressCallback
) -> fcxl::archive::ArchiveOps::ArchiveProgressCallback {
    if (progressCallback == nil) {
        return nullptr;
    }

    return [progressCallback](const std::string& current_file,
                              int64_t bytes_done,
                              int64_t bytes_total,
                              int files_done,
                              int files_total,
                              int64_t compressed_bytes) {
        @autoreleasepool {
            NSString* current_file_ns = string_from_utf8_or_empty(current_file);

            const int64_t normalized_bytes_total = std::max<int64_t>(bytes_total, 1);
            const int64_t normalized_bytes_done =
                std::clamp<int64_t>(bytes_done, 0, normalized_bytes_total);
            const int normalized_files_total = std::max(files_total, 1);
            const int normalized_files_done =
                std::clamp(files_done, 0, normalized_files_total);

            progressCallback(current_file_ns,
                             normalized_bytes_done,
                             normalized_bytes_total,
                             normalized_files_done,
                             normalized_files_total,
                             compressed_bytes);
        }
    };
}

}  // namespace

- (instancetype)init {
    self = [super init];
    return self;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)listEntriesInArchive:(NSString *)archivePath
                                                                   error:(NSError**)error {
    return [self listEntriesInArchive:archivePath password:@"" error:error];
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)listEntriesInArchive:(NSString *)archivePath
                                                                password:(NSString *)password
                                                                   error:(NSError**)error {
    fcxl::archive::ArchiveReader::reset_cancelled();
    fcxl::archive::ArchiveWriter::reset_cancelled();
    fcxl::archive::ArchiveReader reader;

    const auto open_result = reader.open(archivePath.UTF8String, password.UTF8String);
    if (!open_result.has_value()) {
        if (error != nullptr) {
            *error = make_nserror(open_result.error());
        }
        return nil;
    }

    const auto entries_result = reader.list_entries();
    reader.close();
    if (!entries_result.has_value()) {
        if (error != nullptr) {
            *error = make_nserror(entries_result.error());
        }
        return nil;
    }

    NSMutableArray<NSDictionary<NSString*, id>*>* converted = [NSMutableArray array];
    for (const auto& entry : entries_result.value()) {
        NSString* path = string_from_utf8_or_empty(entry.path);
        NSString* method = string_from_utf8_or_empty(entry.method);
        NSDictionary<NSString*, id>* item = @{
            @"path" : path,
            @"size" : @(entry.uncompressed_size),
            @"compressedSize" : @(entry.compressed_size),
            @"isDirectory" : @(entry.is_directory),
            @"isEncrypted" : @(entry.is_encrypted),
            @"method" : method
        };
        [converted addObject:item];
    }

    return converted;
}

- (BOOL)extractAllFromArchive:(NSString *)archivePath
                 toDestination:(NSString *)destinationPath
             overwriteExisting:(BOOL)overwriteExisting
              progressCallback:(FCXLArchiveExtractProgressCallback)progressCallback
                         error:(NSError**)error {
    return [self extractAllFromArchive:archivePath toDestination:destinationPath
                     overwriteExisting:overwriteExisting password:@""
                      progressCallback:progressCallback error:error];
}

- (BOOL)extractAllFromArchive:(NSString *)archivePath
                 toDestination:(NSString *)destinationPath
             overwriteExisting:(BOOL)overwriteExisting
                     password:(NSString *)password
              progressCallback:(FCXLArchiveExtractProgressCallback)progressCallback
                         error:(NSError**)error {
    fcxl::archive::ArchiveReader::reset_cancelled();
    fcxl::archive::ArchiveWriter::reset_cancelled();
    fcxl::archive::ArchiveReader reader;

    const auto open_result = reader.open(archivePath.UTF8String, password.UTF8String);
    if (!open_result.has_value()) {
        if (error != nullptr) {
            *error = make_nserror(open_result.error());
        }
        return NO;
    }

    const auto extract_result = reader.extract_all(
        destinationPath.UTF8String,
        nullptr,
        overwriteExisting,
        [progressCallback](const std::string& current_file,
                           uint64_t bytes_done,
                           uint64_t bytes_total,
                           int files_done,
                           int files_total) {
            if (progressCallback == nil) {
                return;
            }

            const double bytes_progress = bytes_total > 0
                ? static_cast<double>(bytes_done) / static_cast<double>(bytes_total)
                : 0.0;
            const double files_progress = files_total > 0
                ? static_cast<double>(files_done) / static_cast<double>(files_total)
                : 0.0;
            const double progress = std::max(bytes_progress, files_progress);
            NSString* current_file_ns = string_from_utf8_or_empty(current_file);
            progressCallback(current_file_ns,
                             progress,
                             static_cast<int64_t>(bytes_done),
                             static_cast<int64_t>(bytes_total),
                             files_done,
                             files_total);
        }
    );
    reader.close();
    return assign_void_result(extract_result, error);
}

- (BOOL)extractEntryInArchive:(NSString *)archivePath
                    entryPath:(NSString *)entryPath
              destinationPath:(NSString *)destinationPath
                        error:(NSError**)error {
    return [self extractEntryInArchive:archivePath entryPath:entryPath
                       destinationPath:destinationPath password:@"" error:error];
}

- (BOOL)extractEntryInArchive:(NSString *)archivePath
                    entryPath:(NSString *)entryPath
              destinationPath:(NSString *)destinationPath
                     password:(NSString *)password
                        error:(NSError**)error {
    fcxl::archive::ArchiveReader::reset_cancelled();
    fcxl::archive::ArchiveWriter::reset_cancelled();
    fcxl::archive::ArchiveReader reader;

    const auto open_result = reader.open(archivePath.UTF8String, password.UTF8String);
    if (!open_result.has_value()) {
        if (error != nullptr) {
            *error = make_nserror(open_result.error());
        }
        return NO;
    }

    const auto extract_result =
        reader.extract_entry(entryPath.UTF8String, destinationPath.UTF8String);
    reader.close();
    return assign_void_result(extract_result, error);
}

- (BOOL)createArchiveAtPath:(NSString *)archivePath
                     format:(NSString *)format
                    sources:(NSArray<NSString*>*)sources
         includeSubfolders:(BOOL)includeSubfolders
               preservePaths:(BOOL)preservePaths
            compressionLevel:(NSInteger)compressionLevel
           progressCallback:(FCXLArchiveCreateProgressCallback)progressCallback
                      error:(NSError**)error {
    return [self createArchiveAtPath:archivePath format:format sources:sources
                   includeSubfolders:includeSubfolders preservePaths:preservePaths
                    compressionLevel:compressionLevel password:@""
                    progressCallback:progressCallback error:error];
}

- (BOOL)createArchiveAtPath:(NSString *)archivePath
                     format:(NSString *)format
                    sources:(NSArray<NSString*>*)sources
         includeSubfolders:(BOOL)includeSubfolders
               preservePaths:(BOOL)preservePaths
            compressionLevel:(NSInteger)compressionLevel
                   password:(NSString *)password
           progressCallback:(FCXLArchiveCreateProgressCallback)progressCallback
                      error:(NSError**)error {
    FCXLInvalidateArchiveListing();
    fcxl::archive::ArchiveReader::reset_cancelled();
    fcxl::archive::ArchiveWriter::reset_cancelled();
    if (sources.count == 0) {
        if (error != nullptr) {
            fcxl::common::Error core_error = fcxl::common::Error::make(
                fcxl::common::ErrorCode::InvalidArgument,
                "No sources provided for archive",
                archivePath.UTF8String
            );
            *error = make_nserror(core_error);
        }
        return NO;
    }

    fcxl::archive::ArchiveFormat archive_format;
    if (!archive_format_from_string(format, &archive_format)) {
        if (error != nullptr) {
            fcxl::common::Error core_error = fcxl::common::Error::make(
                fcxl::common::ErrorCode::InvalidArgument,
                "Unsupported archive format",
                format.UTF8String
            );
            *error = make_nserror(core_error);
        }
        return NO;
    }

    const auto totals_result =
        calculate_archive_source_totals(sources, includeSubfolders, error);
    if (!totals_result.has_value()) {
        return NO;
    }
    const ArchiveSourceTotals totals = totals_result.value();

    fcxl::archive::ArchiveWriter::ArchiveProgressCallback core_progress_callback = nullptr;
    if (progressCallback != nil) {
        core_progress_callback = [progressCallback](const std::string& current_file,
                                                    int64_t bytes_read,
                                                    int64_t bytes_total,
                                                    int files_done,
                                                    int files_total,
                                                    int64_t compressed_bytes) {
            @autoreleasepool {
                NSString* current_file_ns = string_from_utf8_or_empty(current_file);

                const int64_t normalized_bytes_total = std::max<int64_t>(bytes_total, 1);
                const int64_t normalized_bytes_read =
                    std::clamp<int64_t>(bytes_read, 0, normalized_bytes_total);
                const int normalized_files_total = std::max(files_total, 1);
                const int normalized_files_done =
                    std::clamp(files_done, 0, normalized_files_total);

                progressCallback(current_file_ns,
                                 normalized_bytes_read,
                                 normalized_bytes_total,
                                 normalized_files_done,
                                 normalized_files_total,
                                 compressed_bytes);
            }
        };
    }

    fcxl::archive::ArchiveWriter writer;
    const auto create_result = writer.create(
        archivePath.UTF8String,
        archive_format,
        password.UTF8String,
        static_cast<int>(compressionLevel),
        preservePaths,
        core_progress_callback,
        totals.bytes_total,
        totals.files_total
    );
    if (!assign_void_result(create_result, error)) {
        return NO;
    }

    if (!add_sources_to_archive(&writer, sources, includeSubfolders, preservePaths, error)) {
        return NO;
    }

    const auto finalize_result = writer.finalize();
    return assign_void_result(finalize_result, error);
}

- (BOOL)addFilesToArchive:(NSString *)archivePath
                    files:(NSArray<NSString *> *)filePaths
                 basePath:(NSString *)basePath
         progressCallback:(FCXLArchiveCreateProgressCallback)progressCallback
                    error:(NSError **)error {
    FCXLInvalidateArchiveListing();
    fcxl::archive::ArchiveReader::reset_cancelled();
    fcxl::archive::ArchiveWriter::reset_cancelled();
    fcxl::archive::ArchiveOps::reset_cancelled();

    if (filePaths.count == 0) {
        if (error != nullptr) {
            fcxl::common::Error core_error = fcxl::common::Error::make(
                fcxl::common::ErrorCode::InvalidArgument,
                "No files provided for archive modification",
                archivePath.UTF8String
            );
            *error = make_nserror(core_error);
        }
        return NO;
    }

    std::vector<std::string> paths;
    paths.reserve(filePaths.count);
    for (NSString* filePath in filePaths) {
        if (filePath != nil) {
            paths.emplace_back(filePath.UTF8String);
        }
    }

    const std::string base = basePath != nil ? std::string(basePath.UTF8String) : std::string();
    auto core_progress = make_archive_modify_progress_callback(progressCallback);

    fcxl::archive::ArchiveOps archive_ops;
    const auto result = archive_ops.add_files(
        archivePath.UTF8String,
        paths,
        base,
        nullptr,
        std::move(core_progress)
    );
    return assign_void_result(result, error);
}

- (BOOL)deleteEntriesFromArchive:(NSString *)archivePath
                         entries:(NSArray<NSString *> *)entryPaths
                progressCallback:(FCXLArchiveCreateProgressCallback)progressCallback
                           error:(NSError **)error {
    FCXLInvalidateArchiveListing();
    fcxl::archive::ArchiveReader::reset_cancelled();
    fcxl::archive::ArchiveWriter::reset_cancelled();
    fcxl::archive::ArchiveOps::reset_cancelled();

    if (entryPaths.count == 0) {
        if (error != nullptr) {
            fcxl::common::Error core_error = fcxl::common::Error::make(
                fcxl::common::ErrorCode::InvalidArgument,
                "No entries provided for deletion",
                archivePath.UTF8String
            );
            *error = make_nserror(core_error);
        }
        return NO;
    }

    std::vector<std::string> entries;
    entries.reserve(entryPaths.count);
    for (NSString* entryPath in entryPaths) {
        if (entryPath != nil) {
            entries.emplace_back(entryPath.UTF8String);
        }
    }

    auto core_progress = make_archive_modify_progress_callback(progressCallback);
    fcxl::archive::ArchiveOps archive_ops;
    const auto result = archive_ops.delete_entries(
        archivePath.UTF8String,
        entries,
        nullptr,
        std::move(core_progress)
    );
    return assign_void_result(result, error);
}

- (BOOL)renameEntryInArchive:(NSString *)archivePath
                    oldEntry:(NSString *)oldPath
                    newEntry:(NSString *)newPath
            progressCallback:(FCXLArchiveCreateProgressCallback)progressCallback
                       error:(NSError **)error {
    FCXLInvalidateArchiveListing();
    fcxl::archive::ArchiveReader::reset_cancelled();
    fcxl::archive::ArchiveWriter::reset_cancelled();
    fcxl::archive::ArchiveOps::reset_cancelled();

    if (oldPath == nil || newPath == nil || oldPath.length == 0 || newPath.length == 0) {
        if (error != nullptr) {
            fcxl::common::Error core_error = fcxl::common::Error::make(
                fcxl::common::ErrorCode::InvalidArgument,
                "Old and new archive entry paths are required",
                archivePath.UTF8String
            );
            *error = make_nserror(core_error);
        }
        return NO;
    }

    auto core_progress = make_archive_modify_progress_callback(progressCallback);
    fcxl::archive::ArchiveOps archive_ops;
    const auto result = archive_ops.rename_entry(
        archivePath.UTF8String,
        oldPath.UTF8String,
        newPath.UTF8String,
        nullptr,
        std::move(core_progress)
    );
    return assign_void_result(result, error);
}

/// The reader caches an archive's entry list keyed by path+mtime, and mtime only has
/// one-second resolution — an add that finishes inside the same second leaves the cache
/// looking valid, so the panel keeps showing the archive's OLD contents and the file just
/// added seems to have vanished. Nothing ever invalidated that cache after a mutation.
/// Drop it explicitly whenever we change an archive.
static void FCXLInvalidateArchiveListing(void) {
    fcxl::archive::ArchiveReader::invalidate_cached_listing();
}

- (void)cancelCurrentArchiveOperation {
    fcxl::archive::ArchiveReader::cancel_current_operation();
    fcxl::archive::ArchiveWriter::cancel_current_operation();
    fcxl::archive::ArchiveOps::cancel_current_operation();
}

@end
