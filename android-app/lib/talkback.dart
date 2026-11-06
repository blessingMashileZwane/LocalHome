/// Two-way audio ("talk") over the camera's RTSP backchannel.
///
/// Packet path established by the 2026-10-28 LAN test against the HiMost
/// firmware (macro-video RTSP server): TCP 554, RTSP interleaved RTP,
/// outgoing G.711 A-law as payload type 8 on interleaved channel 2 after a
/// SETUP of the audio track with `Require: www.onvif.org/ver20/backchannel`.
///
/// Outgoing audio goes out in 20 ms blocks (160 A-law bytes), RTP timestamps
/// advancing 160 per block at the camera's PCMA clock rate of 8000 Hz. The
/// audible result on the camera speaker is not yet user-confirmed; this
/// client exists to make that test possible.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int _pcmaPayloadType = 8;
const int _pcmuPayloadType = 0;

/// One talkback framing validated against the camera. The camera accepted the
/// backchannel SETUP in every shape but only some may actually play.
class TalkVariant {
  const TalkVariant({
    required this.key,
    required this.label,
    this.blockSamples = 800,
    this.pcma = true,
    this.withVideo = true,
    this.requireOnPlay = false,
    this.playOnAudioTrack = false,
    this.marker = true,
  });

  final String key;
  final String label;

  /// Samples per outgoing RTP payload (800 = 100 ms, 160 = 20 ms).
  final int blockSamples;

  /// true = G.711 A-law (PT 8), false = G.711 µ-law (PT 0).
  final bool pcma;

  /// Whether the session also SETUPs the video track like a normal viewer.
  final bool withVideo;

  /// Whether PLAY carries the ONVIF backchannel Require header.
  final bool requireOnPlay;

  /// Whether PLAY targets the audio track URI instead of the aggregate.
  final bool playOnAudioTrack;

  /// Whether the first RTP packet carries the marker bit.
  final bool marker;

  int get payloadType => pcma ? _pcmaPayloadType : _pcmuPayloadType;
}

/// The supported framings, in the order they are tried on the camera.
const List<TalkVariant> talkVariants = [
  TalkVariant(
    key: 'A',
    label: 'video+audio, PCMA 100 ms, Require on SETUP+PLAY',
    requireOnPlay: true,
  ),
  TalkVariant(
    key: 'B',
    label: 'audio-only session, PCMA 100 ms',
    withVideo: false,
  ),
  TalkVariant(
    key: 'C',
    label: 'video+audio, PCMU 100 ms',
    pcma: false,
  ),
  TalkVariant(
    key: 'E',
    label: 'audio-only, PLAY on track2, PCMA 100 ms',
    withVideo: false,
    playOnAudioTrack: true,
  ),
  TalkVariant(
    key: 'F',
    label: 'video+audio, PCMA 20 ms, no marker',
    blockSamples: 160,
    marker: false,
  ),
  TalkVariant(
    key: 'G',
    label: 'video+audio, PCMA 20 ms (initial framing)',
    blockSamples: 160,
  ),
];

/// Result of negotiating a talk session with the camera.
class TalkSessionInfo {
  const TalkSessionInfo({
    required this.audioTrackControl,
    required this.videoTrackControl,
    this.incomingAudioPayloadType,
  });

  /// SDP control of the audio track used for the backchannel, e.g. `track2`.
  final String audioTrackControl;
  final String videoTrackControl;

  /// RTP payload type of the camera's incoming audio when known (8 = PCMA).
  final int? incomingAudioPayloadType;
}

/// Errors thrown by [TalkbackClient].
class TalkbackException implements Exception {
  TalkbackException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum TalkState { idle, connecting, active, failed }

/// Sends the phone microphone to the camera's speaker over the RTSP
/// backchannel. One client talks to one camera; concurrent use on a second
/// client is intentionally rejected.
class TalkbackClient {
  TalkbackClient({
    required this.address,
    this.port = 554,
    this.path = '/live/ch00_0',
    this.variant = const TalkVariant(key: 'A', label: 'default'),
  });

  final String address;
  final int port;
  final String path;
  final TalkVariant variant;

  int get _pcmBlockBytes => variant.blockSamples * 2;

  Socket? _socket;
  TalkState _state = TalkState.idle;

  final _stateController = StreamController<TalkState>.broadcast();
  Stream<TalkState> get stateStream => _stateController.stream;

  String? _session;
  Timer? _keepAliveTimer;
  int _cseq = 0;
  bool _stopRequested = false;
  bool _failed = false;

  set state(TalkState value) {
    _state = value;
    _stateController.add(value);
  }

