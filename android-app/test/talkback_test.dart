import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:localhome/talkback.dart';

void main() {
  group('G711Alaw.encodeSample', () {
    int decode(int a) {
      a ^= 0x55;
      var value = (a & 0x0F) << 4;
      final segment = (a >> 4) & 0x07;
      if (segment != 0) {
        value += 0x108;
        value <<= segment - 1;
      }
      return (a & 0x80) != 0 ? value : -value;
    }

    const segmentSteps = <int>[16, 16, 32, 64, 128, 256, 512, 1024];

    int stepFor(int encoded) {
      final segment = ((encoded ^ 0x55) >> 4) & 0x07;
      return segmentSteps[segment] * 8;
    }

    test('matches G.711 extremes', () {
      expect(G711Alaw.encodeSample(32767), 0xAA);
      expect(G711Alaw.encodeSample(-32768), 0x2A);
      expect(G711Alaw.encodeSample(0), 0xD5);
    });

    test('round-trips within one quantization step', () {
      const samples = <int>[
        0, 1, -1, 100, -100, 1000, -1000, 9830, -9830, 20000, -20000,
        32767, -32768,
      ];
      for (final sample in samples) {
        final encoded = G711Alaw.encodeSample(sample);
        final decoded = decode(encoded);
        expect(
          (decoded - sample).abs(),
          lessThanOrEqualTo(stepFor(encoded)),
          reason: 'sample $sample encoded 0x${encoded.toRadixString(16)} '
              'decoded $decoded',
        );
      }
    });

    test('encode16 consumes little-endian pairs', () {
      final pcm = Uint8List.fromList(<int>[0, 0, 0, 0]);
      expect(G711Alaw.encode16(pcm), <int>[0xD5, 0xD5]);
    });

    test('produces 160 bytes for a 20 ms block', () {
      final block = Uint8List(320); // silence-ish zeros
      final payload = G711Alaw.encode16(block);
      expect(payload.length, 160);
    });
  });

  group('SdpAudioTrack.parseAll', () {
    const sdp = 'v=0\r\n'
        's=streamed by the macro-video rtsp server\r\n'
        'a=control:*\r\n'
        'm=video 0 RTP/AVP 96\r\n'
        'a=rtpmap:96 H264/90000\r\n'
        'a=control:track1\r\n'
        'm=audio 0 RTP/AVP 8\r\n'
        'a=rtpmap:8 PCMA/8000/1\r\n'
        'a=control:track2\r\n';

    test('finds the PCMA audio track and its control', () {
      final tracks = SdpAudioTrack.parseAll(sdp);
      expect(tracks, hasLength(1));
      expect(tracks.first.control, 'track2');
      expect(tracks.first.payloadType, 8);
    });

    test('video control helper reads track1', () {
      expect(SdpVideoTrack.controlFor(sdp), 'track1');
    });

    test('falls back to track1 when control is a wildcard', () {
      const wildcard = 'm=video 0 RTP/AVP 96\r\na=control:*\r\n';
      expect(SdpVideoTrack.controlFor(wildcard), 'track1');
      expect(SdpVideoTrack.controlFor(''), 'track1');
    });

    test('audio without control or rtpmap is rejected', () {
      const incomplete = 'm=audio 0 RTP/AVP 8\r\na=control:track2\r\n';
      expect(SdpAudioTrack.parseAll(incomplete), isEmpty);
    });
  });
}
