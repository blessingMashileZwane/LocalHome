import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/onvif_ptz.dart';

const _capabilities = '''
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
  xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Body><tds:GetCapabilitiesResponse xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
    <tt:Capabilities>
      <tt:Media><tt:XAddr>http://192.168.1.100:8899/onvif/media_service</tt:XAddr></tt:Media>
      <tt:PTZ><tt:XAddr>http://192.168.1.100:8899/onvif/ptz_service</tt:XAddr></tt:PTZ>
    </tt:Capabilities>
  </tds:GetCapabilitiesResponse></s:Body>
</s:Envelope>
''';

const _profiles = '''
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
  xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
  xmlns:tt="http://www.onvif.org/ver10/schema">
  <s:Body><trt:GetProfilesResponse>
    <trt:Profiles token="PROFILE_NO_PTZ"><tt:Name>Live</tt:Name></trt:Profiles>
    <trt:Profiles token="PROFILE_PTZ"><tt:PTZConfiguration token="PTZCFG"/></trt:Profiles>
  </trt:GetProfilesResponse></s:Body>
</s:Envelope>
''';

const _ok = '''
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Body><tptz:Response xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"/></s:Body>
</s:Envelope>
''';

void main() {
  group('OnvifPtzClient', () {
    test('discovers local services, uses a PTZ profile, and stops', () async {
      final calls = <(Uri, String)>[];
      final client = OnvifPtzClient(
        address: '192.168.1.100',
        transport: (endpoint, body) async {
          calls.add((endpoint, body));
          if (body.contains('GetCapabilities')) return _capabilities;
          if (body.contains('GetProfiles')) return _profiles;
          return _ok;
        },
      );

      await client.move(pan: 0.15, tilt: 0);
      await client.stop();

      expect(calls, hasLength(4));
      expect(calls[0].$1.path, '/onvif/device_service');
      expect(calls[1].$1.path, '/onvif/media_service');
      expect(calls[2].$1.path, '/onvif/ptz_service');
      expect(calls[2].$2, contains('<tptz:ProfileToken>PROFILE_PTZ</tptz:ProfileToken>'));
      expect(calls[2].$2, contains('x="0.15" y="0.00"'));
      expect(calls[2].$2, contains('<tptz:Timeout>PT0.8S</tptz:Timeout>'));
      expect(calls[3].$1.path, '/onvif/ptz_service');
      expect(calls[3].$2, contains('<tptz:Stop>'));
      client.close();
    });

    test('rejects a service URL that points away from the camera', () async {
      var calls = 0;
      final client = OnvifPtzClient(
        address: '192.168.1.100',
        transport: (endpoint, body) async {
          calls++;
          return _capabilities.replaceAll(
            'http://192.168.1.100:8899/onvif/ptz_service',
            'http://example.com/onvif/ptz_service',
          );
        },
      );

      await expectLater(
        client.initialize(),
        throwsA(
          isA<OnvifPtzException>().having(
            (error) => error.message,
            'message',
            contains('unsupported PTZ endpoint'),
          ),
        ),
      );
      expect(calls, 1);
      client.close();
    });

    test('rejects non-private addresses before sending a request', () async {
      var calls = 0;
      final client = OnvifPtzClient(
        address: '8.8.8.8',
        transport: (endpoint, body) async {
          calls++;
          return _capabilities;
        },
      );

      await expectLater(
        client.initialize(),
        throwsA(isA<OnvifPtzException>()),
      );
      expect(calls, 0);
      client.close();
    });

    test('rejects movement above the conservative velocity limit', () async {
      var calls = 0;
      final client = OnvifPtzClient(
        address: '192.168.1.100',
        transport: (endpoint, body) async {
          calls++;
          if (body.contains('GetCapabilities')) return _capabilities;
          return _profiles;
        },
      );

      await expectLater(
        client.move(pan: 0.16, tilt: 0),
        throwsA(
          isA<OnvifPtzException>().having(
            (error) => error.message,
            'message',
            contains('safe speed limit'),
          ),
        ),
      );
      expect(calls, 2);
      client.close();
    });
  });
}
