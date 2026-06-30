import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:provider/provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:orientation/orientation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ============================================================
// 1. MODEL
// ============================================================
class VideoItem {
  final String path;
  final String name;
  final int size;
  String? thumbnail;
  Duration? duration;
  Duration? lastPosition; // untuk resume

  VideoItem({
    required this.path,
    required this.name,
    required this.size,
    this.thumbnail,
    this.duration,
    this.lastPosition,
  });
}

// ============================================================
// 2. PROVIDER
// ============================================================
class PlaylistProvider extends ChangeNotifier {
  List<VideoItem> _playlist = [];
  int _currentIndex = -1;
  bool _shuffle = false;
  bool _repeat = false;
  String _searchQuery = '';
  bool _isGridView = true;
  bool _isScreenLocked = false;
  String _aspectRatio = '16:9'; // '16:9', '4:3', 'fit', 'crop', 'stretch'
  double _playbackSpeed = 1.0;
  Duration? _sleepTimerDuration;
  Timer? _sleepTimer;

  List<VideoItem> get playlist => _playlist;
  int get currentIndex => _currentIndex;
  bool get shuffle => _shuffle;
  bool get repeat => _repeat;
  String get searchQuery => _searchQuery;
  bool get isGridView => _isGridView;
  bool get isScreenLocked => _isScreenLocked;
  String get aspectRatio => _aspectRatio;
  double get playbackSpeed => _playbackSpeed;
  Duration? get sleepTimerDuration => _sleepTimerDuration;

