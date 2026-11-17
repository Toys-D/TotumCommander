#include "fcxl/search/duplicate_finder.h"

#include "fcxl/search/exclusions.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <set>
#include <unordered_map>
#include <utility>
#include <vector>

#include <sys/stat.h>

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

auto collect_files(const std::filesystem::path& root, const DuplicateOptions& options,
                   const ScanProgressCallback& on_scan_dir, bool& cancelled)
    -> std::vector<std::pair<std::filesystem::path, uint64_t>> {
    std::vector<std::pair<std::filesystem::path, uint64_t>> files;
    std::error_code ec;
    auto opts = std::filesystem::directory_options::skip_permission_denied;
    std::filesystem::recursive_directory_iterator it(root, opts, ec);
    if (ec) return files;
    // A file that has several names (hard links) is taken once: (device, inode) of those seen.
    std::set<std::pair<dev_t, ino_t>> seen_files;
    for (; it != std::filesystem::recursive_directory_iterator(); it.increment(ec)) {
        if (cancelled) break;
        if (ec) { ec.clear(); continue; }

        const std::filesystem::path& path = it->path();
        const std::string name = path.filename().string();
        std::error_code dir_ec;
        const bool is_dir = it->is_directory(dir_ec) && !dir_ec;

        if (!options.recursive && is_dir) {
            it.disable_recursion_pending();
        }
        // This is where the excluded tree actually costs nothing: a duplicates run over a home
        // folder used to hash its way through every build cache in it.
        if (is_excluded(name, options.exclude_patterns)) {
            if (is_dir) it.disable_recursion_pending();
            continue;
        }
        // Hidden places the same way: not entered, not compared.
        if (!options.include_hidden &&
            (is_hidden_name(name) || (is_dir && has_hidden_flag(path)))) {
            if (is_dir) it.disable_recursion_pending();
            continue;
        }
        if (is_dir) {
            // Say where we are, exactly as the other two searches do — a duplicates run over a
            // big tree spends minutes here and used to show an empty status line.
            if (on_scan_dir) on_scan_dir(path.string());
            continue;
        }

        // lstat: the entry itself, never what a link points at. A symbolic link is not a
        // regular file here, so it never becomes a "copy" of its own target.
        struct stat info {};
        if (::lstat(path.c_str(), &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0) {
            continue;
        }
        if (!options.include_hidden && (info.st_flags & UF_HIDDEN) != 0) {
            continue;
        }
        if (!options.limits.allows(
                static_cast<uint64_t>(info.st_size),
                std::chrono::system_clock::from_time_t(info.st_mtimespec.tv_sec))) {
            continue;
        }
        if (info.st_nlink > 1 && !seen_files.emplace(info.st_dev, info.st_ino).second) {
            continue;   // another name of a file already taken
        }
        files.emplace_back(path, static_cast<uint64_t>(info.st_size));
    }
    // The walk hands entries over in whatever order the disk keeps them. Sorted here, every
    // group below comes out with its copies in path order, and which name of a hard-linked
    // file was kept does not depend on the disk either.
    std::sort(files.begin(), files.end());
    return files;
}

/// Most wasted space first, then more copies, then by path — a fixed order, so the same
/// folder gives the same list every time.
void sort_groups(std::vector<common::DuplicateGroup>& groups) {
    for (auto& group : groups) {
        std::sort(group.files.begin(), group.files.end());
    }
    const auto waste = [](const common::DuplicateGroup& group) {
        return group.size * static_cast<uint64_t>(group.files.size() - 1);
    };
    std::sort(groups.begin(), groups.end(),
              [&waste](const common::DuplicateGroup& a, const common::DuplicateGroup& b) {
                  if (waste(a) != waste(b)) return waste(a) > waste(b);
                  if (a.files.size() != b.files.size()) return a.files.size() > b.files.size();
                  return a.files.front() < b.files.front();
              });
}

}  // namespace

auto DuplicateFinder::find(std::string_view root_path,
                            DuplicateStrategy strategy,
                            bool recursive,
                            const std::vector<std::string>& exclude_patterns,
                            DuplicateCallback on_found,
                            ScanProgressCallback on_scan_dir)
    -> common::Result<std::vector<common::DuplicateGroup>> {
    DuplicateOptions options;
    options.strategy = strategy;
    options.recursive = recursive;
    options.exclude_patterns = exclude_patterns;
    return find(root_path, options, std::move(on_found), std::move(on_scan_dir));
}

auto DuplicateFinder::find(std::string_view root_path,
                            const DuplicateOptions& options,
                            DuplicateCallback on_found,
                            ScanProgressCallback on_scan_dir)
    -> common::Result<std::vector<common::DuplicateGroup>> {
    const DuplicateStrategy strategy = options.strategy;

    if (root_path.empty()) {
        return common::Error::make(common::ErrorCode::InvalidArgument, "Root path empty");
    }

    const std::filesystem::path root(root_path);
    std::error_code ec;
    if (!std::filesystem::is_directory(root, ec)) {
        return common::Error::make(common::ErrorCode::NotADirectory, "Not a directory", root.string());
    }

    cancelled_ = false;
    auto files = collect_files(root, options, on_scan_dir, cancelled_);
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

    sort_groups(results);
    return results;
}

void DuplicateFinder::cancel() { cancelled_ = true; }

}  // namespace fcxl::search
