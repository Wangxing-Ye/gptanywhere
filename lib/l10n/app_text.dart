import 'package:flutter/widgets.dart';

import '../domain/app_error.dart';
import '../domain/app_settings.dart';

typedef UiLine = String Function(AppText text);

class InterfaceScope extends InheritedWidget {
  const InterfaceScope({
    super.key,
    required this.language,
    required super.child,
  });

  final InterfaceLanguage language;

  static InterfaceLanguage languageOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<InterfaceScope>();
    return scope?.language ?? InterfaceLanguage.english;
  }

  @override
  bool updateShouldNotify(InterfaceScope oldWidget) {
    return language != oldWidget.language;
  }
}

class AppText {
  const AppText(this.language);

  final InterfaceLanguage language;

  bool get chinese => language == InterfaceLanguage.zhHans;

  String pick(String english, String chineseText) =>
      chinese ? chineseText : english;

  static AppText of(BuildContext context) {
    return AppText(InterfaceScope.languageOf(context));
  }

  String get appTitle => 'GPTAnywhere';
  String get settings => pick('Settings', '设置');
  String get chatTab => pick('Chat', '对话');
  String get textTab => pick('Text', '文字');
  String get send => pick('Send', '发送');
  String get play => pick('Play', '播放');
  String get stopPlayback => pick('Stop', '停止');
  String get messageHint => pick('Message', '消息');
  String get photoTab => pick('Photo', '图片');
  String get voiceTab => pick('Voice', '语音');
  String get languageSetting => pick('Language', '语言');
  String get interfaceLanguage => pick('Interface language', '界面语言');
  String get textModels => pick('Text models', '文本大模型');
  String get textModelsSubtitle =>
      pick('Model used for translation', '翻译使用的文字模型');
  String get speechModels => pick('Speech models', '语音模型');
  String get speechModelsSubtitle =>
      pick('Model that turns speech into text', '语音输出文字的模型');
  String get thinkingMode => pick('Thinking mode', '思考模式');
  String get thinkingOffByDefault => pick('Off by default', '缺省关闭');
  String get download => pick('Download', '下载');
  String get modelNotListed =>
      pick('This model is not in the list', '清单里没有这个模型');
  String get downloadedSuffix => pick(', downloaded', '，已下载');
  String get notEnoughMemorySuffix =>
      pick('. Not enough memory on this phone', '。这台手机内存不够');
  String get downloading => pick('Downloading', '正在下载');
  String get extracting => pick('Extracting', '正在解压');

  String downloadingAmount(int shownMb) =>
      pick('Downloading $shownMb MB', '正在下载 $shownMb MB');

  String downloadingFraction(int shownMb, int totalMb, int? percent) {
    final base = pick(
      'Downloading $shownMb / $totalMb MB',
      '正在下载 $shownMb / $totalMb MB',
    );
    return percent == null ? base : '$base  $percent%';
  }

  String extractingFraction(int shownMb, int totalMb, int? percent) {
    final base = pick(
      'Extracting $shownMb / $totalMb MB',
      '正在解压 $shownMb / $totalMb MB',
    );
    return percent == null ? base : '$base  $percent%';
  }

  String currentModel(String label) =>
      pick('Current model: $label', '当前模型: $label');

  String get checkingModel => pick('Checking the model', '正在检查模型');
  String get modelNotReadyToTranslate => pick(
    'The model is not ready. Download or import one before translating.',
    '模型还没有准备好。下载或导入后才能翻译。',
  );
  String get chooseDifferentTarget =>
      pick('Choose a different target language.', '请选择不同的目标语言。');
  String get translating => pick('Translating', '翻译中');
  String get noTranslation => pick('No translation was produced.', '没有得到译文。');
  String get canceled => pick('Canceled', '已取消');
  String get translationCopied => pick('Translation copied', '译文已复制');
  String get swapLanguages => pick('Swap languages', '交换语言');
  String get sourceText => pick('Source text', '原文');
  String get cancel => pick('Cancel', '取消');
  String get translate => pick('Translate', '翻译');
  String get translation => pick('Translation', '译文');
  String get copy => pick('Copy', '复制');
  String get noTranslationYet => pick('No translation yet', '尚无译文');
  String get verifyFailedKeptOld => pick(
    'The model file failed verification. The previous model was kept.',
    '模型文件校验失败，已保留原来的模型。',
  );
  String get notEnoughStorage => pick('Not enough storage.', '存储空间不足。');
  String get languagePairUnsupported =>
      pick('This language pair cannot be translated yet.', '这个语言组合还不能翻译。');
  String get translationDidNotStart =>
      pick('Translation did not start.', '翻译没有启动。');
  String get translationDidNotFinish =>
      pick('Translation did not finish.', '翻译没有完成。');
  String get modelNotReady => pick('The model is not ready.', '模型还没有准备好。');
  String get visionFileNotReady => pick(
    'This model cannot see the image until its vision file is downloaded.',
    '这个模型的看图文件还没下载，还不能看图片。',
  );
  String get downloadDidNotFinish =>
      pick('The download did not finish.', '下载没有完成。');
  String get downloadPaused => pick('Download paused.', '下载已暂停。');
  String get offlineNoDownload =>
      pick('No network, so the download did not start.', '当前没有网络，没有开始下载。');
  String get downloadInterrupted => pick(
    'The download was interrupted. The previous model was kept.',
    '下载中断，已保留原来的模型。',
  );
  String get speechModelNotReady =>
      pick('The speech model is not ready.', '听写模型还没有准备好。');
  String get speechVerifyFailed => pick(
    'The speech model could not be verified. Please download it again.',
    '听写模型无法校验，请重新下载。',
  );
  String get extractFailedKeptDownload => pick(
    'The speech model could not be extracted. The download was kept.',
    '听写模型无法解压，已保留下载的文件。',
  );

