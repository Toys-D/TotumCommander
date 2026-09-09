#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FCXLArchiveExtractProgressCallback)(NSString *currentFile,
                                                   double progress,
                                                   int64_t bytesDone,
                                                   int64_t bytesTotal,
                                                   int filesDone,
                                                   int filesTotal);
typedef void (^FCXLArchiveCreateProgressCallback)(NSString *currentFile,
                                                  int64_t bytesRead,
                                                  int64_t bytesTotal,
                                                  int filesDone,
                                                  int filesTotal,
                                                  int64_t compressedBytes);

@interface FCXLArchiveBridge : NSObject

- (instancetype)init;
- (nullable NSArray<NSDictionary<NSString*, id>*>*)listEntriesInArchive:(NSString *)archivePath
                                                                   error:(NSError**)error;
/// Password-aware twin: pass an empty string for archives that need none.
- (nullable NSArray<NSDictionary<NSString*, id>*>*)listEntriesInArchive:(NSString *)archivePath
                                                                password:(NSString *)password
                                                                   error:(NSError**)error;
- (BOOL)extractAllFromArchive:(NSString *)archivePath
                 toDestination:(NSString *)destinationPath
             overwriteExisting:(BOOL)overwriteExisting
              progressCallback:(nullable FCXLArchiveExtractProgressCallback)progressCallback
                         error:(NSError**)error;
- (BOOL)extractAllFromArchive:(NSString *)archivePath
                 toDestination:(NSString *)destinationPath
             overwriteExisting:(BOOL)overwriteExisting
                     password:(NSString *)password
              progressCallback:(nullable FCXLArchiveExtractProgressCallback)progressCallback
                         error:(NSError**)error;
- (BOOL)extractEntryInArchive:(NSString *)archivePath
                    entryPath:(NSString *)entryPath
              destinationPath:(NSString *)destinationPath
                        error:(NSError**)error;
- (BOOL)extractEntryInArchive:(NSString *)archivePath
                    entryPath:(NSString *)entryPath
              destinationPath:(NSString *)destinationPath
                     password:(NSString *)password
                        error:(NSError**)error;
- (BOOL)createArchiveAtPath:(NSString *)archivePath
                     format:(NSString *)format
                    sources:(NSArray<NSString*>*)sources
         includeSubfolders:(BOOL)includeSubfolders
               preservePaths:(BOOL)preservePaths
            compressionLevel:(NSInteger)compressionLevel
           progressCallback:(nullable FCXLArchiveCreateProgressCallback)progressCallback
                      error:(NSError**)error;
/// AES-256, ZIP only; any other format with a non-empty password errors rather than shipping
/// an archive the user merely believes is protected.
- (BOOL)createArchiveAtPath:(NSString *)archivePath
                     format:(NSString *)format
                    sources:(NSArray<NSString*>*)sources
         includeSubfolders:(BOOL)includeSubfolders
               preservePaths:(BOOL)preservePaths
            compressionLevel:(NSInteger)compressionLevel
                   password:(NSString *)password
           progressCallback:(nullable FCXLArchiveCreateProgressCallback)progressCallback
                      error:(NSError**)error;
- (BOOL)addFilesToArchive:(NSString *)archivePath
                    files:(NSArray<NSString *> *)filePaths
                 basePath:(NSString *)basePath
         progressCallback:(nullable FCXLArchiveCreateProgressCallback)progressCallback
                    error:(NSError **)error;
- (BOOL)deleteEntriesFromArchive:(NSString *)archivePath
                         entries:(NSArray<NSString *> *)entryPaths
                progressCallback:(nullable FCXLArchiveCreateProgressCallback)progressCallback
                           error:(NSError **)error;
- (BOOL)renameEntryInArchive:(NSString *)archivePath
                    oldEntry:(NSString *)oldPath
                    newEntry:(NSString *)newPath
            progressCallback:(nullable FCXLArchiveCreateProgressCallback)progressCallback
                       error:(NSError **)error;
- (void)cancelCurrentArchiveOperation;

@end

NS_ASSUME_NONNULL_END
