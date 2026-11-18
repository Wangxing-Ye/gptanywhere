# 实机步骤

样本见 `benchmarks/samples/index.md`。权重用 `benchmarks/fetch_p0_models.sh` 下载到 `models/weights/`，不要提交 Git。编译脚本在 `native/llm/` 和 `native/asr/`。一次完整探针是 `benchmarks/run_p0_engines.sh`。OCR 用调试包里的 P0 页面，不走命令行。

本轮环境变量：

```sh
export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home
export ANDROID_HOME=$HOME/Library/Android/sdk
export ANDROID_NDK=$ANDROID_HOME/ndk/28.2.13676358
export PATH="/Users/user/git/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmake/3.22.1/bin:$PATH"
```

文字探针固定 `-c 2048`、`--reasoning off`、`--temp 0.2`。6T 上 llama 用 4 线程。Mac 冒烟用 6 线程，不能把 Mac 速度写成手机速度。

## OnePlus 6T

本轮已执行。设备 `89ed17e8`，ONEPLUS A6013，Android 9 / API 28，arm64-v8a。

1. `adb devices` 确认序列号。
2. 运行 `benchmarks/run_p0_engines.sh`。脚本把二进制和权重大推进 `/data/local/tmp/ta`，再拉回日志。只重跑 SenseVoice 和中文朗读时用 `benchmarks/run_sherpa_device.sh`。sherpa 的 Android 程序先用 `native/asr/build_sherpa_android.sh` 编译，不要换回 Termux 预编译包。
3. `flutter build apk --debug` 后 `adb install -r build/app/outputs/flutter-apk/app-debug.apk`。
4. 启动 `dev.local.gptanywhere/.MainActivity`，在 logcat 里找 `P0_OCR_RESULT`。
5. 日志在 `benchmarks/results/`，该目录不入库。

未做：飞行模式、连续 15 分钟发热、100 句质量集、第二次进程之外的真正热启动。

## P1 文字页

未执行。手机重新出现在 `adb devices` 后运行 `benchmarks/run_p1_text_device.sh`。脚本把已核对的 Qwen 文件放到应用外部目录，再跑 `integration_test/p1_text_device_test.dart`。测试复制进应用私有目录后，用安装包里的翻译程序做中英双向、繁体提示和取消。日志写到 `benchmarks/results/p1-text-device.txt`，该目录不入库。

2026-11-02 的结果是 `DEVICE_ABSENT 89ed17e8`。更早尝试打开飞行模式时，设置值可以写成 1，但广播被拒绝，无线网络没有断开，随后已把设置改回 0。没有飞行模式或重启后的译文日志。iOS 文字翻译程序还没有编译，通道会返回失败，不产生假译文。

## P2 图片页

未执行。2026-11-02 调试包已覆盖安装到 `89ed17e8`，启动命令发出后 USB 断开，没有图片页截图。

手机重新出现后：

1. 打开 GPTAnywhere，进入「图片」。
2. 点「相册」选一张清晰的中文或英文图片，或点「拍照」。
3. 确认识别文字来自这张图，译文出现在下方。需要时向上滑动。模型未就绪时只保留识别文字。
4. 点「取消」后立刻再识别另一张，确认上一张的译文不会盖住新结果。

没有这些记录之前，不把图片入口写成 6T 已通过。

## P2 语音页

未执行。录音、导入音频和听写都还没有手机记录。

手机重新出现后：

1. 打开 GPTAnywhere，进入「语音」。文字模型未就绪时，先在「文字」页下载。
2. 点「下载听写模型」。缺省是 SenseVoice。下载完成前不要开始录音。
3. 点「录音」，说一句中文或英文，最长 30 秒，再点「停止」。确认听到的文字可以改，译文出现在下方。
4. 也可以点「选择音频」导入不超过 60 秒的文件。超过 60 秒应提示还不分段。
5. 安静不说话时，应显示「没有听到语音。」，不要出现编造的句子。
6. 设置里的「语音模型」可以改成 Whisper-small 或 Whisper-medium，再录同一句。两者都由 whisper.cpp 调用。中文不要使用英文专用权重。Whisper-medium 还没有手机记录。

没有这些记录之前，不把语音入口写成手机已通过，也不写「离线就绪」。

## 较新的 Android 手机

未执行。接上 USB 调试后把 `ANDROID_SERIAL` 设成新序列号，再跑上面的脚本和 OCR 包。API 必须不低于 24。把机型、系统版本、峰值内存和 tokens/s 另记，不要抄 6T 的数。

## 8GB iPhone

未执行。本轮只编译了未签名的 `build/ios/iphoneos/Runner.app`。真机需要解锁、数据线或已配对的开发者模式，以及开发者签名。最低系统因 ML Kit 定为 iOS 15.5。无线调试本轮报 CoreDevice code -27，没有拿到运行日志。

iOS 上还要确认中文 OCR pod 随包，并且断网后仍能识别 `benchmarks/samples/` 里的两张图。llama、whisper、sherpa 目前只有 Android 交叉编译和 Mac 主机二进制，没有 iOS 设备日志。
