#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface HXScriptStore : NSObject
+ (instancetype)sharedStore;
- (NSArray<NSDictionary *> *)allScripts:(NSError **)error;
- (BOOL)saveScriptNamed:(NSString *)name code:(NSString *)code error:(NSError **)error;
- (nullable NSString *)loadScriptNamed:(NSString *)name error:(NSError **)error;
- (BOOL)deleteScriptNamed:(NSString *)name error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
