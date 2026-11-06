/// Authenticated local IOT session for HiMost/V380 cameras.
///
/// Opens TCP 8089, performs the X25519 LAN password exchange (LANPASS), and
/// sends AES-CBC encrypted method requests. No vendor cloud is used.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;

import 'camera_endpoint.dart';

const int lanIotCommand = 0x38030818;
const int methodLanpass = 196870;
const int methodGetProperties = 197376;
const int methodSetProperties = 197378;

const List<int> lanIotStaticKey = [
  0x36,
  0x3a,
  0xe5,
  0x28,
  0x16,
  0x38,
  0xcf,
  0x84,
  0x96,
  0x9a,
  0x63,
  0x4e,
  0x9f,
  0x96,
  0x6a,
  0x98,
  0xb5,
  0x73,
  0xd1,
  0xff,
  0xe9,
  0x37,
  0xb2,
  0x77,
  0xd1,
  0xf1,
  0xd6,
  0x2b,
  0x38,
  0x74,
  0x8a,
  0xe5,
];

class LanIotException implements Exception {
  const LanIotException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}

/// Minimal request interface used by feature clients. [LanIotSession] is the
/// production implementation; tests provide a fake implementation.
abstract class LanIotClient {
  Future<void> connect();
  Future<Map<String, dynamic>> getProperties(List<int> dpids);
  Future<Map<String, dynamic>> setProperties(
    List<(int dpid, Object value)> entries,
  );
  Future<void> close();
}

/// Byte transport used by [LanIotSession]. The socket implementation is the
/// production path; tests provide an in-memory implementation.
abstract class LanIotTransport {
  Future<void> connect();
  void add(List<int> bytes);
  Future<void> flush();
  Future<Uint8List> readExact(int size);
  Future<void> close();
}

typedef LanIotTransportFactory =
    Future<LanIotTransport> Function(String address, int port);

Future<LanIotTransport> _connectSocket(String address, int port) async {
  final socket = await Socket.connect(
    address,
    port,
    timeout: const Duration(seconds: 5),
  );
  socket.setOption(SocketOption.tcpNoDelay, true);
  return _SocketLanIotTransport(socket);
}

class _SocketLanIotTransport implements LanIotTransport {
  _SocketLanIotTransport(this._socket);

  final Socket _socket;
  final List<int> _incoming = [];
  final List<Object> _errors = [];
  Completer<void>? _dataReady;
  late final StreamSubscription<Uint8List> _subscription;

  @override
  Future<void> connect() async {
    _subscription = _socket.listen(
      (data) {
        _incoming.addAll(data);
        _dataReady?.complete();
        _dataReady = null;
      },
      onError: (Object error) {
        _errors.add(error);
        _dataReady?.complete();
        _dataReady = null;
      },
      onDone: () {
        _errors.add(
          const LanIotException('The camera closed the local session.'),
        );
        _dataReady?.complete();
        _dataReady = null;
      },
      cancelOnError: false,
    );
  }

  @override
  void add(List<int> bytes) {
    _socket.add(bytes);
  }

  @override
  Future<void> flush() => _socket.flush();

  @override
  Future<Uint8List> readExact(int size) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_incoming.length < size) {
      if (_errors.isNotEmpty) {
        throw LanIotException('The camera closed the local session.');
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw const LanIotException('Timed out waiting for the camera.');
      }
      final waiter = _dataReady ??= Completer<void>();
      await waiter.future.timeout(
        remaining,
        onTimeout: () {
          throw const LanIotException('Timed out waiting for the camera.');
        },
      );
    }
    final bytes = Uint8List.fromList(_incoming.sublist(0, size));
    _incoming.removeRange(0, size);
    return bytes;
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}

class _IotFrame {
  const _IotFrame(this.command, this.secure, this.body);

  final int command;
  final int secure;
  final Uint8List body;
}

/// One authenticated LAN IOT session. Requests are serialized by the caller.
class LanIotSession implements LanIotClient {
  LanIotSession({
    required this.address,
    required this.password,
    this.port = 8089,
    LanIotTransportFactory? transportFactory,
  }) : _transportFactory = transportFactory ?? _connectSocket;

  final String address;
  final String password;
  final int port;
  final LanIotTransportFactory _transportFactory;

