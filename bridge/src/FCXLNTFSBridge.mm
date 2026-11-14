// FCXLNTFSBridge.mm — Objective-C++ bridge for NTFS write operations
// Handles the admin-privileged step (unmount + hand the device node to the user) via
// NSTask (sudo or the osascript password dialog), then delegates actual NTFS I/O to
// libntfs-3g via fcxl::NtfsWriter.

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

/// The privileged step as a fixed script. What it works on arrives as positional
/// parameters and never becomes part of the script text: a volume is named by whoever
/// formatted the disk, and that name must not be able to turn into a command for root.
///
/// The device node is handed to the user running the program (`$3`), not opened to
/// everyone: a node keeps its owner and mode until the disk is detached — remounting the
/// volume does not reset them — so a world-writable node would stay writable for every
/// account and every process long after the work is done.
static NSString* const kFCXLPrepareScript =
    @"/usr/sbin/diskutil unmount force \"$1\" && /usr/sbin/chown \"$3\" \"$2\"";

/// `$0` of that script — it only shows up in the shell's own error messages.
static NSString* const kFCXLPrepareName = @"fcxl-ntfs";

/// Whether the privileged step may be run on these two values at all. Both come from the
/// mount table of whatever was plugged in, and the step runs as root: only a disk node is
/// ever handed over, and only a full path is unmounted.
static BOOL canPrepare(NSString* devicePath, NSString* mountPoint) {
    static NSRegularExpression* diskNode;
    static NSCharacterSet* nul;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        diskNode = [NSRegularExpression regularExpressionWithPattern:@"/dev/disk[0-9]+(s[0-9]+)*"
                                                             options:0 error:nil];
        nul = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)];
    });
    // The whole string has to be the node name: `$` in a pattern would let a trailing
    // line break through.
    NSRange whole = NSMakeRange(0, devicePath.length);
    NSRange node = [diskNode rangeOfFirstMatchInString:devicePath
                                               options:NSMatchingAnchored range:whole];
    if (whole.length == 0 || !NSEqualRanges(node, whole)) return NO;

    if (![mountPoint hasPrefix:@"/"]) return NO;
    // A word of a command line ends at the first NUL, so the path would be cut short.
    return [mountPoint rangeOfCharacterFromSet:nul].location == NSNotFound;
}

/// Runs a command line as root via `sudo -S`, feeding the password through stdin
/// (never via argv, so it can't leak into the process list). Returns NO on any
/// failure, including a wrong password — the caller then falls back to the
/// interactive dialog.
static BOOL runWithSudoPassword(NSArray<NSString*>* commandLine, NSString* password,
                                NSError** outError) {
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sudo"];
    task.arguments = [@[@"-S", @"-p", @""] arrayByAddingObjectsFromArray:commandLine];

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

/// Run the privileged step. If the user saved an admin password in the Keychain, runs
/// `commandLine` silently via `sudo -S`; otherwise (or if that password no longer works)
/// runs `dialogCommandLine`, which brings up the system password dialog.
///
/// Nothing is written to disk on the way: a script file that root is about to execute could
/// be swapped by any process of the same user between being written and being run.
static BOOL runPrivilegedStep(NSArray<NSString*>* commandLine,
                              NSArray<NSString*>* dialogCommandLine, NSError** outError) {
    NSString* stored = loadStoredAdminPassword();
    if (stored != nil) {
        if (runWithSudoPassword(commandLine, stored, NULL)) return YES;
        // Stored password failed (e.g. changed) — fall through to the dialog
        // rather than hard-failing the operation.
    }

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:dialogCommandLine.firstObject];
    task.arguments = [dialogCommandLine subarrayWithRange:
                         NSMakeRange(1, dialogCommandLine.count - 1)];

    NSPipe* errPipe = [NSPipe pipe];
    task.standardError = errPipe;
    task.standardOutput = [NSPipe pipe]; // Suppress stdout

    NSError* launchError = nil;
    [task launchAndReturnError:&launchError];
    if (launchError) {
        if (outError) *outError = launchError;
        return NO;
    }

    [task waitUntilExit];

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

+ (nullable NSArray<NSString*>*)shellArgumentsToPrepareDevice:(NSString*)devicePath
                                                   mountPoint:(NSString*)mountPoint
                                                        owner:(unsigned int)owner {
    if (!canPrepare(devicePath, mountPoint)) return nil;
    return @[@"/bin/sh", @"-c", kFCXLPrepareScript, kFCXLPrepareName, mountPoint, devicePath,
             [NSString stringWithFormat:@"%u", owner]];
}

+ (nullable NSArray<NSString*>*)appleScriptArgumentsToPrepareDevice:(NSString*)devicePath
                                                         mountPoint:(NSString*)mountPoint
                                                              owner:(unsigned int)owner
                                                         privileged:(BOOL)privileged {
    if (!canPrepare(devicePath, mountPoint)) return nil;
    // The AppleScript text is fixed as well: the values reach it as `argv`, and
    // `quoted form of` is AppleScript's own way of making any text one shell word.
    NSString* call = [NSString stringWithFormat:
        @"do shell script \"/bin/sh -c \" & quoted form of (item 1 of argv)"
        @" & \" %@ \" & quoted form of (item 2 of argv)"
        @" & \" \" & quoted form of (item 3 of argv)"
        @" & \" \" & quoted form of (item 4 of argv)", kFCXLPrepareName];
    if (privileged) call = [call stringByAppendingString:@" with administrator privileges"];
    return @[@"/usr/bin/osascript", @"-e", @"on run argv", @"-e", call, @"-e", @"end run",
             kFCXLPrepareScript, mountPoint, devicePath,
             [NSString stringWithFormat:@"%u", owner]];
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
    // Step 1: Force-unmount macOS read-only NTFS driver + make the user the owner of the
    // device node, so libntfs-3g can open it without running as root.
    // Force is needed because our own app may have open handles on the volume (panel browsing).
    NSArray<NSString*>* step = [FCXLNTFSBridge shellArgumentsToPrepareDevice:devicePath
                                                                  mountPoint:mountPoint
                                                                       owner:getuid()];
    NSArray<NSString*>* dialogStep = [FCXLNTFSBridge appleScriptArgumentsToPrepareDevice:devicePath
                                                                              mountPoint:mountPoint
                                                                                   owner:getuid()
                                                                              privileged:YES];
    if (step == nil || dialogStep == nil) {
        // Not a disk volume: nothing is asked of the administrator and nothing is run.
        if (error) *error = makeError("Failed to prepare NTFS volume: not a disk volume");
        return NO;
    }
    _devicePath = [devicePath copy];
    _mountPoint = [mountPoint copy];

    NSError* privError = nil;
    if (!runPrivilegedStep(step, dialogStep, &privError)) {
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

    // Step 2: Re-mount (always try, even if close failed)
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
    // The device node is NOT given back to root here: that would take a second password
    // prompt, and macOS does not reset a node's owner on remount. It stays the user's
    // until the disk is detached; nobody else gains access to it.
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
