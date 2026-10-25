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

/// What a symbolic link becomes in a new archive.
typedef NS_ENUM(NSInteger, FCXLArchiveLinks) {
    /// The link itself, as tar and zip -y keep it.
    FCXLArchiveLinksKeep = 0,
    /// What it points to, when it points outside what is packed: by a full path or above it.
    FCXLArchiveLinksFollowOutside = 1,
    /// Always what it points to.
    FCXLArchiveLinksFollowAll = 2,
};

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
/// Bytes that come out for each path (a folder: everything under it), in the order of
/// `entries` — summed inside, without bridging every entry of an archive of half a million.
- (nullable NSArray<NSNumber*>*)plannedBytesForEntries:(NSArray<NSString*>*)entries
                                             inArchive:(NSString *)archivePath
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
/// an archive the user merely believes is protected. `links` — what goes in for a symbolic link.
- (BOOL)createArchiveAtPath:(NSString *)archivePath
                     format:(NSString *)format
                    sources:(NSArray<NSString*>*)sources
         includeSubfolders:(BOOL)includeSubfolders
               preservePaths:(BOOL)preservePaths
            compressionLevel:(NSInteger)compressionLevel
                   password:(NSString *)password
                      links:(FCXLArchiveLinks)links
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
