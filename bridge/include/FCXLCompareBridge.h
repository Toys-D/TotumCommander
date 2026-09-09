#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface FCXLCompareBridge : NSObject
- (instancetype)init;

/// Compare two files line by line. Returns array of dicts: {lineLeft, lineRight, type, content}
/// type: "equal", "added", "removed", "modified"
- (nullable NSArray<NSDictionary<NSString*, id>*>*)compareFileAtPath:(NSString *)pathA
                                                          withFileAtPath:(NSString *)pathB
                                                                   error:(NSError**)error;

/// Check if two files are byte-identical
- (BOOL)areFilesIdenticalAtPath:(NSString *)pathA
                     andPath:(NSString *)pathB
                    identical:(BOOL *)identical
                        error:(NSError**)error;

/// Compare two directories. Returns array of dicts: {relativePath, status, isDirectory}
/// status: "same", "different", "leftOnly", "rightOnly"
- (nullable NSArray<NSDictionary<NSString*, id>*>*)compareDirectoryAtPath:(NSString *)dirA
                                                        withDirectoryAtPath:(NSString *)dirB
                                                                  byContent:(BOOL)byContent
                                                                      error:(NSError**)error;

@end
NS_ASSUME_NONNULL_END
