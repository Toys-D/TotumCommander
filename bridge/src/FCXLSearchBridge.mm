#import "FCXLSearchBridge.h"

#include <chrono>
#include <memory>

#include <sys/stat.h>

#include "fcxl/search/content_search.h"
#include "fcxl/search/duplicate_finder.h"
#include "fcxl/search/file_search.h"


/// The exclusion list as the UI hands it over: already split, so the bridge only converts.
static std::vector<std::string> excludeList(NSArray<NSString*>* patterns) {
    std::vector<std::string> out;
    out.reserve(patterns.count);
    for (NSString* pattern in patterns) {
        if (pattern.length > 0) {
            out.emplace_back(pattern.UTF8String);
        }
    }
    return out;
}

@implementation FCXLSearchBridge
{
    std::unique_ptr<fcxl::search::FileSearch> _fileSearch;
    std::unique_ptr<fcxl::search::ContentSearch> _contentSearch;
    std::unique_ptr<fcxl::search::DuplicateFinder> _duplicateFinder;
}

namespace {

/// Convert std::string → NSString, tolerating invalid UTF-8 (falls back to Latin-1, then
/// empty). Raw file bytes in search results are often CP1251/KOI8-R; a nil NSString would
/// crash the moment it's inserted into an NSDictionary literal below.
auto safe_nsstring(const std::string& value) -> NSString* {
    NSString* converted = [NSString stringWithUTF8String:value.c_str()];
    if (converted != nil) return converted;
    converted = [[NSString alloc] initWithBytes:value.data()
                                         length:value.size()
                                       encoding:NSISOLatin1StringEncoding];
    return converted != nil ? converted : @"";
}

auto make_nserror(const fcxl::common::Error& core_error) -> NSError* {
    NSString* message = safe_nsstring(core_error.message);
    NSString* path = safe_nsstring(core_error.path);
    return [NSError errorWithDomain:@"com.fcxl.error"
                               code:static_cast<NSInteger>(core_error.code)
                           userInfo:@{
                               NSLocalizedDescriptionKey : message,
                               @"path" : path
                           }];
}

auto date_from_time_point(const std::chrono::system_clock::time_point& time_point) -> NSDate* {
    const auto seconds =
        std::chrono::duration_cast<std::chrono::seconds>(time_point.time_since_epoch());
    return [NSDate dateWithTimeIntervalSince1970:seconds.count()];
}

auto time_point_from_interval(NSTimeInterval interval) -> std::chrono::system_clock::time_point {
    if (interval <= 0) return {};
    return std::chrono::system_clock::time_point(
        std::chrono::seconds(static_cast<int64_t>(interval)));
}

/// Limits as the UI hands them over: 0 means "no limit" on that side.
auto make_limits(uint64_t minSize, uint64_t maxSize, NSTimeInterval dateFrom,
                 NSTimeInterval dateTo) -> fcxl::search::FileLimits {
    fcxl::search::FileLimits limits;
    limits.min_size = minSize;
    limits.max_size = maxSize > 0 ? maxSize : UINT64_MAX;
    limits.date_from = time_point_from_interval(dateFrom);
    limits.date_to = time_point_from_interval(dateTo);
    return limits;
}

/// A content find as the list wants it — with the file's size and date for its columns: one
/// look at the disk per found file, not per line.
auto match_to_dict(const fcxl::search::ContentMatch& match) -> NSDictionary<NSString*, id>* {
    struct stat info {};
    const bool known = ::stat(match.file.c_str(), &info) == 0;
    return @{
        @"path" : safe_nsstring(match.file.string()),
        @"name" : safe_nsstring(match.file.filename().string()),
        @"lineNumber" : @(match.line_number),
        @"column" : @(match.column),
        @"lineContent" : safe_nsstring(match.line_content),
        @"matchCount" : @(match.match_count),
        @"size" : @(known ? static_cast<uint64_t>(info.st_size) : 0),
        @"dateModified" : [NSDate dateWithTimeIntervalSince1970:
                                      known ? static_cast<NSTimeInterval>(info.st_mtimespec.tv_sec) : 0]
    };
}

/// Hands finds over in batches while a search is still running: a batch goes out when it is
/// full or when enough time has passed, so a slow search shows its first finds at once and a
/// fast one does not cross the bridge for every single file.
class FoundBatcher {
public:
    explicit FoundBatcher(FCXLFoundBlock block)
        : block_(block), pending_([NSMutableArray array]),
          last_(std::chrono::steady_clock::now()) {}

    void add(NSDictionary<NSString*, id>* item) {
        [pending_ addObject:item];
        const auto now = std::chrono::steady_clock::now();
        if (pending_.count >= 256 || now - last_ > std::chrono::milliseconds(150)) {
            flush();
            last_ = now;
        }
    }

