# P0 冒烟样本

这些句子只用于引擎是否真正跑通。它们不是 A02–A04 的正式质量集。

| 文件 | 内容 | 用途 |
| --- | --- | --- |
| `zh_clear.png` | 今天下午三点不见，不是五点。 | 中文 OCR，清晰白底 |
| `en_clear.png` | The train does not leave at 15:00. | 拉丁文 OCR，清晰白底 |
| `zh.wav` | 与中文图片同一句。Tingting，16 kHz，单声道 | 中文 ASR。不是英文专用权重的测试 |
| `en.wav` | 与英文图片同一句。Samantha，16 kHz，单声道 | 英文 ASR |
| `silence.wav` | 1 秒全零，16 kHz，单声道 | 静音不应生成正文 |

图片由 macOS Songti SC 渲染，实际像素 2160×720。正式图片集仍须另备倾斜、低光、菜单和多段样本。
