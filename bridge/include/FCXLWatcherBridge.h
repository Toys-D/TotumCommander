#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Callback type for directory change notifications.
/// Parameters: changed path (NSString) and event type (NSString: "created", "modified", "deleted", "renamed").
typedef void (^FCXLWatcherCallback)(NSString *path, NSString *event);

/// Objective-C bridge for the C++ FSEvents directory watcher.
/// Monitors a directory for file system changes and fires a callback.
@interface FCXLWatcherBridge : NSObject
- (instancetype)init;
/// Start watching a directory. Returns YES on success.
/// Callback fires on a background thread for each change event.
- (BOOL)watchDirectory:(NSString *)path
              callback:(FCXLWatcherCallback)callback
                 error:(NSError *_Nullable *_Nullable)error;
/// Stop watching. Safe to call multiple times.
- (void)stop;
/// Returns YES if currently watching a directory.
- (BOOL)isWatching;
@end
NS_ASSUME_NONNULL_END
