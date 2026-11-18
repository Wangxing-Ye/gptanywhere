#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// whisper.cpp for a multilingual ggml weight. English-only weights are rejected.
@interface IosWhisper : NSObject
- (void)start:(NSDictionary *)args
      onEvent:(void (^)(NSDictionary *event))onEvent;
- (void)cancel:(NSString *)taskId;
@end

NS_ASSUME_NONNULL_END
