#include "fcxl/network/ftp_client.h"
#include <curl/curl.h>
#include <fstream>
#include <sstream>
#include <cstring>
#include <cstdio>
#include <cctype>
#include <optional>
#include <mutex>

namespace fcxl::network {

/// How long a transfer may say nothing at all before the link is declared dead. Short enough
/// that a pulled cable is noticed while the person is still looking at the window: the real
/// server answers in tens of milliseconds, so ten seconds of NOTHING is already an eternity.
constexpr long kSilenceLimitSeconds = 10;

// MARK: - Internal state — single persistent handle per session

struct FtpClient::Impl {
    CURL* curl = nullptr;
    ConnectionInfo info;
    bool connected = false;
    // Kept here rather than in ConnectionInfo: a bandwidth ceiling is the user's setting for
    // the whole app, not part of the saved connection. Re-applied after every reset.
    int64_t max_download_bps = 0;
    int64_t max_upload_bps = 0;
    // "*OPTS UTF8 ON" — sent before ordinary ops so the server uses UTF-8 for filenames.
    // Owned here; referenced by curl via CURLOPT_QUOTE, freed on disconnect.
    curl_slist* utf8_quote = nullptr;
    // Последняя строка, пришедшая по управляющему каналу: «530 User cannot log in.».
    // Из неё складывается то, что человек прочтёт вместо английского «Login denied».
    std::string last_reply;

    void apply_options();
    void reset_for_next_op();
};

// MARK: - libcurl callbacks

struct WriteData { std::string buffer; };

static size_t write_cb(char* ptr, size_t size, size_t nmemb, void* ud) {
    static_cast<WriteData*>(ud)->buffer.append(ptr, size * nmemb);
    return size * nmemb;
}

/// Ответы управляющего канала. Оставляем последнюю непустую строку: именно её сервер
/// сказал перед тем, как всё кончилось, и именно она объясняет человеку, что произошло.
static size_t control_reply_cb(char* ptr, size_t size, size_t nmemb, void* ud) {
    const size_t bytes = size * nmemb;
    auto* out = static_cast<std::string*>(ud);
    if (!out) return bytes;
    std::string line(ptr, bytes);
    while (!line.empty() && std::isspace(static_cast<unsigned char>(line.back()))) line.pop_back();
    if (!line.empty()) *out = line;
    return bytes;
}

static size_t write_file_cb(char* ptr, size_t size, size_t nmemb, void* ud) {
    static_cast<std::ofstream*>(ud)->write(ptr, static_cast<std::streamsize>(size * nmemb));
    return size * nmemb;
}

static size_t read_file_cb(char* buf, size_t size, size_t nmemb, void* ud) {
    auto* f = static_cast<std::ifstream*>(ud);
    f->read(buf, static_cast<std::streamsize>(size * nmemb));
    return static_cast<size_t>(f->gcount());
}

/// `offset` is what already lay at the destination when this transfer started, and
/// `known_total` the size of the whole file when the caller knows it (it does for uploads).
/// A resumed transfer must report the progress of the WHOLE file: without the offset the bar
/// would fall back to zero on every reconnect, and the person watching would think the
/// previous hour was lost.
struct ProgressData {
    ProgressCallback callback;
    bool cancelled = false;
    int64_t offset = 0;
    int64_t known_total = 0;
};

/// curl codes that mean the transport itself is gone (as opposed to "the server said no").
/// CURLE_OPERATION_TIMEDOUT is what the low-speed watchdog raises when a transfer goes silent.
/// On any of these the session is marked disconnected so callers stop reusing a dead handle.
static bool is_transport_dead(CURLcode res) {
    switch (res) {
        case CURLE_OPERATION_TIMEDOUT:
        case CURLE_COULDNT_CONNECT:
        case CURLE_RECV_ERROR:
        case CURLE_SEND_ERROR:
        case CURLE_GOT_NOTHING:
        case CURLE_PARTIAL_FILE:
            return true;
        default:
            return false;
    }
}

/// Tells "the link broke" apart from "this server cannot continue a transfer at all".
/// Old or minimal FTP servers answer REST/APPE with a refusal, and curl reports it as a
/// range error. That is not a network failure and retrying identically would fail forever —
/// the caller has to drop what it has and start from zero, so it gets a distinct code.
static auto transfer_error(CURLcode res, int64_t resume_from) -> common::Error {
    if (resume_from > 0 && (res == CURLE_RANGE_ERROR || res == CURLE_BAD_DOWNLOAD_RESUME)) {
        return common::Error::make(
            common::ErrorCode::NotSupported,
            std::string("Server refused to continue the transfer: ") + curl_easy_strerror(res));
    }
    return common::Error::make(common::ErrorCode::NetworkError, curl_easy_strerror(res));
}

/// Три первые цифры ответа сервера — 0, если строка начинается не с них.
static int reply_code(std::string_view reply) {
    if (reply.size() < 3) return 0;
    for (int i = 0; i < 3; ++i)
        if (!std::isdigit(static_cast<unsigned char>(reply[i]))) return 0;
    return (reply[0] - '0') * 100 + (reply[1] - '0') * 10 + (reply[2] - '0');
}

static std::string trim_copy(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && std::isspace(static_cast<unsigned char>(s[b]))) ++b;
    while (e > b && std::isspace(static_cast<unsigned char>(s[e - 1]))) --e;
    return std::string(s.substr(b, e - b));
}

