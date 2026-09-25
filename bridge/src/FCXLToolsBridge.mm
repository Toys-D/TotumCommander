#import "FCXLToolsBridge.h"
#include <memory>
#include <string>
#include <vector>
#include "fcxl/tools/checksum.h"
#include "fcxl/tools/multi_rename.h"
#include "fcxl/tools/file_splitter.h"

namespace {

auto make_nserror(const fcxl::common::Error& core_error) -> NSError* {
    NSString* message = [NSString stringWithUTF8String:core_error.message.c_str()];
    NSString* path = core_error.path.empty() ? @"" : [NSString stringWithUTF8String:core_error.path.c_str()];
    return [NSError errorWithDomain:@"com.fcxl.tools"
                               code:static_cast<NSInteger>(core_error.code)
                           userInfo:@{
                               NSLocalizedDescriptionKey : message,
                               @"path" : path
                           }];
}

}  // namespace

@implementation FCXLToolsBridge {
    std::unique_ptr<fcxl::tools::Checksum> _checksum;
    std::unique_ptr<fcxl::tools::MultiRename> _multiRename;
    std::unique_ptr<fcxl::tools::FileSplitter> _fileSplitter;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _checksum = std::make_unique<fcxl::tools::Checksum>();
        _multiRename = std::make_unique<fcxl::tools::MultiRename>();
        _fileSplitter = std::make_unique<fcxl::tools::FileSplitter>();
    }
    return self;
}

// MARK: - Checksum

- (nullable NSString*)md5ForFileAtPath:(NSString *)path error:(NSError**)error {
    auto result = _checksum->md5(path.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }
    return [NSString stringWithUTF8String:result.value().c_str()];
}

- (nullable NSString*)sha1ForFileAtPath:(NSString *)path error:(NSError**)error {
    auto result = _checksum->sha1(path.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }
    return [NSString stringWithUTF8String:result.value().c_str()];
}

- (nullable NSString*)sha256ForFileAtPath:(NSString *)path error:(NSError**)error {
    auto result = _checksum->sha256(path.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }
    return [NSString stringWithUTF8String:result.value().c_str()];
}

- (nullable NSDictionary<NSString*, NSString*>*)allChecksumsForFileAtPath:(NSString *)path error:(NSError**)error {
    auto result = _checksum->compute_all(path.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }
    const auto& checksums = result.value();
    return @{
        @"md5" : [NSString stringWithUTF8String:checksums.md5.c_str()],
        @"sha1" : [NSString stringWithUTF8String:checksums.sha1.c_str()],
        @"sha256" : [NSString stringWithUTF8String:checksums.sha256.c_str()]
    };
}

- (BOOL)verifyFileAtPath:(NSString *)path againstHash:(NSString *)expectedHash match:(BOOL*)match error:(NSError**)error {
    auto result = _checksum->verify(path.UTF8String, expectedHash.UTF8String);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return NO;
    }
    if (match) *match = result.value() ? YES : NO;
    return YES;
}

// MARK: - Multi-Rename

- (nullable NSArray<NSDictionary<NSString*, NSString*>*>*)previewRenameFiles:(NSArray<NSString*>*)files
                                                              searchPattern:(NSString *)searchPattern
                                                             replacePattern:(NSString *)replacePattern
                                                                   useRegex:(BOOL)useRegex
                                                                 changeCase:(BOOL)changeCase
                                                              counterFormat:(NSString *)counterFormat
                                                                      error:(NSError**)error {
    std::vector<std::string> cpp_files;
    cpp_files.reserve(files.count);
    for (NSString* f in files) {
        cpp_files.emplace_back(f.UTF8String);
    }

    fcxl::tools::RenameRule rule;
    rule.search_pattern = searchPattern.UTF8String;
    rule.replace_pattern = replacePattern.UTF8String;
    rule.use_regex = useRegex;
    rule.change_case = changeCase;
    rule.counter_format = counterFormat.UTF8String;

    auto previews = _multiRename->preview(cpp_files, rule);

    NSMutableArray<NSDictionary<NSString*, NSString*>*>* result = [NSMutableArray arrayWithCapacity:previews.size()];
    for (const auto& p : previews) {
        [result addObject:@{
            @"original" : [NSString stringWithUTF8String:p.original.c_str()],
            @"renamed" : [NSString stringWithUTF8String:p.renamed.c_str()]
        }];
    }
    return result;
}

- (BOOL)executeRenameFiles:(NSArray<NSString*>*)files
             searchPattern:(NSString *)searchPattern
            replacePattern:(NSString *)replacePattern
                  useRegex:(BOOL)useRegex
                changeCase:(BOOL)changeCase
             counterFormat:(NSString *)counterFormat
                     error:(NSError**)error {
    std::vector<std::string> cpp_files;
    cpp_files.reserve(files.count);
    for (NSString* f in files) {
        cpp_files.emplace_back(f.UTF8String);
    }

    fcxl::tools::RenameRule rule;
    rule.search_pattern = searchPattern.UTF8String;
    rule.replace_pattern = replacePattern.UTF8String;
    rule.use_regex = useRegex;
    rule.change_case = changeCase;
    rule.counter_format = counterFormat.UTF8String;

    auto result = _multiRename->execute(cpp_files, rule);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return NO;
    }
    return YES;
}

// MARK: - File Splitter

- (nullable NSArray<NSString*>*)splitFileAtPath:(NSString *)path
                                      chunkSize:(uint64_t)chunkSize
                                      outputDir:(NSString *)outputDir
                                          error:(NSError**)error {
    return [self splitFileAtPath:path chunkSize:chunkSize outputDir:outputDir
                        progress:nil error:error];
}

- (nullable NSArray<NSString*>*)splitFileAtPath:(NSString *)path
                                      chunkSize:(uint64_t)chunkSize
                                      outputDir:(NSString *)outputDir
                                       progress:(nullable FCXLByteProgressBlock)progress
                                          error:(NSError**)error {
    fcxl::tools::ProgressFn fn = nullptr;
    if (progress) {
        fn = [progress](uint64_t done, uint64_t total) -> bool {
            return progress(done, total) == YES;
        };
    }
    auto result = _fileSplitter->split(path.UTF8String, chunkSize, outputDir.UTF8String, fn);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }

    NSMutableArray<NSString*>* arr = [NSMutableArray arrayWithCapacity:result.value().size()];
    for (const auto& part : result.value()) {
        [arr addObject:[NSString stringWithUTF8String:part.c_str()]];
    }
    return arr;
}

- (BOOL)joinFiles:(NSArray<NSString*>*)parts
       outputPath:(NSString *)outputPath
            error:(NSError**)error {
    return [self joinFiles:parts outputPath:outputPath progress:nil error:error];
}

- (BOOL)joinFiles:(NSArray<NSString*>*)parts
       outputPath:(NSString *)outputPath
         progress:(nullable FCXLByteProgressBlock)progress
            error:(NSError**)error {
    std::vector<std::string> cpp_parts;
    cpp_parts.reserve(parts.count);
    for (NSString* p in parts) {
        cpp_parts.emplace_back(p.UTF8String);
    }

    fcxl::tools::ProgressFn fn = nullptr;
    if (progress) {
        fn = [progress](uint64_t done, uint64_t total) -> bool {
            return progress(done, total) == YES;
        };
    }
    auto result = _fileSplitter->join(cpp_parts, outputPath.UTF8String, fn);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return NO;
    }
    return YES;
}

@end
