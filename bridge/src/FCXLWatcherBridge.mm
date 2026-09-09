#import "FCXLWatcherBridge.h"
#include <memory>
#include "fcxl/filesystem/watcher.h"

@implementation FCXLWatcherBridge {
    std::unique_ptr<fcxl::fs::Watcher> _watcher;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _watcher = std::make_unique<fcxl::fs::Watcher>();
    }
    return self;
}

- (BOOL)watchDirectory:(NSString *)path
              callback:(FCXLWatcherCallback)callback
                 error:(NSError **)error {
    if (!_watcher) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.fcxl.watcher"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Watcher not initialized"}];
        }
        return NO;
    }

    // Copy the block so it survives on the heap
    FCXLWatcherCallback callbackCopy = [callback copy];

    auto result = _watcher->watch(
        path.UTF8String,
        [callbackCopy](const std::filesystem::path& changedPath, fcxl::fs::WatchEvent event) {
            NSString *pathStr = [NSString stringWithUTF8String:changedPath.c_str()];
            NSString *eventStr;
            switch (event) {
                case fcxl::fs::WatchEvent::Created:  eventStr = @"created"; break;
                case fcxl::fs::WatchEvent::Modified: eventStr = @"modified"; break;
                case fcxl::fs::WatchEvent::Deleted:  eventStr = @"deleted"; break;
                case fcxl::fs::WatchEvent::Renamed:  eventStr = @"renamed"; break;
            }
            callbackCopy(pathStr, eventStr);
        }
    );

    if (!result.has_value()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.fcxl.watcher"
                                         code:static_cast<NSInteger>(result.error().code)
                                     userInfo:@{
                                         NSLocalizedDescriptionKey:
                                             [NSString stringWithUTF8String:result.error().message.c_str()]
                                     }];
        }
        return NO;
    }
    return YES;
}

- (void)stop {
    if (_watcher) {
        _watcher->stop();
    }
}

- (BOOL)isWatching {
    return _watcher ? _watcher->is_watching() : NO;
}

@end
