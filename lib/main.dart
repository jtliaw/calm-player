import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';

const ytdl = MethodChannel('calm/ytdl');
const audioExts = {
  '.mp3', '.m4a', '.mp4', '.aac', '.flac', '.wav', '.ogg', '.opus',
  '.mkv', '.webm', '.3gp', '.amr', '.m4b'
};
const downloadDir = '/storage/emulated/0/Music/YouTube';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.calm.player.audio',
    androidNotificationChannelName: '静心音乐播放',
    androidNotificationOngoing: true,
  );
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '静心音乐',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo, brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: const Home(),
      );
}

String songTitle(File f) {
  final n = f.path.split('/').last;
  final i = n.lastIndexOf('.');
  return i > 0 ? n.substring(0, i) : n;
}

String extOf(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i).toLowerCase();
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final player = AudioPlayer();
  List<File> songs = [];
  bool scanning = false;
  String? scanMsg;
  LoopMode loop = LoopMode.all;
  bool shuffle = false;

  Timer? sleepTimer, fadeTimer;
  DateTime? sleepEnd;

  final urlCtl = TextEditingController();
  bool busy = false;
  double progress = 0;
  String status = '';
  String? error;

  @override
  void initState() {
    super.initState();
    ytdl.setMethodCallHandler(_onNative);
    player.setLoopMode(loop);
    scan();
  }

  @override
  void dispose() {
    sleepTimer?.cancel();
    fadeTimer?.cancel();
    player.dispose();
    urlCtl.dispose();
    super.dispose();
  }

  Future<dynamic> _onNative(MethodCall c) async {
    if (c.method == 'progress' && mounted) {
      final m = Map<String, dynamic>.from(c.arguments as Map);
      final p = (m['percent'] as num).toDouble();
      final line = (m['line'] as String).trim();
      setState(() {
        progress = (p.clamp(0, 100) / 100).toDouble();
        if (line.isNotEmpty) status = line;
      });
    }
  }

  // ---------- 扫描手机里的音乐 ----------
  Future<void> scan() async {
    setState(() {
      scanning = true;
      scanMsg = null;
    });
    final st = await Permission.manageExternalStorage.request();
    await Permission.notification.request();
    if (!st.isGranted) {
      setState(() {
        scanning = false;
        scanMsg = '需要“所有文件访问”权限，才能读取手机里的音乐。';
      });
      return;
    }
    final found = <File>[];
    Future<void> walk(Directory d, int depth) async {
      try {
        await for (final e in d.list(followLinks: false)) {
          final name = e.path.split('/').last;
          if (name.startsWith('.')) continue;
          if (e is Directory) {
            if (e.path == '/storage/emulated/0/Android' || depth > 6) continue;
            await walk(e, depth + 1);
          } else if (e is File && audioExts.contains(extOf(name))) {
            found.add(e);
          }
        }
      } catch (_) {}
    }

    await walk(Directory('/storage/emulated/0'), 0);
    found.sort((a, b) => a.path.compareTo(b.path));
    if (!mounted) return;
    setState(() {
      songs = found;
      scanning = false;
      if (found.isEmpty) scanMsg = '没有找到音乐文件。';
    });
  }

  Future<void> _buildSource(int index) async {
    if (songs.isEmpty) return;
    await player.setAudioSource(
      ConcatenatingAudioSource(
        children: [
          for (final f in songs)
            AudioSource.file(f.path,
                tag: MediaItem(id: f.path, title: songTitle(f))),
        ],
      ),
      initialIndex: index,
      initialPosition: Duration.zero,
    );
  }

  Future<void> _playIndex(int i) async {
    await _buildSource(i);
    player.play();
  }

  // ---------- 睡眠定时 ----------
  void _cancelSleep() {
    sleepTimer?.cancel();
    fadeTimer?.cancel();
    player.setVolume(1);
    setState(() => sleepEnd = null);
  }

  void _startSleep(int minutes) {
    _cancelSleep();
    setState(() => sleepEnd = DateTime.now().add(Duration(minutes: minutes)));
    sleepTimer = Timer(Duration(minutes: minutes), () {
      var step = 0;
      fadeTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
        step++;
        final v = 1 - step / 40; // 约 20 秒淡出
        if (v <= 0) {
          t.cancel();
          player.pause();
          player.setVolume(1);
          if (mounted) setState(() => sleepEnd = null);
        } else {
          player.setVolume(v);
        }
      });
    });
  }

  Future<void> _sleepDialog() async {
    final v = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('睡眠定时'),
        children: [
          for (final m in [15, 30, 45, 60, 90, 120])
            SimpleDialogOption(
                onPressed: () => Navigator.pop(c, m),
                child: Text('$m 分钟后淡出并停止')),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(c, 0),
              child: const Text('关闭定时')),
        ],
      ),
    );
    if (v == null) return;
    if (v == 0) {
      _cancelSleep();
    } else {
      _startSleep(v);
    }
  }

  // ---------- 下载 ----------
  Future<void> download() async {
    final url = urlCtl.text.trim();
    if (url.isEmpty) return;
    final st = await Permission.manageExternalStorage.request();
    if (!st.isGranted) {
      setState(() => error = '需要“所有文件访问”权限才能保存音乐。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      progress = 0;
      status = '开始下载…';
    });
    try {
      await ytdl.invokeMethod('download', {'url': url, 'dir': downloadDir});
      setState(() => status = '下载完成，已保存到 Music/YouTube');
      await scan();
    } on PlatformException catch (e) {
      setState(() => error = '${e.message ?? ''}\n${e.details ?? ''}');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> updateCore() async {
    setState(() {
      busy = true;
      error = null;
      status = '正在更新下载核心…';
    });
    try {
      final r = await ytdl.invokeMethod('update');
      setState(() => status = '更新完成：$r');
    } on PlatformException catch (e) {
      setState(() => error = '${e.message ?? ''}\n${e.details ?? ''}');
    }
    if (mounted) setState(() => busy = false);
  }

  void copyError() {
    final text = '我在安卓上用 yt-dlp (youtubedl-android) 下载 YouTube 播放列表时出错。\n'
        '链接：${urlCtl.text.trim()}\n错误信息：\n$error';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制，可以贴给 AI 询问')));
  }

  // ---------- 界面 ----------
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('静心音乐'),
          actions: [
            IconButton(
                onPressed: scan,
                icon: const Icon(Icons.refresh),
                tooltip: '重新扫描')
          ],
          bottom: const TabBar(
              tabs: [Tab(text: '播放'), Tab(text: '下载')]),
        ),
        body: TabBarView(children: [_playTab(), _downloadTab()]),
        bottomNavigationBar: _bar(),
      ),
    );
  }

  Widget _playTab() {
    if (scanning) return const Center(child: CircularProgressIndicator());
    if (songs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(scanMsg ?? '没有找到音乐文件。', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: scan, child: const Text('授权并扫描')),
          ]),
        ),
      );
    }
    return StreamBuilder<int?>(
      stream: player.currentIndexStream,
      builder: (c, snap) {
        final cur = snap.data;
        return ListView.builder(
          itemCount: songs.length,
          itemBuilder: (c, i) => ListTile(
            leading: Icon(
                i == cur ? Icons.graphic_eq : Icons.music_note_outlined,
                color: i == cur ? Theme.of(context).colorScheme.primary : null),
            title: Text(songTitle(songs[i]),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => _playIndex(i),
          ),
        );
      },
    );
  }

  Widget _downloadTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: urlCtl,
          decoration: const InputDecoration(
            labelText: '粘贴 YouTube 播放列表或视频链接',
            border: OutlineInputBorder(),
          ),
          minLines: 1,
          maxLines: 3,
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: FilledButton.icon(
                  onPressed: busy ? null : download,
                  icon: const Icon(Icons.download),
                  label: const Text('下载'))),
          const SizedBox(width: 8),
          OutlinedButton.icon(
              onPressed: busy ? null : updateCore,
              icon: const Icon(Icons.system_update),
              label: const Text('更新下载核心')),
        ]),
        if (busy)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Expanded(child: LinearProgressIndicator(value: progress)),
              IconButton(
                  onPressed: () => ytdl.invokeMethod('cancel'),
                  icon: const Icon(Icons.stop_circle_outlined),
                  tooltip: '取消'),
            ]),
          ),
        const SizedBox(height: 12),
        if (status.isNotEmpty) Text(status, maxLines: 4),
        if (error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('下载失败', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(error!, maxLines: 8, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                  onPressed: copyError,
                  icon: const Icon(Icons.copy),
                  label: const Text('复制错误信息（贴给 AI）')),
            ]),
          ),
        ],
        const SizedBox(height: 20),
        const Text(
          '提示：下载失败时，先点“更新下载核心”再重试（YouTube 改动后需要更新）。'
          '仍然失败，就复制错误信息发给 AI 询问。\n'
          '已下载的歌曲不会重复下载，保存在 Music/YouTube。',
          style: TextStyle(color: Colors.grey),
        ),
      ],
    );
  }

  Widget _bar() {
    String two(int n) => n.toString().padLeft(2, '0');
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            StreamBuilder<SequenceState?>(
              stream: player.sequenceStateStream,
              builder: (c, s) {
                final tag = s.data?.currentSource?.tag;
                return Text(tag is MediaItem ? tag.title : '未播放',
                    maxLines: 1, overflow: TextOverflow.ellipsis);
              },
            ),
            if (sleepEnd != null)
              Text('将在 ${two(sleepEnd!.hour)}:${two(sleepEnd!.minute)} 淡出停止',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              IconButton(
                icon: Icon(
                    loop == LoopMode.one ? Icons.repeat_one : Icons.repeat),
                tooltip: loop == LoopMode.one ? '单曲循环' : '列表循环',
                onPressed: () {
                  setState(() => loop =
                      loop == LoopMode.all ? LoopMode.one : LoopMode.all);
                  player.setLoopMode(loop);
                },
              ),
              IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: player.seekToPrevious),
              StreamBuilder<PlayerState>(
                stream: player.playerStateStream,
                builder: (c, s) {
                  final playing = s.data?.playing ?? false;
                  return IconButton(
                    iconSize: 48,
                    icon: Icon(
                        playing ? Icons.pause_circle : Icons.play_circle),
                    onPressed: () async {
                      if (playing) {
                        player.pause();
                      } else {
                        if (player.audioSource == null) await _buildSource(0);
                        player.play();
                      }
                    },
                  );
                },
              ),
              IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: player.seekToNext),
              IconButton(
                icon: Icon(Icons.shuffle,
                    color: shuffle ? Theme.of(context).colorScheme.primary : null),
                onPressed: () {
                  setState(() => shuffle = !shuffle);
                  player.setShuffleModeEnabled(shuffle);
                },
              ),
              IconButton(
                icon: Icon(Icons.bedtime,
                    color: sleepEnd != null
                        ? Theme.of(context).colorScheme.primary
                        : null),
                tooltip: '睡眠定时',
                onPressed: _sleepDialog,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
