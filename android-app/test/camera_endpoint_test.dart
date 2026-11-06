import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/camera_endpoint.dart';

void main() {
  group('CameraEndpoint.isPrivateIpv4', () {
    test('accepts RFC1918 address ranges', () {
      expect(CameraEndpoint.isPrivateIpv4('10.0.0.1'), isTrue);
      expect(CameraEndpoint.isPrivateIpv4('172.16.0.1'), isTrue);
      expect(CameraEndpoint.isPrivateIpv4('172.31.255.254'), isTrue);
      expect(CameraEndpoint.isPrivateIpv4('192.168.1.20'), isTrue);
      expect(CameraEndpoint.isPrivateIpv4('192.168.1.101'), isTrue);
      expect(CameraEndpoint.isPrivateIpv4('192.168.1.102'), isTrue);
    });

    test('rejects non-private, non-numeric and ambiguous addresses', () {
      expect(CameraEndpoint.isPrivateIpv4('172.15.0.1'), isFalse);
      expect(CameraEndpoint.isPrivateIpv4('172.32.0.1'), isFalse);
      expect(CameraEndpoint.isPrivateIpv4('192.167.1.20'), isFalse);
      expect(CameraEndpoint.isPrivateIpv4('8.8.8.8'), isFalse);
      expect(CameraEndpoint.isPrivateIpv4('camera.local'), isFalse);
      expect(CameraEndpoint.isPrivateIpv4('::1'), isFalse);
      expect(CameraEndpoint.isPrivateIpv4('192.168.001.20'), isFalse);
      expect(CameraEndpoint.isPrivateIpv4('192.168.1.256'), isFalse);
    });
  });

  group('CameraEndpoint.parse', () {
    test('builds a direct RTSP URI on the verified camera port', () {
      expect(
        CameraEndpoint.parse(
          address: '192.168.1.20',
          path: '/live/ch00_0',
        ).toString(),
        'rtsp://192.168.1.20:554/live/ch00_0',
      );
    });

    test('rejects missing path, URL authority, and query or fragment', () {
      expect(
        () => CameraEndpoint.parse(address: '192.168.1.20', path: ''),
        throwsFormatException,
      );
      expect(
        () => CameraEndpoint.parse(
          address: '192.168.1.20',
          path: '//outside.example/live',
        ),
        throwsFormatException,
      );
      expect(
        () => CameraEndpoint.parse(
          address: '192.168.1.20',
          path: '/live?channel=1',
        ),
        throwsFormatException,
      );
      expect(
        () => CameraEndpoint.parse(
          address: '192.168.1.20',
          path: '/live#fragment',
        ),
        throwsFormatException,
      );
    });
  });

  group('isLiveRtspSeekError', () {
    test('recognizes known non-fatal live-stream seek messages', () {
      expect(isLiveRtspSeekError('Cannot seek in this stream.'), isTrue);
      expect(
        isLiveRtspSeekError("You can force it with '--force-seekable=yes'."),
        isTrue,
      );
    });

    test('does not hide unrelated stream errors', () {
      expect(isLiveRtspSeekError('Connection refused'), isFalse);
    });
  });
}
