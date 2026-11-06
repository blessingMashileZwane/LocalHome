/// Direct-LAN talkback for HiMost/V380 cameras.
///
/// Establishes the camera's IOT session on TCP 8089 using the device LAN
/// password (QR field 8), then sends microphone audio as media frames
/// (`0x38030820`, sec=2) encoded as 8 kHz G.711 A-law. No vendor cloud is
/// used; the session key is derived locally with X25519.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;

const int _cmdIot = 0x38030818;
const int _cmdMedia = 0x38030820;
const int _methodLanpass = 196870;
const int _methodLiveCtrl = 197122;
const int _methodGetProps = 197376;
const int _methodEcho = 197120;
const int _frameSamples = 256;

const List<int> _staticKey = [
  0x36, 0x3a, 0xe5, 0x28, 0x16, 0x38, 0xcf, 0x84,
  0x96, 0x9a, 0x63, 0x4e, 0x9f, 0x96, 0x6a, 0x98,
  0xb5, 0x73, 0xd1, 0xff, 0xe9, 0x37, 0xb2, 0x77,
  0xd1, 0xf1, 0xd6, 0x2b, 0x38, 0x74, 0x8a, 0xe5,
];

class LanTalkException implements Exception {
  LanTalkException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LanTalkbackClient {
  LanTalkbackClient({
    required this.address,
    required this.password,
    this.port = 8089,
  });

  final String address;
  final String password;
  final int port;

  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  late final AesCbc _aes;
  Uint8List _key32 = Uint8List(32);
  int _sid = 0;
  final List<int> _audio = <int>[];
  final List<int> _incoming = <int>[];
  Completer<void>? _dataReady;
  bool _closed = false;
  bool _mediaUp = false;

  int framesSent = 0;
  int bytesSent = 0;
  int _pcmChunks = 0;
  int _peak = 0;
  int _mediaFramesIn = 0;

  Future<void> connect() async {
    debugPrint('lan talk: connecting to $address:$port');
    _aes = AesCbc.with128bits(macAlgorithm: MacAlgorithm.empty);
    final socket = await Socket.connect(
      address,
      port,
      timeout: const Duration(seconds: 5),
    );
    _socket = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);
    _subscription = socket.listen(
      (data) {
        _incoming.addAll(data);
        if (_mediaUp) {
          _drainFrames();
        } else if (_incoming.length > 65536) {
          _incoming.removeRange(0, _incoming.length - 65536);
        }
        _dataReady?.complete();
        _dataReady = null;
      },
      onError: (Object _) {},
      cancelOnError: false,
    );

    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final public = (await keyPair.extractPublicKey()).bytes;
    if (public.length != 32) {
      throw LanTalkException('Unexpected X25519 public key length.');
    }
    final magic = Random.secure().nextInt(126) + 1;
    final pkm = Uint8List.fromList([for (final byte in public) byte ^ magic]);
    final challenge = await Sha256().hash([...pkm, ...utf8.encode(password)]);

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final message = jsonEncode({
      'id': Random.secure().nextInt(0x7fffff),
      'method_id': _methodLanpass,
      'chn': 1,
      'ts': now,
      'params': {
        'act': 1,
        'verify': {
          'cKM': base64Encode(pkm),
          'cS': base64Encode(challenge.bytes),
          'tz': 200,
          'ts': now,
        },
      },
    });
    final body = await _encrypt(_staticKey, utf8.encode(message));
    await _writeFrame(_cmdIot, sec: 2, sid: 0, magic: magic, body: body);

    final reply = await _readFrame();
    var replyBody = reply.body;
    if (reply.secure == 2) {
      replyBody = await _decrypt(_staticKey, replyBody);
    }
    final parsed = jsonDecode(utf8.decode(replyBody)) as Map<String, dynamic>;
    final result = (parsed['result'] as Map?)?.cast<String, dynamic>();
    final code = result?['code'];
    if (code != 1000) {
      throw LanTalkException('Camera rejected the LAN password ($code).');
    }
    final data = (parsed['data'] as Map?)?.cast<String, dynamic>();
    final verify = (data?['verify'] as Map?)?.cast<String, dynamic>();
    final dk = verify?['dK'] as String?;
    final ds = verify?['dS'] as String?;
    final sid = verify?['sid'];
    if (dk == null || ds == null || sid is! int) {
      throw LanTalkException('Camera reply is missing session keys.');
    }
    final cameraKey = base64Decode(dk);
    final check = await Sha256().hash(cameraKey);
    if (base64Encode(check.bytes) != ds) {
      throw LanTalkException('Camera session key failed verification.');
    }
    final shared = await algorithm.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(cameraKey, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.length != 32) {
      throw LanTalkException('Unexpected session key length.');
    }
    _key32 = Uint8List.fromList(sharedBytes);
    _sid = sid;
    debugPrint('lan talk: session established sid=$_sid');
    if (kDebugMode) {
      debugPrint('lan talk key=${_key32.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
    }
    await _startMediaSession();
  }

  void _drainFrames() {
    var offset = 0;
    while (_incoming.length - offset >= 16) {
      final length =
          _incoming[offset + 12] |
          (_incoming[offset + 13] << 8) |
          (_incoming[offset + 14] << 16) |
          (_incoming[offset + 15] << 24);
      if (length < 0 || length > 200000 || _incoming.length - offset < 16 + length) {
        break;
      }
      offset += 16 + length;
      final cmd =
          _incoming[offset - 16 - length] |
          (_incoming[offset - 15 - length] << 8) |
          (_incoming[offset - 14 - length] << 16) |
          (_incoming[offset - 13 - length] << 24);
      if (cmd == _cmdMedia) {
        _mediaFramesIn += 1;
        if (_mediaFramesIn == 1 || _mediaFramesIn % 200 == 0) {
          debugPrint('lan talk: media frames in=$_mediaFramesIn');
        }
      }
      if (offset > 262144) break;
    }
    if (offset > 0) {
      _incoming.removeRange(0, offset);
    }
  }

  Future<void> _sendIot(int method, Map<String, Object?> params) async {
    final message = jsonEncode({
      'id': Random.secure().nextInt(0x7fffff),
      'method_id': method,
      'chn': 1,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'params': params,
    });
    final body = await _encrypt(_key32, utf8.encode(message));
    await _writeFrame(_cmdIot, sec: 2, sid: _sid, magic: 0, body: body);
  }

  Future<void> _startMediaSession() async {
    final tms = DateTime.now().millisecondsSinceEpoch & 0xffffffff;
    await _sendIot(_methodLiveCtrl, {
      'up': {'quality': 1, 'video': 1, 'audio': 0, 'IDRreq': 1},
    });
    await _sendIot(_methodGetProps, {
      'dplist': [393478, 1114368],
    });
    await _sendIot(_methodLiveCtrl, {
      'up': {'audio': 0},
    });
    await _sendIot(_methodEcho, {'flag': 2, 'tms1': tms, 'decode_tms': 0});
    await _sendIot(_methodGetProps, {
      'dplist': [262402, 721152, 721153, 65792],
    });
    await _sendIot(_methodLiveCtrl, {
      'down': {
        'aattr': {'codec': 103, 'samplerate': 16000, 'bits': 16, 'chns': 1},
      },
    });
    _mediaUp = true;
    debugPrint('lan talk: media session requested');
  }

  /// Sends 8 kHz mono PCM16 microphone audio to the camera speaker.
  void sendPcm16(Uint8List pcm) {
    if (_closed) return;
    _pcmChunks += 1;
    var peak = 0;
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      final sample = (pcm[i] | (pcm[i + 1] << 8)).toSigned(16);
      final abs = sample < 0 ? -sample : sample;
      if (abs > peak) peak = abs;
      _audio.add(_alawEncode(sample));
    }
    if (peak > _peak) _peak = peak;
    if (_pcmChunks == 1 || _pcmChunks % 100 == 0) {
      debugPrint(
        'lan talk: mic chunk $_pcmChunks (${pcm.length} B) '
        'peak=$peak max=$_peak frames=$framesSent mediaUp=$_mediaUp',
      );
    }
    while (_audio.length >= _frameSamples) {
      final frame = Uint8List.fromList(_audio.sublist(0, _frameSamples));
      _audio.removeRange(0, _frameSamples);
      unawaited(_sendAudio(frame));
    }
  }

