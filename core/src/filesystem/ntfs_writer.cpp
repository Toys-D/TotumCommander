// ntfs_writer.cpp — NTFS write support via libntfs-3g
// Copyright (c) 2026 Totum Commander — GPL-2.0

#include "fcxl/filesystem/ntfs_writer.h"

#include <sys/stat.h>
#include <sys/mount.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <filesystem>

// libntfs-3g headers (C)
extern "C" {
#include <ntfs-3g/volume.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/security.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/misc.h>
#include <ntfs-3g/ntfstime.h>
}

namespace fcxl {

namespace fs = std::filesystem;

// ─── Helpers ────────────────────────────────────────────────────────────────

static constexpr size_t COPY_BUFFER_SIZE = 1024 * 1024; // 1 MB

// Note: volume unmount/mount and device chmod are handled by the ObjC bridge
// (FCXLNTFSBridge) which calls osascript for admin privileges.
// C++ layer only does ntfs_mount/ntfs_umount on the raw device.

/// Convert a relative NTFS path to ntfschar (UTF-16LE) name.
/// libntfs-3g uses ntfschar* for file names in most APIs.
static std::vector<ntfschar> to_ntfschar(const std::string& name) {
    std::vector<ntfschar> result;
    // Simple UTF-8 to UTF-16 conversion (handles BMP characters)
    const unsigned char* s = reinterpret_cast<const unsigned char*>(name.c_str());
    size_t len = name.size();
    size_t i = 0;
    while (i < len) {
        uint32_t cp;
        if (s[i] < 0x80) {
            cp = s[i++];
        } else if ((s[i] & 0xE0) == 0xC0) {
            cp = (s[i] & 0x1F) << 6;
            if (i + 1 < len) cp |= (s[i + 1] & 0x3F);
            i += 2;
        } else if ((s[i] & 0xF0) == 0xE0) {
            cp = (s[i] & 0x0F) << 12;
            if (i + 1 < len) cp |= (s[i + 1] & 0x3F) << 6;
            if (i + 2 < len) cp |= (s[i + 2] & 0x3F);
            i += 3;
        } else if ((s[i] & 0xF8) == 0xF0) {
            cp = (s[i] & 0x07) << 18;
            if (i + 1 < len) cp |= (s[i + 1] & 0x3F) << 12;
            if (i + 2 < len) cp |= (s[i + 2] & 0x3F) << 6;
            if (i + 3 < len) cp |= (s[i + 3] & 0x3F);
            i += 4;
            // Surrogate pair
            if (cp > 0xFFFF) {
                cp -= 0x10000;
                result.push_back(static_cast<ntfschar>(0xD800 + (cp >> 10)));
                result.push_back(static_cast<ntfschar>(0xDC00 + (cp & 0x3FF)));
                continue;
            }
        } else {
            i++;
            continue;
        }
        result.push_back(static_cast<ntfschar>(cp));
    }
    return result;
}

/// Convert ntfschar (UTF-16LE) name to UTF-8 std::string.
static std::string from_ntfschar(const ntfschar* name, int name_len) {
    std::string result;
    for (int i = 0; i < name_len; i++) {
        uint32_t cp = static_cast<uint16_t>(le16_to_cpu(name[i]));
        // Handle surrogate pairs
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < name_len) {
            uint32_t low = static_cast<uint16_t>(le16_to_cpu(name[i + 1]));
            if (low >= 0xDC00 && low <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                i++;
            }
        }
        // Encode as UTF-8
        if (cp < 0x80) {
            result += static_cast<char>(cp);
        } else if (cp < 0x800) {
            result += static_cast<char>(0xC0 | (cp >> 6));
            result += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            result += static_cast<char>(0xE0 | (cp >> 12));
            result += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            result += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            result += static_cast<char>(0xF0 | (cp >> 18));
            result += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            result += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            result += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }
    return result;
}

/// Context for ntfs_readdir filldir callback.
struct ReadDirContext {
    std::vector<std::pair<std::string, MFT_REF>> entries; // name + MFT ref
    std::vector<unsigned> dt_types;                        // NTFS_DT_* type
};

/// filldir callback for ntfs_readdir.
static int readdir_callback(void* dirent, const ntfschar* name, const int name_len,
                            const int name_type, const s64 /*pos*/,
                            const MFT_REF mref, const unsigned dt_type) {
    // Skip DOS 8.3 short names to avoid duplicates
    if (name_type == FILE_NAME_DOS) return 0;

    auto* ctx = static_cast<ReadDirContext*>(dirent);
    std::string utf8_name = from_ntfschar(name, name_len);

    // Skip . and .. entries
    if (utf8_name == "." || utf8_name == "..") return 0;

    ctx->entries.emplace_back(std::move(utf8_name), mref);
    ctx->dt_types.push_back(dt_type);
    return 0;
}

/// Split a path like "/Documents/Sub/file.txt" into components.
static std::vector<std::string> split_path(const std::string& path) {
    std::vector<std::string> parts;
    std::string current;
    for (char c : path) {
        if (c == '/') {
            if (!current.empty()) {
                parts.push_back(current);
                current.clear();
            }
        } else {
            current += c;
        }
    }
    if (!current.empty()) {
        parts.push_back(current);
    }
    return parts;
}

/// Navigate to an inode by following path components from root.
/// Returns the inode (caller must close) or nullptr.
static ntfs_inode* navigate_to_inode(ntfs_volume* vol, const std::string& rel_path) {
    return ntfs_pathname_to_inode(vol, nullptr, rel_path.c_str());
}

// ─── NtfsWriter ─────────────────────────────────────────────────────────────

NtfsWriter::~NtfsWriter() {
    if (is_open()) {
        close_volume();
    }
}

bool NtfsWriter::is_open() const {
    return session_.vol_handle != nullptr;
}

NtfsResult NtfsWriter::open_volume(const std::string& device_path,
                                   const std::string& mount_point) {
    if (is_open()) {
        return {false, "Volume already open"};
    }

    // Suppress libntfs-3g verbose logging (catastrophic for performance)
    ntfs_log_set_handler(ntfs_log_handler_null);

    // Note: caller (ObjC bridge) must unmount the volume and chmod the device BEFORE calling this.
    session_.was_mounted_by_os = !mount_point.empty();

    // Open via libntfs-3g (read-write)
    ntfs_volume* vol = ntfs_mount(device_path.c_str(), 0);
    if (!vol) {
        return {false, "libntfs-3g failed to open " + device_path + ": " + std::string(strerror(errno))};
    }

    session_.vol_handle = vol;
    session_.device_path = device_path;
    session_.mount_point = mount_point;

    return {true, ""};
}

NtfsResult NtfsWriter::close_volume() {
    if (!is_open()) {
        return {true, ""};
    }

    auto* vol = static_cast<ntfs_volume*>(session_.vol_handle);
    int rc = ntfs_umount(vol, static_cast<BOOL>(0));
    session_.vol_handle = nullptr;

    // Note: caller (ObjC bridge) must restore device permissions and re-mount.
    session_.was_mounted_by_os = false;

    if (rc != 0) {
        return {false, "ntfs_umount failed"};
    }
    return {true, ""};
}

NtfsResult NtfsWriter::ensure_parent_dirs(const std::string& rel_path) {
    auto parts = split_path(rel_path);
    if (parts.size() <= 1) return {true, ""};

    auto* vol = static_cast<ntfs_volume*>(session_.vol_handle);
    std::string current_path;

    // Create each parent directory if it doesn't exist
    for (size_t i = 0; i + 1 < parts.size(); i++) {
        current_path += "/" + parts[i];
        ntfs_inode* ni = navigate_to_inode(vol, current_path);
        if (ni) {
            ntfs_inode_close(ni);
            continue;
        }
        // Need to create this directory
        auto result = mkdir(current_path);
        if (!result.success) return result;
    }
    return {true, ""};
}

NtfsResult NtfsWriter::mkdir(const std::string& rel_path) {
    if (!is_open()) return {false, "Volume not open"};

    auto* vol = static_cast<ntfs_volume*>(session_.vol_handle);

    // Check if already exists
    ntfs_inode* existing = navigate_to_inode(vol, rel_path);
    if (existing) {
        ntfs_inode_close(existing);
        return {true, ""}; // Already exists
    }

    // Find parent directory
    auto parts = split_path(rel_path);
    if (parts.empty()) return {false, "Invalid path"};

    std::string parent_path;
    for (size_t i = 0; i + 1 < parts.size(); i++) {
        parent_path += "/" + parts[i];
    }

    ntfs_inode* parent_ni;
    if (parent_path.empty()) {
        parent_ni = ntfs_inode_open(vol, FILE_root);
    } else {
        parent_ni = navigate_to_inode(vol, parent_path);
    }
    if (!parent_ni) {
        return {false, "Parent directory not found: " + parent_path};
    }

    const std::string& dirname = parts.back();
    auto uname = to_ntfschar(dirname);

    ntfs_inode* new_dir = ntfs_create(parent_ni, 0,
                                       uname.data(),
                                       static_cast<u8>(uname.size()),
                                       S_IFDIR);
    ntfs_inode_close(parent_ni);

    if (!new_dir) {
        return {false, "Failed to create directory: " + rel_path + " — " + strerror(errno)};
    }

    ntfs_inode_close(new_dir);
    return {true, ""};
}

NtfsResult NtfsWriter::copy_file(const std::string& src_path,
                                  const std::string& dst_rel_path,
                                  NtfsProgressCallback progress,
                                  NtfsCancelCallback cancel) {
    if (!is_open()) return {false, "Volume not open"};

    // Ensure parent directories exist
    auto prep = ensure_parent_dirs(dst_rel_path);
    if (!prep.success) return prep;

    auto* vol = static_cast<ntfs_volume*>(session_.vol_handle);

    // Open source file
    int src_fd = open(src_path.c_str(), O_RDONLY);
    if (src_fd < 0) {
        return {false, "Cannot open source: " + src_path + " — " + strerror(errno)};
    }

    struct stat st;
    fstat(src_fd, &st);
    int64_t total_bytes = st.st_size;

    // Find parent inode and file name
    auto parts = split_path(dst_rel_path);
    if (parts.empty()) {
        ::close(src_fd);
        return {false, "Invalid destination path"};
    }

    std::string parent_path;
    for (size_t i = 0; i + 1 < parts.size(); i++) {
        parent_path += "/" + parts[i];
    }

    ntfs_inode* parent_ni;
    if (parent_path.empty()) {
        parent_ni = ntfs_inode_open(vol, FILE_root);
    } else {
        parent_ni = navigate_to_inode(vol, parent_path);
    }
    if (!parent_ni) {
        ::close(src_fd);
        return {false, "Parent directory not found on NTFS: " + parent_path};
    }

    const std::string& filename = parts.back();
    auto uname = to_ntfschar(filename);

    // Resolve the destination inode: reuse it if the file already exists,
    // otherwise create a new one.
    //
    // IMPORTANT: for an existing regular file we OVERWRITE IN PLACE (reuse the
    // inode and truncate its data below) instead of delete-then-create. The
    // delete+create sequence on the same name mutates the parent directory's
    // B-tree index twice in one session and was corrupting it — the directory
    // would read back empty after remount, losing every entry. Overwriting in
    // place leaves the directory index completely untouched.
    ntfs_inode* file_ni = navigate_to_inode(vol, dst_rel_path);
    if (file_ni) {
        const bool existingIsDir =
            (file_ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) != 0;
        if (existingIsDir) {
            // Replacing a directory with a file (rare): remove the directory
            // entry, then create a fresh file in its place.
            auto uname_del = to_ntfschar(filename);
            int del_rc = ntfs_delete(vol, dst_rel_path.c_str(),
                                     file_ni, parent_ni,
                                     uname_del.data(),
                                     static_cast<u8>(uname_del.size()));
            // ntfs_delete() closes BOTH file_ni AND parent_ni. Re-open the parent
            // before creating the replacement file (using it here would be a
            // use-after-close; closing it again would be a double-close).
            if (del_rc != 0) {
                ::close(src_fd);
                return {false, "Cannot replace directory with file: " + filename};
            }
            parent_ni = parent_path.empty()
                ? ntfs_inode_open(vol, FILE_root)
                : navigate_to_inode(vol, parent_path);
            if (!parent_ni) {
                ::close(src_fd);
                return {false, "Parent directory lost after delete: " + parent_path};
            }
            file_ni = ntfs_create(parent_ni, 0, uname.data(),
                                   static_cast<u8>(uname.size()), S_IFREG);
            ntfs_inode_close(parent_ni);
        } else {
            // Existing regular file → reuse it, data is truncated below.
            ntfs_inode_close(parent_ni);
        }
    } else {
        // New file → create it.
        file_ni = ntfs_create(parent_ni, 0, uname.data(),
                               static_cast<u8>(uname.size()), S_IFREG);
        ntfs_inode_close(parent_ni);
    }

    if (!file_ni) {
        ::close(src_fd);
        return {false, "Failed to create file on NTFS: " + filename + " — " + strerror(errno)};
    }

    // Open the $DATA attribute for writing
    ntfs_attr* na = ntfs_attr_open(file_ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) {
        ntfs_inode_close(file_ni);
        ::close(src_fd);
        return {false, "Failed to open $DATA attribute for " + filename};
    }

    // Clear any previous contents. For a freshly created file this is a no-op
    // (size already 0); for an overwritten file it drops the old data so no
    // stale tail remains past the end of the new, shorter file.
    if (ntfs_attr_truncate(na, 0) != 0) {
        ntfs_attr_close(na);
        ntfs_inode_close(file_ni);
        ::close(src_fd);
        return {false, "Failed to truncate destination: " + filename};
    }

    // Copy data in chunks
    std::vector<char> buffer(COPY_BUFFER_SIZE);
    int64_t bytes_written = 0;
    NtfsResult result{true, ""};

    while (true) {
        if (cancel && cancel()) {
            result = {false, "Cancelled"};
            break;
        }

        ssize_t bytes_read = read(src_fd, buffer.data(), buffer.size());
        if (bytes_read < 0) {
            result = {false, "Read error: " + std::string(strerror(errno))};
            break;
        }
        if (bytes_read == 0) break; // EOF

        // ntfs_attr_pwrite may write fewer bytes than requested — keep writing
        // the rest of this buffer before reading more, or the unwritten tail
        // would be silently dropped and the file truncated/corrupted.
        s64 chunk_off = 0;
        while (chunk_off < bytes_read) {
            s64 written = ntfs_attr_pwrite(na, bytes_written,
                                           bytes_read - chunk_off,
                                           buffer.data() + chunk_off);
            if (written <= 0) {
                result = {false, "NTFS write error at offset " + std::to_string(bytes_written)};
                break;
            }
            chunk_off += written;
            bytes_written += written;
        }
        if (!result.success) break;

        if (progress) {
            progress(bytes_written, total_bytes, src_path);
        }
    }

    ntfs_attr_close(na);
    ntfs_inode_close(file_ni);
    ::close(src_fd);

    return result;
}

NtfsResult NtfsWriter::copy_tree(const std::string& src_dir,
                                  const std::string& dst_rel_dir,
                                  NtfsProgressCallback progress,
                                  NtfsCancelCallback cancel) {
    if (!is_open()) return {false, "Volume not open"};

    // Create destination directory
    auto r = mkdir(dst_rel_dir);
    if (!r.success) return r;

    // Compute total bytes for progress
    int64_t total_bytes = compute_total_bytes(src_dir);
    int64_t accumulated = 0;

    // Iterate local directory
    std::error_code ec;
    for (auto& entry : fs::recursive_directory_iterator(src_dir, ec)) {
        if (cancel && cancel()) {
            return {false, "Cancelled"};
        }

        // Compute relative path
        std::string rel = entry.path().string().substr(src_dir.size());
        std::string ntfs_path = dst_rel_dir + rel;

        if (entry.is_directory(ec)) {
            auto dr = mkdir(ntfs_path);
            if (!dr.success) return dr;
        } else if (entry.is_regular_file(ec)) {
            int64_t file_size = static_cast<int64_t>(entry.file_size(ec));
            int64_t file_copied = 0;

            auto fr = copy_file(
                entry.path().string(),
                ntfs_path,
                [&](int64_t copied, int64_t /*total*/, const std::string& file) {
                    file_copied = copied;
                    if (progress) {
                        progress(accumulated + copied, total_bytes, file);
                    }
                },
                cancel
            );
            if (!fr.success) return fr;

            accumulated += file_size;
        }
        // Skip symlinks and special files
    }

    return {true, ""};
}

NtfsResult NtfsWriter::remove(const std::string& rel_path) {
    if (!is_open()) return {false, "Volume not open"};

    auto* vol = static_cast<ntfs_volume*>(session_.vol_handle);

    ntfs_inode* ni = navigate_to_inode(vol, rel_path);
    if (!ni) {
        return {false, "Path not found: " + rel_path};
    }

    // NTFS (like POSIX) refuses to delete a non-empty directory. If this is a
    // directory, recursively clear its contents first, then delete the now-empty
    // directory below. Without this, deleting any folder with files fails with
    // "Directory not empty".
    const bool isDir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) != 0;
    if (isDir) {
        ntfs_inode_close(ni);   // reopened after the children are gone
        std::vector<NtfsFileEntry> children;
        auto lr = list_directory(rel_path, children);
        if (!lr.success) return lr;

        std::string base = rel_path;
        if (!base.empty() && base.back() == '/') base.pop_back();
        for (const auto& child : children) {
            if (child.name == "." || child.name == "..") continue;
            const std::string childPath = base + "/" + child.name;
            auto r = remove(childPath);
            if (!r.success) {
                // A child can be listed under both its long and short (8.3) NTFS
                // name, so a second delete finds it already gone — that's fine.
                // Only a child that is still present counts as a real failure.
                ntfs_inode* check = navigate_to_inode(vol, childPath);
                if (check) { ntfs_inode_close(check); return r; }
            }
        }

        ni = navigate_to_inode(vol, rel_path);
        if (!ni) return {true, ""};   // directory already removed
    }