  // Outgoing RTP clock.
  int _seq = 0;
  int _timestamp = 0;
  late final int _ssrc = DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFF;

  /// Inbound byte counters; the camera keeps streaming while we talk and the
  /// buffers must stay consumed for its TCP window to stay open.
  int inboundVideoBytes = 0;
  int inboundAudioBytes = 0;

  /// Smoothed mean A-law amplitude of the camera's own microphone (0..16000).
 /// If the camera's speaker plays our voice, its mic hears it and this level
  /// jumps, giving visible echo feedback.
  double inboundAudioLevel = 0;

  /// Outgoing RTP counters for the on-screen talk status line.
  int blocksSent = 0;
  int payloadBytesSent = 0;

  final _pcmQueue = <int>[];
  Future<void> _sendChain = Future<void>.value();

  /// Negotiates the session. Call [sendPcm16] repeatedly afterwards; call
  /// [stop] to end the session.
  Future<TalkSessionInfo> connect() async {
    if (_state == TalkState.active || _state == TalkState.connecting) {
      throw TalkbackException('Talk already in progress.');
    }
    _stopRequested = false;
    _failed = false;
    state = TalkState.connecting;
    try {
      final socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 6),
      );
      _socket = socket;
      socket.listen(
        _onData,
        onError: (Object error) => _onConnectionLost(),
        onDone: _onConnectionLost,
      );
      final info = await _negotiate();
      if (_failed || _stopRequested) {
        throw TalkbackException('Talk session ended before it started.');
      }
      state = TalkState.active;
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        unawaited(_keepAlive());
      });
      return info;
    } on TalkbackException {
      _failed = true;
      state = TalkState.failed;
      await close();
      rethrow;
    } on SocketException catch (error) {
      _failed = true;
      state = TalkState.failed;
      await close();
      throw TalkbackException('Talk connection failed: ${error.message}');
    }
  }

  /// Encodes little-endian mono 16-bit PCM into A-law 20 ms blocks and sends
  /// them. Partial blocks are buffered until full. Sends are serialized.
  void sendPcm16(Uint8List pcm) {
    if (_state != TalkState.active) return;
    _pcmQueue.addAll(pcm);
    while (_pcmQueue.length >= _pcmBlockBytes) {
      final block = Uint8List.fromList(_pcmQueue.sublist(0, _pcmBlockBytes));
      _pcmQueue.removeRange(0, _pcmBlockBytes);
      final payload = variant.pcma
          ? G711Alaw.encode16(block)
          : G711Ulaw.encode16(block);
      _sendChain = _sendChain.then(
        (_) => _sendRtpPayload(payload),
        onError: (Object error) {
          _onConnectionLost();
        },
      );
    }
    // Bound the queue: if the mic outpaces the link, drop oldest audio rather
    // than let latency grow.
    if (_pcmQueue.length > _pcmBlockBytes * 4) {
      _pcmQueue.removeRange(0, _pcmBlockBytes * 2);
    }
  }

  /// Keeps the RTSP session alive during long talks; the same request also
  /// surfaces a dead connection.
  Future<void> _keepAlive() async {
    try {
      await _request(
        'OPTIONS',
        _baseUri,
        extra: _sessionHeader(),
      ).timeout(const Duration(seconds: 4));
    } on Exception {
      _onConnectionLost();
    }
  }

  /// Stops the talk session: TEARDOWN, then socket close. Safe to call twice.
  Future<void> stop() async {
    _stopRequested = true;
    _pcmQueue.clear();
    final socket = _socket;
    if (socket != null && _session != null) {
      try {
        // The camera often keeps streaming instead of replying; bound the
        // wait so stopping talk never hangs the UI.
        await _request('TEARDOWN', _baseUri, extra: _sessionHeader())
            .timeout(const Duration(seconds: 1));
      } on TalkbackException {
        // The camera may have already dropped the session; closing below is
        // the same outcome.
      } on TimeoutException {
        // Same outcome.
      }
    }
    await close();
    if (!_failed) state = TalkState.idle;
  }

  String get _baseUri => 'rtsp://$address:$port$path';

  String _trackUri(String base, String control) =>
      control.startsWith('rtsp://') ? control : '$base/$control';

  String _sessionHeader() {
    final session = _session;
    if (session == null || session.isEmpty) return '';
    return 'Session: $session\r\n';
  }

  Future<TalkSessionInfo> _negotiate() async {
    final options = await _request('OPTIONS', _baseUri);
    _assertOk(options, 'OPTIONS');

    final describe = await _request(
      'DESCRIBE',
      _baseUri,
      extra: 'Accept: application/sdp\r\n',
    );
    _assertOk(describe, 'DESCRIBE');
    final sdp = describe.bodyText;
    final audioTracks = SdpAudioTrack.parseAll(sdp);
    if (audioTracks.isEmpty) {
      throw TalkbackException('Camera SDP has no audio track to talk on.');
    }

    final videoControl = SdpVideoTrack.controlFor(sdp);
    if (variant.withVideo) {
      final video = await _request(
        'SETUP',
        _trackUri(_baseUri, videoControl),
        extra: 'Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n',
      );
      _assertOk(video, 'SETUP video');
      _session = video.header('session');
    }

    final audio = audioTracks.first;
    final audioSetup = await _request(
      'SETUP',
      _trackUri(_baseUri, audio.control),
      extra:
          'Transport: RTP/AVP/TCP;unicast;interleaved=2-3\r\n'
          'Require: www.onvif.org/ver20/backchannel\r\n',
    );
    _assertOk(audioSetup, 'SETUP backchannel audio');
    final audioSession = audioSetup.header('session');
    if (audioSession != null && audioSession.isNotEmpty) {
      _session = audioSession;
    }

    final playUri = variant.playOnAudioTrack
        ? _trackUri(_baseUri, audio.control)
        : _baseUri;
    final playExtra = StringBuffer(_sessionHeader());
    if (variant.requireOnPlay) {
      playExtra.write('Require: www.onvif.org/ver20/backchannel\r\n');
    }
    final play = await _request('PLAY', playUri, extra: playExtra.toString());
    _assertOk(play, 'PLAY');
    return TalkSessionInfo(
      audioTrackControl: audio.control,
      videoTrackControl: videoControl,
      incomingAudioPayloadType: audio.payloadType,
    );
  }

  /// Sends one A-law/mu-law block as an interleaved RTP frame on channel 2.
  Future<void> _sendRtpPayload(List<int> payload) async {
    final socket = _socket;
    if (socket == null || _stopRequested || _failed) return;
    final marker = variant.marker && blocksSent == 0;
    final rtp = _rtpPacket(
      payload,
      marker: marker,
      timestampDelta: variant.blockSamples,
    );
    final frame = BytesBuilder()
      ..addByte(0x24) // '$' interleaved frame marker
      ..addByte(2) // outgoing audio channel
      ..addByte((rtp.length >> 8) & 0xFF)
      ..addByte(rtp.length & 0xFF)
      ..add(rtp);
    socket.add(frame.takeBytes());
    await socket.flush();
    blocksSent += 1;
    payloadBytesSent += payload.length;
  }

  Uint8List _rtpPacket(
    List<int> payload, {
    required bool marker,
    required int timestampDelta,
  }) {
    final header = ByteData(12)
      ..setUint8(0, 0x80)
      ..setUint8(1, (marker ? 0x80 : 0) | variant.payloadType)
      ..setUint16(2, _seq & 0xFFFF)
      ..setUint32(4, _timestamp & 0xFFFFFFFF)
      ..setUint32(8, _ssrc & 0xFFFFFFFF);
    _seq = (_seq + 1) & 0xFFFF;
    _timestamp = (_timestamp + timestampDelta) & 0xFFFFFFFF;
    return Uint8List.fromList([...header.buffer.asUint8List(), ...payload]);
  }

  // --- Inbound demux: interleaved frames vs RTSP replies on one socket ---

  final _rawBuffer = BytesBuilder(copy: true);
  Completer<_RtspResponse>? _pendingResponse;

  void _onData(Uint8List data) {
    _rawBuffer.add(data);
    _processBuffer();
  }

  void _processBuffer() {
    var bytes = _rawBuffer.takeBytes();
    var offset = 0;
    while (offset < bytes.length) {
      if (bytes[offset] == 0x24) {
        if (bytes.length - offset < 4) break;
        final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
        if (bytes.length - offset < 4 + length) break;
        final channel = bytes[offset + 1];
        if (channel == 0) {
          inboundVideoBytes += length;
        } else if (channel == 2) {
          inboundAudioBytes += length;
          final frame = Uint8List.sublistView(
            bytes,
            offset + 4 + 12, // skip interleaved and RTP headers
            offset + 4 + length,
          );
          if (frame.isNotEmpty) {
            var total = 0;
            for (final value in frame) {
              total += G711Alaw.decodeAmplitude(value);
            }
            final frameMean = total / frame.length;
            inboundAudioLevel = inboundAudioLevel * 0.7 + frameMean * 0.3;
          }
        }
        offset += 4 + length;
        continue;
      }
      final headerEnd = _findDoubleCrlf(bytes, offset);
      if (headerEnd < 0) break;
      final headerText = utf8.decode(
        bytes.sublist(offset, headerEnd),
        allowMalformed: true,
      );
      final contentLength = Header.contentLength(headerText);
      final total = headerEnd + 4 + contentLength;
      if (bytes.length < total) break;
      final response = _RtspResponse.parse(
        Uint8List.sublistView(bytes, offset, total),
      );
      offset = total;
      final completer = _pendingResponse;
      _pendingResponse = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete(response);
      }
    }
    if (offset < bytes.length) {
      _rawBuffer.add(bytes.sublist(offset));
    }
  }

  void _onConnectionLost() {
    _failed = true;
    if (_state == TalkState.active || _state == TalkState.connecting) {
      state = TalkState.failed;
    }
    final completer = _pendingResponse;
    _pendingResponse = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        TalkbackException('Talk connection closed by the camera.'),
      );
    }
  }

  Future<void> close() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final socket = _socket;
    _socket = null;
    _session = null;
    _pcmQueue.clear();
    try {
      socket?.destroy();
    } catch (_) {
      // Already gone.
    }
  }

  // --- Minimal sequential RTSP request/response over the talk socket ---

  Future<_RtspResponse> _request(
    String method,
    String uri, {
    String extra = '',
  }) async {
    final socket = _socket;
    if (socket == null) {
      throw TalkbackException('Talk socket is closed.');
    }
    if (_pendingResponse != null) {
      throw TalkbackException('Another RTSP request is in flight.');
    }
    _cseq += 1;
    final request =
        '$method $uri RTSP/1.0\r\n'
        'CSeq: $_cseq\r\n'
        'User-Agent: HiMostLocal/1.0\r\n'
        '$extra'
        '\r\n';
    final completer = Completer<_RtspResponse>();
    _pendingResponse = completer;
    try {
      socket.add(utf8.encode(request));
      await socket.flush();
      return await completer.future.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      _pendingResponse = null;
      throw TalkbackException('$method got no reply within 6 s.');
    } on SocketException catch (error) {
      _pendingResponse = null;
      throw TalkbackException('$method failed: ${error.message}');
    }
  }

  void _assertOk(_RtspResponse response, String what) {
    if (!response.statusLine.startsWith('RTSP/1.0 2')) {
      throw TalkbackException('$what rejected: ${response.statusLine}');
    }
  }

  static int _findDoubleCrlf(List<int> bytes, int start) {
    for (var i = start; i + 4 <= bytes.length; i++) {
      if (bytes[i] == 0x0D &&
          bytes[i + 1] == 0x0A &&
          bytes[i + 2] == 0x0D &&
          bytes[i + 3] == 0x0A) {
        return i;
      }
    }
    return -1;
  }
}