  Future<void> _sendAudio(Uint8List alaw) async {
    final socket = _socket;
    if (socket == null || _closed) return;
    try {
      final iv = List<int>.generate(16, (_) => Random.secure().nextInt(256));
      final plain = Uint8List(16 + alaw.length);
      plain[7] = 1;
      plain.setRange(16, plain.length, alaw);
      final cipher = CBCBlockCipher(AESEngine())
        ..init(
          true,
          ParametersWithIV(
            KeyParameter(_key32.sublist(0, 16)),
            Uint8List.fromList(iv),
          ),
        );
      final ct = Uint8List(plain.length);
      for (var offset = 0; offset < plain.length; offset += 16) {
        cipher.processBlock(plain, offset, ct, offset);
      }
      final body = Uint8List.fromList([...iv, ...ct]);
      await _writeFrame(_cmdMedia, sec: 2, sid: _sid, magic: 0, body: body);
      framesSent += 1;
      bytesSent += alaw.length;
    } on Object catch (error) {
      debugPrint('lan talk: send failed: $error');
      unawaited(stop());
    }
  }

  Future<Uint8List> _encrypt(List<int> key32, List<int> plain) async {
    final box = await _aes.encrypt(
      plain,
      secretKey: SecretKey(key32.sublist(0, 16)),
      nonce: key32.sublist(16, 32),
    );
    return Uint8List.fromList(box.cipherText);
  }

