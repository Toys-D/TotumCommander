#import "FCXLCompareBridge.h"
#include <memory>
#include <string>
#include <vector>
#include "fcxl/compare/file_diff.h"
#include "fcxl/compare/dir_diff.h"

namespace {

/// A C++ string as an NSString that is never nil.
///
/// `+stringWithUTF8String:` returns nil for anything that is not valid UTF-8 — a file in some
/// other encoding, or a binary one that slipped past the caller's check — and a nil in a
/// dictionary literal is not an error but a CRASH. Latin-1 accepts every byte there is, so the
/// line survives as something printable and, more to the point, comparable.
auto safeString(const std::string& text) -> NSString* {
    NSString* utf8 = [[NSString alloc] initWithBytes:text.data()
                                              length:text.size()
                                            encoding:NSUTF8StringEncoding];
    if (utf8 != nil) { return utf8; }
    NSString* latin = [[NSString alloc] initWithBytes:text.data()
                                               length:text.size()
                                             encoding:NSISOLatin1StringEncoding];
    return latin != nil ? latin : @"";
}

auto make_nserror(const fcxl::common::Error& e) -> NSError* {
    return [NSError errorWithDomain:@"com.fcxl.compare"
                               code:static_cast<NSInteger>(e.code)
                           userInfo:@{
                               NSLocalizedDescriptionKey : safeString(e.message),
                               @"path" : safeString(e.path)
                           }];
}

auto diffTypeString(fcxl::compare::DiffType t) -> NSString* {
    switch (t) {
        case fcxl::compare::DiffType::Equal: return @"equal";
        case fcxl::compare::DiffType::Added: return @"added";
        case fcxl::compare::DiffType::Removed: return @"removed";
        case fcxl::compare::DiffType::Modified: return @"modified";
    }
    return @"equal";
}

auto dirStatusString(fcxl::compare::DirEntryStatus s) -> NSString* {
    switch (s) {
        case fcxl::compare::DirEntryStatus::Same: return @"same";
        case fcxl::compare::DirEntryStatus::Different: return @"different";
        case fcxl::compare::DirEntryStatus::LeftOnly: return @"leftOnly";
        case fcxl::compare::DirEntryStatus::RightOnly: return @"rightOnly";
    }
    return @"same";
}

}  // namespace

@implementation FCXLCompareBridge {
    std::unique_ptr<fcxl::compare::FileDiff> _fileDiff;
    std::unique_ptr<fcxl::compare::DirDiff> _dirDiff;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fileDiff = std::make_unique<fcxl::compare::FileDiff>();
        _dirDiff = std::make_unique<fcxl::compare::DirDiff>();
    }
    return self;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)compareFileAtPath:(NSString *)pathA
                                                          withFileAtPath:(NSString *)pathB
                                                                   error:(NSError**)error {
    auto result = _fileDiff->compare(pathA.UTF8String, pathB.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }

    NSMutableArray* arr = [NSMutableArray arrayWithCapacity:result.value().size()];
    for (const auto& line : result.value()) {
        [arr addObject:@{
            @"lineLeft" : @(line.line_left),
            @"lineRight" : @(line.line_right),
            @"type" : diffTypeString(line.type),
            @"content" : safeString(line.content)
        }];
    }
    return arr;
}

- (BOOL)areFilesIdenticalAtPath:(NSString *)pathA
                     andPath:(NSString *)pathB
                    identical:(BOOL *)identical
                        error:(NSError**)error {
    auto result = _fileDiff->are_identical(pathA.UTF8String, pathB.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return NO;
    }
    if (identical) *identical = result.value() ? YES : NO;
    return YES;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)compareDirectoryAtPath:(NSString *)dirA
                                                        withDirectoryAtPath:(NSString *)dirB
                                                                  byContent:(BOOL)byContent
                                                                      error:(NSError**)error {
    auto result = _dirDiff->compare(dirA.UTF8String, dirB.UTF8String, byContent);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }

    NSMutableArray* arr = [NSMutableArray arrayWithCapacity:result.value().size()];
    for (const auto& entry : result.value()) {
        [arr addObject:@{
            @"relativePath" : safeString(entry.relative_path.string()),
            @"status" : dirStatusString(entry.status),
            @"isDirectory" : @(entry.is_directory)
        }];
    }
    return arr;
}

@end