    void flush() {
        if (pending_.count == 0) return;
        block_([pending_ copy]);
        [pending_ removeAllObjects];
    }

private:
    FCXLFoundBlock block_;
    NSMutableArray<NSDictionary<NSString*, id>*>* pending_;
    std::chrono::steady_clock::time_point last_;
};

auto entry_to_dict(const fcxl::common::FileEntry& entry) -> NSDictionary<NSString*, id>* {
    return @{
        @"path" : safe_nsstring(entry.path.string()),
        @"name" : safe_nsstring(entry.name),
        @"extension" : safe_nsstring(entry.extension),
        @"size" : @(entry.size),
        @"isDirectory" : @(entry.type == fcxl::common::EntryType::Directory),
        @"dateModified" : date_from_time_point(entry.date_modified)
    };
}

}  // namespace

- (instancetype)init {
    self = [super init];
    if (self) {
        _fileSearch = std::make_unique<fcxl::search::FileSearch>();
        _contentSearch = std::make_unique<fcxl::search::ContentSearch>();
        _duplicateFinder = std::make_unique<fcxl::search::DuplicateFinder>();
    }
    return self;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)findFilesAtPath:(NSString *)rootPath
                                                            pattern:(NSString *)pattern
                                                           useRegex:(BOOL)useRegex
                                                          recursive:(BOOL)recursive
                                                      includeHidden:(BOOL)includeHidden
                                                              error:(NSError**)error {
    fcxl::common::SearchFilter filter;
    filter.name_pattern = pattern.UTF8String;
    filter.use_regex = useRegex;
    filter.recursive = recursive;
    filter.include_hidden = includeHidden;

    const auto result = _fileSearch->search(rootPath.UTF8String, filter);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }

    NSMutableArray* converted = [NSMutableArray arrayWithCapacity:result.value().size()];
    for (const auto& entry : result.value()) {
        [converted addObject:entry_to_dict(entry)];
    }
    return converted;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)advancedSearchAtPath:(NSString *)rootPath
                                                                pattern:(NSString *)pattern
                                                               useRegex:(BOOL)useRegex
                                                              recursive:(BOOL)recursive
                                                          includeHidden:(BOOL)includeHidden
                                                                minSize:(uint64_t)minSize
                                                                maxSize:(uint64_t)maxSize
                                                               dateFrom:(NSTimeInterval)dateFrom
                                                                 dateTo:(NSTimeInterval)dateTo
                                                             typeFilter:(int)typeFilter
                                                        excludePatterns:(NSArray<NSString*>*)excludePatterns
                                                              onScanDir:(nullable FCXLScanProgressBlock)onScanDir
                                                                onFound:(nullable FCXLFoundBlock)onFound
                                                                  error:(NSError**)error {
    fcxl::common::SearchFilter filter;
    filter.name_pattern = pattern.UTF8String;
    filter.use_regex = useRegex;
    filter.recursive = recursive;
    filter.include_hidden = includeHidden;
    filter.min_size = minSize;
    filter.max_size = maxSize > 0 ? maxSize : UINT64_MAX;
    filter.date_from = time_point_from_interval(dateFrom);
    filter.date_to = time_point_from_interval(dateTo);

    switch (typeFilter) {
        case 1: filter.type_filter = fcxl::common::FileTypeFilter::FilesOnly; break;
        case 2: filter.type_filter = fcxl::common::FileTypeFilter::DirsOnly; break;
        default: filter.type_filter = fcxl::common::FileTypeFilter::All; break;
    }

    fcxl::search::ScanProgressCallback scanCb = nullptr;
    if (onScanDir) {
        scanCb = [onScanDir](std::string_view dir) { onScanDir(safe_nsstring(std::string(dir))); };
    }

    filter.exclude_patterns = excludeList(excludePatterns);
    std::unique_ptr<FoundBatcher> batcher;
    fcxl::search::SearchResultCallback foundCb = nullptr;
    if (onFound) {
        batcher = std::make_unique<FoundBatcher>(onFound);
        FoundBatcher* batches = batcher.get();
        foundCb = [batches](const fcxl::common::FileEntry& entry) {
            batches->add(entry_to_dict(entry));
        };
    }
    const auto result = _fileSearch->search(rootPath.UTF8String, filter, foundCb, scanCb);
    if (batcher) batcher->flush();
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }

    NSMutableArray* converted = [NSMutableArray arrayWithCapacity:result.value().size()];
    for (const auto& entry : result.value()) {
        [converted addObject:entry_to_dict(entry)];
    }
    return converted;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)findContentAtPath:(NSString *)rootPath
                                                              pattern:(NSString *)pattern
                                                             useRegex:(BOOL)useRegex
                                                            recursive:(BOOL)recursive
                                                        caseSensitive:(BOOL)caseSensitive
                                                        includeHidden:(BOOL)includeHidden
                                                             nameMask:(NSString *)nameMask
                                                              minSize:(uint64_t)minSize
                                                              maxSize:(uint64_t)maxSize
                                                             dateFrom:(NSTimeInterval)dateFrom
                                                               dateTo:(NSTimeInterval)dateTo
                                                      excludePatterns:(NSArray<NSString*>*)excludePatterns
                                                            onScanDir:(nullable FCXLScanProgressBlock)onScanDir
                                                              onFound:(nullable FCXLFoundBlock)onFound
                                                                error:(NSError**)error {
    fcxl::search::ScanProgressCallback scanCb = nullptr;
    if (onScanDir) {
        scanCb = [onScanDir](std::string_view dir) { onScanDir(safe_nsstring(std::string(dir))); };
    }
    fcxl::search::ContentOptions options;
    options.use_regex = useRegex;
    options.recursive = recursive;
    options.case_sensitive = caseSensitive;
    options.include_hidden = includeHidden;
    options.name_mask = nameMask.UTF8String;
    options.exclude_patterns = excludeList(excludePatterns);
    options.limits = make_limits(minSize, maxSize, dateFrom, dateTo);
    // The window lists FILES: one row per file, with the first matching line and the number
    // of lines that matched.
    options.one_per_file = true;
    std::unique_ptr<FoundBatcher> batcher;
    fcxl::search::ContentResultCallback foundCb = nullptr;
    if (onFound) {
        batcher = std::make_unique<FoundBatcher>(onFound);
        FoundBatcher* batches = batcher.get();
        foundCb = [batches](const fcxl::search::ContentMatch& match) {
            batches->add(match_to_dict(match));
        };
    }
    const auto result =
        _contentSearch->search(rootPath.UTF8String, pattern.UTF8String, options, foundCb, scanCb);
    if (batcher) batcher->flush();
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }

    NSMutableArray* converted = [NSMutableArray arrayWithCapacity:result.value().size()];
    for (const auto& match : result.value()) {
        [converted addObject:match_to_dict(match)];
    }
    return converted;
}