    // Get parent directory and filename for ntfs_delete
    auto parts = split_path(rel_path);
    if (parts.empty()) {
        ntfs_inode_close(ni);
        return {false, "Invalid path"};
    }

    std::string parent_path;
    for (size_t i = 0; i + 1 < parts.size(); i++) {
        parent_path += "/" + parts[i];
    }

    ntfs_inode* dir_ni;
    if (parent_path.empty()) {
        dir_ni = ntfs_inode_open(vol, FILE_root);
    } else {
        dir_ni = navigate_to_inode(vol, parent_path);
    }
    if (!dir_ni) {
        ntfs_inode_close(ni);
        return {false, "Parent directory not found: " + parent_path};
    }

    auto uname = to_ntfschar(parts.back());
    int rc = ntfs_delete(vol, rel_path.c_str(), ni, dir_ni,
                          uname.data(), static_cast<u8>(uname.size()));
    // IMPORTANT: ntfs_delete() closes BOTH `ni` AND `dir_ni` (see its `out:`
    // label in third_party/ntfs-3g/dir.c — the doc-comment only mentions `ni`,
    // but the implementation closes both, on success and on failure). Closing
    // dir_ni again here was a double-close that corrupted the in-memory inode
    // cache and, on umount, wrote stale directory records back to disk —
    // silently destroying the volume's directory structure.

