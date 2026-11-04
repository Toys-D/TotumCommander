// FCXLNTFSBridge.mm — Objective-C++ bridge for NTFS write operations
// Handles admin-privileged unmount/chmod via NSTask + osascript,
// then delegates actual NTFS I/O to libntfs-3g via fcxl::NtfsWriter.

#import "FCXLNTFSBridge.h"
#import <Security/Security.h>
#include "fcxl/filesystem/ntfs_writer.h"
#include <sys/stat.h>

// Keychain coordinates for the optional saved admin password. MUST match the
// Swift side (NTFSPasswordStore).
static NSString* const kFCXLKeychainService = @"com.filecommanderxl.ntfs-admin";
static NSString* const kFCXLKeychainAccount = @"admin";

static NSError* makeError(const std::string& msg) {
    return [NSError errorWithDomain:@"FCXLNTFSBridge"
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey: @(msg.c_str())}];
}

/// Reads the admin password the user optionally saved in the Keychain, or nil.
static NSString* loadStoredAdminPassword(void) {
    NSDictionary* query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kFCXLKeychainService,
        (__bridge id)kSecAttrAccount: kFCXLKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) return nil;
    NSData* data = (__bridge_transfer NSData*)result;
    NSString* pw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return pw.length > 0 ? pw : nil;
}

/// Runs a command as root via `sudo -S`, feeding the password through stdin
/// (never via argv, so it can't leak into the process list). Returns NO on any
/// failure, including a wrong password — the caller then falls back to the
/// interactive dialog.
static BOOL runWithSudoPassword(NSString* command, NSString* password, NSError** outError) {
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sudo"];
    task.arguments = @[@"-S", @"-p", @"", @"/bin/sh", @"-c", command];

    NSPipe* inPipe = [NSPipe pipe];
    NSPipe* errPipe = [NSPipe pipe];
    task.standardInput = inPipe;
    task.standardError = errPipe;
    task.standardOutput = [NSPipe pipe];

    NSError* launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (outError) *outError = launchError;
        return NO;
    }

    NSData* pwData = [[password stringByAppendingString:@"\n"]
                      dataUsingEncoding:NSUTF8StringEncoding];
    @try {
        [inPipe.fileHandleForWriting writeData:pwData];
        [inPipe.fileHandleForWriting closeFile];
    } @catch (__unused NSException* e) {}

    [task waitUntilExit];

    if (task.terminationStatus != 0) {
        NSData* errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        NSString* errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding]
                           ?: @"sudo failed";
        if (outError) {
            *outError = [NSError errorWithDomain:@"FCXLNTFSBridge" code:task.terminationStatus
                                        userInfo:@{NSLocalizedDescriptionKey: errStr}];
        }
        return NO;
    }
    return YES;
}