class Header {
  static int contentLength(String headerText) {
    for (final line in headerText.toLowerCase().split('\r\n')) {
      if (line.startsWith('content-length:')) {
        return int.tryParse(line.split(':')[1].trim()) ?? 0;
      }
    }
    return 0;
  }
}

class _RtspResponse {
  _RtspResponse({
    required this.statusLine,
    required this.headers,
    required this.bodyText,
  });

  factory _RtspResponse.parse(Uint8List bytes) {
    var headerEnd = -1;
    for (var i = 0; i + 4 <= bytes.length; i++) {
      if (bytes[i] == 0x0D &&
          bytes[i + 1] == 0x0A &&
          bytes[i + 2] == 0x0D &&
          bytes[i + 3] == 0x0A) {
        headerEnd = i;
        break;
      }
    }
    final headerEndIndex = headerEnd < 0 ? bytes.length : headerEnd;
    final headerText = utf8.decode(
      bytes.sublist(0, headerEndIndex),
      allowMalformed: true,
    );
    final lines = headerText
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        headers[line.substring(0, colon).trim().toLowerCase()] = line
            .substring(colon + 1)
            .trim();
      }
    }
    final body = utf8.decode(
      bytes.sublist((headerEnd < 0 ? bytes.length : headerEnd) + 4),
      allowMalformed: true,
    );
    return _RtspResponse(
      statusLine: lines.isEmpty ? '' : lines.first,
      headers: headers,
      bodyText: body,
    );
  }

  final String statusLine;
  final Map<String, String> headers;
  final String bodyText;

  String? header(String name) => headers[name.toLowerCase()];
}

