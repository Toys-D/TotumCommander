#include "fcxl/common/logger.h"
#include <iostream>
#include <mutex>

namespace fcxl::common::logger {

static Level current_level = Level::Info;
static std::mutex log_mutex;

void set_level(Level level) { current_level = level; }

static void log(Level level, std::string_view prefix, std::string_view message) {
    if (level < current_level) return;
    std::lock_guard<std::mutex> lock(log_mutex);
    std::cerr << "[" << prefix << "] " << message << "\n";
}

void debug(std::string_view message) { log(Level::Debug, "DEBUG", message); }
void info(std::string_view message) { log(Level::Info, "INFO", message); }
void warning(std::string_view message) { log(Level::Warning, "WARN", message); }
void error(std::string_view message) { log(Level::Error, "ERROR", message); }

} // namespace fcxl::common::logger
