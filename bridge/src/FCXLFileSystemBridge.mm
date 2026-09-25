#import "FCXLFileSystemBridge.h"
#include <chrono>
#include <memory>
#include <vector>
#include <sys/clonefile.h>
#include <copyfile.h>
#include <removefile.h>

#include "fcxl/filesystem/navigator.h"

@implementation FCXLFileSystemBridge {
    std::unique_ptr<fcxl::fs::Navigator> _navigator;
}

namespace {

auto make_nserror(const fcxl::common::Error& core_error) -> NSError* {
    NSString* message = [NSString stringWithUTF8String:core_error.message.c_str()];
    NSString* path = [NSString stringWithUTF8String:core_error.path.c_str()];
    return [NSError errorWithDomain:@"com.fcxl.error"
                               code:static_cast<NSInteger>(core_error.code)
                           userInfo:@{
                               NSLocalizedDescriptionKey : message,
                               @"path" : path
                           }];
}

auto convert_entries_to_array(
    const fcxl::common::Result<std::vector<fcxl::common::FileEntry>>& result,
    NSError** error) -> NSArray<NSDictionary<NSString*, id>*>* {
    if (!result.has_value()) {
        if (error != nullptr) {
            *error = make_nserror(result.error());
        }
        return nil;
    }

    NSMutableArray<NSDictionary<NSString*, id>*>* converted = [NSMutableArray array];
    for (const auto& entry : result.value()) {
        const bool is_directory = entry.type == fcxl::common::EntryType::Directory;
        const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(
            entry.date_modified.time_since_epoch());
        const auto created_seconds = std::chrono::duration_cast<std::chrono::seconds>(
            entry.date_created.time_since_epoch());
        NSDate* modified_date = [NSDate dateWithTimeIntervalSince1970:seconds.count()];
        NSDate* created_date = [NSDate dateWithTimeIntervalSince1970:created_seconds.count()];

        NSDictionary<NSString*, id>* item = @{
            @"name" : [NSString stringWithUTF8String:entry.name.c_str()],
            @"path" : [NSString stringWithUTF8String:entry.path.string().c_str()],
            @"extension" : [NSString stringWithUTF8String:entry.extension.c_str()],
            @"size" : @(entry.size),
            @"entryCount" : @(entry.entry_count),
            @"isDirectory" : @(is_directory),
            @"isHidden" : @(entry.is_hidden),
            @"isSymlink" : @(entry.is_symlink),
            @"isAlias" : @(entry.is_alias),
            @"permissions" : [NSString stringWithUTF8String:entry.permissions.c_str()],
            @"dateModified" : modified_date,
            @"dateCreated" : created_date,
            @"owner" : [NSString stringWithUTF8String:entry.owner.c_str()]
        };
        [converted addObject:item];
    }

    return converted;
}

}  // namespace

- (instancetype)init {
    self = [super init];
    if (self) {
        _navigator = std::make_unique<fcxl::fs::Navigator>();
    }
    return self;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)listDirectory:(NSString *)path
                                                       showHidden:(BOOL)showHidden
                                                            error:(NSError**)error {
    return convert_entries_to_array(
        _navigator->list_directory(path.UTF8String, showHidden), error);
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)listDirectoryFast:(NSString *)path
                                                          showHidden:(BOOL)showHidden
                                                               error:(NSError**)error {
    return convert_entries_to_array(
        _navigator->list_directory_fast(path.UTF8String, showHidden), error);
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)listDirectoryNamesOnly:(NSString *)path
                                                               showHidden:(BOOL)showHidden
                                                                    error:(NSError**)error {
    return convert_entries_to_array(
        _navigator->list_directory_names_only(path.UTF8String, showHidden), error);
}

- (nullable NSString*)parentPath:(NSString *)path error:(NSError**)error {
    const auto result = _navigator->parent_path(path.UTF8String);
    if (!result.has_value()) {
        if (error != nullptr) {
            *error = make_nserror(result.error());
        }
        return nil;
    }

    return [NSString stringWithUTF8String:result.value().string().c_str()];
}

- (BOOL)copyItemAtPath:(NSString *)src toPath:(NSString *)dst error:(NSError**)error {
    // Try instant APFS clone first via clonefile(2).
    if (clonefile(src.fileSystemRepresentation, dst.fileSystemRepresentation, CLONE_NOOWNERCOPY) == 0) {
        return YES;
    }

    // clonefile failed — use copyfile() with COPYFILE_CLONE (tries CoW, falls back to byte copy).
    copyfile_flags_t flags = COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW;
    if (copyfile(src.fileSystemRepresentation, dst.fileSystemRepresentation, NULL, flags) == 0) {
        return YES;
    }

    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:errno
                                 userInfo:@{
                                     NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Copy failed: %s", strerror(errno)],
                                     NSFilePathErrorKey : src
                                 }];
    }
    return NO;
}

- (BOOL)moveItemAtPath:(NSString *)src toPath:(NSString *)dst error:(NSError**)error {
    // rename() is O(1) on the same volume — instant for any size.
    if (rename(src.fileSystemRepresentation, dst.fileSystemRepresentation) == 0) {
        return YES;
    }

    // EXDEV = cross-device: copy + remove.
    if (errno == EXDEV) {
        NSError *copyError = nil;
        if ([self copyItemAtPath:src toPath:dst error:&copyError]) {
            // Successfully copied cross-volume, now remove source.
            if (removefile(src.fileSystemRepresentation, NULL, REMOVEFILE_RECURSIVE) == 0) {
                return YES;
            }
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:errno
                                         userInfo:@{
                                             NSLocalizedDescriptionKey : @"Failed to remove source after cross-volume move",
                                             NSFilePathErrorKey : src
                                         }];
            }
            return NO;
        }
        if (error) *error = copyError;
        return NO;
    }

    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:errno
                                 userInfo:@{
                                     NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Move failed: %s", strerror(errno)],
                                     NSFilePathErrorKey : src
                                 }];
    }
    return NO;
}

- (BOOL)trashItemAtPath:(NSString *)path error:(NSError**)error {
    NSURL *url = [NSURL fileURLWithPath:path];
    return [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:error];
}

- (BOOL)createDirectoryAtPath:(NSString *)path error:(NSError**)error {
    NSURL *url = [NSURL fileURLWithPath:path];
    return [[NSFileManager defaultManager] createDirectoryAtURL:url
        withIntermediateDirectories:NO attributes:nil error:error];
}

@end
