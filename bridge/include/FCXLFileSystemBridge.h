#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface FCXLFileSystemBridge : NSObject
- (instancetype)init;
- (nullable NSArray<NSDictionary<NSString*, id>*>*)listDirectory:(NSString *)path
                                                       showHidden:(BOOL)showHidden
                                                            error:(NSError**)error;
- (nullable NSArray<NSDictionary<NSString*, id>*>*)listDirectoryFast:(NSString *)path
                                                          showHidden:(BOOL)showHidden
                                                               error:(NSError**)error;
- (nullable NSArray<NSDictionary<NSString*, id>*>*)listDirectoryNamesOnly:(NSString *)path
                                                               showHidden:(BOOL)showHidden
                                                                    error:(NSError**)error;
- (nullable NSString*)parentPath:(NSString *)path error:(NSError**)error;
- (BOOL)copyItemAtPath:(NSString *)src toPath:(NSString *)dst error:(NSError**)error;
- (BOOL)moveItemAtPath:(NSString *)src toPath:(NSString *)dst error:(NSError**)error;
- (BOOL)trashItemAtPath:(NSString *)path error:(NSError**)error;
- (BOOL)createDirectoryAtPath:(NSString *)path error:(NSError**)error;
@end
NS_ASSUME_NONNULL_END
