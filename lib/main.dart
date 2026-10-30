import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

List<String> parseArgs(String text) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;
  var has = false;
  for (final ch in text.runes.map(String.fromCharCode)) {
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        buf.write(ch);
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
      has = true;
    } else if (ch.trim().isEmpty) {
      if (has || buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
        has = false;
      }
    } else {
      buf.write(ch);
    }
  }
  if (has || buf.isNotEmpty) out.add(buf.toString());
  return out;
}

String folderName(String path) => path.split('/').last;
String relPath(String path) => path.replaceFirst('/storage/emulated/0/', '');

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

class _HomeState extends State<Home> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 3, vsync: this);
  final player = AudioPlayer();
  List<File> songs = [];
  List<File> queue = [];
  List<String> targets = [];
  String? openFolder; // null = 文件夹列表, '*' = 全部歌曲
  Set<String> pick = {};
  String dlDir = downloadDir;
  bool scanning = false;
  String? scanMsg;
  LoopMode loop = LoopMode.all;
  bool shuffle = false;

  Timer? sleepTimer, fadeTimer;
  DateTime? sleepEnd;

  // 发现 / 下载
  final urlCtl = TextEditingController();
  final argsCtl = TextEditingController();
  SharedPreferences? prefs;
  String extraArgs = '';
  List<Map<String, String>> links = [];
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
    _loadSettings();
    scan();
  }

  @override
  void dispose() {
    sleepTimer?.cancel();
    fadeTimer?.cancel();
    player.dispose();
    urlCtl.dispose();
    argsCtl.dispose();
    tabs.dispose();
    super.dispose();
  }

  // ---------- 设置 ----------
  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    prefs = p;
    extraArgs = p.getString('extraArgs') ?? '';
    argsCtl.text = extraArgs;
    try {
      final raw = p.getString('links');
      if (raw != null) {
        links = (jsonDecode(raw) as List)
            .map((e) => Map<String, String>.from(e as Map))
            .toList();
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _saveLinks() async {
    await prefs?.setString('links', jsonEncode(links));
  }

  void _snack(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _saveArgs() async {
    final text = argsCtl.text.trim();
    if (parseArgs(text).any((a) => a.startsWith('--exec'))) {
      _snack(t('出于安全，不允许使用 --exec', '--exec is not allowed (for safety)'));
      return;
    }
    extraArgs = text;
    await prefs?.setString('extraArgs', text);
    _snack(t('已保存', 'Saved'));
    if (mounted) setState(() {});
  }

  Future<void> _addLinkDialog([String prefill = '']) async {
    final nameCtl = TextEditingController();
    final urlC = TextEditingController(text: prefill);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('添加常用链接', 'Add saved link')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: nameCtl,
              decoration: InputDecoration(labelText: t('名称', 'Name'))),
          TextField(
              controller: urlC,
              decoration: InputDecoration(
                  labelText: t('链接或搜索词', 'Link or search words'))),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t('取消', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(t('保存', 'Save'))),
        ],
      ),
    );
    if (ok == true && urlC.text.trim().isNotEmpty) {
      final u = urlC.text.trim();
      links.add({
        'name': nameCtl.text.trim().isEmpty ? u : nameCtl.text.trim(),
        'url': u,
      });
      await _saveLinks();
      if (mounted) setState(() {});
    }
  }

  void _openLink(Map<String, String> l) {
    urlCtl.text = l['url'] ?? '';
    tabs.animateTo(1);
    loadList();
  }

  Widget _settingsTab() {
    final head = Theme.of(context).textTheme.titleMedium;
    const grey = TextStyle(color: Colors.grey, fontSize: 13);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(t('常用链接', 'Saved links'), style: head),
        const SizedBox(height: 4),
        Text(
          t('把常听的播放列表链接或搜索词存在这里，点一下就能载入。YouTube 地址变了，在这里换成新的即可。',
              'Save your favourite playlist links or search words here and open them with one tap. If a link changes, just replace it here.'),
          style: grey,
        ),
        for (final l in links)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link),
            title: Text(l['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(l['url'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _openLink(l),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                links.remove(l);
                await _saveLinks();
                if (mounted) setState(() {});
              },
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            onPressed: () => _addLinkDialog(),
            icon: const Icon(Icons.add),
            label: Text(t('添加链接', 'Add link'))),
        const Divider(height: 40),
        Text(t('额外下载参数（高级）', 'Extra download options (advanced)'), style: head),
        const SizedBox(height: 4),
        Text(
          t('YouTube 改版导致下载失败时，把错误信息发给 AI，问它“yt-dlp 要加什么参数”，再把答案贴在这里保存。会同时用于搜索和下载。',
              'If downloads break after a YouTube change, send the error to an AI, ask which yt-dlp options fix it, and paste the answer here. Used for both search and download.'),
          style: grey,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: argsCtl,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '--extractor-args youtube:player_client=android',
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton(onPressed: _saveArgs, child: Text(t('保存', 'Save'))),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              argsCtl.clear();
              await _saveArgs();
            },
            child: Text(t('恢复默认', 'Reset')),
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          t('上面灰色的只是示例格式，不一定适用于现在。只贴你信任的 AI 给的参数；出于安全，不支持 --exec。',
              'The grey text is only an example of the format and may not apply today. Only paste options from sources you trust; --exec is blocked for safety.'),
          style: grey,
        ),
      ],
    );
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
    await _refreshTargets();
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

  Future<void> _buildSource(int index, [List<File>? list]) async {
    final src = list ?? songs;
    if (src.isEmpty) return;
    queue = src;
    await player.setAudioSource(
      ConcatenatingAudioSource(
        children: [
          for (final f in src)
            AudioSource.file(f.path,
                tag: MediaItem(id: f.path, title: songTitle(f))),
        ],
      ),
      initialIndex: index,
      initialPosition: Duration.zero,
    );
  }

  Future<void> _playFrom(List<File> list, int i) async {
    await _buildSource(i, list);
    player.play();
  }

  // ---------- 文件夹 ----------
  Future<void> _refreshTargets() async {
    final list = <String>[downloadDir];
    try {
      final d = Directory(downloadDir);
      if (await d.exists()) {
        final subs = <String>[];
        await for (final e in d.list(followLinks: false)) {
          if (e is Directory && !folderName(e.path).startsWith('.')) {
            subs.add(e.path);
          }
        }
        subs.sort((a, b) =>
            folderName(a).toLowerCase().compareTo(folderName(b).toLowerCase()));
        list.addAll(subs);
      }
    } catch (_) {}
    targets = list;
  }

  Future<String?> _newFolderDialog() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('新建文件夹', 'New folder')),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: t('名称（例如：雨声）', 'Name (e.g. Rain)')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t('取消', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(t('创建', 'Create'))),
        ],
      ),
    );
    if (ok != true) return null;
    final name = ctl.text.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    if (name.isEmpty || name.startsWith('.')) return null;
    final path = '$downloadDir/$name';
    try {
      await Directory(path).create(recursive: true);
    } catch (_) {
      _snack(t('创建失败，请确认已授权“所有文件访问”', 'Could not create the folder. Check the file access permission.'));
      return null;
    }
    await _refreshTargets();
    if (mounted) setState(() {});
    return path;
  }

  Future<String?> _pickFolder() async {
    await _refreshTargets();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(t('选择文件夹', 'Choose folder')),
        children: [
          for (final p in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, p),
              child: Row(children: [
                const Icon(Icons.folder_outlined),
                const SizedBox(width: 12),
                Expanded(child: Text(p == downloadDir ? 'YouTube' : folderName(p))),
              ]),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final p = await _newFolderDialog();
              if (c.mounted) Navigator.pop(c, p);
            },
            child: Row(children: [
              const Icon(Icons.create_new_folder_outlined),
              const SizedBox(width: 12),
              Text(t('新建文件夹…', 'New folder…')),
            ]),
          ),
        ],
      ),
    );
  }

  Future<void> _moveSongs(List<File> files, String targetPath) async {
    var ok = 0;
    for (final f in files) {
      final dest = '$targetPath/${f.path.split('/').last}';
      if (dest == f.path) continue;
      try {
        if (await File(dest).exists()) continue;
        await f.rename(dest);
        ok++;
      } catch (_) {
        try {
          await f.copy(dest);
          await f.delete();
          ok++;
        } catch (_) {}
      }
    }
    pick = {};
    _snack(t('已移动 $ok 首', 'Moved $ok'));
    await scan();
  }

  Future<void> _moveDialog(List<File> list) async {
    final p = await _pickFolder();
    if (p == null) return;
    final files = list.where((f) => pick.contains(f.path)).toList();
    await _moveSongs(files, p);
  }

  bool _sameQueue(List<File> list) {
    if (queue.length != list.length) return false;
    for (var i = 0; i < list.length; i++) {
      if (queue[i].path != list[i].path) return false;
    }
    return true;
  }

  // 打开文件夹时，如果当前没有在播放，底部播放器自动切换到这个文件夹
  Future<void> _openFolder(String k) async {
    setState(() {
      openFolder = k;
      pick = {};
    });
    if (player.playing) return;
    final list =
        k == '*' ? songs : songs.where((f) => f.parent.path == k).toList();
    if (list.isEmpty || _sameQueue(list)) return;
    await _buildSource(0, list);
  }

  void _togglePick(File f) {
    setState(() {
      if (!pick.add(f.path)) pick.remove(f.path);
    });
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
      final out = await ytdl.invokeMethod<String>(
          'list', {'url': target, 'args': parseArgs(extraArgs)});
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
          'dir': dlDir,
          'archive': '$downloadDir/.archive.txt',
          'args': parseArgs(extraArgs),
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
    return Scaffold(
        appBar: AppBar(
          title: Text(t('静心音乐', 'Calm Music')),
          actions: [
            IconButton(
                onPressed: scan,
                icon: const Icon(Icons.refresh),
                tooltip: t('重新扫描', 'Rescan'))
          ],
          bottom: TabBar(controller: tabs, tabs: [
            Tab(text: t('播放', 'Play')),
            Tab(text: t('发现', 'Discover')),
            Tab(text: t('设置', 'Settings')),
          ]),
        ),
        body: TabBarView(
            controller: tabs,
            children: [_playTab(), _discoverTab(), _settingsTab()]),
        bottomNavigationBar: _bar(),
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
            FilledButton(
                onPressed: scan,
                child: Text(t('授权并扫描', 'Grant access & scan'))),
          ]),
        ),
      );
    }
    return openFolder == null ? _folderList() : _folderSongs();
  }

  Widget _folderList() {
    final m = <String, List<File>>{};
    for (final f in songs) {
      (m[f.parent.path] ??= []).add(f);
    }
    for (final p in targets) {
      if (p != downloadDir) m.putIfAbsent(p, () => []);
    }
    final keys = m.keys.toList()
      ..sort((a, b) =>
          folderName(a).toLowerCase().compareTo(folderName(b).toLowerCase()));
    final primary = Theme.of(context).colorScheme.primary;
    return ListView(children: [
      ListTile(
        leading: Icon(Icons.library_music, color: primary),
        title: Text(t('全部歌曲', 'All songs')),
        subtitle: Text(t('${songs.length} 首', '${songs.length} songs')),
        onTap: () => _openFolder('*'),
      ),
      for (final k in keys)
        ListTile(
          leading: Icon(Icons.folder, color: primary),
          title: Text(folderName(k), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              '${m[k]!.length} ${t('首', 'songs')} · ${relPath(k)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          onTap: () => _openFolder(k),
        ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: OutlinedButton.icon(
          onPressed: () async {
            await _newFolderDialog();
          },
          icon: const Icon(Icons.create_new_folder_outlined),
          label: Text(t('新建文件夹', 'New folder')),
        ),
      ),
    ]);
  }

  Widget _folderSongs() {
    final all = openFolder == '*';
    final list =
        all ? songs : songs.where((f) => f.parent.path == openFolder).toList();
    final title = all ? t('全部歌曲', 'All songs') : folderName(openFolder!);
    final selecting = pick.isNotEmpty;
    final primary = Theme.of(context).colorScheme.primary;
    return Column(children: [
      Row(children: [
        IconButton(
          icon: Icon(selecting ? Icons.close : Icons.arrow_back),
          onPressed: () => setState(() {
            if (selecting) {
              pick = {};
            } else {
              openFolder = null;
            }
          }),
        ),
        Expanded(
          child: Text(
            selecting ? t('已选 ${pick.length} 首', '${pick.length} selected') : title,
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (selecting)
          TextButton.icon(
            onPressed: () => _moveDialog(list),
            icon: const Icon(Icons.drive_file_move_outline),
            label: Text(t('移动到…', 'Move to…')),
          )
        else if (list.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.play_circle_outline),
            tooltip: t('循环播放这个文件夹', 'Play this folder on repeat'),
            onPressed: () => _playFrom(list, 0),
          ),
      ]),
      Expanded(
        child: list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    t('这个文件夹还没有歌曲。\n可以在“发现”页选择“保存到”这个文件夹，或把歌曲移动进来。',
                        'No songs here yet.\nChoose this folder under "Save to" in Discover, or move songs in.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              )
            : StreamBuilder<int?>(
                stream: player.currentIndexStream,
                builder: (c, snap) {
                  final cur = snap.data;
                  final playing =
                      (cur != null && cur < queue.length) ? queue[cur].path : null;
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (c, i) {
                      final f = list[i];
                      return ListTile(
                        leading: selecting
                            ? Checkbox(
                                value: pick.contains(f.path),
                                onChanged: (_) => _togglePick(f))
                            : Icon(
                                f.path == playing
                                    ? Icons.graphic_eq
                                    : Icons.music_note_outlined,
                                color: f.path == playing ? primary : null),
                        title: Text(songTitle(f),
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        onTap: () =>
                            selecting ? _togglePick(f) : _playFrom(list, i),
                        onLongPress: () => _togglePick(f),
                      );
                    },
                  );
                },
              ),
      ),
    ]);
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
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  icon: const Icon(Icons.bookmark_add_outlined),
                  tooltip: t('保存为常用链接', 'Save as saved link'),
                  onPressed: () {
                    final v = urlCtl.text.trim();
                    if (v.isNotEmpty) _addLinkDialog(v);
                  }),
              IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: (loading || busy) ? null : loadList),
            ]),
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
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            const Icon(Icons.folder_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t('保存到：', 'Save to: ') +
                    (dlDir == downloadDir ? 'YouTube' : folderName(dlDir)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      final p = await _pickFolder();
                      if (p != null && mounted) setState(() => dlDir = p);
                    },
              child: Text(t('更换', 'Change')),
            ),
          ]),
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