auto describe_connect_failure(int curl_code, std::string_view last_reply,
                              std::string_view fallback) -> ConnectFailure {
    const auto reply = trim_copy(last_reply);
    const int code = reply_code(reply);
    const auto words = reply.empty() ? trim_copy(fallback) : reply;

    // Сервер отказал прямо: 530 у большинства, 430 и 532 — те же слова у остальных.
    if (curl_code == CURLE_LOGIN_DENIED || code == 530 || code == 430 || code == 532)
        return {common::ErrorCode::PermissionDenied, words};

    // До пароля дошло, а ответа на него не было: связь оборвалась. Так закрывают
    // соединение на неверный пароль и так же ведёт себя защита, забанившая адрес.
    if (code == 331 && is_transport_dead(static_cast<CURLcode>(curl_code)))
        return {common::ErrorCode::PermissionDenied, reply};

    return {common::ErrorCode::NetworkError, words};
}

static int progress_cb(void* ud, curl_off_t dltotal, curl_off_t dlnow,
                       curl_off_t ultotal, curl_off_t ulnow) {
    auto* p = static_cast<ProgressData*>(ud);
    if (!p || !p->callback) return 0;
    int64_t total = dltotal > 0 ? int64_t(dltotal) : int64_t(ultotal);
    int64_t done  = dlnow > 0  ? int64_t(dlnow)  : int64_t(ulnow);
    // curl counts this leg only; the caller is told about the file.
    done += p->offset;
    if (p->known_total > 0) total = p->known_total;
    else if (total > 0) total += p->offset;
    if (p->callback(done, total)) { p->cancelled = true; return 1; }
    return 0;
}

/// Lets curl move our upload stream itself when it resumes: without a seek function it
/// would read and throw away every byte up to the offset, which on a half-sent gigabyte
/// means reading half a gigabyte to send nothing.
static int seek_file_cb(void* ud, curl_off_t offset, int origin) {
    auto* f = static_cast<std::ifstream*>(ud);
    if (!f) return CURL_SEEKFUNC_FAIL;
    const auto direction = origin == SEEK_CUR ? std::ios::cur
                         : origin == SEEK_END ? std::ios::end
                                              : std::ios::beg;
    f->clear();
    f->seekg(static_cast<std::streamoff>(offset), direction);
    return f->fail() ? CURL_SEEKFUNC_FAIL : CURL_SEEKFUNC_OK;
}

// MARK: - Global init (thread-safe, called exactly once)

static std::once_flag curl_init_flag;
static void ensure_curl_initialized() {
    std::call_once(curl_init_flag, [] {
        curl_global_init(CURL_GLOBAL_DEFAULT);
    });
}

// MARK: - Constructor / Destructor

FtpClient::FtpClient() : impl_(new Impl()) {
    ensure_curl_initialized();
}

FtpClient::~FtpClient() {
    disconnect();
    delete impl_;
}

// MARK: - URL helpers