  List<VideoItem> get filteredPlaylist {
    if (_searchQuery.isEmpty) return _playlist;
    return _playlist
        .where((v) => v.name.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  void addVideos(List<VideoItem> videos) {
    _playlist.addAll(videos);
    if (_currentIndex == -1 && _playlist.isNotEmpty) {
      _currentIndex = 0;
    }
    notifyListeners();
  }

  void removeVideo(int index) {
    if (index < 0 || index >= _playlist.length) return;
    _playlist.removeAt(index);
    if (_currentIndex == index) {
      _currentIndex = -1;
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
    notifyListeners();
  }

  void clearAll() {
    _playlist.clear();
    _currentIndex = -1;
    notifyListeners();
  }

  void setCurrentIndex(int index) {
    if (index >= 0 && index < _playlist.length) {
      _currentIndex = index;
      notifyListeners();
    }
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    notifyListeners();
  }

  void toggleRepeat() {
    _repeat = !_repeat;
    notifyListeners();
  }

  void toggleViewMode() {
    _isGridView = !_isGridView;
    notifyListeners();
  }

  void toggleScreenLock() {
    _isScreenLocked = !_isScreenLocked;
    if (_isScreenLocked) {
      OrientationPlugin.forceOrientation(
        DeviceOrientation.landscapeLeft, 
        callback: () {}
      );
    } else {
      OrientationPlugin.unforceOrientation();
    }
    notifyListeners();
  }

  void setAspectRatio(String ratio) {
    _aspectRatio = ratio;
    notifyListeners();
  }

  void setPlaybackSpeed(double speed) {
    _playbackSpeed = speed;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void updateLastPosition(int index, Duration position) {
    if (index >= 0 && index < _playlist.length) {
      _playlist[index].lastPosition = position;
      _saveResumePosition(_playlist[index].path, position);
      notifyListeners();
    }
  }

  // Sleep Timer
  void startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTimerDuration = duration;
    _sleepTimer = Timer(duration, () {
      _sleepTimerDuration = null;
      notifyListeners();
      // Pause video & show notification (dilakukan di HomeScreen)
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerDuration = null;
    notifyListeners();
  }

  int? getNextIndex() {
    if (_playlist.isEmpty) return null;
    if (_shuffle) {
      final filtered = filteredPlaylist;
      if (filtered.isEmpty) return null;
      final random = filtered[DateTime.now().millisecondsSinceEpoch % filtered.length];
      return _playlist.indexOf(random);
    } else {
      int next = _currentIndex + 1;
      if (next >= _playlist.length) {
        if (_repeat) return 0;
        return null;
      }
      return next;
    }
  }

  int? getPrevIndex() {
    if (_playlist.isEmpty) return null;
    int prev = _currentIndex - 1;
    if (prev < 0) {
      if (_repeat) return _playlist.length - 1;
      return null;
    }
    return prev;
  }

  // ===== RESUME POSITION (SharedPreferences) =====
  Future<void> _saveResumePosition(String path, Duration pos) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('resume_${path.hashCode}', pos.inSeconds);
  }

  Future<Duration?> getResumePosition(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('resume_${path.hashCode}');
    if (seconds != null && seconds > 5) {
      return Duration(seconds: seconds);
    }
    return null;
  }
}

// ============================================================
// 3. SUBTITLE PARSER
// ============================================================
class SubtitleParser {
  static List<ChewieSubtitle> parseSrt(String content) {
    List<ChewieSubtitle> subtitles = [];
    final blocks = content.trim().split(/\r?\n\r?\n/);
    for (var block in blocks) {
      final lines = block.split(/\r?\n/);
      if (lines.length < 3) continue;
      final timeLine = lines[1];
      final textLines = lines.sublist(2);
      final timeParts = timeLine.split(' --> ');
      if (timeParts.length != 2) continue;
      try {
        final start = _parseTime(timeParts[0]);
        final end = _parseTime(timeParts[1]);
        subtitles.add(ChewieSubtitle(
          start: start,
          end: end,
          text: textLines.join('\n'),
        ));
      } catch (_) {}
    }
    return subtitles;
  }

  static Duration _parseTime(String time) {
    time = time.replaceAll(',', '.');
    final parts = time.split(':');
    if (parts.length != 3) return Duration.zero;
    final h = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final secParts = parts[2].split('.');
    final s = int.parse(secParts[0]);
    final ms = int.parse(secParts.length > 1 ? secParts[1].padRight(3, '0') : '0');
    return Duration(hours: h, minutes: m, seconds: s, milliseconds: ms);
  }
}

// ============================================================
// 4. MAIN & APP
// ============================================================
void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlaylistProvider(),
      child: MaterialApp(
        title: 'TubePro MX',
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.black,
          primaryColor: Colors.red,
          appBarTheme: AppBarTheme(backgroundColor: Colors.grey[900]),
        ),
        home: HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

// ============================================================
// 5. HOME SCREEN (Versi MX Player)
// ============================================================
class HomeScreen extends StatefulWidget {
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  ChewieController? _chewieController;
  String? _subtitleFilePath;
  bool _isPlayerReady = false;
  bool _showOverlayControls = true;
  Timer? _hideOverlayTimer;
  double _currentBrightness = 0.5;
  double _currentVolume = 1.0;
  bool _isSleepTimerTriggered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBrightness();
    WakelockPlus.enable(); // layar tetap menyala
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _chewieController?.dispose();
    _hideOverlayTimer?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _loadBrightness() async {
    try {
      final brightness = await ScreenBrightness().current;
      setState(() => _currentBrightness = brightness);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Save current position when app goes background
      final provider = Provider.of<PlaylistProvider>(context, listen: false);
      if (provider.currentIndex != -1 && _controller != null && _controller!.value.isInitialized) {
        provider.updateLastPosition(provider.currentIndex, _controller!.value.position);
      }
    }
  }

  // ========== PLAYER INIT ==========
  Future<void> _initPlayer(String path, {String? subtitlePath, bool resume = true}) async {
    try {
      final oldController = _controller;
      final oldChewie = _chewieController;
      _controller = null;
      _chewieController = null;
      await oldController?.dispose();
      await oldChewie?.dispose();

      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      _controller = controller;

      // Resume position
      final provider = Provider.of<PlaylistProvider>(context, listen: false);
      Duration? startPos;
      if (resume) {
        startPos = await provider.getResumePosition(path);
        // juga cek dari provider
        final idx = provider.playlist.indexWhere((v) => v.path == path);
        if (idx != -1 && provider.playlist[idx].lastPosition != null) {
          startPos = provider.playlist[idx].lastPosition;
        }
      }
      if (startPos != null && startPos.inSeconds > 5 && startPos < controller.value.duration) {
        await controller.seekTo(startPos);
      }

      // Subtitle
      List<ChewieSubtitle> subs = [];
      if (subtitlePath != null) {
        final file = File(subtitlePath);
        if (await file.exists()) {
          final content = await file.readAsString();
          subs = SubtitleParser.parseSrt(content);
        }
      }

      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        looping: false,
        showControls: false, // kita bikin custom overlay
        materialProgressColors: ChewieProgressColors(
          playedColor: Colors.red,
          handleColor: Colors.red,
          backgroundColor: Colors.grey,
        ),
        subtitles: subs.isNotEmpty ? subs : null,
        subtitleStyle: TextStyle(
          fontSize: 20,
          color: Colors.white,
          background: Paint()..color = Colors.black54,
        ),
        allowFullScreen: true,
        allowMixing: true,
        deviceOrientationsOnFullScreen: [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        systemOverlayAfterFullScreen: SystemUiOverlayStyle.dark,
        additionalOptions: (context) {
          return _buildAdditionalOptions(context);
        },
      );

      setState(() {
        _chewieController = chewie;
        _isPlayerReady = true;
        _showOverlayControls = true;
        _isSleepTimerTriggered = false;
      });
      _startHideOverlayTimer();

      // Listen for completed
      chewie.videoPlayerController.addListener(() {
        if (chewie.videoPlayerController.value.isCompleted) {
          _playNext();
        }
      });

      // Update last position periodically
      Timer.periodic(Duration(seconds: 5), (timer) {
        if (mounted && _controller != null && _controller!.value.isInitialized) {
          final idx = provider.currentIndex;
          if (idx != -1) {
            provider.updateLastPosition(idx, _controller!.value.position);
          }
        }
      });

      // Set playback speed
      controller.setPlaybackSpeed(provider.playbackSpeed);

    } catch (e) {
      print("Error init player: $e");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal memutar video: $e')));
    }
  }

  // ========== OVERLAY CONTROLS ==========
  void _startHideOverlayTimer() {
    _hideOverlayTimer?.cancel();
    _hideOverlayTimer = Timer(Duration(seconds: 4), () {
      if (mounted) setState(() => _showOverlayControls = false);
    });
  }

  void _toggleOverlay() {
    setState(() => _showOverlayControls = !_showOverlayControls);
    if (_showOverlayControls) _startHideOverlayTimer();
  }

  // ========== GESTURE HANDLING ==========
  void _onTapLeft() {
    if (_controller != null && _controller!.value.isInitialized) {
      final newPos = _controller!.value.position - Duration(seconds: 10);
      if (newPos < Duration.zero) {
        _controller!.seekTo(Duration.zero);
      } else {
        _controller!.seekTo(newPos);
      }
      _showOverlayControls = true;
      _startHideOverlayTimer();
    }
  }

  void _onTapRight() {
    if (_controller != null && _controller!.value.isInitialized) {
      final newPos = _controller!.value.position + Duration(seconds: 10);
      if (newPos > _controller!.value.duration) {
        _controller!.seekTo(_controller!.value.duration);
      } else {
        _controller!.seekTo(newPos);
      }
      _showOverlayControls = true;
      _startHideOverlayTimer();
    }
  }

  void _onDoubleTap() {
    if (_controller != null) {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
      } else {
        _controller!.play();
      }
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, bool isLeftSide) {
    final dy = details.delta.dy;
    if (isLeftSide) {
      // Brightness (kiri)
      double newBright = _currentBrightness - (dy / 500);
      newBright = newBright.clamp(0.0, 1.0);
      _currentBrightness = newBright;
      ScreenBrightness().setScreenBrightness(newBright);
      setState(() {});
    } else {
      // Volume (kanan)
      double newVol = _currentVolume - (dy / 500);
      newVol = newVol.clamp(0.0, 1.0);
      _currentVolume = newVol;
      if (_controller != null) {
        _controller!.setVolume(newVol);
      }
      setState(() {});
    }
  }

  // ========== PLAY NAVIGATION ==========
  void _playVideo(int index, {String? subtitlePath, bool resume = true}) {
    final provider = Provider.of<PlaylistProvider>(context, listen: false);
    if (index < 0 || index >= provider.playlist.length) return;
    provider.setCurrentIndex(index);
    final item = provider.playlist[index];
    _initPlayer(item.path, subtitlePath: subtitlePath, resume: resume);
  }

  void _playNext() {
    final provider = Provider.of<PlaylistProvider>(context, listen: false);
    final next = provider.getNextIndex();
    if (next != null) {
      _playVideo(next);
    } else {
      setState(() {
        _isPlayerReady = false;
        _chewieController?.pause();
      });
    }
  }

  void _playPrev() {
    final provider = Provider.of<PlaylistProvider>(context, listen: false);
    final prev = provider.getPrevIndex();
    if (prev != null) _playVideo(prev);
  }

  // ========== SLEEP TIMER ==========
  void _showSleepTimerDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Sleep Timer', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _sleepTimerButton(Duration(minutes: 15), '15m'),
                _sleepTimerButton(Duration(minutes: 30), '30m'),
                _sleepTimerButton(Duration(minutes: 60), '60m'),
                _sleepTimerButton(null, 'Off'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sleepTimerButton(Duration? duration, String label) {
    final provider = Provider.of<PlaylistProvider>(context);
    final isActive = duration != null && provider.sleepTimerDuration == duration;
    return ElevatedButton(
      onPressed: () {
        final p = Provider.of<PlaylistProvider>(context, listen: false);
        if (duration == null) {
          p.cancelSleepTimer();
          Navigator.pop(context);
          return;
        }
        p.startSleepTimer(duration);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sleep timer: $label'), duration: Duration(seconds: 2)),
        );
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: isActive ? Colors.red : Colors.grey[800],
        foregroundColor: Colors.white,
      ),
      child: Text(label),
    );
  }

  // ========== ASPECT RATIO ==========
  Widget _buildAdditionalOptions(BuildContext context) {
    final provider = Provider.of<PlaylistProvider>(context);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _aspectButton('16:9'),
            _aspectButton('4:3'),
            _aspectButton('fit'),
            _aspectButton('crop'),
            _aspectButton('stretch'),
          ],
        ),
        SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _speedButton(0.5),
            _speedButton(0.75),
            _speedButton(1.0),
            _speedButton(1.25),
            _speedButton(1.5),
            _speedButton(2.0),
          ],
        ),
      ],
    );
  }

  Widget _aspectButton(String ratio) {
    final provider = Provider.of<PlaylistProvider>(context);
    final isActive = provider.aspectRatio == ratio;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(ratio, style: TextStyle(fontSize: 12)),
        selected: isActive,
        onSelected: (_) {
          provider.setAspectRatio(ratio);
          // Update chewie controller aspect ratio
          if (_chewieController != null) {
            // Chewie doesn't have direct setter, we need to rebuild
            // For simplicity, just rebuild the player
            final currentPath = provider.playlist[provider.currentIndex].path;
            _initPlayer(currentPath, subtitlePath: _subtitleFilePath);
          }
        },
        selectedColor: Colors.red,
        backgroundColor: Colors.grey[800],
        labelStyle: TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }

  Widget _speedButton(double speed) {
    final provider = Provider.of<PlaylistProvider>(context);
    final isActive = provider.playbackSpeed == speed;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text('${speed}x', style: TextStyle(fontSize: 12)),
        selected: isActive,
        onSelected: (_) {
          provider.setPlaybackSpeed(speed);
          if (_controller != null) {
            _controller!.setPlaybackSpeed(speed);
          }
        },
        selectedColor: Colors.red,
        backgroundColor: Colors.grey[800],
        labelStyle: TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }

  // ========== FILE PICKERS ==========
  Future<void> _pickFolder() async {
    final status = await Permission.storage.request();
    if (!status.isGranted && !status.isPermanentlyDenied) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Izin storage ditolak')));
      return;
    }

    String? selectedPath = await FilePicker.platform.getDirectoryPath();
    if (selectedPath == null) return;

    final dir = Directory(selectedPath);
    final List<FileSystemEntity> entities = await dir.list(recursive: true).toList();
    final List<VideoItem> videoItems = [];
    final extensions = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp'];

    for (var entity in entities) {
      if (entity is File) {
        final name = entity.path.split('/').last;
        final ext = entity.path.split('.').last.toLowerCase();
        if (extensions.contains('.$ext') || extensions.contains(ext)) {
          final size = await entity.length();
          final item = VideoItem(
            path: entity.path,
            name: name,
            size: size,
          );
          // Load resume position
          final provider = Provider.of<PlaylistProvider>(context, listen: false);
          final pos = await provider.getResumePosition(entity.path);
          item.lastPosition = pos;
          videoItems.add(item);
        }
      }
    }

    if (videoItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Tidak ada video di folder ini')));
      return;
    }

    final provider = Provider.of<PlaylistProvider>(context, listen: false);
    provider.addVideos(videoItems);

    // Generate thumbnails
    for (var item in videoItems) {
      try {
        final thumb = await VideoThumbnail.thumbnailFile(
          video: item.path,
          thumbnailPath: (await getTemporaryDirectory()).path,
          imageFormat: ImageFormat.JPEG,
          maxHeight: 90,
          maxWidth: 160,
          quality: 70,
        );
        if (thumb != null) {
          item.thumbnail = thumb;
          provider.notifyListeners();
        }
      } catch (_) {}
    }

    if (provider.playlist.isNotEmpty && provider.currentIndex == -1) {
      _playVideo(0, resume: true);
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${videoItems.length} video ditambahkan')));
  }

  Future<void> _pickFiles() async {
    final status = await Permission.storage.request();
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Izin storage ditolak')));
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.video,
    );
    if (result == null || result.files.isEmpty) return;

    final List<VideoItem> videoItems = [];
    final provider = Provider.of<PlaylistProvider>(context, listen: false);
    for (var file in result.files) {
      final item = VideoItem(
        path: file.path!,
        name: file.name,
        size: file.size,
      );
      final pos = await provider.getResumePosition(file.path!);
      item.lastPosition = pos;
      videoItems.add(item);
    }

    provider.addVideos(videoItems);

    for (var item in videoItems) {
      try {
        final thumb = await VideoThumbnail.thumbnailFile(
          video: item.path,
          thumbnailPath: (await getTemporaryDirectory()).path,
          imageFormat: ImageFormat.JPEG,
          maxHeight: 90,
          maxWidth: 160,
          quality: 70,
        );
        if (thumb != null) {
          item.thumbnail = thumb;
          provider.notifyListeners();
        }
      } catch (_) {}
    }

    if (provider.playlist.isNotEmpty && provider.currentIndex == -1) {
      _playVideo(0, resume: true);
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${videoItems.length} video ditambahkan')));
  }

  Future<void> _pickSubtitle() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['srt', 'vtt'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    setState(() {
      _subtitleFilePath = path;
    });
    final provider = Provider.of<PlaylistProvider>(context, listen: false);
    if (provider.currentIndex != -1) {
      _playVideo(provider.currentIndex, subtitlePath: path);
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Subtitle dimuat')));
  }

  void _removeSubtitle() {
    setState(() {
      _subtitleFilePath = null;
    });
    final provider = Provider.of<PlaylistProvider>(context, listen: false);
    if (provider.currentIndex != -1) {
      _playVideo(provider.currentIndex, subtitlePath: null);
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Subtitle dihapus')));
  }

  String formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    final i = (bytes.log / 1024.log).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<PlaylistProvider>(
        builder: (ctx, provider, _) {
          final filtered = provider.filteredPlaylist;
          final currentVideo = provider.currentIndex != -1 && provider.currentIndex < provider.playlist.length
              ? provider.playlist[provider.currentIndex]
              : null;

          // Sleep timer triggered
          if (provider.sleepTimerDuration != null && _isPlayerReady && _controller != null && _controller!.value.isPlaying) {
            // Timer will auto-pause when duration reached (via provider)
            // We check periodically
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (provider.sleepTimerDuration == Duration.zero) {
                _controller?.pause();
                provider.cancelSleepTimer();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('⏰ Sleep timer: video dijeda'), duration: Duration(seconds: 3)),
                );
              }
            });
          }

          return Column(
            children: [
              // ---- PLAYER AREA with GESTURE ----
              Container(
                color: Colors.black,
                height: MediaQuery.of(context).size.height * 0.35,
                child: Stack(
                  children: [
                    // Video Player
                    if (_isPlayerReady && _chewieController != null)
                      Chewie(controller: _chewieController!)
                    else
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.play_circle_outline, size: 60, color: Colors.grey),
                            SizedBox(height: 10),
                            Text(
                              currentVideo?.name ?? 'Pilih video untuk diputar',
                              style: TextStyle(color: Colors.grey, fontSize: 14),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),

                    // ---- GESTURE OVERLAY ----
                    if (_isPlayerReady && !provider.isScreenLocked)
                      GestureDetector(
                        onTap: _toggleOverlay,
                        onDoubleTap: _onDoubleTap,
                        onVerticalDragUpdate: (details) {
                          // Deteksi sisi kiri/kanan
                          final size = MediaQuery.of(context).size;
                          final isLeft = details.localPosition.dx < size.width / 2;
                          _onVerticalDragUpdate(details, isLeft);
                        },
                        child: Row(
                          children: [
                            // Left side (brightness)
                            Expanded(
                              child: GestureDetector(
                                onTap: _onTapLeft,
                                behavior: HitTestBehavior.translucent,
                              ),
                            ),
                            // Right side (volume)
                            Expanded(
                              child: GestureDetector(
                                onTap: _onTapRight,
                                behavior: HitTestBehavior.translucent,
                              ),
                            ),
                          ],
                        ),
                      ),

                    // ---- OVERLAY CONTROLS (top & bottom) ----
                    if (_showOverlayControls && _isPlayerReady && !provider.isScreenLocked)
                      _buildOverlayControls(provider),

                    // ---- SLEEP TIMER INDICATOR ----
                    if (provider.sleepTimerDuration != null)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.8),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.timer, size: 16, color: Colors.white),
                              SizedBox(width: 4),
                              Text(
                                _formatDuration(provider.sleepTimerDuration!),
                                style: TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // ---- LOCK ICON ----
                    if (provider.isScreenLocked)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Icon(Icons.lock, color: Colors.white70, size: 20),
                      ),
                  ],
                ),
              ),

              // ---- SUBTITLE BAR ----
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                color: Colors.grey[900],
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.closed_caption, size: 20, color: Colors.white70),
                      onPressed: _pickSubtitle,
                      tooltip: 'Upload Subtitle (.srt/.vtt)',
                    ),
                    Expanded(
                      child: Text(
                        _subtitleFilePath != null ? '✅ Subtitle aktif' : 'Tidak ada subtitle',
                        style: TextStyle(fontSize: 12, color: Colors.green),
                      ),
                    ),
                    if (_subtitleFilePath != null)
                      IconButton(
                        icon: Icon(Icons.close, size: 18, color: Colors.red),
                        onPressed: _removeSubtitle,
                      ),
                    // Sleep Timer button
                    IconButton(
                      icon: Icon(Icons.timer, color: provider.sleepTimerDuration != null ? Colors.red : Colors.white70),
                      onPressed: _showSleepTimerDialog,
                    ),
                    // Lock button
                    IconButton(
                      icon: Icon(provider.isScreenLocked ? Icons.lock : Icons.lock_open, color: Colors.white70),
                      onPressed: provider.toggleScreenLock,
                    ),
                  ],
                ),
              ),

              // ---- TOOLBAR ----
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: Colors.grey[850],
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        style: TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Cari video...',
                          hintStyle: TextStyle(color: Colors.grey),
                          prefixIcon: Icon(Icons.search, color: Colors.grey, size: 20),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.grey[800],
                          contentPadding: EdgeInsets.symmetric(vertical: 0, horizontal: 8),
                          isDense: true,
                        ),
                        onChanged: provider.setSearchQuery,
                      ),
                    ),
                    IconButton(
                      icon: Icon(provider.isGridView ? Icons.grid_view : Icons.list, color: Colors.white70),
                      onPressed: provider.toggleViewMode,
                    ),
                    IconButton(
                      icon: Icon(Icons.shuffle, color: provider.shuffle ? Colors.red : Colors.white70),
                      onPressed: provider.toggleShuffle,
                    ),
                    IconButton(
                      icon: Icon(Icons.repeat, color: provider.repeat ? Colors.red : Colors.white70),
                      onPressed: provider.toggleRepeat,
                    ),
                  ],
                ),
              ),

              // ---- PLAYLIST ----
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.video_library, size: 60, color: Colors.grey[700]),
                            SizedBox(height: 12),
                            Text('Belum ada video', style: TextStyle(color: Colors.grey)),
                            Text('Tekan + untuk pilih folder/file', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                          ],
                        ),
                      )
                    : provider.isGridView
                        ? GridView.builder(
                            padding: EdgeInsets.all(8),
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: MediaQuery.of(context).size.width > 600 ? 4 : 2,
                              childAspectRatio: 0.8,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                            itemCount: filtered.length,
                            itemBuilder: (ctx, idx) {
                              final video = filtered[idx];
                              final originalIndex = provider.playlist.indexOf(video);
                              final isActive = originalIndex == provider.currentIndex;
                              return GestureDetector(
                                onTap: () => _playVideo(originalIndex, subtitlePath: _subtitleFilePath, resume: true),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isActive ? Colors.red[900] : Colors.grey[850],
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: isActive ? Colors.red : Colors.transparent, width: 2),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                                          child: video.thumbnail != null
                                              ? Image.file(File(video.thumbnail!), fit: BoxFit.cover, width: double.infinity)
                                              : Container(
                                                  color: Colors.grey[800],
                                                  child: Center(child: Icon(Icons.video_file, color: Colors.grey[600])),
                                                ),
                                        ),
                                      ),
                                      Padding(
                                        padding: EdgeInsets.all(6),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              video.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                            ),
                                            SizedBox(height: 2),
                                            Text(
                                              '${video.duration != null ? _formatDuration(video.duration!) : '--:--'} • ${formatSize(video.size)}',
                                              style: TextStyle(fontSize: 10, color: Colors.grey),
                                            ),
                                            if (video.lastPosition != null && video.lastPosition!.inSeconds > 10)
                                              Row(
                                                children: [
                                                  Icon(Icons.play_circle_outline, size: 10, color: Colors.green),
                                                  SizedBox(width: 4),
                                                  Text(
                                                    'Resume ${_formatDuration(video.lastPosition!)}',
                                                    style: TextStyle(fontSize: 9, color: Colors.green),
                                                  ),
                                                ],
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          )
                        : ListView.builder(
                            padding: EdgeInsets.symmetric(vertical: 4),
                            itemCount: filtered.length,
                            itemBuilder: (ctx, idx) {
                              final video = filtered[idx];
                              final originalIndex = provider.playlist.indexOf(video);
                              final isActive = originalIndex == provider.currentIndex;
                              return ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: video.thumbnail != null
                                      ? Image.file(File(video.thumbnail!), width: 80, height: 50, fit: BoxFit.cover)
                                      : Container(width: 80, height: 50, color: Colors.grey[800], child: Icon(Icons.video_file)),
                                ),
                                title: Text(video.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${video.duration != null ? _formatDuration(video.duration!) : '--:--'} • ${formatSize(video.size)}',
                                      style: TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                    if (video.lastPosition != null && video.lastPosition!.inSeconds > 10)
                                      Text(
                                        'Resume ${_formatDuration(video.lastPosition!)}',
                                        style: TextStyle(fontSize: 11, color: Colors.green),
                                      ),
                                  ],
                                ),
                                trailing: IconButton(
                                  icon: Icon(Icons.close, color: Colors.grey),
                                  onPressed: () => provider.removeVideo(originalIndex),
                                ),
                                tileColor: isActive ? Colors.red[900]?.withOpacity(0.3) : null,
                                onTap: () => _playVideo(originalIndex, subtitlePath: _subtitleFilePath, resume: true),
                              );
                            },
                          ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            backgroundColor: Colors.grey[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
            builder: (ctx) => SafeArea(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: Icon(Icons.folder_open, color: Colors.white),
                      title: Text('Pilih Folder (Semua Video)'),
                      onTap: () { Navigator.pop(ctx); _pickFolder(); },
                    ),
                    ListTile(
                      leading: Icon(Icons.add, color: Colors.white),
                      title: Text('Pilih File Video (Multiple)'),
                      onTap: () { Navigator.pop(ctx); _pickFiles(); },
                    ),
                    ListTile(
                      leading: Icon(Icons.delete_sweep, color: Colors.red),
                      title: Text('Hapus Semua Video', style: TextStyle(color: Colors.red)),
                      onTap: () {
                        Navigator.pop(ctx);
                        final p = Provider.of<PlaylistProvider>(context, listen: false);
                        p.clearAll();
                        setState(() {
                          _isPlayerReady = false;
                          _controller?.dispose();
                          _chewieController?.dispose();
                          _controller = null;
                          _chewieController = null;
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        icon: Icon(Icons.add),
        label: Text('Tambah Video'),
        backgroundColor: Colors.red,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  // ========== BUILD OVERLAY CONTROLS ==========
  Widget _buildOverlayControls(PlaylistProvider provider) {
    return Stack(
      children: [
        // Top bar: title & close
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withOpacity(0.7), Colors.transparent],
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    provider.currentIndex != -1 ? provider.playlist[provider.currentIndex].name : '',
                    style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: Colors.white),
                  onPressed: () => setState(() => _showOverlayControls = false),
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints(),
                ),
              ],
            ),
          ),
        ),

        // Bottom bar: play/pause, prev, next, progress, speed
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black.withOpacity(0.8), Colors.transparent],
              ),
            ),
            child: Column(
              children: [
                // Progress bar
                Row(
                  children: [
                    Text(
                      _controller != null && _controller!.value.isInitialized
                          ? _formatDuration(_controller!.value.position)
                          : '0:00',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    Expanded(
                      child: Slider(
                        value: _controller != null && _controller!.value.isInitialized
                            ? _controller!.value.position.inSeconds.toDouble()
                            : 0,
                        min: 0,
                        max: _controller != null && _controller!.value.isInitialized
                            ? _controller!.value.duration.inSeconds.toDouble()
                            : 1,
                        onChanged: (val) {
                          if (_controller != null && _controller!.value.isInitialized) {
                            _controller!.seekTo(Duration(seconds: val.toInt()));
                          }
                        },
                        activeColor: Colors.red,
                        inactiveColor: Colors.grey,
                      ),
                    ),
                    Text(
                      _controller != null && _controller!.value.isInitialized
                          ? _formatDuration(_controller!.value.duration)
                          : '0:00',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
                // Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(Icons.skip_previous, color: Colors.white, size: 28),
                      onPressed: _playPrev,
                    ),
                    IconButton(
                      icon: Icon(
                        _controller != null && _controller!.value.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        color: Colors.white,
                        size: 40,
                      ),
                      onPressed: () {
                        if (_controller != null) {
                          if (_controller!.value.isPlaying) {
                            _controller!.pause();
                          } else {
                            _controller!.play();
                          }
                          setState(() {});
                        }
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.skip_next, color: Colors.white, size: 28),
                      onPressed: _playNext,
                    ),
                    // Speed indicator
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${provider.playbackSpeed}x',
                        style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// END OF FILE
// ============================================================