  LanIotTransport? _transport;
  Uint8List _key32 = Uint8List(32);
  int _sessionId = 0;
  int _requestId = 0;
  bool _closed = false;

  @override
  Future<void> connect() async {
    if (!CameraEndpoint.isPrivateIpv4(address)) {
      throw const LanIotException(
        'Light control requires a numeric private IPv4 camera address.',
      );
    }
    if (password.isEmpty) {
      throw const LanIotException(
        'Set the camera LAN password (QR field 8) in Edit camera first.',
      );
    }
    late final LanIotTransport transport;
    try {
      transport = await _transportFactory(address, port);
      await transport.connect();
    } on SocketException {
      throw const LanIotException('Could not reach the camera on port 8089.');
    } on TimeoutException {
      throw const LanIotException('Timed out connecting to the camera.');
    }
    _transport = transport;

    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final public = (await keyPair.extractPublicKey()).bytes;
    if (public.length != 32) {
      throw const LanIotException('Unexpected local key length.');
    }
    final magic = Random.secure().nextInt(126) + 1;
    final pkm = Uint8List.fromList([for (final byte in public) byte ^ magic]);
    final challenge = await Sha256().hash([...pkm, ...utf8.encode(password)]);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final message = jsonEncode({
      'id': _nextRequestId(),
      'method_id': methodLanpass,
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
    final body = await _encrypt(lanIotStaticKey, utf8.encode(message));
    await _writeFrame(
      lanIotCommand,
      secure: 2,
      sid: 0,
      magic: magic,
      body: body,
    );

    final reply = await _readFrame();
    var replyBody = reply.body;
    if (reply.secure == 2) {
      replyBody = await _decrypt(lanIotStaticKey, replyBody);
    }
    final parsed = _parseJson(replyBody);
    final result = (parsed['result'] as Map?)?.cast<String, dynamic>();
    final code = result?['code'];
    if (code != 1000) {
      throw LanIotException(
        _resultMessage(code, 'The camera rejected the LAN password.'),
        code: code is int ? code : null,
      );
    }
    final data = (parsed['data'] as Map?)?.cast<String, dynamic>();
    final verify = (data?['verify'] as Map?)?.cast<String, dynamic>();
    final dk = verify?['dK'] as String?;
    final ds = verify?['dS'] as String?;
    final sid = verify?['sid'];
    if (dk == null || ds == null || sid is! int) {
      throw const LanIotException('Camera reply is missing session keys.');
    }
    final cameraKey = base64Decode(dk);
    if (cameraKey.length != 32) {
      throw const LanIotException('Camera session key has an invalid length.');
    }
    final check = await Sha256().hash(cameraKey);
    if (base64Encode(check.bytes) != ds) {
      throw const LanIotException('Camera session key failed verification.');
    }
    final shared = await algorithm.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(cameraKey, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.length != 32) {
      throw const LanIotException('Unexpected session key length.');
    }
    _key32 = Uint8List.fromList(sharedBytes);
    _sessionId = sid;
  }

  Future<Map<String, dynamic>> request(
    int method,
    Map<String, Object?> params,
  ) async {
    await _send(method, params);
    final reply = await _readFrame();
    var body = reply.body;
    if (reply.secure == 2) {
      body = await _decrypt(_key32, body);
    }
    final parsed = _parseJson(body);
    final result = (parsed['result'] as Map?)?.cast<String, dynamic>();
    final code = result?['code'];
    if (code != 1000) {
      throw LanIotException(
        _resultMessage(code, 'The camera rejected the request.'),
        code: code is int ? code : null,
      );
    }
    return parsed;
  }

  @override
  Future<Map<String, dynamic>> getProperties(List<int> dpids) {
    return request(methodGetProperties, {'dplist': dpids});
  }

  @override
  Future<Map<String, dynamic>> setProperties(
    List<(int dpid, Object value)> entries,
  ) {
    return request(methodSetProperties, {
      'dplist': [
        for (final (dpid, value) in entries) {'dpid': dpid, 'value': value},
      ],
    });
  }

  Future<void> _send(int method, Map<String, Object?> params) async {
    final message = jsonEncode({
      'id': _nextRequestId(),
      'method_id': method,
      'chn': 1,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'params': params,
    });
    final body = await _encrypt(_key32, utf8.encode(message));
    await _writeFrame(
      lanIotCommand,
      secure: 2,
      sid: _sessionId,
      magic: 0,
      body: body,
    );
  }

  int _nextRequestId() {
    _requestId = (_requestId + 1) & 0x7fffff;
    if (_requestId == 0) _requestId = 1;
    return _requestId;
  }

  Future<void> _writeFrame(
    int command, {
    required int secure,
    required int sid,
    required int magic,
    required List<int> body,
  }) async {
    final transport = _transport;
    if (transport == null || _closed) {
      throw const LanIotException('The local session is closed.');
    }
    final header = ByteData(16)
      ..setUint32(0, command, Endian.little)
      ..setUint8(4, 1)
      ..setUint8(5, secure)
      ..setUint8(6, sid & 0xff)
      ..setUint8(7, magic & 0xff)
      ..setUint32(8, 0, Endian.little)
      ..setUint32(12, body.length, Endian.little);
    try {
      transport.add(header.buffer.asUint8List());
      transport.add(body);
      await transport.flush();
    } on SocketException {
      throw const LanIotException('The camera closed the local session.');
    }
  }

  Future<_IotFrame> _readFrame() async {
    final transport = _transport;
    if (transport == null || _closed) {
      throw const LanIotException('The local session is closed.');
    }
    final header = await transport.readExact(16);
    final view = ByteData.sublistView(header);
    final command = view.getUint32(0, Endian.little);
    final secure = view.getUint8(5);
    final length = view.getUint32(12, Endian.little);
    if (length > 200000) {
      throw const LanIotException('Camera sent an invalid frame length.');
    }
    final body = length == 0 ? Uint8List(0) : await transport.readExact(length);
    return _IotFrame(command, secure, body);
  }

  Future<Uint8List> _encrypt(List<int> key32, List<int> plain) async {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV(
          KeyParameter(Uint8List.fromList(key32.sublist(0, 16))),
          Uint8List.fromList(key32.sublist(16, 32)),
        ),
      );
    final padded = _pkcs7Pad(plain);
    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += 16) {
      cipher.processBlock(padded, offset, out, offset);
    }
    return out;
  }

