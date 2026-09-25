#pragma once
/// @file FCXLNetworkBridge.h
/// Objective-C++ bridge for FTP (libcurl) and SFTP (libssh2) clients.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Represents a remote file entry returned by directory listing.
@interface FCXLRemoteEntry : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fileExtension;
@property (nonatomic, assign) uint64_t size;
@property (nonatomic, assign) BOOL isDirectory;
@property (nonatomic, assign) BOOL isHidden;
@property (nonatomic, assign) BOOL isSymlink;
@property (nonatomic, copy) NSString *permissions;
@property (nonatomic, copy) NSString *owner;
@property (nonatomic, strong, nullable) NSDate *modificationDate;
@end

/// FTP/FTPS client bridge.
@interface FCXLFTPBridge : NSObject

- (BOOL)connectToHost:(NSString *)host
                 port:(uint16_t)port
             username:(NSString *)username
             password:(NSString *)password
               useTLS:(BOOL)useTLS
          passiveMode:(BOOL)passiveMode
              timeout:(int)timeout
                error:(NSError *_Nullable *_Nullable)error;

- (void)disconnect;
- (BOOL)isConnected;

- (nullable NSArray<FCXLRemoteEntry *> *)listDirectoryAt:(NSString *)path
                                                   error:(NSError *_Nullable *_Nullable)error;

- (BOOL)downloadFile:(NSString *)remotePath
                  to:(NSString *)localPath
            progress:(nullable BOOL (^)(int64_t bytesDone, int64_t bytesTotal))progress
               error:(NSError *_Nullable *_Nullable)error;

- (BOOL)uploadFile:(NSString *)localPath
                to:(NSString *)remotePath
          progress:(nullable BOOL (^)(int64_t bytesDone, int64_t bytesTotal))progress
             error:(NSError *_Nullable *_Nullable)error;

/// The same two transfers, continued: `resumeFrom` is how much already lies at the far end.
/// Zero behaves exactly like the pair above. Progress counts the whole file either way.
/// A far end that cannot continue answers `FCXLErrorNotSupported` — throw the leftovers
/// away and ask again from zero rather than treating it as a broken link.
- (BOOL)downloadFile:(NSString *)remotePath
                  to:(NSString *)localPath
          resumeFrom:(int64_t)resumeFrom
            progress:(nullable BOOL (^)(int64_t bytesDone, int64_t bytesTotal))progress
               error:(NSError *_Nullable *_Nullable)error;

- (BOOL)uploadFile:(NSString *)localPath
                to:(NSString *)remotePath
        resumeFrom:(int64_t)resumeFrom
          progress:(nullable BOOL (^)(int64_t bytesDone, int64_t bytesTotal))progress
             error:(NSError *_Nullable *_Nullable)error;

/// Ceiling in bytes per second for every following transfer; zero lifts it.
- (void)setDownloadSpeedLimit:(int64_t)downloadBytesPerSecond
              uploadSpeedLimit:(int64_t)uploadBytesPerSecond;

- (BOOL)deleteFileAt:(NSString *)remotePath error:(NSError *_Nullable *_Nullable)error;
- (BOOL)deleteDirectoryAt:(NSString *)remotePath error:(NSError *_Nullable *_Nullable)error;
- (BOOL)createDirectoryAt:(NSString *)remotePath error:(NSError *_Nullable *_Nullable)error;
- (BOOL)renameFrom:(NSString *)from to:(NSString *)to error:(NSError *_Nullable *_Nullable)error;

@end

/// SFTP client bridge.
@interface FCXLSFTPBridge : NSObject

- (BOOL)connectToHost:(NSString *)host
                 port:(uint16_t)port
             username:(NSString *)username
             password:(NSString *)password
       privateKeyPath:(NSString *)keyPath
              timeout:(int)timeout
                error:(NSError *_Nullable *_Nullable)error;

- (void)disconnect;
- (BOOL)isConnected;

- (nullable NSArray<FCXLRemoteEntry *> *)listDirectoryAt:(NSString *)path
                                                   error:(NSError *_Nullable *_Nullable)error;

- (BOOL)downloadFile:(NSString *)remotePath
                  to:(NSString *)localPath
            progress:(nullable BOOL (^)(int64_t bytesDone, int64_t bytesTotal))progress
               error:(NSError *_Nullable *_Nullable)error;

- (BOOL)uploadFile:(NSString *)localPath
                to:(NSString *)remotePath
          progress:(nullable BOOL (^)(int64_t bytesDone, int64_t bytesTotal))progress
             error:(NSError *_Nullable *_Nullable)error;

/// The same two transfers, continued: `resumeFrom` is how much already lies at the far end.
/// Zero behaves exactly like the pair above. Progress counts the whole file either way.
/// A far end that cannot continue answers `FCXLErrorNotSupported` — throw the leftovers
/// away and ask again from zero rather than treating it as a broken link.
- (BOOL)downloadFile:(NSString *)remotePath
                  to:(NSString *)localPath
          resumeFrom:(int64_t)resumeFrom
            progress:(nullable BOOL (^)(int64_t bytesDone, int64_t bytesTotal))progress
               error:(NSError *_Nullable *_Nullable)error;

- (BOOL)uploadFile:(NSString *)localPath
                to:(NSString *)remotePath
        resumeFrom:(int64_t)resumeFrom
          progress:(nullable BOOL (^)(int64_t bytesDone, int64_t bytesTotal))progress
             error:(NSError *_Nullable *_Nullable)error;

/// Ceiling in bytes per second for every following transfer; zero lifts it.
- (void)setDownloadSpeedLimit:(int64_t)downloadBytesPerSecond
              uploadSpeedLimit:(int64_t)uploadBytesPerSecond;

- (BOOL)deleteFileAt:(NSString *)remotePath error:(NSError *_Nullable *_Nullable)error;
- (BOOL)deleteDirectoryAt:(NSString *)remotePath error:(NSError *_Nullable *_Nullable)error;
- (BOOL)createDirectoryAt:(NSString *)remotePath error:(NSError *_Nullable *_Nullable)error;
- (BOOL)renameFrom:(NSString *)from to:(NSString *)to error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
