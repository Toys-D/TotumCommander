#include "fcxl/search/duplicate_finder.h"

#include "fcxl/search/exclusions.h"

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <unordered_map>
#include <vector>

#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>

namespace fcxl::search {
namespace {

/// First bytes hashed by the cheap prefilter pass. Files whose size AND first
/// 128 KB match are the only ones that get a (possibly huge) full-content hash.
constexpr uint64_t kPartialHashBytes = 128 * 1024;

auto to_hex(const unsigned char* hash, size_t len) -> std::string {
    static const char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(len * 2);
    for (size_t i = 0; i < len; ++i) {
        result.push_back(hex[hash[i] >> 4]);
        result.push_back(hex[hash[i] & 0x0F]);
    }
    return result;
}

/// SHA-256 of the whole file, or of just its first `limit` bytes (limit == 0 → all).
auto sha256_file(const std::filesystem::path& path, uint64_t limit = 0) -> std::string {
    std::ifstream file(path, std::ios::binary);
    if (!file.is_open()) return {};

    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);

    char buffer[65536];
    uint64_t remaining = limit == 0 ? UINT64_MAX : limit;
    while (remaining > 0 && (file.read(buffer, static_cast<std::streamsize>(
                                 std::min<uint64_t>(sizeof(buffer), remaining))) ||
                             file.gcount() > 0)) {
        CC_SHA256_Update(&ctx, buffer, static_cast<CC_LONG>(file.gcount()));
        remaining -= static_cast<uint64_t>(file.gcount());
        if (file.eof()) break;
    }

    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(hash, &ctx);
    return to_hex(hash, CC_SHA256_DIGEST_LENGTH);
}

/// Hash many files concurrently (dispatch_apply over all CPU cores).
/// Returns path→hash; empty hashes (unreadable files) are omitted.
auto hash_files_parallel(const std::vector<std::filesystem::path>& paths,
                         uint64_t limit,
                         const bool& cancelled)
    -> std::unordered_map<std::string, std::string> {
    std::vector<std::string> hashes(paths.size());
    // Blocks capture C++ locals as CONST copies — mutate through pointers instead.
    auto* hashes_ptr = &hashes;
    const auto* paths_ptr = &paths;
    const bool* cancelled_ptr = &cancelled;
    dispatch_queue_t queue =
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_apply(paths.size(), queue, ^(size_t i) {
        if (*cancelled_ptr) return;
        (*hashes_ptr)[i] = sha256_file((*paths_ptr)[i], limit);
    });

    std::unordered_map<std::string, std::string> result;
    result.reserve(paths.size());
    for (size_t i = 0; i < paths.size(); ++i) {
        if (!hashes[i].empty()) result[paths[i].string()] = hashes[i];
    }
    return result;
}

auto collect_files(const std::filesystem::path& root, bool recursive,
                   const std::vector<std::string>& exclude_patterns,
                   const ScanProgressCallback& on_scan_dir, bool& cancelled)
    -> std::vector<std::pair<std::filesystem::path, uint64_t>> {
    std::vector<std::pair<std::filesystem::path, uint64_t>> files;
    std::error_code ec;

    auto opts = std::filesystem::directory_options::skip_permission_denied;
    std::filesystem::recursive_directory_iterator it(root, opts, ec);
    if (ec) return files;

    for (; it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
        if (cancelled) break;
        if (ec) { ec.clear(); continue; }

        // Say where we are, exactly as the other two searches do — a duplicates run over a
        // big tree spends minutes here and used to show an empty status line.
        std::error_code dir_ec;
        if (on_scan_dir && it->is_directory(dir_ec) && !dir_ec) {
            on_scan_dir(it->path().string());
        }

        if (!recursive && it.depth() > 0) {
            it.disable_recursion_pending();
            continue;
        }

        // This is where the excluded tree actually costs nothing: a duplicates run over a home
        // folder used to hash its way through every build cache in it.
        if (is_excluded(it->path().filename().string(), exclude_patterns)) {
            std::error_code dir_ec;
            if (it->is_directory(dir_ec) && !dir_ec) {
                it.disable_recursion_pending();
            }
            continue;
        }

        if (it->is_regular_file(ec) && !ec) {
            auto size = it->file_size(ec);
            if (!ec && size > 0) {
                files.emplace_back(it->path(), static_cast<uint64_t>(size));
            }
        }
    }
    return files;
}

}  // namespace

