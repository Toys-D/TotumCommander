#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridge to libntfs-3g for writing files to NTFS volumes on macOS.
@interface FCXLNTFSBridge : NSObject

/// Detect NTFS volume at given path.
/// Returns dictionary with keys: devicePath, mountPoint, fsType, isReadOnly.
+ (nullable NSDictionary<NSString*, id>*)detectNTFSVolumeAtPath:(NSString*)path;

/// Verifies an admin password by running a no-op via `sudo -S -k`. Used before
/// saving the password to the Keychain so a wrong one isn't stored.
+ (BOOL)verifyAdminPassword:(NSString*)password;

/// Open an NTFS volume for writing. Unmounts macOS read-only driver.
/// Must call closeVolume when done.
- (BOOL)openVolumeWithDevice:(NSString*)devicePath
                  mountPoint:(NSString*)mountPoint
                       error:(NSError**)error;

/// Close the NTFS volume and re-mount via macOS.
- (BOOL)closeVolumeWithError:(NSError**)error;

/// Check if volume is currently open for writing.
- (BOOL)isOpen;

/// Copy a single file to the NTFS volume.
/// @param srcPath      Local source file path
/// @param dstRelPath   Destination path relative to NTFS root (e.g. "/Documents/file.txt")
/// @param progress     Called with (bytesCopied, totalBytes, currentFile)
/// @param cancel       Return YES to cancel
- (BOOL)copyFileFrom:(NSString*)srcPath
                   to:(NSString*)dstRelPath
             progress:(nullable void(^)(int64_t bytesCopied, int64_t totalBytes, NSString* currentFile))progress
               cancel:(nullable BOOL(^)(void))cancel
                error:(NSError**)error;

/// Create a directory on NTFS.
- (BOOL)mkdirAtPath:(NSString*)relPath error:(NSError**)error;

/// Recursively copy a directory tree to NTFS.
- (BOOL)copyTreeFrom:(NSString*)srcDir
                   to:(NSString*)dstRelDir
             progress:(nullable void(^)(int64_t bytesCopied, int64_t totalBytes, NSString* currentFile))progress
               cancel:(nullable BOOL(^)(void))cancel
                error:(NSError**)error;

/// Delete a file or directory on NTFS.
- (BOOL)removeAtPath:(NSString*)relPath error:(NSError**)error;

/// Rename (move) a file or directory within NTFS.
- (BOOL)renameAtPath:(NSString*)oldRelPath
              toPath:(NSString*)newRelPath
               error:(NSError**)error;

/// List directory contents on the open NTFS volume.
/// Returns array of dictionaries with keys: name (String), isDirectory (Bool),
/// isHidden (Bool), size (Int64), dateModified (TimeInterval), dateCreated (TimeInterval).
- (nullable NSArray<NSDictionary<NSString*, id>*>*)listDirectoryAtPath:(NSString*)relPath
                                                                 error:(NSError**)error;

/// Read a file from the NTFS volume to a local filesystem path.
- (BOOL)readFileFrom:(NSString*)relPath
          toLocalPath:(NSString*)localDestPath
             progress:(nullable void(^)(int64_t bytesCopied, int64_t totalBytes, NSString* currentFile))progress
               cancel:(nullable BOOL(^)(void))cancel
                error:(NSError**)error;

@end

NS_ASSUME_NONNULL_END
