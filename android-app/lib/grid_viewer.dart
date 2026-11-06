import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'camera_endpoint.dart';
import 'camera_profile.dart';
import 'camera_status.dart';
import 'light_controls.dart';
import 'ptz_controls.dart';
import 'talk_controls.dart';

class GridViewerPage extends StatefulWidget {
  const GridViewerPage({
    super.key,
    required this.profiles,
    this.singleCamera = false,
  });

  final List<CameraProfile> profiles;
  final bool singleCamera;

  @override
  State<GridViewerPage> createState() => _GridViewerPageState();
}

class _GridViewerPageState extends State<GridViewerPage> {
  final _tileKeys = <String, GlobalKey<_GridCameraTileState>>{};
  int _connectGeneration = 0;
  bool _openingCamera = false;

  @override
  void initState() {
    super.initState();
    for (final profile in widget.profiles) {
      _tileKeys[profile.id] = GlobalKey<_GridCameraTileState>();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_connectAll());
    });
  }

  Future<void> _connectAll() async {
    final generation = ++_connectGeneration;
    for (final key in _tileKeys.values) {
      if (!mounted || generation != _connectGeneration) return;
      unawaited(key.currentState?.connect());
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
  }

  Future<void> _stopAll() async {
    ++_connectGeneration;
    await Future.wait([
      for (final key in _tileKeys.values)
        if (key.currentState case final state?) state.disconnect(),
    ]);
  }

  Future<void> _openCamera(CameraProfile profile) async {
    if (_openingCamera) return;
    _openingCamera = true;
    await _stopAll();
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GridViewerPage(profiles: [profile], singleCamera: true),
      ),
    );
    if (!mounted) return;
    _openingCamera = false;
    unawaited(_connectAll());
  }

  @override
  void dispose() {
    ++_connectGeneration;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1000
        ? 4
        : width >= 650
        ? 3
        : 2;
    final aspectRatio = columns == 2 ? 0.88 : 1.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.singleCamera ? widget.profiles.first.name : 'Camera grid',
        ),
        actions: widget.singleCamera
            ? null
            : [
                IconButton(
                  tooltip: 'Connect all cameras',
                  onPressed: () => unawaited(_connectAll()),
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
                IconButton(
                  tooltip: 'Stop all cameras',
                  onPressed: () => unawaited(_stopAll()),
                  icon: const Icon(Icons.stop_rounded),
                ),
              ],
      ),
      body: widget.profiles.isEmpty
          ? const Center(child: Text('Add a camera to see it in the grid.'))
          : widget.singleCamera
          ? Padding(
              padding: const EdgeInsets.all(6),
              child: SizedBox.expand(
                child: _GridCameraTile(
                  key: _tileKeys[widget.profiles.first.id],
                  profile: widget.profiles.first,
                  large: true,
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: aspectRatio,
              ),
              itemCount: widget.profiles.length,
              itemBuilder: (context, index) {
                final profile = widget.profiles[index];
                return _GridCameraTile(
                  key: _tileKeys[profile.id],
                  profile: profile,
                  onTap: () => unawaited(_openCamera(profile)),
                );
              },
            ),
    );
  }
}

class _GridCameraTile extends StatefulWidget {
  const _GridCameraTile({
    super.key,
    required this.profile,
    this.large = false,
    this.onTap,
  });

  final CameraProfile profile;
  final bool large;
  final VoidCallback? onTap;

  @override
  State<_GridCameraTile> createState() => _GridCameraTileState();
}

