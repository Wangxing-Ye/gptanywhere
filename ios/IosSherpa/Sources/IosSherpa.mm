#import "IosSherpa.h"

#include <bzlib.h>

#include <climits>
#include <cstdint>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "c-api.h"

namespace {

std::string baseName(const std::string &path) {
  size_t slash = path.find_last_of('/');
  return slash == std::string::npos ? path : path.substr(slash + 1);
}

uint64_t octal(const char *text, size_t length) {
  uint64_t value = 0;
  for (size_t i = 0; i < length; i++) {
    char ch = text[i];
    if (ch == 0 || ch == ' ') continue;
    if (ch < '0' || ch > '7') break;
    value = (value << 3) + static_cast<uint64_t>(ch - '0');
  }
  return value;
}

bool readFully(BZFILE *input, void *destination, size_t count) {
  auto *out = static_cast<char *>(destination);
  size_t done = 0;
  while (done < count) {
    int bzError = BZ_OK;
    int got = BZ2_bzRead(&bzError, input, out + done, static_cast<int>(count - done));
    if (got > 0) done += static_cast<size_t>(got);
    if (bzError == BZ_STREAM_END) return done == count;
    if (bzError != BZ_OK || got <= 0) return false;
  }
  return true;
}

bool extractTarBz2(
    const std::string &archive,
    const std::string &destination,
    const std::vector<std::string> &names,
    int64_t expected,
    const std::function<void(int64_t)> &progress) {
  if (expected > 0) {
    std::string model = destination + "/model.onnx";
    std::string tokens = destination + "/tokens.txt";
    FILE *modelFile = fopen(model.c_str(), "rb");
    FILE *tokenFile = fopen(tokens.c_str(), "rb");
    if (modelFile != nullptr && tokenFile != nullptr) {
      fseek(modelFile, 0, SEEK_END);
      long modelSize = ftell(modelFile);
      fseek(tokenFile, 0, SEEK_END);
      long tokenSize = ftell(tokenFile);
      fclose(modelFile);
      fclose(tokenFile);
      if (modelSize == expected && tokenSize > 0) {
        progress(modelSize);
        return true;
      }
    } else {
      if (modelFile != nullptr) fclose(modelFile);
      if (tokenFile != nullptr) fclose(tokenFile);
    }
  }
  remove((destination + "/model.onnx").c_str());
  remove((destination + "/tokens.txt").c_str());

  FILE *file = fopen(archive.c_str(), "rb");
  if (file == nullptr) return false;
  int bzError = BZ_OK;
  BZFILE *input = BZ2_bzReadOpen(&bzError, file, 0, 0, nullptr, 0);
  if (input == nullptr) {
    fclose(file);
    return false;
  }
  std::string nextName;
  bool ok = true;
  while (ok) {
    char header[512];
    if (!readFully(input, header, sizeof(header))) break;
    bool zero = true;
    for (char ch : header) {
      if (ch != 0) {
        zero = false;
        break;
      }
    }
    if (zero) break;
    std::string name(header, strnlen(header, 100));
    if (memcmp(header + 257, "ustar", 5) == 0) {
      std::string prefix(header + 345, strnlen(header + 345, 155));
      if (!prefix.empty()) name = prefix + "/" + name;
    }
    uint64_t size = octal(header + 124, 12);
    char type = header[156];
    if (!nextName.empty()) {
      name = nextName;
      nextName.clear();
    }
    if (type == 'L' || type == 'K') {
      std::string longName(static_cast<size_t>(size), '\0');
      if (!longName.empty() &&
          !readFully(input, longName.data(), longName.size())) {
        ok = false;
        break;
      }
      size_t pad = (512 - (size % 512)) % 512;
      if (pad != 0) {
        char skip[512];
        if (!readFully(input, skip, pad)) {
          ok = false;
          break;
        }
      }
      if (type == 'L') nextName = longName.c_str();
      continue;
    }
    std::string leaf = baseName(name);
    bool wanted = type != '5' && !leaf.empty() && leaf != "." && leaf != "..";
    if (wanted) {
      wanted = false;
      for (const std::string &allowed : names) {
        if (leaf == allowed) {
          wanted = true;
          break;
        }
      }
    }
    FILE *out = nullptr;
    if (wanted) {
      std::string path = destination + "/" + leaf;
      out = fopen(path.c_str(), "wb");
      if (out == nullptr) {
        ok = false;
        break;
      }
    }
    uint64_t remaining = size;
    int64_t written = 0;
    int64_t reported = 0;
    char buffer[256 * 1024];
    while (remaining > 0) {
      size_t chunk = remaining > sizeof(buffer) ? sizeof(buffer) : static_cast<size_t>(remaining);
      if (!readFully(input, buffer, chunk)) {
        ok = false;
        break;
      }
      if (out != nullptr && fwrite(buffer, 1, chunk, out) != chunk) {
        ok = false;
        break;
      }
      remaining -= chunk;
      written += static_cast<int64_t>(chunk);
      if (out != nullptr && leaf == "model.onnx" && written - reported >= 1024 * 1024) {
        reported = written;
        progress(written);
      }
    }
    if (out != nullptr) fclose(out);
    if (!ok) break;
    uint64_t pad = (512 - (size % 512)) % 512;
    if (pad != 0) {
      char skip[512];
      if (!readFully(input, skip, static_cast<size_t>(pad))) break;
    }
  }
  BZ2_bzReadClose(&bzError, input);
  fclose(file);
  return ok;
}

}  // namespace

