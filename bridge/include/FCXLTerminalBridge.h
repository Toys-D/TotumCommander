#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

typedef void (^FCXLTerminalOutputCallback)(NSString *output);

@interface FCXLTerminalBridge : NSObject
- (instancetype)init;

/// Start terminal with shell (default: /bin/zsh)
- (BOOL)startWithShell:(NSString *)shell error:(NSError**)error;

/// Stop the terminal
- (void)stop;

/// Write input to terminal
- (BOOL)writeInput:(NSString *)input error:(NSError**)error;

/// Set callback for terminal output
- (void)setOutputCallback:(FCXLTerminalOutputCallback)callback;

/// Resize terminal
- (BOOL)resizeCols:(uint16_t)cols rows:(uint16_t)rows error:(NSError**)error;

/// Check if terminal is running
@property (nonatomic, readonly) BOOL isRunning;

/// Change directory in terminal
- (BOOL)changeDirectory:(NSString *)path error:(NSError**)error;

@end
NS_ASSUME_NONNULL_END