    if (rc != 0) {
        return {false, "Failed to delete: " + rel_path + " — " + strerror(errno)};
    }

    return {true, ""};
}

NtfsResult NtfsWriter::rename(const std::string& old_rel_path,
                              const std::string& new_rel_path) {
    if (!is_open()) return {false, "Volume not open"};

    auto* vol = static_cast<ntfs_volume*>(session_.vol_handle);

    // Open the inode to rename
    ntfs_inode* ni = navigate_to_inode(vol, old_rel_path);
    if (!ni) {
        return {false, "Source not found: " + old_rel_path};
    }

    // Get old parent dir and old name
    auto old_parts = split_path(old_rel_path);
    if (old_parts.empty()) {
        ntfs_inode_close(ni);
        return {false, "Invalid source path"};
    }

    std::string old_parent_path;
    for (size_t i = 0; i + 1 < old_parts.size(); i++) {
        old_parent_path += "/" + old_parts[i];
    }

    ntfs_inode* old_dir;
    if (old_parent_path.empty()) {
        old_dir = ntfs_inode_open(vol, FILE_root);
    } else {
        old_dir = navigate_to_inode(vol, old_parent_path);
    }
    if (!old_dir) {
        ntfs_inode_close(ni);
        return {false, "Source parent directory not found"};
    }

    // Get new parent dir and new name
    auto new_parts = split_path(new_rel_path);
    if (new_parts.empty()) {
        ntfs_inode_close(ni);
        ntfs_inode_close(old_dir);
        return {false, "Invalid destination path"};
    }

    std::string new_parent_path;
    for (size_t i = 0; i + 1 < new_parts.size(); i++) {
        new_parent_path += "/" + new_parts[i];
    }

    ntfs_inode* new_dir;
    if (new_parent_path.empty()) {
        new_dir = ntfs_inode_open(vol, FILE_root);
    } else {
        new_dir = navigate_to_inode(vol, new_parent_path);
    }
    if (!new_dir) {
        ntfs_inode_close(ni);
        ntfs_inode_close(old_dir);
        return {false, "Destination parent directory not found"};
    }

    auto old_uname = to_ntfschar(old_parts.back());
    auto new_uname = to_ntfschar(new_parts.back());

    int rc = ntfs_link(ni, new_dir, new_uname.data(), static_cast<u8>(new_uname.size()));
    if (rc != 0) {
        ntfs_inode_close(ni);
        ntfs_inode_close(old_dir);
        ntfs_inode_close(new_dir);
        return {false, "Failed to create new link: " + new_rel_path + " — " + strerror(errno)};
    }

    // Remove old link
    rc = ntfs_delete(vol, old_rel_path.c_str(), ni, old_dir,
                     old_uname.data(), static_cast<u8>(old_uname.size()));
    // ntfs_delete() closes BOTH `ni` AND `old_dir` (see remove() above). Only
    // `new_dir` (from ntfs_link, which does not close it) must be closed here.
    // Closing old_dir again was a double-close that corrupted the inode cache.
    ntfs_inode_close(new_dir);

    if (rc != 0) {
        return {false, "Failed to remove old link: " + old_rel_path + " — " + strerror(errno)};
    }

    return {true, ""};
}

