import 'dart:async';

import 'package:flutter/material.dart';

import 'camera_profile.dart';
import 'onvif_ptz.dart';

class PtzControls extends StatefulWidget {
  const PtzControls({super.key, required this.profile});

  final CameraProfile profile;

  @override
  State<PtzControls> createState() => _PtzControlsState();
}

class _PtzControlsState extends State<PtzControls>
    with WidgetsBindingObserver {
  late final OnvifPtzClient _client = OnvifPtzClient(
    address: widget.profile.address,
  );
  final _repeatInterval = const Duration(milliseconds: 350);
  static const _minimumTapMove = Duration(milliseconds: 300);
  Timer? _repeatTimer;
  Stopwatch? _moveDuration;
  Future<void>? _pendingMove;
  _PtzDirection? _heldDirection;
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _client.initialize();
      if (mounted) setState(() => _ready = true);
    } on OnvifPtzException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  void _beginMove(_PtzDirection direction) {
    if (!_ready || _heldDirection != null) return;
    setState(() {
      _heldDirection = direction;
      _error = null;
    });
    _moveDuration = Stopwatch()..start();
    unawaited(_sendMove());
    _repeatTimer = Timer.periodic(_repeatInterval, (_) {
      if (_pendingMove == null && _heldDirection != null) {
        unawaited(_sendMove());
      }
    });
  }

  Future<void> _sendMove() async {
    final direction = _heldDirection;
    if (direction == null || _pendingMove != null) return;
    final movement = _client.move(pan: direction.pan, tilt: direction.tilt);
    _pendingMove = movement;
    try {
      await movement;
    } on OnvifPtzException catch (error) {
      _repeatTimer?.cancel();
      _heldDirection = null;
      if (mounted) setState(() => _error = error.message);
      await _stopAfterError();
    } finally {
      _pendingMove = null;
    }
  }

  Future<void> _releaseMove({bool immediate = false}) async {
    final wasMoving = _heldDirection != null;
    _heldDirection = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    if (mounted) setState(() {});
    if (!wasMoving) return;

    final pendingMove = _pendingMove;
    if (pendingMove != null) await pendingMove;
    final moveDuration = _moveDuration;
    if (!immediate &&
        moveDuration != null &&
        moveDuration.elapsed < _minimumTapMove) {
      await Future<void>.delayed(_minimumTapMove - moveDuration.elapsed);
    }
    _moveDuration = null;
    try {
      await _client.stop();
    } on OnvifPtzException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _stopAfterError() async {
    try {
      await _client.stop();
    } on OnvifPtzException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
    unawaited(_releaseMove(immediate: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _repeatTimer?.cancel();
    if (_heldDirection != null) {
      unawaited(
        _releaseMove(immediate: true).whenComplete(_client.close),
      );
    } else {
      _client.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xE610191A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF516363)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ??
                (_ready
                        ? 'Tap for a nudge · hold to move · release to stop'
                    : 'Checking local ONVIF PTZ…'),
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(
              color: _error == null
                  ? const Color(0xFFD4E0DD)
                  : const Color(0xFFFFA18F),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _directionButton(
                _PtzDirection.left,
                Icons.chevron_left_rounded,
                'Pan left',
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _directionButton(
                    _PtzDirection.up,
                    Icons.keyboard_arrow_up_rounded,
                    'Tilt up',
                  ),
                  _directionButton(
                    _PtzDirection.down,
                    Icons.keyboard_arrow_down_rounded,
                    'Tilt down',
                  ),
                ],
              ),
              _directionButton(
                _PtzDirection.right,
                Icons.chevron_right_rounded,
                'Pan right',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _directionButton(
    _PtzDirection direction,
    IconData icon,
    String label,
  ) {
    final enabled = _ready;
    final selected = _heldDirection == direction;
    return Listener(
      onPointerDown: enabled ? (_) => _beginMove(direction) : null,
      onPointerUp: enabled ? (_) => unawaited(_releaseMove()) : null,
      onPointerCancel: enabled
          ? (_) => unawaited(_releaseMove(immediate: true))
          : null,
      child: Semantics(
        button: true,
        label: label,
        child: Container(
          width: 42,
          height: 34,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF47715C)
                : const Color(0xFF263637),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            icon,
            color: enabled ? Colors.white : const Color(0xFF6D7A78),
            size: 25,
          ),
        ),
      ),
    );
  }
}

enum _PtzDirection {
  up(0, 0.15),
  down(0, -0.15),
  left(-0.15, 0),
  right(0.15, 0);

  const _PtzDirection(this.pan, this.tilt);

  final double pan;
  final double tilt;
}
