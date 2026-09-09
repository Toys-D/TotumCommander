#include "fcxl/network/sftp_client.h"
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <chrono>
#include <fstream>
#include <cstring>
#include <mutex>
#include <thread>

namespace fcxl::network {

struct SftpClient::Impl {
    int sock = -1;
    LIBSSH2_SESSION* session = nullptr;
    LIBSSH2_SFTP* sftp = nullptr;
    SftpConnectionInfo info;
    bool connected = false;
    int64_t max_download_bps = 0;
    int64_t max_upload_bps = 0;
};

/// Holds a transfer down to an average rate by sleeping off whatever it ran ahead by.
///
/// libssh2 has no throttle of its own, so the pacing is ours. It is deliberately about the
/// AVERAGE since the transfer started, not about each block: a single slow block must not
/// earn the right to race afterwards, and a single fast one must not stall the next ten.
class SpeedPacer {
public:
    explicit SpeedPacer(int64_t bytes_per_second) : limit_(bytes_per_second) {}

    void wait_out(int64_t bytes) {
        if (limit_ <= 0) return;
        moved_ += bytes;
        const auto deserved = std::chrono::duration<double>(double(moved_) / double(limit_));
        const auto spent = std::chrono::steady_clock::now() - started_;
        if (deserved > spent) std::this_thread::sleep_for(deserved - spent);
    }

private:
    int64_t limit_;
    int64_t moved_ = 0;
    std::chrono::steady_clock::time_point started_ = std::chrono::steady_clock::now();
};

static std::once_flag ssh2_init_flag;
static void ensure_ssh2_initialized() {
    std::call_once(ssh2_init_flag, [] {
        libssh2_init(0);
    });
}

SftpClient::SftpClient() : impl_(new Impl()) {
    ensure_ssh2_initialized();
}

SftpClient::~SftpClient() {
    disconnect();
    delete impl_;
}

auto SftpClient::is_connected() const -> bool { return impl_->connected; }

auto SftpClient::connect(const SftpConnectionInfo& info) -> common::Result<void> {
    disconnect();
    impl_->info = info;

    // Resolve host
    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    auto port_str = std::to_string(info.port);
    int rc = getaddrinfo(info.host.c_str(), port_str.c_str(), &hints, &res);
    if (rc != 0 || !res) {
        return common::Error::make(common::ErrorCode::NetworkError,
                                   "Cannot resolve host: " + info.host);
    }

    impl_->sock = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (impl_->sock < 0) {
        freeaddrinfo(res);
        return common::Error::make(common::ErrorCode::NetworkError, "Socket creation failed");
    }

    // Set timeout
    struct timeval tv;
    tv.tv_sec = info.timeout_seconds;
    tv.tv_usec = 0;
    setsockopt(impl_->sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(impl_->sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    if (::connect(impl_->sock, res->ai_addr, res->ai_addrlen) != 0) {
        freeaddrinfo(res);
        close(impl_->sock);
        impl_->sock = -1;
        return common::Error::make(common::ErrorCode::NetworkError,
                                   "Connection to " + info.host + ":" + port_str + " failed");
    }
    freeaddrinfo(res);

    // Create SSH session
    impl_->session = libssh2_session_init();
    if (!impl_->session) {
        close(impl_->sock);
        impl_->sock = -1;
        return common::Error::make(common::ErrorCode::NetworkError, "SSH session init failed");
    }

    libssh2_session_set_timeout(impl_->session, info.timeout_seconds * 1000);

    rc = libssh2_session_handshake(impl_->session, impl_->sock);
    if (rc) {
        disconnect();
        return common::Error::make(common::ErrorCode::NetworkError,
                                   "SSH handshake failed (rc=" + std::to_string(rc) + ")");
    }

    // Authenticate
    if (!info.private_key_path.empty()) {
        // Key-based auth
        rc = libssh2_userauth_publickey_fromfile(
            impl_->session,
            info.username.c_str(),
            nullptr, // public key derived from private key
            info.private_key_path.c_str(),
            info.password.c_str() // passphrase
        );
    } else {
        // Password auth
        rc = libssh2_userauth_password(impl_->session,
                                        info.username.c_str(),
                                        info.password.c_str());
    }

    if (rc) {
        disconnect();
        return common::Error::make(common::ErrorCode::PermissionDenied,
                                   "SSH authentication failed for " + info.username);
    }

    // Open SFTP channel
    impl_->sftp = libssh2_sftp_init(impl_->session);
    if (!impl_->sftp) {
        disconnect();
        return common::Error::make(common::ErrorCode::NetworkError, "SFTP subsystem init failed");
    }

    impl_->connected = true;
    return {};
}

void SftpClient::disconnect() {
    if (impl_->sftp) {
        libssh2_sftp_shutdown(impl_->sftp);
        impl_->sftp = nullptr;
    }
    if (impl_->session) {
        libssh2_session_disconnect(impl_->session, "Bye");
        libssh2_session_free(impl_->session);
        impl_->session = nullptr;
    }
    if (impl_->sock >= 0) {
        close(impl_->sock);
        impl_->sock = -1;
    }
    impl_->connected = false;
}

auto SftpClient::list_directory(std::string_view path)
    -> common::Result<std::vector<common::FileEntry>> {
    if (!impl_->connected || !impl_->sftp)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");

    std::string dir(path);
    auto* handle = libssh2_sftp_opendir(impl_->sftp, dir.c_str());
    if (!handle) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Cannot open directory: " + dir);
    }

    std::vector<common::FileEntry> entries;
    char buf[512];
    LIBSSH2_SFTP_ATTRIBUTES attrs;

    while (true) {
        int rc = libssh2_sftp_readdir(handle, buf, sizeof(buf), &attrs);
        if (rc <= 0) break;

        std::string name(buf, rc);
        if (name == "." || name == "..") continue;

        common::FileEntry e;
        e.name = name;

        std::string bp(path);
        if (!bp.empty() && bp.back() == '/') bp.pop_back();
        e.path = bp + "/" + name;

        if (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) {
            if (LIBSSH2_SFTP_S_ISDIR(attrs.permissions))
                e.type = common::EntryType::Directory;
            else if (LIBSSH2_SFTP_S_ISLNK(attrs.permissions))
                e.type = common::EntryType::Symlink;
            else
                e.type = common::EntryType::File;

            // Format permissions like -rwxr-xr-x
            char perm[11] = "----------";
            auto p = attrs.permissions;
            if (LIBSSH2_SFTP_S_ISDIR(p)) perm[0] = 'd';
            else if (LIBSSH2_SFTP_S_ISLNK(p)) perm[0] = 'l';
            if (p & LIBSSH2_SFTP_S_IRUSR) perm[1] = 'r';
            if (p & LIBSSH2_SFTP_S_IWUSR) perm[2] = 'w';
            if (p & LIBSSH2_SFTP_S_IXUSR) perm[3] = 'x';
            if (p & LIBSSH2_SFTP_S_IRGRP) perm[4] = 'r';
            if (p & LIBSSH2_SFTP_S_IWGRP) perm[5] = 'w';
            if (p & LIBSSH2_SFTP_S_IXGRP) perm[6] = 'x';
            if (p & LIBSSH2_SFTP_S_IROTH) perm[7] = 'r';
            if (p & LIBSSH2_SFTP_S_IWOTH) perm[8] = 'w';
            if (p & LIBSSH2_SFTP_S_IXOTH) perm[9] = 'x';
            e.permissions = perm;
        }

        if (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE)
            e.size = attrs.filesize;

        if (attrs.flags & LIBSSH2_SFTP_ATTR_ACMODTIME) {
            e.date_modified = std::chrono::system_clock::from_time_t(
                static_cast<time_t>(attrs.mtime));
        }

        auto dot = name.rfind('.');
        if (dot != std::string::npos && dot > 0 && e.type != common::EntryType::Directory)
            e.extension = name.substr(dot + 1);

        e.is_hidden = (!name.empty() && name[0] == '.');
        e.is_symlink = (e.type == common::EntryType::Symlink);

        entries.push_back(std::move(e));
    }

    libssh2_sftp_closedir(handle);
    return entries;
}

auto SftpClient::download(std::string_view remote, std::string_view local,
                          int64_t resume_from, ProgressCallback progress)
    -> common::Result<void> {
    if (!impl_->connected || !impl_->sftp)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");

    std::string rpath(remote);
    auto* handle = libssh2_sftp_open(impl_->sftp, rpath.c_str(),
                                      LIBSSH2_FXF_READ, 0);
    if (!handle) {
        return common::Error::make(common::ErrorCode::NotFound,
                                   "Cannot open remote file: " + rpath);
    }

    // Get file size
    LIBSSH2_SFTP_ATTRIBUTES attrs;
    int64_t total = 0;
    if (libssh2_sftp_fstat(handle, &attrs) == 0 && (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE))
        total = static_cast<int64_t>(attrs.filesize);

    if (resume_from < 0) resume_from = 0;
    if (resume_from > 0 && total > 0 && resume_from > total) {
        // We hold more than the server has — the remote file was replaced while we were
        // away, and continuing would splice two different files together.
        libssh2_sftp_close(handle);
        return common::Error::make(common::ErrorCode::NotSupported,
                                   "Cannot continue: the remote file is shorter than what "
                                   "is already downloaded");
    }
    if (resume_from > 0) libssh2_sftp_seek64(handle, static_cast<libssh2_uint64_t>(resume_from));

    std::ofstream file(std::string(local),
                       resume_from > 0 ? (std::ios::binary | std::ios::app)
                                       : (std::ios::binary | std::ios::trunc));
    if (!file.is_open()) {
        libssh2_sftp_close(handle);
        return common::Error::make(common::ErrorCode::IOError,
                                   "Cannot open local file: " + std::string(local));
    }

    char buf[32768];
    int64_t done = resume_from;
    SpeedPacer pacer(impl_->max_download_bps);
    while (true) {
        auto n = libssh2_sftp_read(handle, buf, sizeof(buf));
        if (n < 0) {
            file.close();
            libssh2_sftp_close(handle);
            return common::Error::make(common::ErrorCode::NetworkError, "SFTP read error");
        }
        if (n == 0) break;
        file.write(buf, n);
        done += n;
        pacer.wait_out(n);
        if (progress && progress(done, total)) {
            file.close();
            libssh2_sftp_close(handle);
            return common::Error::make(common::ErrorCode::Cancelled, "Download cancelled");
        }
    }

    file.close();
    libssh2_sftp_close(handle);
    return {};
}

auto SftpClient::upload(std::string_view local, std::string_view remote,
                        int64_t resume_from, ProgressCallback progress)
    -> common::Result<void> {
    if (!impl_->connected || !impl_->sftp)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");

    std::ifstream file(std::string(local), std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        return common::Error::make(common::ErrorCode::IOError,
                                   "Cannot open local file: " + std::string(local));
    }
    int64_t total = file.tellg();

    if (resume_from < 0) resume_from = 0;
    if (resume_from > total) {
        return common::Error::make(common::ErrorCode::NotSupported,
                                   "Cannot continue: the local file is shorter than what is "
                                   "already on the server");
    }
    file.seekg(resume_from);

    std::string rpath(remote);
    // Continuing must NOT truncate — the bytes already on the server are the point.
    const long open_flags = resume_from > 0
        ? (LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT)
        : (LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC);
    auto* handle = libssh2_sftp_open(impl_->sftp, rpath.c_str(), open_flags,
                                      LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
                                      LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH);
    if (!handle) {
        return common::Error::make(common::ErrorCode::PermissionDenied,
                                   "Cannot create remote file: " + rpath);
    }
    if (resume_from > 0) {
        // Trust the offset only if the server really holds that much: a shorter remote file
        // would leave a hole of zeros in the middle, and nothing downstream would notice.
        LIBSSH2_SFTP_ATTRIBUTES attrs;
        if (libssh2_sftp_fstat(handle, &attrs) == 0 && (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) &&
            static_cast<int64_t>(attrs.filesize) < resume_from) {
            libssh2_sftp_close(handle);
            return common::Error::make(common::ErrorCode::NotSupported,
                                       "Cannot continue: the server holds less than expected");
        }
        libssh2_sftp_seek64(handle, static_cast<libssh2_uint64_t>(resume_from));
    }

    char buf[32768];
    int64_t done = resume_from;
    SpeedPacer pacer(impl_->max_upload_bps);
    while (file.good()) {
        file.read(buf, sizeof(buf));
        auto n = file.gcount();
        if (n <= 0) break;

        ssize_t written = 0;
        while (written < n) {
            auto rc = libssh2_sftp_write(handle, buf + written, n - written);
            if (rc < 0) {
                libssh2_sftp_close(handle);
                return common::Error::make(common::ErrorCode::NetworkError, "SFTP write error");
            }
            written += rc;
        }
        done += n;
        pacer.wait_out(n);
        if (progress && progress(done, total)) {
            libssh2_sftp_close(handle);
            return common::Error::make(common::ErrorCode::Cancelled, "Upload cancelled");
        }
    }

    libssh2_sftp_close(handle);
    return {};
}

void SftpClient::set_speed_limits(int64_t download_bytes_per_second,
                                  int64_t upload_bytes_per_second) {
    impl_->max_download_bps = download_bytes_per_second > 0 ? download_bytes_per_second : 0;
    impl_->max_upload_bps = upload_bytes_per_second > 0 ? upload_bytes_per_second : 0;
}

auto SftpClient::remove(std::string_view remote) -> common::Result<void> {
    if (!impl_->connected || !impl_->sftp)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");
    std::string path(remote);
    int rc = libssh2_sftp_unlink(impl_->sftp, path.c_str());
    if (rc) return common::Error::make(common::ErrorCode::NetworkError, "SFTP unlink failed");
    return {};
}

auto SftpClient::remove_directory(std::string_view remote) -> common::Result<void> {
    if (!impl_->connected || !impl_->sftp)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");
    std::string path(remote);
    int rc = libssh2_sftp_rmdir(impl_->sftp, path.c_str());
    if (rc) return common::Error::make(common::ErrorCode::NetworkError, "SFTP rmdir failed");
    return {};
}

auto SftpClient::create_directory(std::string_view remote) -> common::Result<void> {
    if (!impl_->connected || !impl_->sftp)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");
    std::string path(remote);
    int rc = libssh2_sftp_mkdir(impl_->sftp, path.c_str(),
                                 LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP |
                                 LIBSSH2_SFTP_S_IXGRP | LIBSSH2_SFTP_S_IROTH |
                                 LIBSSH2_SFTP_S_IXOTH);
    if (rc) return common::Error::make(common::ErrorCode::NetworkError, "SFTP mkdir failed");
    return {};
}

auto SftpClient::rename(std::string_view from, std::string_view to) -> common::Result<void> {
    if (!impl_->connected || !impl_->sftp)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");
    std::string f(from), t(to);
    int rc = libssh2_sftp_rename(impl_->sftp, f.c_str(), t.c_str());
    if (rc) return common::Error::make(common::ErrorCode::NetworkError, "SFTP rename failed");
    return {};
}

} // namespace fcxl::network
