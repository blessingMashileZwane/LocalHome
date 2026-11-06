import 'dart:async';

import 'package:flutter/services.dart';

/// Mono 16-bit PCM microphone capture at 8 kHz via the platform channel.
///
/// Chunks arrive in 20 ms blocks (160 samples). The Android side uses the
/// VOICE_COMMUNICATION audio source so platform echo suppression applies:
/// while talking, the camera's speaker plays into its own microphone.
class MicCapture {
  static const _method = MethodChannel('localhome/mic');
  static const _events = EventChannel('localhome/mic_pcm16');

  StreamSubscription<dynamic>? _subscription;
  StreamController<Uint8List>? _controller;

  /// Whether the OS already granted microphone permission.
  Future<bool> hasPermission() async {
    try {
      return await _method.invokeMethod<bool>('hasPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Requests microphone permission. Returns whether it is now granted.
  Future<bool> requestPermission() async {
    try {
      return await _method.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Starts capture. Capture errors (permission missing, device busy) surface
  /// as [MicCaptureException] in the returned stream.
  Stream<Uint8List> start() {
    final controller = _controller ??= StreamController<Uint8List>.broadcast(
      onCancel: stop,
    );
    _subscription = _events.receiveBroadcastStream().listen(
      (data) {
        if (data is Uint8List) {
          controller.add(data);
        } else if (data is List<int>) {
          controller.add(Uint8List.fromList(data));
        }
      },
      onError: (Object error) {
        controller.addError(MicCaptureException('$error'));
      },
      cancelOnError: false,
    );
    return controller.stream;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller?.close();
    _controller = null;
  }
}

class MicCaptureException implements Exception {
  MicCaptureException(this.message);

  final String message;

  @override
  String toString() => message;
}