class SdpAudioTrack {
  const SdpAudioTrack({required this.control, required this.payloadType});

  final String control;
  final int payloadType;

  /// Returns the audio media sections' control/payload-type pairs.
  static List<SdpAudioTrack> parseAll(String sdp) {
    final tracks = <SdpAudioTrack>[];
    var inAudio = false;
    String? control;
    int? payloadType;
    for (final rawLine in sdp.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('m=')) {
        if (inAudio && control != null && payloadType != null) {
          tracks.add(SdpAudioTrack(control: control, payloadType: payloadType));
        }
        inAudio = line.startsWith('m=audio');
        control = null;
        payloadType = null;
        continue;
      }
      if (!inAudio) continue;
      if (line.startsWith('a=control:')) {
        final value = line.substring('a=control:'.length).trim();
        if (value.isNotEmpty && value != '*') control = value;
      } else if (line.startsWith('a=rtpmap:')) {
        final parts = line
            .substring('a=rtpmap:'.length)
            .trim()
            .split(RegExp(r'\s+'));
        if (parts.isNotEmpty) payloadType = int.tryParse(parts.first);
      }
    }
    if (inAudio && control != null && payloadType != null) {
      tracks.add(SdpAudioTrack(control: control, payloadType: payloadType));
    }
    return tracks;
  }
}