auto FtpClient::base_url() const -> std::string {
    std::string s = impl_->info.use_tls ? "ftps" : "ftp";
    s += "://" + impl_->info.host;
    if (impl_->info.port != 0 && impl_->info.port != 21)
        s += ":" + std::to_string(impl_->info.port);
    return s;
}

/// Percent-encode a single path component for FTP URL.
/// Encodes spaces, parentheses, and other unsafe chars but preserves slashes.
static std::string url_encode_path(std::string_view path) {
    std::string result;
    result.reserve(path.size() * 2);
    for (char c : path) {
        if (c == '/') {
            result += '/';
        } else if (std::isalnum(static_cast<unsigned char>(c)) ||
                   c == '-' || c == '_' || c == '.' || c == '~') {
            result += c;
        } else {
            char hex[4];
            std::snprintf(hex, sizeof(hex), "%%%02X", static_cast<unsigned char>(c));
            result += hex;
        }
    }
    return result;
}

/// Build FTP URL with proper absolute path encoding.
/// Per libcurl docs: ftp://host/%2Fpath/ for absolute paths from root.
/// ftp://host/path/ is relative to home directory.
auto FtpClient::make_url(std::string_view path) const -> std::string {
    auto url = base_url();
    if (path.empty() || path == "/") {
        // Root — use %2F for absolute root
        url += "/%2F";
    } else if (path[0] == '/') {
        // Absolute path: /home/user → /%2Fhome/user
        url += "/%2F";
        url += url_encode_path(path.substr(1));
    } else {
        url += "/";
        url += url_encode_path(path);
    }
    return url;
}

/// Apply common auth/TLS/passive settings after curl_easy_reset().
/// curl_easy_reset() clears all options but PRESERVES the TCP connection.
void FtpClient::Impl::apply_options() {
    if (!curl) return;
    if (!info.username.empty()) {
        curl_easy_setopt(curl, CURLOPT_USERNAME, info.username.c_str());
        curl_easy_setopt(curl, CURLOPT_PASSWORD, info.password.c_str());
    }
    if (info.use_tls) {
        curl_easy_setopt(curl, CURLOPT_USE_SSL, CURLUSESSL_ALL);
        // TODO: Enable SSL certificate verification before production release.
        // Currently disabled to allow self-signed certs during development.
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
        curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
    }
    if (info.passive_mode) {
        curl_easy_setopt(curl, CURLOPT_FTP_USE_EPSV, 1L);
        curl_easy_setopt(curl, CURLOPT_FTP_SKIP_PASV_IP, 1L);
    } else {
        curl_easy_setopt(curl, CURLOPT_FTPPORT, "-");
    }
    // SINGLECWD: one CWD per operation — fast and compatible
    curl_easy_setopt(curl, CURLOPT_FTP_FILEMETHOD, CURLFTPMETHOD_SINGLECWD);
    // Ответы сервера идут сюда, а не в stdout, где их никто не читает: без них человеку
    // достаётся английское «Login denied» вместо «530 User cannot log in.».
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, control_reply_cb);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, &last_reply);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
    // Ten, not thirty: the real server answers in milliseconds, and during a dead network
    // every reconnect attempt HANGS for exactly this long. Thirty seconds of that read as
    // "the program froze" — and it kept hanging after the Wi-Fi was already back.
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    // Ask the server to speak UTF-8 for filenames. Without this, Windows FTP servers
    // send names in the system codepage (CP1251 for Russian Windows); those bytes are
    // not valid UTF-8, the ObjC bridge drops them, and Cyrillic names show up blank.
    // Once accepted, OPTS UTF8 ON applies to the whole control connection — both the
    // listing it returns and the paths we send back — so navigation works too. The "*"
    // prefix tells curl to keep going even if an older server rejects the command.
    if (!utf8_quote) utf8_quote = curl_slist_append(nullptr, "*OPTS UTF8 ON");
    curl_easy_setopt(curl, CURLOPT_QUOTE, utf8_quote);
    // Zero is curl's own "no ceiling", so this is set unconditionally — and it must be set
    // HERE, because every operation resets the handle and would otherwise lose the ceiling.
    curl_easy_setopt(curl, CURLOPT_MAX_RECV_SPEED_LARGE, curl_off_t(max_download_bps));
    curl_easy_setopt(curl, CURLOPT_MAX_SEND_SPEED_LARGE, curl_off_t(max_upload_bps));
    // Do NOT set FORBID_REUSE or FRESH_CONNECT — we want persistent connections
}

