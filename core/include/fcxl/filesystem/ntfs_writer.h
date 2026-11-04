#pragma once

#include <string>
#include <vector>
#include <functional>
#include <cstdint>

namespace fcxl {

/// Result of an NTFS operation.
struct NtfsResult {
    bool success{false};
    std::string error;
};

/// Progress callback: (bytes_copied, total_bytes, current_file)
using NtfsProgressCallback = std::function<void(int64_t, int64_t, const std::string&)>;
/// Cancel check callback
using NtfsCancelCallback = std::function<bool()>;

/// A single directory entry returned by list_directory().
struct NtfsFileEntry {
    std::string name;
    bool is_directory{false};
    bool is_hidden{false};
    int64_t size{0};
    int64_t creation_time{0};      // Unix timestamp (seconds since epoch)
    int64_t modification_time{0};  // Unix timestamp (seconds since epoch)
};

/// Information about a mounted NTFS volume (for the raw-device approach).
struct NtfsVolumeSession {
    void* vol_handle{nullptr};       // ntfs_volume*
    std::string device_path;         // e.g. /dev/disk4s1
    std::string mount_point;         // e.g. /Volumes/Toshiba
    bool was_mounted_by_os{false};   // true if we had to unmount macOS driver
};

/// High-level NTFS writer.
/// Workflow:
///   1. open_volume()  — unmounts macOS read-only driver, opens raw device via libntfs-3g
///   2. copy_file() / mkdir() / copy_tree()  — file operations
///   3. close_volume() — closes libntfs-3g, re-mounts volume via macOS
class NtfsWriter {
public:
    NtfsWriter() = default;
    ~NtfsWriter();

    // Non-copyable
    NtfsWriter(const NtfsWriter&) = delete;
    NtfsWriter& operator=(const NtfsWriter&) = delete;

    /// Open an NTFS volume for writing.
    /// @param device_path  Raw device, e.g. "/dev/disk4s1"
    /// @param mount_point  Current macOS mount point, e.g. "/Volumes/Toshiba"
    NtfsResult open_volume(const std::string& device_path,
                           const std::string& mount_point);

    /// Close the volume and optionally re-mount via macOS.
    NtfsResult close_volume();

    /// Check if a volume is currently open.
    bool is_open() const;

    /// Copy a single file from the local filesystem to the NTFS volume.
    /// @param src_path     Local source file path
    /// @param dst_rel_path Destination path relative to NTFS root (e.g. "/Documents/file.txt")
    NtfsResult copy_file(const std::string& src_path,
                         const std::string& dst_rel_path,
                         NtfsProgressCallback progress = nullptr,
                         NtfsCancelCallback cancel = nullptr);

    /// Create a directory on the NTFS volume.
    /// @param rel_path  Path relative to NTFS root (e.g. "/Documents/NewFolder")
    NtfsResult mkdir(const std::string& rel_path);

    /// Recursively copy a directory tree from local FS to NTFS volume.
    /// @param src_dir      Local source directory
    /// @param dst_rel_dir  Destination path relative to NTFS root
    NtfsResult copy_tree(const std::string& src_dir,
                         const std::string& dst_rel_dir,
                         NtfsProgressCallback progress = nullptr,
                         NtfsCancelCallback cancel = nullptr);

    /// Delete a file or directory on the NTFS volume.
    /// @param rel_path  Path relative to NTFS root
    NtfsResult remove(const std::string& rel_path);

    /// Rename (move) a file or directory within the NTFS volume.
    /// @param old_rel_path  Current path relative to NTFS root
    /// @param new_rel_path  New path relative to NTFS root
    NtfsResult rename(const std::string& old_rel_path,
                      const std::string& new_rel_path);

    /// List directory contents on the NTFS volume.
    /// @param rel_path    Directory path relative to NTFS root (e.g. "/" or "/Documents")
    /// @param out_entries Receives the directory entries
    NtfsResult list_directory(const std::string& rel_path,
                              std::vector<NtfsFileEntry>& out_entries);

    /// Read a file from the NTFS volume to a local filesystem path.
    /// @param rel_path        Source path relative to NTFS root
    /// @param local_dest_path Local destination file path
    NtfsResult read_file(const std::string& rel_path,
                         const std::string& local_dest_path,
                         NtfsProgressCallback progress = nullptr,
                         NtfsCancelCallback cancel = nullptr);

    /// Get the current session info.
    const NtfsVolumeSession& session() const { return session_; }

private:
    NtfsVolumeSession session_;

    /// Helper: ensure parent directories exist on NTFS for a given relative path.
    NtfsResult ensure_parent_dirs(const std::string& rel_path);

    /// Helper: compute total bytes for progress reporting.
    int64_t compute_total_bytes(const std::string& local_path);
};

/// Utility: detect NTFS volume info for a given macOS path.
/// Returns device_path and mount_point for use with NtfsWriter.
struct NtfsVolumeInfo {
    std::string device_path;   // e.g. /dev/disk4s1
    std::string mount_point;   // e.g. /Volumes/Toshiba
    std::string fs_type;       // e.g. "ntfs"
    bool is_read_only{false};
};

NtfsVolumeInfo detect_ntfs_volume(const std::string& path);

} // namespace fcxl