@implementation IosSherpa {
  dispatch_queue_t _queue;
  std::mutex _mu;
  NSString *_task;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create(
        "dev.local.gptanywhere.sherpa", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (BOOL)owns:(NSString *)taskId {
  std::lock_guard<std::mutex> lock(_mu);
  return _task != nil && [taskId isEqualToString:_task];
}

- (void)cancel:(NSString *)taskId {
  std::lock_guard<std::mutex> lock(_mu);
  if (_task != nil && [taskId isEqualToString:_task]) _task = nil;
}

- (void)start:(NSDictionary *)args
      onEvent:(void (^)(NSDictionary *event))onEvent {
  NSString *taskId = [args[@"taskId"] copy];
  NSDictionary *copied = [args copy];
  void (^event)(NSDictionary *) = [onEvent copy];
  {
    std::lock_guard<std::mutex> lock(_mu);
    _task = taskId;
  }
  dispatch_async(_queue, ^{
    if (![self owns:taskId]) return;
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

- (void)extract:(NSDictionary *)args
       progress:(void (^)(int written))progress
         result:(void (^)(NSError *_Nullable error))result {
  NSDictionary *copied = [args copy];
  void (^report)(int) = [progress copy];
  void (^done)(NSError *) = [result copy];
  dispatch_async(_queue, ^{
    NSString *archive = copied[@"archive"];
    NSString *destination = copied[@"destination"];
    NSArray *names = copied[@"names"];
    NSNumber *expected = copied[@"expectedBytes"];
    NSString *root = NSHomeDirectory();
    NSString *realDest = destination.stringByStandardizingPath;
    BOOL inside = realDest.length > 0 &&
        ([realDest isEqualToString:root] ||
         [realDest hasPrefix:[root stringByAppendingString:@"/"]]);
    if (archive.length == 0 || !inside || ![names isKindOfClass:[NSArray class]]) {
      done([NSError errorWithDomain:@"IosSherpa" code:1 userInfo:nil]);
      return;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:realDest
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    std::vector<std::string> allowed;
    for (id name in names) {
      if (![name isKindOfClass:[NSString class]]) continue;
      allowed.push_back([[(NSString *)name lastPathComponent] UTF8String]);
    }
    int64_t expectedBytes = expected == nil ? -1 : expected.longLongValue;
    bool ok = extractTarBz2(
        archive.UTF8String, realDest.UTF8String, allowed, expectedBytes,
        [report](int64_t written) {
          int value = written > INT_MAX ? INT_MAX : static_cast<int>(written);
          dispatch_async(dispatch_get_main_queue(), ^{
            report(value);
          });
        });
    dispatch_async(dispatch_get_main_queue(), ^{
      done(ok ? nil : [NSError errorWithDomain:@"IosSherpa" code:2 userInfo:nil]);
    });
  });
}

- (void)run:(NSDictionary *)args
     taskId:(NSString *)taskId
    onEvent:(void (^)(NSDictionary *))onEvent {
  NSString *engine = args[@"engine"] ?: @"";
  NSString *wavPath = args[@"wavPath"] ?: @"";
  const SherpaOnnxWave *wave = SherpaOnnxReadWave(wavPath.UTF8String);
  if (wave == nullptr) {
    [self fail:taskId message:@"听写没有启动。" type:@"modelLoadFailed" onEvent:onEvent];
    return;
  }
  SherpaOnnxOfflineRecognizerConfig config;
  memset(&config, 0, sizeof(config));
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.num_threads = 4;
  config.model_config.debug = 0;
  config.model_config.provider = "cpu";
  config.decoding_method = "greedy_search";

  auto field = [&](NSString *key) -> std::string {
    id value = args[key];
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) return {};
    return [(NSString *)value UTF8String];
  };
  std::string tokens;
  std::string model;
  std::string language;
  std::string conv;
  std::string encoder;
  std::string decoder;
  std::string tokenizer;
  if ([engine isEqualToString:@"qwen3Asr"]) {
    conv = field(@"convPath");
    encoder = field(@"encoderPath");
    decoder = field(@"decoderPath");
    tokenizer = field(@"tokenizerPath");
    if (conv.empty() || encoder.empty() || decoder.empty() || tokenizer.empty()) {
      SherpaOnnxFreeWave(wave);
      [self fail:taskId
          message:@"听写模型还没有准备好。"
             type:@"modelMissing"
          onEvent:onEvent];
      return;
    }
    config.model_config.qwen3_asr.conv_frontend = conv.c_str();
    config.model_config.qwen3_asr.encoder = encoder.c_str();
    config.model_config.qwen3_asr.decoder = decoder.c_str();
    config.model_config.qwen3_asr.tokenizer = tokenizer.c_str();
    config.model_config.qwen3_asr.max_total_len = 512;
    config.model_config.qwen3_asr.max_new_tokens = 512;
    config.model_config.qwen3_asr.temperature = 1e-6f;
    config.model_config.qwen3_asr.top_p = 0.8f;
    config.model_config.qwen3_asr.seed = 42;
  } else {
    tokens = field(@"tokensPath");
    model = field(@"modelPath");
    language = field(@"language");
    if (tokens.empty() || model.empty()) {
      SherpaOnnxFreeWave(wave);
      [self fail:taskId
          message:@"听写模型还没有准备好。"
             type:@"modelMissing"
          onEvent:onEvent];
      return;
    }
    config.model_config.tokens = tokens.c_str();
    config.model_config.sense_voice.model = model.c_str();
    config.model_config.sense_voice.language =
        language.empty() ? "auto" : language.c_str();
    config.model_config.sense_voice.use_itn = 0;
  }

  const SherpaOnnxOfflineRecognizer *recognizer =
      SherpaOnnxCreateOfflineRecognizer(&config);
  if (recognizer == nullptr) {
    SherpaOnnxFreeWave(wave);
    [self fail:taskId message:@"听写没有启动。" type:@"modelLoadFailed" onEvent:onEvent];
    return;
  }
  const SherpaOnnxOfflineStream *stream = SherpaOnnxCreateOfflineStream(recognizer);
  if (stream == nullptr) {
    SherpaOnnxDestroyOfflineRecognizer(recognizer);
    [self fail:taskId message:@"听写没有启动。" type:@"modelLoadFailed" onEvent:onEvent];
    return;
  }
  SherpaOnnxAcceptWaveformOffline(
      stream, wave->sample_rate, wave->samples, wave->num_samples);
  SherpaOnnxFreeWave(wave);
  SherpaOnnxDecodeOfflineStream(recognizer, stream);
  const SherpaOnnxOfflineRecognizerResult *decoded =
      SherpaOnnxGetOfflineStreamResult(stream);
  NSString *json = nil;
  if (decoded != nullptr && decoded->json != nullptr) {
    json = [NSString stringWithUTF8String:decoded->json];
  }
  if (json == nil) {
    NSString *text = decoded != nullptr && decoded->text != nullptr
        ? [NSString stringWithUTF8String:decoded->text]
        : @"";
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{@"text" : text ?: @""}
                                                   options:0
                                                     error:nil];
    json = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"{\"text\":\"\"}";
  }
  if (decoded != nullptr) SherpaOnnxDestroyOfflineRecognizerResult(decoded);
  SherpaOnnxDestroyOfflineStream(stream);
  SherpaOnnxDestroyOfflineRecognizer(recognizer);
  if (![self owns:taskId]) return;
  [self emit:@{
    @"taskId" : taskId,
    @"chunk" : json,
    @"done" : @YES,
    @"json" : @YES,
  }
        taskId:taskId
       onEvent:onEvent];
}

- (void)fail:(NSString *)taskId
     message:(NSString *)message
        type:(NSString *)type
     onEvent:(void (^)(NSDictionary *))onEvent {
  [self emit:@{
    @"taskId" : taskId,
    @"done" : @YES,
    @"error" : message,
    @"errorType" : type,
  }
        taskId:taskId
       onEvent:onEvent];
}

@end