auto DuplicateFinder::find(std::string_view root_path,
                            DuplicateStrategy strategy,
                            bool recursive,
                            const std::vector<std::string>& exclude_patterns,
                            DuplicateCallback on_found,
                            ScanProgressCallback on_scan_dir)
    -> common::Result<std::vector<common::DuplicateGroup>> {

    if (root_path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Root path empty");
    }

    const std::filesystem::path root(root_path);
    std::error_code ec;
    if (!std::filesystem::is_directory(root, ec)) {
        return common::Error::make(common::ErrorCode::NotADirectory, "Not a directory", root.string());
    }

    cancelled_ = false;
    auto files = collect_files(root, recursive, exclude_patterns, on_scan_dir, cancelled_);
    if (cancelled_) return std::vector<common::DuplicateGroup>{};

    std::vector<common::DuplicateGroup> results;

    if (strategy == DuplicateStrategy::ByName) {
        std::unordered_map<std::string, std::vector<std::filesystem::path>> by_name;
        for (const auto& [path, size] : files) {
            by_name[path.filename().string()].push_back(path);
        }
        for (auto& [name, paths] : by_name) {
            if (cancelled_) break;
            if (paths.size() < 2) continue;
            common::DuplicateGroup group;
            group.files = std::move(paths);
            if (on_found) on_found(group);
            results.push_back(std::move(group));
        }
    }
    else if (strategy == DuplicateStrategy::BySize) {
        std::unordered_map<uint64_t, std::vector<std::filesystem::path>> by_size;
        for (const auto& [path, size] : files) {
            by_size[size].push_back(path);
        }
        for (auto& [size, paths] : by_size) {
            if (cancelled_) break;
            if (paths.size() < 2) continue;
            common::DuplicateGroup group;
            group.size = size;
            group.files = std::move(paths);
            if (on_found) on_found(group);
            results.push_back(std::move(group));
        }
    }
    else {
        // ByHash, three cheap-to-expensive stages:
        //   1) group by SIZE (free — from the directory walk),
        //   2) partial hash (first 128 KB) of size-duplicates — discards almost
        //      every false candidate without reading whole files,
        //   3) full hash ONLY where size+partial still collide.
        // Both hash stages run on all CPU cores (dispatch_apply).
        std::unordered_map<uint64_t, std::vector<std::filesystem::path>> by_size;
        for (const auto& [path, size] : files) {
            by_size[size].push_back(path);
        }

        for (auto& [size, paths] : by_size) {
            if (cancelled_) break;
            if (paths.size() < 2) continue;

            // Stage 2: partial-hash prefilter.
            auto partial = hash_files_parallel(paths, kPartialHashBytes, cancelled_);
            if (cancelled_) break;
            std::unordered_map<std::string, std::vector<std::filesystem::path>> by_partial;
            for (const auto& path : paths) {
                auto it_h = partial.find(path.string());
                if (it_h != partial.end()) by_partial[it_h->second].push_back(path);
            }

            for (auto& [partial_hash, candidates] : by_partial) {
                if (cancelled_) break;
                if (candidates.size() < 2) continue;

                // Small files: the partial hash already covered the whole file.
                if (size <= kPartialHashBytes) {
                    common::DuplicateGroup group;
                    group.size = size;
                    group.hash = partial_hash;
                    group.files = std::move(candidates);
                    if (on_found) on_found(group);
                    results.push_back(std::move(group));
                    continue;
                }

                // Stage 3: full-content hash of the survivors.
                auto full = hash_files_parallel(candidates, 0, cancelled_);
                if (cancelled_) break;
                std::unordered_map<std::string, std::vector<std::filesystem::path>> by_hash;
                for (const auto& path : candidates) {
                    auto it_h = full.find(path.string());
                    if (it_h != full.end()) by_hash[it_h->second].push_back(path);
                }
                for (auto& [hash, hash_paths] : by_hash) {
                    if (hash_paths.size() < 2) continue;
                    common::DuplicateGroup group;
                    group.size = size;
                    group.hash = hash;
                    group.files = std::move(hash_paths);
                    if (on_found) on_found(group);
                    results.push_back(std::move(group));
                }
            }
        }
    }

    return results;
}

void DuplicateFinder::cancel() { cancelled_ = true; }

}  // namespace fcxl::search