/// Reset handle and re-apply options (preserves TCP connection).
void FtpClient::Impl::reset_for_next_op() {
    if (!curl) return;
    curl_easy_reset(curl);
    apply_options();
}

// MARK: - Connection lifecycle

auto FtpClient::connect(const ConnectionInfo& info) -> common::Result<void> {
    disconnect();
    impl_->info = info;
    if (impl_->info.timeout_seconds <= 0) impl_->info.timeout_seconds = 60;

    impl_->curl = curl_easy_init();
    if (!impl_->curl)
        return common::Error::make(common::ErrorCode::NetworkError, "curl_easy_init failed");

    impl_->apply_options();

    // Test connection by listing root (NLST — fast, names only)
    auto url = make_url("/");
    url += '/'; // trailing slash = directory listing

    WriteData resp;
    curl_easy_setopt(impl_->curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(impl_->curl, CURLOPT_WRITEDATA, &resp);
    curl_easy_setopt(impl_->curl, CURLOPT_DIRLISTONLY, 1L);
    curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, long(info.timeout_seconds));

    impl_->last_reply.clear();
    CURLcode res = curl_easy_perform(impl_->curl);
    if (res != CURLE_OK) {
        // Считать ДО disconnect(): он уносит с собой и последний ответ сервера.
        auto failure = describe_connect_failure(static_cast<int>(res), impl_->last_reply,
                                                curl_easy_strerror(res));
        disconnect();
        return common::Error::make(failure.code, failure.message);
    }

    impl_->connected = true;
    return {};
}

void FtpClient::disconnect() {
    // curl_easy_cleanup closes ALL connections and destroys the handle
    if (impl_->curl) {
        curl_easy_cleanup(impl_->curl);
        impl_->curl = nullptr;
    }
    if (impl_->utf8_quote) {
        curl_slist_free_all(impl_->utf8_quote);
        impl_->utf8_quote = nullptr;
    }
    impl_->connected = false;
}

auto FtpClient::is_connected() const -> bool { return impl_->connected; }

// MARK: - Directory listing

/// Fill path/extension/is_hidden from an already-parsed name, relative to `base`.
static void finalize_entry(common::FileEntry& e, std::string_view base) {
    auto dot = e.name.rfind('.');
    if (dot != std::string::npos && dot > 0 && e.type != common::EntryType::Directory)
        e.extension = e.name.substr(dot + 1);
    std::string bp(base);
    if (!bp.empty() && bp.back() == '/') bp.pop_back();
    e.path = bp + "/" + e.name;
    e.is_hidden = (!e.name.empty() && e.name[0] == '.');
}