NtfsResult NtfsWriter::list_directory(const std::string& rel_path,
                                      std::vector<NtfsFileEntry>& out_entries) {
    if (!is_open()) return {false, "Volume not open"};

    auto* vol = static_cast<ntfs_volume*>(session_.vol_handle);

    // Open directory inode
    ntfs_inode* dir_ni;
    if (rel_path.empty() || rel_path == "/") {
        dir_ni = ntfs_inode_open(vol, FILE_root);
    } else {
        dir_ni = navigate_to_inode(vol, rel_path);
    }
    if (!dir_ni) {
        return {false, "Directory not found: " + rel_path};
    }

    // Collect entries via readdir callback
    ReadDirContext ctx;
    s64 pos = 0;
    int rc = ntfs_readdir(dir_ni, &pos, &ctx, readdir_callback);
    ntfs_inode_close(dir_ni);

    if (rc != 0 && rc != -1) {
        // rc == -1 with errno==0 means end-of-directory (normal)
        if (errno != 0) {
            return {false, "ntfs_readdir failed: " + std::string(strerror(errno))};
        }
    }

    // Now open each inode to get metadata
    out_entries.clear();
    out_entries.reserve(ctx.entries.size());

    for (size_t i = 0; i < ctx.entries.size(); i++) {
        const auto& [name, mref] = ctx.entries[i];
        NtfsFileEntry entry;
        entry.name = name;
        entry.is_directory = (ctx.dt_types[i] == NTFS_DT_DIR);

        // Open inode for metadata
        ntfs_inode* ni = ntfs_inode_open(vol, MREF(mref));
        if (ni) {
            entry.size = ni->data_size;
            entry.is_hidden = (ni->flags & FILE_ATTR_HIDDEN) != 0;

            // Convert NTFS times to Unix timestamps
            struct timespec ts;
            ts = ntfs2timespec(ni->creation_time);
            entry.creation_time = ts.tv_sec;
            ts = ntfs2timespec(ni->last_data_change_time);
            entry.modification_time = ts.tv_sec;

            ntfs_inode_close(ni);
        } else {
            // Fallback: use dt_type, zero size/time
            entry.size = 0;
            entry.creation_time = 0;
            entry.modification_time = 0;
        }

        // Also treat dot-prefixed files as hidden (Unix convention)
        if (!entry.is_hidden && !name.empty() && name[0] == '.') {
            entry.is_hidden = true;
        }

        out_entries.push_back(std::move(entry));
    }

    return {true, ""};
}

