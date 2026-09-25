#import "FCXLTerminalBridge.h"
#include <memory>
#include <mutex>
#include <vector>
#include "fcxl/terminal/pty_handler.h"

namespace {

auto make_nserror(const fcxl::common::Error& e) -> NSError* {
    return [NSError errorWithDomain:@"com.fcxl.terminal"
                               code:static_cast<NSInteger>(e.code)
                           userInfo:@{
                               NSLocalizedDescriptionKey : [NSString stringWithUTF8String:e.message.c_str()]
                           }];
}

}  // namespace

@implementation FCXLTerminalBridge {
    std::unique_ptr<fcxl::terminal::PtyHandler> _pty;
    FCXLTerminalOutputCallback _outputCallback;
    std::mutex _bufMutex;
    std::vector<uint8_t> _pendingBytes;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pty = std::make_unique<fcxl::terminal::PtyHandler>();
    }
    return self;
}

- (BOOL)startWithShell:(NSString *)shell error:(NSError**)error {
    auto callback = _outputCallback;
    auto* mutexPtr = &_bufMutex;
    auto* pendingPtr = &_pendingBytes;

    _pty->set_output_callback([callback, mutexPtr, pendingPtr](std::string_view data) {
        if (!callback || data.empty()) return;

        std::lock_guard<std::mutex> lock(*mutexPtr);

        // Append new data to pending buffer
        pendingPtr->insert(pendingPtr->end(), data.begin(), data.end());

        // Find longest valid UTF-8 prefix
        const uint8_t* buf = pendingPtr->data();
        size_t total = pendingPtr->size();
        size_t valid = total;

        // Check trailing bytes for incomplete UTF-8 sequence
        if (total > 0) {
            // Scan back from end to find potential incomplete multibyte start
            for (size_t back = 1; back <= 4 && back <= total; ++back) {
                uint8_t b = buf[total - back];
                if ((b & 0x80) == 0) {
                    // ASCII — all complete
                    break;
                }
                if ((b & 0xC0) == 0xC0) {
                    // Start byte found — check if sequence is complete
                    int expected = 0;
                    if ((b & 0xE0) == 0xC0) expected = 2;
                    else if ((b & 0xF0) == 0xE0) expected = 3;
                    else if ((b & 0xF8) == 0xF0) expected = 4;
                    if (total - (total - back) < static_cast<size_t>(expected)) {
                        valid = total - back;  // Incomplete — cut before this byte
                    }
                    break;
                }
            }
        }

        if (valid == 0) return;  // Only incomplete bytes, wait for more

        NSString* str = [[NSString alloc] initWithBytes:buf
                                                 length:valid
                                               encoding:NSUTF8StringEncoding];
        if (!str) {
            // Should not happen but fallback gracefully
            str = [[NSString alloc] initWithBytes:buf
                                           length:valid
                                         encoding:NSISOLatin1StringEncoding];
        }

        // Keep unprocessed tail
        if (valid < total) {
            std::vector<uint8_t> tail(buf + valid, buf + total);
            *pendingPtr = std::move(tail);
        } else {
            pendingPtr->clear();
        }

        if (str) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(str);
            });
        }
    });

    auto result = _pty->start(shell.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return NO;
    }
    return YES;
}

- (void)stop {
    _pty->stop();
    std::lock_guard<std::mutex> lock(_bufMutex);
    _pendingBytes.clear();
}

- (BOOL)writeInput:(NSString *)input error:(NSError**)error {
    // Send raw UTF-8 bytes to PTY
    const char* utf8 = input.UTF8String;
    size_t len = strlen(utf8);
    auto result = _pty->write(std::string_view(utf8, len));
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return NO;
    }
    return YES;
}

- (void)setOutputCallback:(FCXLTerminalOutputCallback)callback {
    _outputCallback = [callback copy];
}

- (BOOL)resizeCols:(uint16_t)cols rows:(uint16_t)rows error:(NSError**)error {
    auto result = _pty->resize(cols, rows);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return NO;
    }
    return YES;
}

- (BOOL)isRunning {
    return _pty->is_running() ? YES : NO;
}

- (BOOL)changeDirectory:(NSString *)path error:(NSError**)error {
    auto result = _pty->change_directory(path.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return NO;
    }
    return YES;
}

@end
