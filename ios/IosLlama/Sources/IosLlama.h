#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// In-process llama-cli. Arguments match the Android text bridge.
@interface IosLlama : NSObject
- (void)start:(NSDictionary *)args
      onEvent:(void (^)(NSDictionary *event))onEvent;
- (void)cancel:(NSString *)taskId;
@end

NS_ASSUME_NONNULL_END
