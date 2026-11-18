#import "IosWhisper.h"

#include <atomic>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "whisper.h"

namespace {

bool englishOnly(NSString *path) {
  NSString *name = path.lastPathComponent.lowercaseString;
  return [name containsString:@".en."] || [name hasSuffix:@".en"] ||
      [name hasSuffix:@".en.bin"];
}

bool loadPcm16(NSString *path, std::vector<float> &samples) {
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (data.length < 44) return false;
  const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
  if (memcmp(bytes, "RIFF", 4) != 0 || memcmp(bytes + 8, "WAVE", 4) != 0) {
    return false;
  }
  uint16_t audioFormat = 1;
  uint16_t channels = 1;
  uint32_t sampleRate = 16000;
  uint16_t bits = 16;
  const uint8_t *pcm = nullptr;
  uint32_t pcmBytes = 0;
  size_t offset = 12;
  while (offset + 8 <= data.length) {
    char id[5] = {};
    memcpy(id, bytes + offset, 4);
    uint32_t size = 0;
    memcpy(&size, bytes + offset + 4, 4);
    size_t start = offset + 8;
    if (start + size > data.length) return false;
    if (strcmp(id, "fmt ") == 0 && size >= 16) {
      memcpy(&audioFormat, bytes + start, 2);
      memcpy(&channels, bytes + start + 2, 2);
      memcpy(&sampleRate, bytes + start + 4, 4);
      memcpy(&bits, bytes + start + 14, 2);
    } else if (strcmp(id, "data") == 0) {
      pcm = bytes + start;
      pcmBytes = size;
    }
    offset = start + size + (size & 1U);
  }
  if (pcm == nullptr || audioFormat != 1 || bits != 16 || channels == 0) {
    return false;
  }
  size_t frames = pcmBytes / (static_cast<size_t>(channels) * 2);
  std::vector<float> mono(frames);
  const int16_t *view = reinterpret_cast<const int16_t *>(pcm);
  for (size_t i = 0; i < frames; i++) {
    float sum = 0;
    for (uint16_t channel = 0; channel < channels; channel++) {
      sum += view[i * channels + channel] / 32768.0f;
    }
    mono[i] = sum / channels;
  }
  if (sampleRate == 16000) {
    samples.swap(mono);
    return !samples.empty();
  }
  size_t outCount =
      std::max<size_t>(1, (mono.size() * 16000) / std::max<uint32_t>(sampleRate, 1));
  samples.resize(outCount);
  for (size_t i = 0; i < outCount; i++) {
    double position = static_cast<double>(i) * sampleRate / 16000.0;
    size_t left = static_cast<size_t>(position);
    if (left >= mono.size()) left = mono.size() - 1;
    size_t right = std::min(left + 1, mono.size() - 1);
    float frac = static_cast<float>(position - left);
    samples[i] = mono[left] * (1.0f - frac) + mono[right] * frac;
  }
  return true;
}

}  // namespace

@implementation IosWhisper {
  dispatch_queue_t _queue;
  std::mutex _mu;
  NSString *_task;
  std::atomic<bool> _stop;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create(
        "dev.local.gptanywhere.whisper", DISPATCH_QUEUE_SERIAL);
    _stop.store(false);
  }
  return self;
}

- (BOOL)owns:(NSString *)taskId {
  std::lock_guard<std::mutex> lock(_mu);
  return _task != nil && [taskId isEqualToString:_task];
}

- (void)cancel:(NSString *)taskId {
  std::lock_guard<std::mutex> lock(_mu);
  if (_task != nil && [taskId isEqualToString:_task]) {
    _task = nil;
    _stop.store(true);
  }
}

- (void)start:(NSDictionary *)args
      onEvent:(void (^)(NSDictionary *event))onEvent {
  NSString *taskId = [args[@"taskId"] copy];
  NSDictionary *copied = [args copy];
  void (^event)(NSDictionary *) = [onEvent copy];
  {
    std::lock_guard<std::mutex> lock(_mu);
    if (_task != nil) _stop.store(true);
    _task = taskId;
  }
  dispatch_async(_queue, ^{
    if (![self owns:taskId]) return;
    _stop.store(false);
    [self run:copied taskId:taskId onEvent:event];
  });
}

- (void)emit:(NSDictionary *)payload
      taskId:(NSString *)taskId
     onEvent:(void (^)(NSDictionary *))onEvent {
  if (![self owns:taskId]) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![self owns:taskId]) return;
    onEvent(payload);
  });
}

- (void)run:(NSDictionary *)args
     taskId:(NSString *)taskId
    onEvent:(void (^)(NSDictionary *))onEvent {
  NSString *model = args[@"modelPath"] ?: @"";
  NSString *wav = args[@"wavPath"] ?: @"";
  NSString *language = args[@"language"] ?: @"";
  if (englishOnly(model)) {
    [self emit:@{
      @"taskId" : taskId,
      @"done" : @YES,
      @"error" : @"不能使用英文专用听写权重。",
      @"errorType" : @"languageUnsupported",
    }
          taskId:taskId
         onEvent:onEvent];
    return;
  }
  std::vector<float> samples;
  if (model.length == 0 || !loadPcm16(wav, samples)) {
    [self emit:@{
      @"taskId" : taskId,
      @"done" : @YES,
      @"error" : @"听写没有启动。",
      @"errorType" : @"modelLoadFailed",
    }
          taskId:taskId
         onEvent:onEvent];
    return;
  }
  struct whisper_context_params cparams = whisper_context_default_params();
  struct whisper_context *ctx =
      whisper_init_from_file_with_params(model.UTF8String, cparams);
  if (ctx == nullptr) {
    [self emit:@{
      @"taskId" : taskId,
      @"done" : @YES,
      @"error" : @"听写没有启动。",
      @"errorType" : @"modelLoadFailed",
    }
          taskId:taskId
         onEvent:onEvent];
    return;
  }
  if (!whisper_is_multilingual(ctx)) {
    whisper_free(ctx);
    [self emit:@{
      @"taskId" : taskId,
      @"done" : @YES,
      @"error" : @"不能使用英文专用听写权重。",
      @"errorType" : @"languageUnsupported",
    }
          taskId:taskId
         onEvent:onEvent];
    return;
  }
  std::string lang = language.UTF8String;
  struct whisper_full_params params =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.n_threads = 4;
  params.no_timestamps = true;
  params.print_timestamps = false;
  params.print_realtime = false;
  params.print_progress = false;
  params.language = lang.c_str();
  params.abort_callback = [](void *data) -> bool {
    return static_cast<std::atomic<bool> *>(data)->load();
  };
  params.abort_callback_user_data = &_stop;
  int code = whisper_full(ctx, params, samples.data(), static_cast<int>(samples.size()));
  std::string text = "\n";
  if (code == 0) {
    int count = whisper_full_n_segments(ctx);
    for (int i = 0; i < count; i++) {
      const char *segment = whisper_full_get_segment_text(ctx, i);
      if (segment != nullptr) text += segment;
    }
  }
  whisper_free(ctx);
  if (![self owns:taskId]) return;
  if (code != 0) {
    [self emit:@{
      @"taskId" : taskId,
      @"done" : @YES,
      @"error" : [NSString stringWithFormat:@"听写程序退出码 %d", code],
      @"errorType" : @"modelLoadFailed",
    }
          taskId:taskId
         onEvent:onEvent];
    return;
  }
  [self emit:@{
    @"taskId" : taskId,
    @"chunk" : [NSString stringWithUTF8String:text.c_str()],
    @"done" : @YES,
    @"json" : @NO,
  }
        taskId:taskId
       onEvent:onEvent];
}

@end