/// Parse one UNIX `ls -l` line: "drwxr-xr-x 1 owner group size Mon DD HH:MM name".
static auto parse_unix_line(const std::string& line, std::string_view base)
    -> std::optional<common::FileEntry> {
    if (line.size() < 20) return std::nullopt;
    common::FileEntry e;
    char tc = line[0];
    e.type = (tc == 'd') ? common::EntryType::Directory
           : (tc == 'l') ? common::EntryType::Symlink : common::EntryType::File;
    e.is_symlink = (tc == 'l');
    e.permissions = line.substr(0, 10);
    // Parse fields: links, owner, group, size
    size_t pos = 10; int field = 0;
    std::string sz;
    while (pos < line.size() && field < 4) {
        while (pos < line.size() && line[pos] == ' ') pos++;
        size_t s = pos;
        while (pos < line.size() && line[pos] != ' ') pos++;
        if (field == 1) e.owner = line.substr(s, pos - s);
        else if (field == 2) e.group = line.substr(s, pos - s);
        else if (field == 3) sz = line.substr(s, pos - s);
        field++;
    }
    try { e.size = std::stoull(sz); } catch (...) {}
    // Parse 3 date fields: month day time/year (e.g. "Jan 15 14:30" or "Jan 15 2024")
    std::string month_str, day_str, time_or_year;
    for (int df = 0; df < 3 && pos < line.size(); df++) {
        while (pos < line.size() && line[pos] == ' ') pos++;
        size_t fs = pos;
        while (pos < line.size() && line[pos] != ' ') pos++;
        if (df == 0) month_str = line.substr(fs, pos - fs);
        else if (df == 1) day_str = line.substr(fs, pos - fs);
        else time_or_year = line.substr(fs, pos - fs);
    }
    // Convert to time_point
    {
        static const char* months[] = {"Jan","Feb","Mar","Apr","May","Jun",
                                       "Jul","Aug","Sep","Oct","Nov","Dec"};
        int mon = 0;
        for (int i = 0; i < 12; i++) {
            if (month_str == months[i]) { mon = i; break; }
        }
        int day = 1;
        try { day = std::stoi(day_str); } catch (...) {}
        std::tm tm{};
        tm.tm_mon = mon;
        tm.tm_mday = day;
        if (time_or_year.find(':') != std::string::npos) {
            // "14:30" format — current year
            auto now = std::time(nullptr);
            auto* lt = std::localtime(&now);
            tm.tm_year = lt->tm_year;
            try {
                auto cp = time_or_year.find(':');
                tm.tm_hour = std::stoi(time_or_year.substr(0, cp));
                tm.tm_min = std::stoi(time_or_year.substr(cp + 1));
            } catch (...) {}
        } else {
            // "2024" format — year without time
            try { tm.tm_year = std::stoi(time_or_year) - 1900; } catch (...) {}
        }
        tm.tm_isdst = 0;
        auto t = timegm(&tm);  // interpret as UTC — preserves server time as-is
        if (t != -1) {
            e.date_modified = std::chrono::system_clock::from_time_t(t);
        }
    }
    while (pos < line.size() && line[pos] == ' ') pos++;
    if (pos >= line.size()) return std::nullopt;
    auto name = line.substr(pos);
    while (!name.empty() && (name.back() == '\r' || name.back() == '\n')) name.pop_back();
    if (e.is_symlink) {
        auto a = name.find(" -> ");
        if (a != std::string::npos) name = name.substr(0, a);
    }
    if (name.empty() || name == "." || name == "..") return std::nullopt;
    e.name = name;
    finalize_entry(e, base);
    return e;
}

/// Parse one MS-DOS / IIS line: "MM-DD-YY  HH:MMAM  <DIR>|size  name".
/// Windows FTP servers (IIS) emit this instead of the UNIX `ls -l` layout.
static auto parse_msdos_line(const std::string& line, std::string_view base)
    -> std::optional<common::FileEntry> {
    size_t pos = 0;
    auto next_token = [&](std::string& out) -> bool {
        while (pos < line.size() && line[pos] == ' ') pos++;
        size_t s = pos;
        while (pos < line.size() && line[pos] != ' ') pos++;
        if (s == pos) return false;
        out = line.substr(s, pos - s);
        return true;
    };
    std::string date_tok, time_tok, size_tok;
    if (!next_token(date_tok) || !next_token(time_tok) || !next_token(size_tok))
        return std::nullopt;
    // The name is the rest of the line — it may contain spaces.
    while (pos < line.size() && line[pos] == ' ') pos++;
    if (pos >= line.size()) return std::nullopt;
    std::string name = line.substr(pos);
    while (!name.empty() && (name.back() == '\r' || name.back() == '\n')) name.pop_back();
    if (name.empty() || name == "." || name == "..") return std::nullopt;

    common::FileEntry e;
    bool is_dir = (size_tok == "<DIR>" || size_tok == "<JUNCTION>");
    e.type = is_dir ? common::EntryType::Directory : common::EntryType::File;
    e.is_symlink = false;
    if (!is_dir) { try { e.size = std::stoull(size_tok); } catch (...) {} }

    // Date/time: "MM-DD-YY" + "HH:MM(AM|PM)" — best-effort, left unset on parse failure.
    int mon = 0, day = 1, year = 1970, hh = 0, mm = 0;
    if (std::sscanf(date_tok.c_str(), "%d-%d-%d", &mon, &day, &year) == 3) {
        if (year < 70) year += 2000; else if (year < 100) year += 1900;
        char ampm[4] = {0};
        if (std::sscanf(time_tok.c_str(), "%d:%d%3s", &hh, &mm, ampm) >= 2) {
            if ((ampm[0] == 'P' || ampm[0] == 'p') && hh != 12) hh += 12;
            if ((ampm[0] == 'A' || ampm[0] == 'a') && hh == 12) hh = 0;
        }
        std::tm tm{};
        tm.tm_year = year - 1900;
        tm.tm_mon = mon - 1;
        tm.tm_mday = day;
        tm.tm_hour = hh;
        tm.tm_min = mm;
        tm.tm_isdst = 0;
        auto t = timegm(&tm);
        if (t != -1) e.date_modified = std::chrono::system_clock::from_time_t(t);
    }

    e.name = name;
    finalize_entry(e, base);
    return e;
}

