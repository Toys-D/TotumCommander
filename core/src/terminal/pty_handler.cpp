#include "fcxl/terminal/pty_handler.h"

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <atomic>

#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>  // forkpty on macOS

namespace fcxl::terminal {

struct PtyHandler::Impl {
    int master_fd = -1;
    pid_t child_pid = -1;
    std::atomic<bool> running{false};
    OutputCallback output_callback;
    std::thread reader_thread;

    ~Impl() {
        stop();
    }

    void stop() {
        running.store(false, std::memory_order_relaxed);

        if (child_pid > 0) {
            ::kill(child_pid, SIGTERM);
            int status = 0;
            ::waitpid(child_pid, &status, WNOHANG);
            child_pid = -1;
        }

        if (master_fd >= 0) {
            ::close(master_fd);
            master_fd = -1;
        }

        if (reader_thread.joinable()) {
            reader_thread.join();
        }
    }

    void reader_loop() {
        char buffer[4096];
        while (running.load(std::memory_order_relaxed)) {
            const auto n = ::read(master_fd, buffer, sizeof(buffer));
            if (n <= 0) {
                break;
            }
            if (output_callback) {
                output_callback(std::string_view(buffer, static_cast<std::size_t>(n)));
            }
        }
        running.store(false, std::memory_order_relaxed);
    }
};

PtyHandler::PtyHandler() : impl_(std::make_unique<Impl>()) {}
PtyHandler::~PtyHandler() = default;

auto PtyHandler::start(std::string_view shell) -> common::Result<void> {
    if (impl_->running.load(std::memory_order_relaxed)) {
        return common::Error::make(common::ErrorCode::AlreadyExists, "Terminal already running");
    }

    struct winsize ws {};
    ws.ws_col = 80;
    ws.ws_row = 24;

    pid_t pid = 0;
    int master_fd = -1;

    pid = ::forkpty(&master_fd, nullptr, nullptr, &ws);
    if (pid < 0) {
        return common::Error::make(common::ErrorCode::IOError,
                                   std::string("forkpty failed: ") + std::strerror(errno));
    }

    if (pid == 0) {
        // Child process — exec shell
        const std::string shell_str(shell);
        const char* shell_name = std::strrchr(shell_str.c_str(), '/');
        shell_name = shell_name ? shell_name + 1 : shell_str.c_str();

        ::setenv("TERM", "xterm-256color", 1);
        ::execl(shell_str.c_str(), shell_name, "-l", nullptr);
        ::_exit(1);
    }

    // Parent
    impl_->master_fd = master_fd;
    impl_->child_pid = pid;
    impl_->running.store(true, std::memory_order_relaxed);

    // Set non-blocking would cause issues with simple read loop, keep blocking
    impl_->reader_thread = std::thread([this] { impl_->reader_loop(); });

    return common::Result<void>();
}

void PtyHandler::stop() {
    impl_->stop();
}

auto PtyHandler::write(std::string_view input) -> common::Result<void> {
    if (!impl_->running.load(std::memory_order_relaxed) || impl_->master_fd < 0) {
        return common::Error::make(common::ErrorCode::IOError, "Terminal not running");
    }

    const auto n = ::write(impl_->master_fd, input.data(), input.size());
    if (n < 0) {
        return common::Error::make(common::ErrorCode::IOError,
                                   std::string("Write failed: ") + std::strerror(errno));
    }

    return common::Result<void>();
}

void PtyHandler::set_output_callback(OutputCallback callback) {
    impl_->output_callback = std::move(callback);
}

auto PtyHandler::resize(uint16_t cols, uint16_t rows) -> common::Result<void> {
    if (impl_->master_fd < 0) {
        return common::Error::make(common::ErrorCode::IOError, "Terminal not running");
    }

    struct winsize ws {};
    ws.ws_col = cols;
    ws.ws_row = rows;

    if (::ioctl(impl_->master_fd, TIOCSWINSZ, &ws) != 0) {
        return common::Error::make(common::ErrorCode::IOError,
                                   std::string("Resize failed: ") + std::strerror(errno));
    }

    return common::Result<void>();
}

auto PtyHandler::is_running() const -> bool {
    return impl_->running.load(std::memory_order_relaxed);
}

auto PtyHandler::change_directory(std::string_view path) -> common::Result<void> {
    if (!impl_->running.load(std::memory_order_relaxed)) {
        return common::Error::make(common::ErrorCode::IOError, "Terminal not running");
    }

    // Send cd command to the shell
    std::string cmd = "cd ";
    cmd += "'";
    // Escape single quotes in path
    for (char c : path) {
        if (c == '\'') {
            cmd += "'\\''";
        } else {
            cmd += c;
        }
    }
    cmd += "'\n";

    return write(cmd);
}

}  // namespace fcxl::terminal
