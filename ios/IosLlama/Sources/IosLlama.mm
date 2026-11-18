#import "IosLlama.h"

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

#include <unistd.h>

// Same symbol the llama-cli executable calls. The local server runs on a
// thread inside that call, so this process does not spawn another executable.
struct cli_context {
  static std::atomic<bool> &interrupted();
};

int llama_cli(int argc, char **argv);

@implementation IosLlama {
  dispatch_queue_t _queue;
  std::mutex _mu;
  NSString *_task;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _queue = dispatch_queue_create(
        "dev.local.gptanywhere.llama", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)cancel:(NSString *)taskId {
  std::lock_guard<std::mutex> lock(_mu);
  if (_task != nil && [taskId isEqualToString:_task]) {
    _task = nil;
    cli_context::interrupted().store(true);
  }
}

- (void)start:(NSDictionary *)args
      onEvent:(void (^)(NSDictionary *event))onEvent {
  NSString *taskId = [args[@"taskId"] copy];
  NSDictionary *copied = [args copy];
  void (^event)(NSDictionary *) = [onEvent copy];
  {
    std::lock_guard<std::mutex> lock(_mu);
    if (_task != nil) cli_context::interrupted().store(true);
    _task = taskId;
  }
  dispatch_async(_queue, ^{
    if (![self owns:taskId]) return;
    cli_context::interrupted().store(false);
    [self run:copied taskId:taskId onEvent:event];
  });
}

- (BOOL)owns:(NSString *)taskId {
  std::lock_guard<std::mutex> lock(_mu);
  return _task != nil && [taskId isEqualToString:_task];
}

- (void)emit:(NSDictionary *)payload
      taskId:(NSString *)taskId
     onEvent:(void (^)(NSDictionary *))onEvent {
  if (![self owns:taskId]) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![self owns:taskId] && payload[@"done"] == nil) return;
    if (![self owns:taskId] && payload[@"error"] != nil) return;
    onEvent(payload);
  });
}

- (void)run:(NSDictionary *)args
     taskId:(NSString *)taskId
    onEvent:(void (^)(NSDictionary *))onEvent {
  NSString *model = args[@"modelPath"];
  NSString *system = args[@"systemPrompt"] ?: @"";
  NSString *prompt = args[@"prompt"] ?: @"";
  int maxTokens = [args[@"maxTokens"] intValue];
  BOOL thinking = [args[@"thinking"] boolValue];
  if (model.length == 0 || maxTokens <= 0) {
    [self emit:@{
      @"taskId" : taskId,
      @"done" : @YES,
      @"error" : @"翻译没有启动。",
      @"errorType" : @"modelLoadFailed",
    }
          taskId:taskId
         onEvent:onEvent];
    return;
  }

  std::vector<std::string> storage;
  storage.push_back("llama-cli");
  storage.push_back("-m");
  storage.push_back(model.UTF8String);
  storage.push_back("-c");
  storage.push_back("2048");
  storage.push_back("-n");
  storage.push_back(std::to_string(maxTokens));
  storage.push_back("--temp");
  storage.push_back("0.2");
  storage.push_back("--reasoning");
  storage.push_back(thinking ? "on" : "off");
  storage.push_back("-t");
  storage.push_back("4");
  storage.push_back("--single-turn");
  storage.push_back("--simple-io");
  storage.push_back("--log-disable");
  storage.push_back("--no-perf");
  storage.push_back("-sys");
  storage.push_back(system.UTF8String);
  storage.push_back("-p");
  storage.push_back(prompt.UTF8String);
  NSString *vision = args[@"visionPath"];
  NSArray *images = args[@"imagePaths"];
  int imageMax = [args[@"imageMaxTokens"] intValue];
  if ([vision isKindOfClass:[NSString class]] && vision.length > 0 &&
      [images isKindOfClass:[NSArray class]] && images.count > 0) {
    storage.push_back("--mmproj");
    storage.push_back(vision.UTF8String);
    if (imageMax > 0) {
      storage.push_back("--image-max-tokens");
      storage.push_back(std::to_string(imageMax));
    }
    for (id item in images) {
      if (![item isKindOfClass:[NSString class]]) continue;
      NSString *path = (NSString *)item;
      if (path.length == 0) continue;
      storage.push_back("--image");
      storage.push_back(path.UTF8String);
    }
  }
  std::vector<char *> argv;
  argv.reserve(storage.size() + 1);
  for (std::string &item : storage) argv.push_back(item.data());
  argv.push_back(nullptr);

  int fds[2];
  if (pipe(fds) != 0) {
    [self emit:@{
      @"taskId" : taskId,
      @"done" : @YES,
      @"error" : @"翻译没有启动。",
      @"errorType" : @"modelLoadFailed",
    }
          taskId:taskId
         onEvent:onEvent];
    return;
  }
  int saved = dup(STDOUT_FILENO);
  dup2(fds[1], STDOUT_FILENO);
  close(fds[1]);
  setvbuf(stdout, nullptr, _IONBF, 0);

  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  int readFd = fds[0];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    std::string pending;
    char buffer[512];
    while (true) {
      ssize_t count = read(readFd, buffer, sizeof(buffer));
      if (count <= 0) break;
      pending.append(buffer, static_cast<size_t>(count));
      while (!pending.empty()) {
        size_t usable = pending.size();
        NSString *text = nil;
        for (int drop = 0; drop < 4 && usable > 0; drop++) {
          text = [[NSString alloc] initWithBytes:pending.data()
                                          length:usable
                                        encoding:NSUTF8StringEncoding];
          if (text != nil) break;
          usable--;
        }
        if (text == nil) {
          pending.erase(0, 1);
          continue;
        }
        if (text.length > 0) {
          [self emit:@{@"taskId" : taskId, @"chunk" : text}
                taskId:taskId
               onEvent:onEvent];
        }
        pending.erase(0, usable);
      }
    }
    close(readFd);
    dispatch_semaphore_signal(finished);
  });

  int code = 1;
  try {
    code = llama_cli(static_cast<int>(argv.size() - 1), argv.data());
  } catch (...) {
    code = 1;
  }
  fflush(stdout);
  if (saved >= 0) {
    dup2(saved, STDOUT_FILENO);
    close(saved);
  }
  dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);

  if (![self owns:taskId]) return;
  if (code != 0) {
    [self emit:@{
      @"taskId" : taskId,
      @"done" : @YES,
      @"error" : [NSString stringWithFormat:@"翻译程序退出码 %d", code],
      @"errorType" : @"modelLoadFailed",
    }
          taskId:taskId
         onEvent:onEvent];
    return;
  }
  [self emit:@{@"taskId" : taskId, @"done" : @YES} taskId:taskId onEvent:onEvent];
}

@end
