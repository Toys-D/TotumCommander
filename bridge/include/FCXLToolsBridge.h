#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// Callback for rename preview: array of dictionaries with "original" and "renamed" keys
typedef void (^FCXLRenamePreviewCallback)(NSArray<NSDictionary<NSString*, NSString*>*>* _Nullable previews, NSError* _Nullable error);

@interface FCXLToolsBridge : NSObject
- (instancetype)init;

// MARK: - Checksum

/// Compute MD5 hash for file at path
- (nullable NSString*)md5ForFileAtPath:(NSString *)path error:(NSError**)error;

/// Compute SHA-1 hash for file at path
- (nullable NSString*)sha1ForFileAtPath:(NSString *)path error:(NSError**)error;

/// Compute SHA-256 hash for file at path
- (nullable NSString*)sha256ForFileAtPath:(NSString *)path error:(NSError**)error;

/// Compute all checksums (MD5, SHA-1, SHA-256) in a single pass
- (nullable NSDictionary<NSString*, NSString*>*)allChecksumsForFileAtPath:(NSString *)path error:(NSError**)error;

/// Verify file against expected hash (auto-detects algorithm by hash length)
- (BOOL)verifyFileAtPath:(NSString *)path againstHash:(NSString *)expectedHash match:(BOOL*)match error:(NSError**)error;

// MARK: - Multi-Rename

/// Preview rename results without executing. Returns array of {original, renamed} dictionaries.
- (nullable NSArray<NSDictionary<NSString*, NSString*>*>*)previewRenameFiles:(NSArray<NSString*>*)files
                                                              searchPattern:(NSString *)searchPattern
                                                             replacePattern:(NSString *)replacePattern
                                                                   useRegex:(BOOL)useRegex
                                                                 changeCase:(BOOL)changeCase
                                                              counterFormat:(NSString *)counterFormat
                                                                      error:(NSError**)error;

/// Execute rename on files with given rule
- (BOOL)executeRenameFiles:(NSArray<NSString*>*)files
             searchPattern:(NSString *)searchPattern
            replacePattern:(NSString *)replacePattern
                  useRegex:(BOOL)useRegex
                changeCase:(BOOL)changeCase
             counterFormat:(NSString *)counterFormat
                     error:(NSError**)error;

// MARK: - File Splitter

/// Called with (bytes done, bytes total); return YES to cancel — partial output is removed.
typedef BOOL (^FCXLByteProgressBlock)(uint64_t done, uint64_t total);

/// Split file into chunks. Returns array of part file paths.
- (nullable NSArray<NSString*>*)splitFileAtPath:(NSString *)path
                                      chunkSize:(uint64_t)chunkSize
                                      outputDir:(NSString *)outputDir
                                       progress:(nullable FCXLByteProgressBlock)progress
                                          error:(NSError**)error;

- (nullable NSArray<NSString*>*)splitFileAtPath:(NSString *)path
                                      chunkSize:(uint64_t)chunkSize
                                      outputDir:(NSString *)outputDir
                                          error:(NSError**)error;

/// Join parts into single file
- (BOOL)joinFiles:(NSArray<NSString*>*)parts
       outputPath:(NSString *)outputPath
         progress:(nullable FCXLByteProgressBlock)progress
            error:(NSError**)error;

- (BOOL)joinFiles:(NSArray<NSString*>*)parts
       outputPath:(NSString *)outputPath
            error:(NSError**)error;

@end
NS_ASSUME_NONNULL_END
