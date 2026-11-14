#import <Foundation/Foundation.h>
#include <stdio.h>

NS_ASSUME_NONNULL_BEGIN
/// Process lifetime interpreter on one OS thread. Calls serialize and wait for
/// actual completion. Cancellation is cooperative, never a hard thread kill.
@interface ActellPythonRuntime : NSObject
+ (instancetype)shared;
- (int)runArguments:(NSArray<NSString *> *)arguments
              input:(FILE *)input output:(FILE *)output error:(FILE *)error
          directory:(NSString *)directory cancelled:(BOOL (^)(void))cancelled;
@end
NS_ASSUME_NONNULL_END