/// An MS-DOS listing line starts with an "MM-DD-YY" date; a UNIX line starts with a
/// permission char ('-', 'd', 'l', …) — never two leading digits.
static bool is_msdos_line(const std::string& line) {
    return line.size() >= 6
        && std::isdigit(static_cast<unsigned char>(line[0]))
        && std::isdigit(static_cast<unsigned char>(line[1]))
        && line[2] == '-'
        && std::isdigit(static_cast<unsigned char>(line[3]))
        && std::isdigit(static_cast<unsigned char>(line[4]))
        && line[5] == '-';
}

/// Parse an FTP directory listing, auto-detecting UNIX (`ls -l`) vs MS-DOS/IIS format
/// per line — Windows FTP servers return the MS-DOS style, UNIX servers the `ls -l` style.
static auto parse_listing(const std::string& raw, std::string_view base)
    -> std::vector<common::FileEntry> {
    std::vector<common::FileEntry> out;
    std::istringstream ss(raw);
    std::string line;
    while (std::getline(ss, line)) {
        if (line.size() < 10) continue;
        auto entry = is_msdos_line(line) ? parse_msdos_line(line, base)
                                         : parse_unix_line(line, base);
        if (entry) out.push_back(std::move(*entry));
    }
    return out;
}

auto FtpClient::list_directory(std::string_view path)
    -> common::Result<std::vector<common::FileEntry>> {
    if (!impl_->connected || !impl_->curl)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");

    // Reset handle, re-apply auth — preserves TCP connection
    impl_->reset_for_next_op();

    auto url = make_url(path);
    if (url.back() != '/') url += '/'; // trailing slash = directory listing

    WriteData resp;
    curl_easy_setopt(impl_->curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(impl_->curl, CURLOPT_WRITEDATA, &resp);
    curl_easy_setopt(impl_->curl, CURLOPT_DIRLISTONLY, 0L); // full LIST (ls -l)
    curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, long(impl_->info.timeout_seconds));

    CURLcode res = curl_easy_perform(impl_->curl);
    if (res != CURLE_OK) {
        // Check if connection died — mark as disconnected
        if (res == CURLE_REMOTE_ACCESS_DENIED || res == CURLE_LOGIN_DENIED) {
            impl_->connected = false;
        }
        return common::Error::make(common::ErrorCode::NetworkError, curl_easy_strerror(res));
    }

    return parse_listing(resp.buffer, path);
}

// MARK: - Download

