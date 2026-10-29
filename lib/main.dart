import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
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

// 中文系统显示中文，其他语言一律显示英文
bool get isZh => ui.PlatformDispatcher.instance.locale.languageCode == 'zh';
String t(String zh, String en) => isZh ? zh : en;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.calm.player.audio',
    androidNotificationChannelName: t('静心音乐播放', 'Calm Music Playback'),
    androidNotificationOngoing: true,
  );
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: t('静心音乐', 'Calm Music'),
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

String fmtDur(int s) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

class Item {
  final String id, title, channel;
  final int? dur;
  Item(this.id, this.title, this.channel, this.dur);
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

  // 发现 / 下载
  final urlCtl = TextEditingController();
  List<Item> items = [];
  Set<String> selected = {};
  Set<String> owned = {};
  bool loading = false;
  bool busy = false;
  bool cancelled = false;
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
      setState(() => progress = (p.clamp(0, 100) / 100).toDouble());
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
        scanMsg = t('需要“所有文件访问”权限，才能读取手机里的音乐。', 'All files access is needed to read the music on your phone.');
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
    await loadOwned();
    if (!mounted) return;
    setState(() {
      songs = found;
      scanning = false;
      if (found.isEmpty) scanMsg = t('没有找到音乐文件。', 'No music files found.');
    });
  }

  Future<void> loadOwned() async {
    try {
      final f = File('$downloadDir/.archive.txt');
      if (await f.exists()) {
        final lines = await f.readAsLines();
        owned = lines
            .map((l) => l.trim().split(' ').last)
            .where((s) => s.isNotEmpty)
            .toSet();
      }
    } catch (_) {}
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
        final v = 1 - step / 40;
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
        title: Text(t('睡眠定时', 'Sleep timer')),
        children: [
          for (final m in [15, 30, 45, 60, 90, 120])
            SimpleDialogOption(
                onPressed: () => Navigator.pop(c, m),
                child: Text(t('$m 分钟后淡出并停止', 'Fade out and stop in $m min'))),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(c, 0),
              child: Text(t('关闭定时', 'Turn off timer'))),
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

  // ---------- 发现：搜索 / 载入链接 ----------
  Future<void> loadList() async {
    final q = urlCtl.text.trim();
    if (q.isEmpty || loading || busy) return;
    FocusScope.of(context).unfocus();
    final target = q.startsWith('http') ? q : 'ytsearch30:$q';
    setState(() {
      loading = true;
      error = null;
      status = t('读取中…', 'Loading…');
      items = [];
      selected = {};
    });
    try {
      await loadOwned();
      final out = await ytdl.invokeMethod<String>('list', {'url': target});
      final raw = out ?? '';
      final start = raw.indexOf('{');
      final j = jsonDecode(raw.substring(start < 0 ? 0 : start))
          as Map<String, dynamic>;
      final entries = (j['entries'] as List?) ?? [j];
      final list = <Item>[];
      for (final e in entries) {
        if (e is! Map) continue;
        final id = e['id']?.toString();
        if (id == null || id.length != 11) continue;
        list.add(Item(
          id,
          (e['title'] ?? id).toString(),
          (e['channel'] ?? e['uploader'] ?? '').toString(),
          (e['duration'] as num?)?.toInt(),
        ));
      }
      setState(() {
        items = list;
        status = list.isEmpty
            ? t('没有找到视频。', 'No videos found.')
            : t('找到 ${list.length} 个', 'Found ${list.length}');
      });
    } on PlatformException catch (e) {
      setState(() {
        status = t('读取失败', 'Failed to load');
        error = '${e.message ?? ''}\n${e.details ?? ''}';
      });
    } catch (e) {
      setState(() {
        status = t('读取失败', 'Failed to load');
        error = '$e';
      });
    }
    if (mounted) setState(() => loading = false);
  }

  // ---------- 下载 ----------
  Future<void> downloadItems(List<Item> list) async {
    if (busy || list.isEmpty) return;
    final st = await Permission.manageExternalStorage.request();
    if (!st.isGranted) {
      setState(() => error = t('需要“所有文件访问”权限才能保存音乐。', 'All files access is needed to save music.'));
      return;
    }
    setState(() {
      busy = true;
      cancelled = false;
      error = null;
    });
    var ok = 0, fail = 0;
    String? lastErr;
    for (var i = 0; i < list.length; i++) {
      final it = list[i];
      if (cancelled) break;
      setState(() {
        progress = 0;
        status = '(${i + 1}/${list.length}) ${it.title}';
      });
      try {
        await ytdl.invokeMethod('download', {
          'url': 'https://www.youtube.com/watch?v=${it.id}',
          'dir': downloadDir,
        });
        ok++;
        owned.add(it.id);
        selected.remove(it.id);
      } on PlatformException catch (e) {
        fail++;
        lastErr = '${e.message ?? ''}\n${e.details ?? ''}';
      }
    }
    await scan();
    if (!mounted) return;
    setState(() {
      busy = false;
      status = cancelled
          ? t('已取消（成功 $ok 首）', 'Cancelled ($ok done)')
          : t('完成：成功 $ok 首${fail > 0 ? '，失败 $fail 首' : ''}',
              'Done: $ok succeeded${fail > 0 ? ', $fail failed' : ''}');
      error = lastErr;
    });
  }

  Future<void> updateCore() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      status = t('正在更新下载核心…', 'Updating download core…');
    });
    try {
      final r = await ytdl.invokeMethod('update');
      setState(() => status = t('更新完成：$r', 'Updated: $r'));
    } on PlatformException catch (e) {
      setState(() => error = '${e.message ?? ''}\n${e.details ?? ''}');
    }
    if (mounted) setState(() => busy = false);
  }

  void cancelDownload() {
    cancelled = true;
    ytdl.invokeMethod('cancel');
  }

  void copyError() {
    final text = t(
        '我在安卓上用 yt-dlp (youtubedl-android) 下载 YouTube 时出错。\n输入内容：${urlCtl.text.trim()}\n错误信息：\n$error',
        'I got an error using yt-dlp (youtubedl-android) on Android to download from YouTube.\nInput: ${urlCtl.text.trim()}\nError:\n$error');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t('已复制，可以贴给 AI 询问', 'Copied. You can paste it to an AI for help.'))));
  }

  void _toggle(Item it) {
    setState(() {
      if (!selected.add(it.id)) selected.remove(it.id);
    });
  }

  void _longPress(Item it) {
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              title: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis)),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(t('下载这一首', 'Download this one')),
            onTap: () {
              Navigator.pop(c);
              downloadItems([it]);
            },
          ),
        ]),
      ),
    );
  }

  // ---------- 界面 ----------
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('静心音乐', 'Calm Music')),
          actions: [
            IconButton(
                onPressed: scan,
                icon: const Icon(Icons.refresh),
                tooltip: t('重新扫描', 'Rescan'))
          ],
          bottom: TabBar(tabs: [
            Tab(text: t('播放', 'Play')),
            Tab(text: t('发现', 'Discover'))
          ]),
        ),
        body: TabBarView(children: [_playTab(), _discoverTab()]),
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
            Text(scanMsg ?? t('没有找到音乐文件。', 'No music files found.'),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: scan, child: Text(t('授权并扫描', 'Grant access & scan'))),
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

  Widget _discoverTab() {
    final todo = items.where((e) => !owned.contains(e.id)).toList();
    final chosen = items.where((e) => selected.contains(e.id)).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: TextField(
          controller: urlCtl,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => loadList(),
          decoration: InputDecoration(
            labelText: t('搜索关键词，或粘贴 YouTube 链接', 'Search, or paste a YouTube link'),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: (loading || busy) ? null : loadList),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Expanded(
            child: Text(status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.grey)),
          ),
          TextButton.icon(
              onPressed: busy ? null : updateCore,
              icon: const Icon(Icons.system_update, size: 18),
              label: Text(t('更新下载核心', 'Update core'))),
        ]),
      ),
      if (busy)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(child: LinearProgressIndicator(value: progress)),
            IconButton(
                onPressed: cancelDownload,
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: t('取消', 'Cancel')),
          ]),
        ),
      if (error != null)
        Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(error!, maxLines: 4, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            FilledButton.tonalIcon(
                onPressed: copyError,
                icon: const Icon(Icons.copy),
                label: Text(t('复制错误信息（贴给 AI）', 'Copy error (paste to an AI)'))),
          ]),
        ),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        t(
                          '输入关键词搜索（例如：静心音乐 雨声），\n或粘贴播放列表链接。\n\n'
                          '勾选想要的歌曲，点下方“下载已选”。\n'
                          '长按某一首，可单独下载。\n'
                          '绿色勾 = 已经下载过。',
                          'Search by keyword (e.g. "calm music rain"),\nor paste a playlist link.\n\n'
                          'Tick the songs you want, then tap "Download selected".\n'
                          'Long-press a song to download just that one.\n'
                          'Green check = already downloaded.',
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (c, i) {
                      final it = items[i];
                      final have = owned.contains(it.id);
                      final sub = [
                        if (it.channel.isNotEmpty) it.channel,
                        if (it.dur != null) fmtDur(it.dur!),
                      ].join(' · ');
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(
                            'https://i.ytimg.com/vi/${it.id}/mqdefault.jpg',
                            width: 80,
                            height: 45,
                            fit: BoxFit.cover,
                            errorBuilder: (c, e, s) => const SizedBox(
                                width: 80,
                                height: 45,
                                child: Icon(Icons.music_note)),
                          ),
                        ),
                        title: Text(it.title,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(sub, maxLines: 1),
                        trailing: have
                            ? const Icon(Icons.check_circle, color: Colors.green)
                            : Checkbox(
                                value: selected.contains(it.id),
                                onChanged: (_) => _toggle(it)),
                        onTap: have ? null : () => _toggle(it),
                        onLongPress: have ? null : () => _longPress(it),
                      );
                    },
                  ),
      ),
      if (items.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(children: [
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                        if (selected.length == todo.length) {
                          selected = {};
                        } else {
                          selected = todo.map((e) => e.id).toSet();
                        }
                      }),
              child: Text(selected.length == todo.length && todo.isNotEmpty
                  ? t('取消全选', 'Deselect all')
                  : t('全选未下载', 'Select all new')),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: (busy || chosen.isEmpty)
                  ? null
                  : () => downloadItems(chosen),
              icon: const Icon(Icons.download),
              label: Text(t('下载已选 (${chosen.length})', 'Download selected (${chosen.length})')),
            ),
          ]),
        ),
    ]);
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
                return Text(tag is MediaItem ? tag.title : t('未播放', 'Not playing'),
                    maxLines: 1, overflow: TextOverflow.ellipsis);
              },
            ),
            if (sleepEnd != null)
              Text(
                  t('将在 ${two(sleepEnd!.hour)}:${two(sleepEnd!.minute)} 淡出停止',
                      'Fades out and stops at ${two(sleepEnd!.hour)}:${two(sleepEnd!.minute)}'),
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              IconButton(
                icon: Icon(
                    loop == LoopMode.one ? Icons.repeat_one : Icons.repeat),
                tooltip: loop == LoopMode.one
                    ? t('单曲循环', 'Repeat one')
                    : t('列表循环', 'Repeat all'),
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
                tooltip: t('睡眠定时', 'Sleep timer'),
                onPressed: _sleepDialog,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