/// Run a shell command with administrator privileges. If the user saved an admin
/// password in the Keychain, runs it silently via `sudo -S`; otherwise (or if
/// that password no longer works) falls back to the osascript password dialog.
static BOOL runPrivilegedShellCommand(NSString* command, NSError** outError) {
    NSString* stored = loadStoredAdminPassword();
    if (stored != nil) {
        if (runWithSudoPassword(command, stored, NULL)) return YES;
        // Stored password failed (e.g. changed) — fall through to the dialog
        // rather than hard-failing the operation.
    }
    // Write command to a temp script file — avoids all quoting/escaping issues
    NSString* tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fcxl_ntfs.sh"];
    NSString* script = [NSString stringWithFormat:@"#!/bin/sh\n%@\n", command];
    [script writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(tmpPath.UTF8String, 0755);

    // Build AppleScript: do shell script "/tmp/.../fcxl_ntfs.sh" with administrator privileges
    NSString* appleScript = [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", tmpPath];

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments = @[@"-e", appleScript];

    NSPipe* errPipe = [NSPipe pipe];
    task.standardError = errPipe;
    task.standardOutput = [NSPipe pipe]; // Suppress stdout

    NSError* launchError = nil;
    [task launchAndReturnError:&launchError];
    if (launchError) {
        [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        if (outError) *outError = launchError;
        return NO;
    }

    [task waitUntilExit];
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

    if (task.terminationStatus != 0) {
        NSData* errData = [errPipe.fileHandleForReading readDataToEndOfFile];
        NSString* errStr = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"Unknown error";
        if (outError) {
            *outError = [NSError errorWithDomain:@"FCXLNTFSBridge" code:task.terminationStatus
                                        userInfo:@{NSLocalizedDescriptionKey: errStr}];
        }
        return NO;
    }
    return YES;
}

@implementation FCXLNTFSBridge {
    fcxl::NtfsWriter _writer;
    NSString* _devicePath;
    NSString* _mountPoint;
}

+ (BOOL)verifyAdminPassword:(NSString*)password {
    if (password.length == 0) return NO;
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sudo"];
    // -k forces a fresh password check (ignores any cached sudo timestamp).
    task.arguments = @[@"-S", @"-k", @"-p", @"", @"/usr/bin/true"];
    NSPipe* inPipe = [NSPipe pipe];
    task.standardInput = inPipe;
    task.standardError = [NSPipe pipe];
    task.standardOutput = [NSPipe pipe];
    if (![task launchAndReturnError:nil]) return NO;
    @try {
        [inPipe.fileHandleForWriting writeData:
            [[password stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [inPipe.fileHandleForWriting closeFile];
    } @catch (__unused NSException* e) {}
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

+ (nullable NSDictionary<NSString*, id>*)detectNTFSVolumeAtPath:(NSString*)path {
    auto info = fcxl::detect_ntfs_volume(path.UTF8String);
    if (info.fs_type.empty()) return nil;

    return @{
        @"devicePath": @(info.device_path.c_str()),
        @"mountPoint": @(info.mount_point.c_str()),
        @"fsType": @(info.fs_type.c_str()),
        @"isReadOnly": @(info.is_read_only)
    };
}

- (BOOL)openVolumeWithDevice:(NSString*)devicePath
                  mountPoint:(NSString*)mountPoint
                       error:(NSError**)error {
    _devicePath = [devicePath copy];
    _mountPoint = [mountPoint copy];

    // Step 1: Force-unmount macOS read-only NTFS driver + chmod device for user access.
    // Force is needed because our own app may have open handles on the volume (panel browsing).
    NSString* cmd = [NSString stringWithFormat:
        @"diskutil unmount force \"%@\" && chmod 666 \"%@\"",
        mountPoint, devicePath];

    NSError* privError = nil;
    if (!runPrivilegedShellCommand(cmd, &privError)) {
        if (error) {
            *error = [NSError errorWithDomain:@"FCXLNTFSBridge" code:-1
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Failed to prepare NTFS volume: %@",
                        privError.localizedDescription ?: @"user cancelled"]}];
        }
        return NO;
    }

    // Step 2: Open via libntfs-3g (device is now accessible)
    auto result = _writer.open_volume(devicePath.UTF8String, mountPoint.UTF8String);
    if (!result.success) {
        [self restoreVolumeIgnoringError];
        if (error) *error = makeError(result.error);
        return NO;
    }
    return YES;
}

- (BOOL)closeVolumeWithError:(NSError**)error {
    // Step 1: Close libntfs-3g
    auto result = _writer.close_volume();

    // Step 2: Restore device permissions and re-mount (always try, even if close failed)
    [self restoreVolumeIgnoringError];

    if (!result.success) {
        if (error) *error = makeError(result.error);
        return NO;
    }
    return YES;
}

- (void)restoreVolumeIgnoringError {
    if (!_devicePath) return;
    // Remount the volume via diskutil (no admin privileges needed).
    // Device permissions are automatically restored by macOS when the volume is remounted.
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/diskutil"];
    task.arguments = @[@"mount", _devicePath];
    task.standardOutput = [NSPipe pipe];
    task.standardError = [NSPipe pipe];
    [task launchAndReturnError:nil];
    [task waitUntilExit];
}

- (BOOL)isOpen {
    return _writer.is_open() ? YES : NO;
}

- (BOOL)copyFileFrom:(NSString*)srcPath
                   to:(NSString*)dstRelPath
             progress:(nullable void(^)(int64_t, int64_t, NSString*))progress
               cancel:(nullable BOOL(^)(void))cancel
                error:(NSError**)error {

    fcxl::NtfsProgressCallback progressCB = nullptr;
    fcxl::NtfsCancelCallback cancelCB = nullptr;

    if (progress) {
        progressCB = [progress](int64_t copied, int64_t total, const std::string& file) {
            @autoreleasepool {
                progress(copied, total, @(file.c_str()));
            }
        };
    }
    if (cancel) {
        cancelCB = [cancel]() -> bool {
            @autoreleasepool {
                return cancel() == YES;
            }
        };
    }

    auto result = _writer.copy_file(srcPath.UTF8String, dstRelPath.UTF8String,
                                     progressCB, cancelCB);
    if (!result.success) {
        if (error) *error = makeError(result.error);
        return NO;
    }
    return YES;
}

- (BOOL)mkdirAtPath:(NSString*)relPath error:(NSError**)error {
    auto result = _writer.mkdir(relPath.UTF8String);
    if (!result.success) {
        if (error) *error = makeError(result.error);
        return NO;
    }
    return YES;
}

- (BOOL)copyTreeFrom:(NSString*)srcDir
                   to:(NSString*)dstRelDir
             progress:(nullable void(^)(int64_t, int64_t, NSString*))progress
               cancel:(nullable BOOL(^)(void))cancel
                error:(NSError**)error {

    fcxl::NtfsProgressCallback progressCB = nullptr;
    fcxl::NtfsCancelCallback cancelCB = nullptr;

    if (progress) {
        progressCB = [progress](int64_t copied, int64_t total, const std::string& file) {
            @autoreleasepool {
                progress(copied, total, @(file.c_str()));
            }
        };
    }
    if (cancel) {
        cancelCB = [cancel]() -> bool {
            @autoreleasepool {
                return cancel() == YES;
            }
        };
    }

    auto result = _writer.copy_tree(srcDir.UTF8String, dstRelDir.UTF8String,
                                     progressCB, cancelCB);
    if (!result.success) {
        if (error) *error = makeError(result.error);
        return NO;
    }
    return YES;
}

- (BOOL)removeAtPath:(NSString*)relPath error:(NSError**)error {
    auto result = _writer.remove(relPath.UTF8String);
    if (!result.success) {
        if (error) *error = makeError(result.error);
        return NO;
    }
    return YES;
}

- (BOOL)renameAtPath:(NSString*)oldRelPath
              toPath:(NSString*)newRelPath
               error:(NSError**)error {
    auto result = _writer.rename(oldRelPath.UTF8String, newRelPath.UTF8String);
    if (!result.success) {
        if (error) *error = makeError(result.error);
        return NO;
    }
    return YES;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)listDirectoryAtPath:(NSString*)relPath
                                                                 error:(NSError**)error {
    std::vector<fcxl::NtfsFileEntry> entries;
    auto result = _writer.list_directory(relPath.UTF8String, entries);
    if (!result.success) {
        if (error) *error = makeError(result.error);
        return nil;
    }

    NSMutableArray* array = [NSMutableArray arrayWithCapacity:entries.size()];
    for (const auto& e : entries) {
        [array addObject:@{
            @"name": @(e.name.c_str()),
            @"isDirectory": @(e.is_directory),
            @"isHidden": @(e.is_hidden),
            @"size": @(e.size),
            @"dateModified": @(static_cast<double>(e.modification_time)),
            @"dateCreated": @(static_cast<double>(e.creation_time))
        }];
    }
    return array;
}

- (BOOL)readFileFrom:(NSString*)relPath
          toLocalPath:(NSString*)localDestPath
             progress:(nullable void(^)(int64_t, int64_t, NSString*))progress
               cancel:(nullable BOOL(^)(void))cancel
                error:(NSError**)error {

    fcxl::NtfsProgressCallback progressCB = nullptr;
    fcxl::NtfsCancelCallback cancelCB = nullptr;

    if (progress) {
        progressCB = [progress](int64_t copied, int64_t total, const std::string& file) {
            @autoreleasepool {
                progress(copied, total, @(file.c_str()));
            }
        };
    }
    if (cancel) {
        cancelCB = [cancel]() -> bool {
            @autoreleasepool {
                return cancel() == YES;
            }
        };
    }

    auto result = _writer.read_file(relPath.UTF8String, localDestPath.UTF8String,
                                     progressCB, cancelCB);
    if (!result.success) {
        if (error) *error = makeError(result.error);
        return NO;
    }
    return YES;
}

@end