  Future<Uint8List> _decrypt(List<int> key32, Uint8List cipherText) async {
    if (cipherText.isEmpty || cipherText.length % 16 != 0) {
      throw const LanIotException('Camera sent an invalid encrypted body.');
    }
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        false,
        ParametersWithIV(
          KeyParameter(Uint8List.fromList(key32.sublist(0, 16))),
          Uint8List.fromList(key32.sublist(16, 32)),
        ),
      );
    final out = Uint8List(cipherText.length);
    for (var offset = 0; offset < cipherText.length; offset += 16) {
      cipher.processBlock(cipherText, offset, out, offset);
    }
    return _pkcs7Unpad(out);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _transport?.close();
    _transport = null;
  }
}

Map<String, dynamic> _parseJson(Uint8List body) {
  try {
    final parsed = jsonDecode(utf8.decode(body));
    if (parsed is Map) return parsed.cast<String, dynamic>();
  } on FormatException {
    // Fall through to the protocol error below.
  }
  throw const LanIotException('Camera sent an invalid JSON reply.');
}

String _resultMessage(int? code, String fallback) {
  return switch (code) {
    1110 => 'The camera does not allow this operation over LAN.',
    1114 => 'This camera does not expose that property.',
    1119 => 'The camera rejected the LAN session.',
    _ => fallback,
  };
}

Uint8List _pkcs7Pad(List<int> data) {
  final padLength = 16 - (data.length % 16);
  final out = Uint8List(data.length + padLength);
  out.setRange(0, data.length, data);
  out.fillRange(data.length, out.length, padLength);
  return out;
}

Uint8List _pkcs7Unpad(Uint8List data) {
  if (data.isEmpty) return data;
  final padLength = data.last;
  if (padLength < 1 || padLength > 16 || padLength > data.length) {
    throw const LanIotException('Camera sent invalid padding.');
  }
  for (var i = data.length - padLength; i < data.length; i++) {
    if (data[i] != padLength) {
      throw const LanIotException('Camera sent invalid padding.');
    }
  }
  return Uint8List.sublistView(data, 0, data.length - padLength);
}