- (nullable NSArray<NSDictionary<NSString*, id>*>*)findDuplicatesAtPath:(NSString *)rootPath
                                                                   mode:(int)mode
                                                              recursive:(BOOL)recursive
                                                          includeHidden:(BOOL)includeHidden
                                                                minSize:(uint64_t)minSize
                                                                maxSize:(uint64_t)maxSize
                                                               dateFrom:(NSTimeInterval)dateFrom
                                                                 dateTo:(NSTimeInterval)dateTo
                                                        excludePatterns:(NSArray<NSString*>*)excludePatterns
                                                              onScanDir:(nullable FCXLScanProgressBlock)onScanDir
                                                                  error:(NSError**)error {
    fcxl::search::DuplicateStrategy strategy;
    switch (mode) {
        case 0: strategy = fcxl::search::DuplicateStrategy::ByName; break;
        case 1: strategy = fcxl::search::DuplicateStrategy::BySize; break;
        default: strategy = fcxl::search::DuplicateStrategy::ByHash; break;
    }

    fcxl::search::ScanProgressCallback dupScanCb = nullptr;
    if (onScanDir) {
        dupScanCb = [onScanDir](std::string_view dir) { onScanDir(safe_nsstring(std::string(dir))); };
    }
    fcxl::search::DuplicateOptions options;
    options.strategy = strategy;
    options.recursive = recursive;
    options.include_hidden = includeHidden;
    options.exclude_patterns = excludeList(excludePatterns);
    options.limits = make_limits(minSize, maxSize, dateFrom, dateTo);
    const auto result = _duplicateFinder->find(rootPath.UTF8String, options, nullptr, dupScanCb);
    if (!result.has_value()) {
        if (error) *error = make_nserror(result.error());
        return nil;
    }

    NSMutableArray* converted = [NSMutableArray arrayWithCapacity:result.value().size()];
    for (const auto& group : result.value()) {
        NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithCapacity:group.files.size()];
        for (const auto& f : group.files) {
            [paths addObject:safe_nsstring(f.string())];
        }
        [converted addObject:@{
            @"size" : @(group.size),
            @"hash" : safe_nsstring(group.hash),
            @"files" : paths
        }];
    }
    return converted;
}

- (void)cancelSearch {
    if (_fileSearch) _fileSearch->cancel();
    if (_contentSearch) _contentSearch->cancel();
    if (_duplicateFinder) _duplicateFinder->cancel();
}
@end
