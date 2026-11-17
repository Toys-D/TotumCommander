#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Called with each directory the search enters, for a "scanning …" status line. Invoked on
/// the search thread — the Swift side throttles and hops to the main thread.
typedef void (^FCXLScanProgressBlock)(NSString *currentDir);
/// Called with the finds made so far, a batch at a time, while the search is still walking —
/// so the list can fill as it goes instead of staying empty until the end. Invoked on the
/// search thread. The method's return value is still the whole, final answer.
typedef void (^FCXLFoundBlock)(NSArray<NSDictionary<NSString*, id>*> *batch);

@interface FCXLSearchBridge : NSObject
- (instancetype)init;

/// Basic file name search
- (nullable NSArray<NSDictionary<NSString*, id>*>*)findFilesAtPath:(NSString *)rootPath
                                                            pattern:(NSString *)pattern
                                                           useRegex:(BOOL)useRegex
                                                          recursive:(BOOL)recursive
                                                      includeHidden:(BOOL)includeHidden
                                                              error:(NSError**)error;

/// Advanced file search with size/date/type filters
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
                                                                  error:(NSError**)error;

/// Size limits are in bytes (0 = none), dates in seconds since 1970 (0 = none) — for the
/// content search and the duplicates run alike.
///
/// Content search. `nameMask` chooses which files are opened at all ("*.txt;*.md"; empty or
/// "*" — every file); a hidden directory is not entered unless `includeHidden`.
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
                                                                error:(NSError**)error;

/// Find duplicate files. mode: 0=byName, 1=bySize, 2=byHash
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
                                                                  error:(NSError**)error;

- (void)cancelSearch;
@end
NS_ASSUME_NONNULL_END