  String get openingCamera => pick('Opening the camera', '打开相机');
  String get openingGallery => pick('Opening the gallery', '打开相册');
  String get imageUnreadable => pick('This image cannot be read.', '这张图片无法读取。');
  String get imageNotChanged => pick('The image was not changed.', '没有更换图片。');
  String get readingImage => pick('Reading the image', '识别图片');
  String get gallery => pick('Gallery', '相册');
  String get camera => pick('Camera', '拍照');
  String get cropPhoto => pick('Crop', '裁剪');
  String get cropHint =>
      pick('Drag the frame to keep part of the photo.', '拖动边框，保留需要的部分。');
  String get useCrop => pick('Use this area', '使用选区');
  String get readAgain => pick('Read again', '重新识别');
  String get ready => pick('Ready', '就绪');
  String get p0Note => pick(
    'P0 check. This page only calls the OCR interface. It is not the translation page.',
    'P0 技术验证。这一页只调用 OCR 接口，不是正式翻译页。',
  );
  String get imageCannotBeShown =>
      pick('This image cannot be shown.', '这张图片无法显示。');
  String get recognizedText => pick('Recognized text', '识别文字');
  String get noTextInImage =>
      pick('No text was found in this image.', '这张图里没有识别到文字。');
  String get cameraPermissionDenied => pick(
    'Camera or photo library permission was not granted.',
    '没有获得使用相机或相册的权限。',
  );
  String get scriptUnsupported =>
      pick('This writing system cannot be read yet.', '这个文字体系还不能识别。');
  String get photoTranslationFailed =>
      pick('Photo translation did not finish.', '图片翻译没有完成。');
  String get modelOnDevice => pick('Model is on this device', '模型已在本机');

  String get checkingSpeechModel =>
      pick('Checking the speech model', '正在检查听写模型');
  String get speechNotReadyToTranscribe => pick(
    'The speech model is not ready. Download it before transcribing.',
    '听写模型还没有准备好。下载后才能识别。',
  );
  String get recording => pick('Recording', '正在录音');
  String get noSpeech => pick('No speech was heard.', '没有听到语音。');
  String get reachedRecordLimit =>
      pick('Reached the 30 second limit', '已录满 30 秒');
  String get recordingInterrupted =>
      pick('Recording was interrupted.', '录音被打断。');
  String get recordingInterruptedShort =>
      pick('Recording was interrupted', '录音被打断');
  String get recordingTooLong =>
      pick('The recording is too long.', '录音超过长度限制。');
  String get openingAudio => pick('Opening audio', '打开音频');
  String get transcribing => pick('Transcribing', '识别语音');
  String get record => pick('Record', '录音');
  String get chooseAudio => pick('Choose audio', '选择音频');
  String stopAfter(String seconds) => pick('Stop $seconds s', '停止 $seconds 秒');
  String get microphonePermissionDenied =>
      pick('Microphone permission was not granted.', '没有获得使用麦克风的权限。');
  String get asrLanguageUnsupported =>
      pick('This language cannot be transcribed yet.', '这个语言还不能听写。');
  String get audioUnreadable => pick('This audio cannot be read.', '这段音频无法读取。');
  String get transcriptionDidNotStart =>
      pick('Transcription did not start.', '听写没有启动。');
  String get speechTranslationFailed =>
      pick('Speech translation did not finish.', '语音翻译没有完成。');
}

UiLine uiFailure(AppFailure error, {UiLine? fallback}) {
  final detail = error.detail ?? '';
  if (detail.contains('没有网络')) return (text) => text.offlineNoDownload;
  if (detail.contains('下载中断')) return (text) => text.downloadInterrupted;
  if (detail.contains('听写模型无法校验')) {
    return (text) => text.speechVerifyFailed;
  }
  if (detail.contains('校验失败')) return (text) => text.verifyFailedKeptOld;
  if (detail.contains('无法解压')) {
    return (text) => text.extractFailedKeptDownload;
  }
  if (detail.contains('已暂停')) return (text) => text.downloadPaused;
  if (detail.contains('看图文件')) return (text) => text.visionFileNotReady;
  if (error.type == AppErrorType.cancelled) return (text) => text.canceled;
  return fallback ?? (text) => text.translationDidNotFinish;
}
