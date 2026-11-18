#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// sherpa-onnx SenseVoice and Qwen3-ASR, plus tar.bz2 model extraction.
@interface IosSherpa : NSObject
- (void)start:(NSDictionary *)args
      onEvent:(void (^)(NSDictionary *event))onEvent;
- (void)cancel:(NSString *)taskId;
- (void)extract:(NSDictionary *)args
       progress:(void (^)(int written))progress
         result:(void (^)(NSError *_Nullable error))result;
@end

NS_ASSUME_NONNULL_END
