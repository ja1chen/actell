#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Cancellation is cooperative. The execution lane stays occupied until ios_system returns.
@interface CommandExecution : NSObject
+ (NSArray<NSString *> *)availableCommands;
- (void)cancel;
- (NSDictionary<NSString *, id> *)run:(NSString *)command directory:(NSURL *)directory timeout:(double)timeout NS_SWIFT_NAME(run(command:directory:timeout:));
@end
NS_ASSUME_NONNULL_END