auto FtpClient::download(std::string_view remote, std::string_view local,
                         int64_t resume_from, ProgressCallback progress) -> common::Result<void> {
    if (!impl_->connected || !impl_->curl)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");

    impl_->reset_for_next_op();

    if (resume_from < 0) resume_from = 0;
    // Continuing keeps what is already on disk and writes after it; starting over truncates,
    // so leftovers from an abandoned attempt can never end up as the head of a new file.
    std::ofstream file(std::string(local),
                       resume_from > 0 ? (std::ios::binary | std::ios::app)
                                       : (std::ios::binary | std::ios::trunc));
    if (!file)
        return common::Error::make(common::ErrorCode::IOError, "Cannot open " + std::string(local));

    curl_easy_setopt(impl_->curl, CURLOPT_URL, make_url(remote).c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_WRITEFUNCTION, write_file_cb);
    curl_easy_setopt(impl_->curl, CURLOPT_WRITEDATA, &file);
    if (resume_from > 0)
        curl_easy_setopt(impl_->curl, CURLOPT_RESUME_FROM_LARGE, curl_off_t(resume_from));
    // No OVERALL timeout — a legitimately slow multi-GB transfer must not be killed. Instead
    // abort when the link goes SILENT: less than 1 byte/s for this long means the peer is gone.
    // Without this a dropped connection hangs the transfer (and its queue slot) forever.
    //
    // Twenty seconds, not sixty: this is how long the person stares at a frozen bar before
    // anything at all happens, and it is also how long a reconnected cable goes on doing
    // nothing — the retry that revives the transfer cannot start until curl gives up.
    curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, 0L);
    curl_easy_setopt(impl_->curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(impl_->curl, CURLOPT_LOW_SPEED_TIME, kSilenceLimitSeconds);

    ProgressData pd{progress, false, resume_from, 0};
    if (progress) {
        curl_easy_setopt(impl_->curl, CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(impl_->curl, CURLOPT_XFERINFOFUNCTION, progress_cb);
        curl_easy_setopt(impl_->curl, CURLOPT_XFERINFODATA, &pd);
    }

    CURLcode res = curl_easy_perform(impl_->curl);
    file.close();

    if (res != CURLE_OK) {
        if (pd.cancelled) return common::Error::make(common::ErrorCode::Cancelled, "Cancelled");
        if (is_transport_dead(res)) impl_->connected = false;
        return transfer_error(res, resume_from);
    }
    return {};
}

// MARK: - Upload

auto FtpClient::upload(std::string_view local, std::string_view remote,
                       int64_t resume_from, ProgressCallback progress) -> common::Result<void> {
    if (!impl_->connected || !impl_->curl)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");

    impl_->reset_for_next_op();

    std::ifstream file(std::string(local), std::ios::binary | std::ios::ate);
    if (!file)
        return common::Error::make(common::ErrorCode::IOError, "Cannot open " + std::string(local));
    const int64_t sz = static_cast<int64_t>(file.tellg());
    file.seekg(0);

    if (resume_from < 0) resume_from = 0;
    if (resume_from > sz) {
        // More on the server than we have to send: the local file was replaced under us, so
        // there is nothing honest to continue.
        return common::Error::make(common::ErrorCode::NotSupported,
                                   "Cannot resume: the local file is shorter than what is "
                                   "already on the server");
    }

    curl_easy_setopt(impl_->curl, CURLOPT_URL, make_url(remote).c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_UPLOAD, 1L);
    curl_easy_setopt(impl_->curl, CURLOPT_READFUNCTION, read_file_cb);
    curl_easy_setopt(impl_->curl, CURLOPT_READDATA, &file);
    // Where in OUR file to pick up; curl appends to the remote one on its own (APPE).
    if (resume_from > 0) {
        curl_easy_setopt(impl_->curl, CURLOPT_RESUME_FROM_LARGE, curl_off_t(resume_from));
        curl_easy_setopt(impl_->curl, CURLOPT_SEEKFUNCTION, seek_file_cb);
        curl_easy_setopt(impl_->curl, CURLOPT_SEEKDATA, &file);
    }
    curl_easy_setopt(impl_->curl, CURLOPT_INFILESIZE_LARGE, curl_off_t(sz));
    curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, 0L);
    // The upload had NO silence watchdog at all: pulling the cable mid-upload hung the
    // transfer, and its queue slot, until the app was quit.
    curl_easy_setopt(impl_->curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(impl_->curl, CURLOPT_LOW_SPEED_TIME, kSilenceLimitSeconds);
    curl_easy_setopt(impl_->curl, CURLOPT_FTP_CREATE_MISSING_DIRS, 1L);

    ProgressData pd{progress, false, resume_from, sz};
    if (progress) {
        curl_easy_setopt(impl_->curl, CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(impl_->curl, CURLOPT_XFERINFOFUNCTION, progress_cb);
        curl_easy_setopt(impl_->curl, CURLOPT_XFERINFODATA, &pd);
    }

    CURLcode res = curl_easy_perform(impl_->curl);
    file.close();

    if (res != CURLE_OK) {
        if (pd.cancelled) return common::Error::make(common::ErrorCode::Cancelled, "Cancelled");
        if (is_transport_dead(res)) impl_->connected = false;
        return transfer_error(res, resume_from);
    }
    return {};
}

void FtpClient::set_speed_limits(int64_t download_bytes_per_second,
                                 int64_t upload_bytes_per_second) {
    impl_->max_download_bps = download_bytes_per_second > 0 ? download_bytes_per_second : 0;
    impl_->max_upload_bps = upload_bytes_per_second > 0 ? upload_bytes_per_second : 0;
    // Takes effect from the next operation, which re-applies the options anyway; doing it
    // now as well means a limit set between transfers is not silently postponed.
    if (impl_->curl) impl_->apply_options();
}

// MARK: - FTP commands via QUOTE (reuse persistent handle)

auto FtpClient::remove(std::string_view remote) -> common::Result<void> {
    if (!impl_->connected || !impl_->curl)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");
    impl_->reset_for_next_op();
    auto* cmds = curl_slist_append(nullptr, "*OPTS UTF8 ON");
    cmds = curl_slist_append(cmds, ("DELE " + std::string(remote)).c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_URL, (base_url() + "/%2F").c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_QUOTE, cmds);
    curl_easy_setopt(impl_->curl, CURLOPT_NOBODY, 1L);
    curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, long(impl_->info.timeout_seconds));
    auto res = curl_easy_perform(impl_->curl);
    curl_slist_free_all(cmds);
    if (res != CURLE_OK)
        return common::Error::make(common::ErrorCode::NetworkError, curl_easy_strerror(res));
    return {};
}

auto FtpClient::remove_directory(std::string_view remote) -> common::Result<void> {
    if (!impl_->connected || !impl_->curl)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");
    impl_->reset_for_next_op();
    auto* cmds = curl_slist_append(nullptr, "*OPTS UTF8 ON");
    cmds = curl_slist_append(cmds, ("RMD " + std::string(remote)).c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_URL, (base_url() + "/%2F").c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_QUOTE, cmds);
    curl_easy_setopt(impl_->curl, CURLOPT_NOBODY, 1L);
    curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, long(impl_->info.timeout_seconds));
    auto res = curl_easy_perform(impl_->curl);
    curl_slist_free_all(cmds);
    if (res != CURLE_OK)
        return common::Error::make(common::ErrorCode::NetworkError, curl_easy_strerror(res));
    return {};
}

