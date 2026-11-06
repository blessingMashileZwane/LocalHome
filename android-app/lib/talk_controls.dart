import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'camera_profile.dart';
import 'lan_talkback.dart';
import 'mic_capture.dart';

/// Talk button for the focused viewer: sends the phone microphone to the
/// camera speaker over the camera's local IOT session (TCP 8089).
///
/// The camera LAN password (QR field 8) is required. Audio is 8 kHz mono,
/// G.711 A-law, sent as media frames with the session key derived locally.
class TalkControls extends StatefulWidget {
  const TalkControls({
    super.key,
    required this.profile,
    required this.onIncomingMute,
  });

  final CameraProfile profile;
  final Future<void> Function(bool muted) onIncomingMute;

  @override
  State<TalkControls> createState() => _TalkControlsState();
}

class _TalkControlsState extends State<TalkControls>
    with WidgetsBindingObserver {
  final MicCapture _mic = MicCapture();
  LanTalkbackClient? _talk;
  StreamSubscription<Uint8List>? _micSubscription;

  bool _starting = false;
  bool _active = false;
  bool _stopping = false;
  String? _error;
  Timer? _statsTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _toggle() async {
    if (_stopping) return;
    if (_active || _starting) {
      await _stop();
      return;
    }
    if (widget.profile.lanPassword.isEmpty) {
      setState(() {
        _error =
            'Set the camera LAN password (QR field 8) in Edit camera first.';
      });
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final granted =
          await _mic.hasPermission() || await _mic.requestPermission();
      if (!granted) {
        throw LanTalkException(
          'Microphone access is off. Allow it for LocalHome in system settings.',
        );
      }
      final talk = LanTalkbackClient(
        address: widget.profile.address,
        password: widget.profile.lanPassword,
      );
      _talk = talk;
      await talk.connect();
      debugPrint('talk: LAN session ready for ${widget.profile.address}');

      final micStream = _mic.start();
      var chunks = 0;
      _micSubscription = micStream.listen(
        (pcm) {
          chunks += 1;
          if (chunks == 1) {
            debugPrint('talk: first mic chunk ${pcm.length} bytes');
          }
          talk.sendPcm16(pcm);
        },
        onError: (Object error) {
          setState(() => _error = 'Microphone error: $error');
          unawaited(_stop());
        },
      );
      await widget.onIncomingMute(true);
      if (!mounted) {
        await _stop();
        return;
      }
      setState(() {
        _active = true;
        _starting = false;
      });
      _statsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } on LanTalkException catch (error) {
      await _cleanup();
      await widget.onIncomingMute(false);
      setState(() {
        _starting = false;
        _error = error.message;
      });
    } catch (error) {
      await _cleanup();
      await widget.onIncomingMute(false);
      setState(() {
        _starting = false;
        _error = 'Could not start talk: $error';
      });
    }
  }

  Future<void> _stop() async {
    if (_stopping) return;
    _stopping = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    try {
      await _micSubscription?.cancel();
      _micSubscription = null;
      await _mic.stop();
      await _cleanup();
      await widget.onIncomingMute(false);
    } finally {
      _stopping = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _cleanup() async {
    final talk = _talk;
    _talk = null;
    _active = false;
    _starting = false;
    await talk?.stop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statsTimer?.cancel();
    unawaited(_micSubscription?.cancel());
    unawaited(_mic.stop());
    unawaited(_cleanup());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _starting;
    final talk = _talk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Tooltip(
          message: 'Talk to the camera speaker over the local network',
          child: InkWell(
            onTap: busy ? null : _toggle,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _active
                    ? const Color(0xFFB3261E)
                    : const Color(0xCC142021),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF273536)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      _active ? Icons.mic : Icons.mic_none,
                      size: 16,
                      color: _active
                          ? Colors.white
                          : const Color(0xFF92E6B5),
                    ),
                  const SizedBox(width: 6),
                  Text(
                    _active ? 'Stop' : 'Talk',
                    style: TextStyle(
                      color: _active
                          ? Colors.white
                          : const Color(0xFF92E6B5),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (talk != null && _active)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'sent ${talk.framesSent} frames / ${talk.bytesSent} B',
              style: const TextStyle(color: Color(0xFF9BAAA8), fontSize: 10),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFFFA18F), fontSize: 12),
            ),
          ),
      ],
    );
  }
}