class SdpVideoTrack {
  /// The video track's control name; `track1` is the macro-video default.
  static String controlFor(String sdp) {
    final media = RegExp(r'^m=video.*$', multiLine: true).firstMatch(sdp);
    if (media == null) return 'track1';
    final section = sdp.substring(media.start);
    final control = RegExp(
      r'^a=control:(.+)$',
      multiLine: true,
    ).firstMatch(section);
    final value = control?.group(1)?.trim();
    if (value == null || value.isEmpty || value == '*') return 'track1';
    return value;
  }
}

/// G.711 A-law encoding for 16-bit little-endian PCM (13-bit segment search).
class G711Alaw {
  G711Alaw._();

  static const _segmentEnds = <int>[
    0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF,
  ];

  /// Absolute decoded amplitude of one A-law byte, for level meters.
  static int decodeAmplitude(int encoded) {
    var value = encoded ^ 0x55;
    var amplitude = (value & 0x0F) << 4;
    final segment = (value >> 4) & 0x07;
    if (segment != 0) {
      amplitude += 0x108;
      amplitude <<= segment - 1;
    }
    return amplitude;
  }

  /// Encodes [pcm16] (little-endian, mono) into A-law bytes.
  static Uint8List encode16(Uint8List pcm16) {
    final out = Uint8List(pcm16.lengthInBytes ~/ 2);
    final data = ByteData.sublistView(pcm16);
    for (var i = 0; i < out.length; i++) {
      out[i] = encodeSample(data.getInt16(i * 2, Endian.little));
    }
    return out;
  }

  /// Encodes one sample. A-law's sign bit is inverted: positive samples get
  /// the 0xD5 mask (bit 7 set).
  static int encodeSample(int sample) {
    if (sample >= 0) return _encode(sample, 0xD5);
    return _encode(-sample, 0x55);
  }

  static int _encode(int magnitude, int mask) {
    var value = magnitude >> 3; // 16-bit PCM to 13-bit linear like G.711
    if (value > 0xFFF) value = 0xFFF;
    var segment = 0;
    while (segment < 8 && value > _segmentEnds[segment]) {
      segment++;
    }
    if (segment > 7) return 0x7F ^ mask;
    final nibble = segment < 2
        ? (value >> 1) & 0x0F
        : (value >> segment) & 0x0F;
    return ((segment << 4) | nibble) ^ mask;
  }
}

/// G.711 µ-law encoding for 16-bit little-endian PCM (Sun algorithm).
class G711Ulaw {
  G711Ulaw._();

  static Uint8List encode16(Uint8List pcm16) {
    final out = Uint8List(pcm16.lengthInBytes ~/ 2);
    final data = ByteData.sublistView(pcm16);
    for (var i = 0; i < out.length; i++) {
      out[i] = encodeSample(data.getInt16(i * 2, Endian.little));
    }
    return out;
  }

  static int encodeSample(int sample) {
    var value = sample;
    final sign = (value >> 8) & 0x80;
    if (sign != 0) value = -value;
    if (value > 32635) value = 32635;
    value += 0x84;
    var exponent = 7;
    var mask = 0x4000;
    while (exponent > 0 && (value & mask) == 0) {
      exponent--;
      mask >>= 1;
    }
    final mantissa = (value >> (exponent + 3)) & 0x0F;
    return ~(sign | (exponent << 4) | mantissa) & 0xFF;
  }
}