  Future<Uint8List> _decrypt(List<int> key32, List<int> cipher) async {
    final clear = await _aes.decrypt(
      SecretBox(cipher, nonce: key32.sublist(16, 32), mac: Mac.empty),
      secretKey: SecretKey(key32.sublist(0, 16)),
    );
    return Uint8List.fromList(clear);
  }

  Future<void> _writeFrame(
    int cmd, {
    required int sec,
    required int sid,
    required int magic,
    required List<int> body,
  }) async {
    final socket = _socket;
    if (socket == null) throw LanTalkException('Socket is closed.');
    final header = ByteData(16)
      ..setUint32(0, cmd, Endian.little)
      ..setUint8(4, 1)
      ..setUint8(5, sec)
      ..setUint8(6, sid & 0xff)
      ..setUint8(7, magic & 0xff)
      ..setUint32(8, 0, Endian.little)
      ..setUint32(12, body.length, Endian.little);
    socket.add(header.buffer.asUint8List());
    socket.add(body);
    await socket.flush();
  }

  Future<_Frame> _readFrame() async {
    final header = await _readExact(16);
    final view = ByteData.sublistView(header);
    final cmd = view.getUint32(0, Endian.little);
    final sec = view.getUint8(5);
    final length = view.getUint32(12, Endian.little);
    final body = length == 0 ? Uint8List(0) : await _readExact(length);
    return _Frame(cmd, sec, body);
  }

  Future<Uint8List> _readExact(int size) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_incoming.length < size) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw LanTalkException('Connection lost while reading reply.');
      }
      final waiter = _dataReady ??= Completer<void>();
      await waiter.future.timeout(remaining, onTimeout: () {
        throw LanTalkException('Timed out reading camera reply.');
      });
    }
    final bytes = Uint8List.fromList(_incoming.sublist(0, size));
    _incoming.removeRange(0, size);
    return bytes;
  }

  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    final socket = _socket;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    await socket?.close();
  }
}

class _Frame {
  const _Frame(this.cmd, this.secure, this.body);

  final int cmd;
  final int secure;
  final Uint8List body;
}

const List<int> _segEnd = [
  0xFF, 0x1FF, 0x3FF, 0x7FF,
  0xFFF, 0x1FFF, 0x3FFF, 0x7FFF,
];

int _alawEncode(int sample) {
  var value = sample;
  var mask = 0xD5;
  if (value < 0) {
    mask = 0x55;
    value = -value - 1;
  }
  value >>= 3;
  if (value > 0x7FFF) value = 0x7FFF;
  var segment = 0;
  while (segment < 8 && value > _segEnd[segment]) {
    segment += 1;
  }
  if (segment >= 8) return 0x7F ^ mask;
  var aval = segment << 4;
  if (segment < 2) {
    aval |= (value >> 1) & 0x0F;
  } else {
    aval |= (value >> segment) & 0x0F;
  }
  return aval ^ mask;
}