class _GridCameraTileState extends State<_GridCameraTile>
    with WidgetsBindingObserver {
  late final _player = Player(
    configuration: PlayerConfiguration(
      bufferSize: widget.large ? 256 * 1024 : 32 * 1024 * 1024,
    ),
  );
  late final VideoController _videoController = VideoController(_player);

  late final StreamSubscription<bool> _playingSubscription;
  late final StreamSubscription<String> _errorSubscription;
  CameraStatus _status = CameraStatus.disconnected;
  String? _error;
  bool _muted = false;
  bool? _preTalkMuted;
  bool _showPtzControls = false;
  bool _showLightControls = false;
  int _generation = 0;
  Timer? _timeout;

  /// Mutes incoming audio while talking so the live feed cannot loop back
  /// through the phone's microphone into the camera's speaker. The user's own
  /// mute choice is restored when talk ends.
  Future<void> _setIncomingMuteForTalk(bool muted) async {
    if (muted) {
      _preTalkMuted = _muted;
      await _player.setVolume(0);
    } else {
      await _player.setVolume(_preTalkMuted ?? _muted ? 0 : 100);
      _preTalkMuted = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playingSubscription = _player.stream.playing.listen((playing) {
      if (playing && mounted && _status == CameraStatus.connecting) {
        _timeout?.cancel();
        setState(() {
          _status = CameraStatus.live;
          _error = null;
        });
      }
    });
    _errorSubscription = _player.stream.error.listen((message) {
      if (isLiveRtspSeekError(message)) return;
      if (mounted &&
          (_status == CameraStatus.live ||
              _status == CameraStatus.connecting)) {
        _timeout?.cancel();
        setState(() {
          _status = CameraStatus.failed;
          _error = message;
        });
      }
    });
  }

  Future<void> connect() async {
    late final Uri uri;
    try {
      uri = CameraEndpoint.parse(
        address: widget.profile.address,
        path: widget.profile.path,
      );
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _status = CameraStatus.failed;
        _error = error.message;
      });
      return;
    }

    final generation = ++_generation;
    _timeout?.cancel();
    setState(() {
      _status = CameraStatus.connecting;
      _error = null;
    });
    try {
      await _player.stop();
      if (!mounted || generation != _generation) return;
      _timeout = Timer(const Duration(seconds: 20), () {
        if (mounted &&
            generation == _generation &&
            _status == CameraStatus.connecting) {
          unawaited(_fail(generation, 'No stream started. Check the IP/path.'));
        }
      });
      await _player.open(Media(uri.toString()), play: true);
    } catch (_) {
      _timeout?.cancel();
      if (!mounted || generation != _generation) return;
      setState(() {
        _status = CameraStatus.failed;
        _error = 'Could not open this local stream.';
      });
    }
  }

  Future<void> _fail(int generation, String message) async {
    if (!mounted || generation != _generation) return;
    await _player.stop();
    if (!mounted || generation != _generation) return;
    setState(() {
      _status = CameraStatus.failed;
      _error = message;
    });
  }

  Future<void> disconnect() async {
    ++_generation;
    _timeout?.cancel();
    await _player.stop();
    if (!mounted) return;
    setState(() {
      _status = CameraStatus.disconnected;
      _error = null;
    });
  }

  Future<void> _toggleMute() async {
    final muted = !_muted;
    await _player.setVolume(muted ? 0 : 100);
    if (mounted) setState(() => _muted = muted);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(disconnect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeout?.cancel();
    unawaited(_playingSubscription.cancel());
    unawaited(_errorSubscription.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = _status == CameraStatus.live;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: const Color(0xFF10191A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF273536)),
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0xFF050A0B)),
                  if (live || _status == CameraStatus.connecting)
                    InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: Video(
                        controller: _videoController,
                        controls: NoVideoControls,
                        fit: BoxFit.contain,
                      ),
                    )
                  else
                    _placeholder(),
                  if (_status == CameraStatus.connecting)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: const Color(0x66000000),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(),
                                const SizedBox(height: 10),
                                Text(
                                  'Connecting to ${widget.profile.name}…',
                                  style: TextStyle(
                                    fontSize: widget.large ? 15 : 11,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 7,
                    left: 7,
                    right: 7,
                    child: Row(
                      children: [
                        Expanded(child: _Chip(label: widget.profile.name)),
                        if (widget.large && live) ...[
                          IconButton(
                            tooltip: _showLightControls
                                ? 'Hide light control'
                                : 'Show light control',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(() {
                              _showLightControls = !_showLightControls;
                              if (_showLightControls) _showPtzControls = false;
                            }),
                            icon: Icon(
                              _showLightControls
                                  ? Icons.lightbulb
                                  : Icons.lightbulb_outline,
                              color: const Color(0xFF92E6B5),
                            ),
                          ),
                          IconButton(
                            tooltip: _showPtzControls
                                ? 'Hide PTZ controls'
                                : 'Show PTZ controls',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(() {
                              _showPtzControls = !_showPtzControls;
                              if (_showPtzControls) _showLightControls = false;
                            }),
                            icon: Icon(
                              _showPtzControls
                                  ? Icons.control_camera
                                  : Icons.control_camera_outlined,
                              color: const Color(0xFF92E6B5),
                            ),
                          ),
                        ],
                        const SizedBox(width: 4),
                        _Chip(
                          label: switch (_status) {
                            CameraStatus.disconnected => 'READY',
                            CameraStatus.connecting => 'CONNECTING',
                            CameraStatus.live => 'LIVE',
                            CameraStatus.failed => 'ISSUE',
                          },
                          live: live,
                        ),
                      ],
                    ),
                  ),
                  if (live)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: IconButton(
                        tooltip: _muted ? 'Unmute' : 'Mute',
                        onPressed: _toggleMute,
                        icon: Icon(
                          _muted ? Icons.volume_off : Icons.volume_up,
                          size: widget.large ? 32 : 24,
                        ),
                      ),
                    ),
                  if (live && widget.large)
                    if (_showLightControls)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 42,
                        child: Center(
                          child: LightControls(profile: widget.profile),
                        ),
                      )
                    else if (_showPtzControls)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 42,
                        child: Center(
                          child: PtzControls(profile: widget.profile),
                        ),
                      )
                    else
                      const Positioned(
                        left: 12,
                        bottom: 12,
                        child: _Chip(label: 'Pinch to zoom'),
                      ),
                  if (live && widget.large)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 8,
                      child: Center(
                        child: TalkControls(
                          profile: widget.profile,
                          onIncomingMute: _setIncomingMuteForTalk,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                widget.large ? 12 : 5,
                2,
                widget.large ? 12 : 5,
                4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.profile.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFF9BAAA8),
                        fontSize: widget.large ? 14 : 10,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: widget.large
                        ? VisualDensity.standard
                        : VisualDensity.compact,
                    tooltip: live ? 'Reconnect' : 'Connect',
                    onPressed: _status == CameraStatus.connecting
                        ? null
                        : connect,
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      size: widget.large ? 28 : 21,
                    ),
                  ),
                  IconButton(
                    visualDensity: widget.large
                        ? VisualDensity.standard
                        : VisualDensity.compact,
                    tooltip: 'Stop',
                    onPressed: live || _status == CameraStatus.connecting
                        ? disconnect
                        : null,
                    icon: Icon(
                      Icons.stop_rounded,
                      size: widget.large ? 26 : 19,
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  _error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: const Color(0xFFFFA18F),
                    fontSize: widget.large ? 13 : 10,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.videocam_outlined,
            size: 28,
            color: Color(0xFF5F7472),
          ),
          const SizedBox(height: 5),
          Text(
            _status == CameraStatus.connecting
                ? 'Connecting'
                : _status == CameraStatus.failed
                ? 'Unavailable'
                : 'No stream',
            style: const TextStyle(color: Color(0xFFB4C1BF), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.live = false});

  final String label;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xCC142021),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: live ? const Color(0xFF92E6B5) : const Color(0xFFD2DCDA),
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
