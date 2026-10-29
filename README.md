https://github.com/jtliaw/calm-player/blob/main/icons/ic_xxhdpi.png
# 静心音乐 · Calm Music

**中文** | [English](#english)

一个为睡前听音乐设计的安卓播放器：**没有广告**，息屏后台持续播放，内置 YouTube 搜索与下载。

## 功能

- 🎵 播放手机里所有音乐，支持 MP3、MP4、M4A、FLAC、WAV、OGG、AAC 等常见格式
- 🌙 后台持续播放：息屏、锁屏都不会中断，只有你按暂停才会停止
- ⏱️ 睡眠定时：15 到 120 分钟，时间到后慢慢淡出再停止
- 🔁 列表循环、单曲循环、随机播放，通知栏和锁屏均可控制
- 🔎 内置搜索：输入关键词，或粘贴 YouTube 视频、播放列表链接
- ✅ 勾选下载：点选多首一起下载，长按单独下载，已下载的显示绿色勾，不会重复下载
- 🔄 一键更新下载核心：YouTube 改版导致失败时，点一下即可更新，无需重装
- 🌐 中文系统显示中文，其他语言系统显示英文
- 🚫 无广告、无账号、无统计、不收集任何数据

## 安装

1. 在 Releases 或 Actions 页面下载 `app-release.apk`
2. 手机允许"安装未知来源应用"，然后安装
3. 首次打开时授权"所有文件访问"和通知权限

## 权限说明

| 权限 | 用途 |
|---|---|
| 所有文件访问 | 扫描手机里的音乐；把下载的歌曲保存到 `Music/YouTube` |
| 网络 | 搜索和下载 |
| 通知、前台服务 | 显示播放控制，保证后台持续播放 |

软件不上传你的任何文件或信息。

## 安全说明

本软件已在 VirusTotal 扫描，**61 个杀毒引擎均未检出威胁**。

- 扫描日期：`[填写日期]`
- 文件 SHA-256：`[填写校验码]`
- 扫描报告：`[粘贴 VirusTotal 链接]`

请注意：扫描结果只对应上面这一个文件。每次重新打包，文件校验码都会不同。你可以用 `sha256sum app-release.apk` 核对下载的文件是否一致。本项目代码完全公开，你也可以自行审查，或用自己的 GitHub 账号按源码重新打包。

## 使用声明

- 本软件仅供**个人学习和个人使用**，与 YouTube、Google 官方无关。
- 请只下载你有权下载的内容（自己的作品、知识共享授权的内容等）。下载受版权保护的内容、违反 YouTube 服务条款，由使用者自行承担责任。
- 软件按"现状"提供，作者不对使用后果负责。
- 请勿上传或分发下载得到的音乐文件。

## 使用的开源项目

[yt-dlp](https://github.com/yt-dlp/yt-dlp)、[youtubedl-android](https://github.com/yausername/youtubedl-android)、[FFmpeg](https://ffmpeg.org/)、[Flutter](https://flutter.dev/)、[just_audio](https://pub.dev/packages/just_audio)。

## 许可证

GPL-3.0（因为使用了 GPL-3.0 许可的 youtubedl-android）。

---

<a name="english"></a>
# Calm Music

An Android music player made for falling asleep to music: **no ads**, keeps playing in the background with the screen off, with built-in YouTube search and download.

## Features

- Plays all music on your phone: MP3, MP4, M4A, FLAC, WAV, OGG, AAC and more
- Uninterrupted background playback, stops only when you press pause
- Sleep timer (15 to 120 minutes) with a gentle fade-out
- Repeat all, repeat one, shuffle, with notification and lock-screen controls
- Built-in search, or paste a YouTube video or playlist link
- Tick songs to download, long-press to download one; downloaded songs show a green check and are never downloaded twice
- One-tap "Update core" when YouTube changes and downloads stop working
- Shows Chinese on Chinese systems, English on all other languages
- No ads, no account, no analytics, no data collection

## Install

1. Download `app-release.apk` from Releases or Actions
2. Allow "install unknown apps" on your phone, then install
3. On first launch, grant "All files access" and notification permission

## Permissions

| Permission | Why |
|---|---|
| All files access | Scan music on your phone; save downloads to `Music/YouTube` |
| Internet | Search and download |
| Notifications, foreground service | Playback controls and background playback |

The app does not upload any of your files or information.

## Security

This app was scanned on VirusTotal: **0 of 61 engines flagged it**.

- Scan date: `[fill in]`
- File SHA-256: `[fill in]`
- Report: `[paste VirusTotal link]`

The result applies only to that exact file. Every rebuild produces a different checksum; verify yours with `sha256sum app-release.apk`. The source code is public, so you can review it or build the APK yourself.

## Disclaimer

- For personal use only. Not affiliated with or endorsed by YouTube or Google.
- Only download content you have the right to download. You are responsible for complying with copyright law and YouTube's Terms of Service.
- Provided "as is", without warranty of any kind.
- Please do not upload or redistribute downloaded music.

## Built with

[yt-dlp](https://github.com/yt-dlp/yt-dlp), [youtubedl-android](https://github.com/yausername/youtubedl-android), [FFmpeg](https://ffmpeg.org/), [Flutter](https://flutter.dev/), [just_audio](https://pub.dev/packages/just_audio).

## License

GPL-3.0 (required because youtubedl-android is GPL-3.0 licensed).