auto FtpClient::create_directory(std::string_view remote) -> common::Result<void> {
    if (!impl_->connected || !impl_->curl)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");
    impl_->reset_for_next_op();
    auto* cmds = curl_slist_append(nullptr, "*OPTS UTF8 ON");
    cmds = curl_slist_append(cmds, ("MKD " + std::string(remote)).c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_URL, (base_url() + "/%2F").c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_QUOTE, cmds);
    curl_easy_setopt(impl_->curl, CURLOPT_NOBODY, 1L);
    curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, long(impl_->info.timeout_seconds));
    auto res = curl_easy_perform(impl_->curl);
    curl_slist_free_all(cmds);
    if (res != CURLE_OK)
        return common::Error::make(common::ErrorCode::NetworkError, curl_easy_strerror(res));
    return {};
}

auto FtpClient::rename(std::string_view from, std::string_view to) -> common::Result<void> {
    if (!impl_->connected || !impl_->curl)
        return common::Error::make(common::ErrorCode::NetworkError, "Not connected");
    impl_->reset_for_next_op();
    auto* cmds = curl_slist_append(nullptr, "*OPTS UTF8 ON");
    cmds = curl_slist_append(cmds, ("RNFR " + std::string(from)).c_str());
    cmds = curl_slist_append(cmds, ("RNTO " + std::string(to)).c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_URL, (base_url() + "/%2F").c_str());
    curl_easy_setopt(impl_->curl, CURLOPT_QUOTE, cmds);
    curl_easy_setopt(impl_->curl, CURLOPT_NOBODY, 1L);
    curl_easy_setopt(impl_->curl, CURLOPT_TIMEOUT, long(impl_->info.timeout_seconds));
    auto res = curl_easy_perform(impl_->curl);
    curl_slist_free_all(cmds);
    if (res != CURLE_OK)
        return common::Error::make(common::ErrorCode::NetworkError, curl_easy_strerror(res));
    return {};
}

} // namespace fcxl::network
