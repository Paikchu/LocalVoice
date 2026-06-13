# LocalVoice 隐私说明

LocalVoice 在本机完成录音、语音识别、文本整理和翻译。应用不包含遥测、广告或分析 SDK，也不会把录音、转写文本或用户画像上传到开发者服务器。

## 本地个性化学习

“本地个性化学习”默认关闭。关闭时，应用不会读取、提取或写入用户画像。

开启后，应用会从确认插入的最终文本中提取：

- 常用术语及其写法
- 常见内容领域
- 邮箱、电话号码和地址
- 本地整理所需的汇总统计

画像保存在：

```text
~/Library/Application Support/LocalVoice/profile.json
```

这些内容只用于后续本地文本整理。

## 模型下载

首次下载本地模型时，应用会连接 Hugging Face。模型固定为：

```text
mlx-community/Qwen3-4B-Instruct-2507-4bit
50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b
```

固定 commit SHA 可防止上游 `main` 分支变化后静默替换模型内容。下载完成后，本地整理和翻译不需要联网。

## 清除数据

菜单栏中的“清除全部本地数据”会删除：

- 用户画像及其临时、损坏备份文件
- 已下载的本地模型
- 邮件签名
- 自定义快捷键和个性化开关

麦克风、语音识别和辅助功能授权由 macOS 管理。请在“系统设置 → 隐私与安全性”中撤销这些权限。

## 联系

隐私问题请通过 GitHub Issues 提交：

https://github.com/Paikchu/LocalVoice/issues