NtfsResult NtfsWriter::read_file(const std::string& rel_path,
                                  const std::string& local_dest_path,
                                  NtfsProgressCallback progress,
                                  NtfsCancelCallback cancel) {
    if (!is_open()) return {false, "Volume not open"};

    auto* vol = static_cast<ntfs_volume*>(session_.vol_handle);

    ntfs_inode* ni = navigate_to_inode(vol, rel_path);
    if (!ni) {
        return {false, "File not found on NTFS: " + rel_path};
    }

    int64_t total_bytes = ni->data_size;

    // Open $DATA attribute for reading
    ntfs_attr* na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) {
        ntfs_inode_close(ni);
        return {false, "Failed to open $DATA attribute: " + rel_path};
    }

    // Open local destination file for writing
    int dest_fd = open(local_dest_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (dest_fd < 0) {
        ntfs_attr_close(na);
        ntfs_inode_close(ni);
        return {false, "Cannot create local file: " + local_dest_path + " — " + strerror(errno)};
    }

    // Read in chunks
    std::vector<char> buffer(COPY_BUFFER_SIZE);
    int64_t bytes_read_total = 0;
    NtfsResult result{true, ""};

    while (bytes_read_total < total_bytes) {
        if (cancel && cancel()) {
            result = {false, "Cancelled"};
            break;
        }

        s64 buf_size = static_cast<s64>(buffer.size());
        s64 remaining = static_cast<s64>(total_bytes - bytes_read_total);
        s64 to_read = buf_size < remaining ? buf_size : remaining;
        s64 got = ntfs_attr_pread(na, bytes_read_total, to_read, buffer.data());
        if (got <= 0) {
            if (got == 0) break; // EOF
            result = {false, "NTFS read error at offset " + std::to_string(bytes_read_total)};
            break;
        }

        ssize_t written = write(dest_fd, buffer.data(), static_cast<size_t>(got));
        if (written < 0) {
            result = {false, "Local write error: " + std::string(strerror(errno))};
            break;
        }

        bytes_read_total += got;

        if (progress) {
            progress(bytes_read_total, total_bytes, rel_path);
        }
    }

    ::close(dest_fd);
    ntfs_attr_close(na);
    ntfs_inode_close(ni);

    if (!result.success) {
        // Clean up partial file on error
        unlink(local_dest_path.c_str());
    }

    return result;
}

int64_t NtfsWriter::compute_total_bytes(const std::string& local_path) {
    int64_t total = 0;
    std::error_code ec;
    for (auto& entry : fs::recursive_directory_iterator(local_path, ec)) {
        if (entry.is_regular_file(ec)) {
            total += static_cast<int64_t>(entry.file_size(ec));
        }
    }
    return total;
}

// ─── Volume detection ────────────────────────────────────────────────────────

NtfsVolumeInfo detect_ntfs_volume(const std::string& path) {
    NtfsVolumeInfo info;

    struct statfs buf;
    if (statfs(path.c_str(), &buf) != 0) {
        return info;
    }

    info.fs_type = buf.f_fstypename;
    info.mount_point = buf.f_mntonname;
    info.device_path = buf.f_mntfromname;
    info.is_read_only = (buf.f_flags & MNT_RDONLY) != 0;

    return info;
}

} // namespace fcxl
