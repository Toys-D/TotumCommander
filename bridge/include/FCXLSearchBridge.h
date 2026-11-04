#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Called with each directory the search enters, for a "scanning …" status line. Invoked on
/// the search thread — the Swift side throttles and hops to the main thread.
typedef void (^FCXLScanProgressBlock)(NSString *currentDir);

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
                                                                  error:(NSError**)error;

/// Content search
- (nullable NSArray<NSDictionary<NSString*, id>*>*)findContentAtPath:(NSString *)rootPath
                                                              pattern:(NSString *)pattern
                                                             useRegex:(BOOL)useRegex
                                                            recursive:(BOOL)recursive
                                                      excludePatterns:(NSArray<NSString*>*)excludePatterns
                                                            onScanDir:(nullable FCXLScanProgressBlock)onScanDir
                                                                error:(NSError**)error;

/// Find duplicate files. mode: 0=byName, 1=bySize, 2=byHash
- (nullable NSArray<NSDictionary<NSString*, id>*>*)findDuplicatesAtPath:(NSString *)rootPath
                                                                   mode:(int)mode
                                                              recursive:(BOOL)recursive
                                                        excludePatterns:(NSArray<NSString*>*)excludePatterns
                                                              onScanDir:(nullable FCXLScanProgressBlock)onScanDir
                                                                  error:(NSError**)error;

- (void)cancelSearch;
@end
NS_ASSUME_NONNULL_END
