import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'camera_endpoint.dart';

typedef OnvifSoapTransport = Future<String> Function(Uri endpoint, String body);

class OnvifPtzException implements Exception {
  const OnvifPtzException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OnvifPtzClient {
  OnvifPtzClient({
    required this.address,
    OnvifSoapTransport? transport,
  }) : _transport = transport;

  static const _port = 8899;
  static const _schemaNamespace = 'http://www.onvif.org/ver10/schema';
  static const _mediaNamespace = 'http://www.onvif.org/ver10/media/wsdl';
  static const _deviceEndpointPath = '/onvif/device_service';
  static const _maximumResponseBytes = 32 * 1024;
  static const _velocityLimit = 0.15;

  final String address;
  final OnvifSoapTransport? _transport;
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..maxConnectionsPerHost = 1;

  Future<void>? _initialization;
  Uri? _ptzEndpoint;
  String? _profileToken;
  bool _closed = false;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!CameraEndpoint.isPrivateIpv4(address)) {
      throw const OnvifPtzException(
        'PTZ requires a numeric private IPv4 camera address.',
      );
    }

    final deviceEndpoint = Uri(
      scheme: 'http',
      host: address,
      port: _port,
      path: _deviceEndpointPath,
    );
    final capabilities = await _postSoap(
      deviceEndpoint,
      '''<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>''',
    );
    final ptzService = _serviceAddress(capabilities, 'PTZ');
    final mediaService = _serviceAddress(capabilities, 'Media');
    final profiles = await _postSoap(
      mediaService,
      '<trt:GetProfiles/>',
    );
    final token = _profileTokenFromProfiles(profiles);

    _ptzEndpoint = ptzService;
    _profileToken = token;
  }

  Future<void> move({required double pan, required double tilt}) async {
    await initialize();
    if (_closed) {
      throw const OnvifPtzException('The PTZ connection is closed.');
    }
    if (pan.abs() > _velocityLimit || tilt.abs() > _velocityLimit) {
      throw const OnvifPtzException('PTZ movement exceeds the safe speed limit.');
    }
    final token = _escapeXml(_profileToken!);
    await _postSoap(
      _ptzEndpoint!,
      '''<tptz:ContinuousMove>
        <tptz:ProfileToken>$token</tptz:ProfileToken>
        <tptz:Velocity>
          <tt:PanTilt x="${pan.toStringAsFixed(2)}" y="${tilt.toStringAsFixed(2)}"/>
        </tptz:Velocity>
        <tptz:Timeout>PT0.8S</tptz:Timeout>
      </tptz:ContinuousMove>''',
    );
  }

  Future<void> stop() async {
    await initialize();
    if (_closed) {
      throw const OnvifPtzException('The PTZ connection is closed.');
    }
    await _postSoap(
      _ptzEndpoint!,
      '''<tptz:Stop>
        <tptz:ProfileToken>${_escapeXml(_profileToken!)}</tptz:ProfileToken>
        <tptz:PanTilt>true</tptz:PanTilt>
        <tptz:Zoom>false</tptz:Zoom>
      </tptz:Stop>''',
    );
  }

  void close() {
    _closed = true;
    _httpClient.close(force: true);
  }

  Uri _serviceAddress(String response, String serviceName) {
    final document = _parseXml(response);
    final service = document
        .findAllElements(serviceName, namespace: _schemaNamespace)
        .firstOrNull;
    final addressText = service
        ?.findElements('XAddr', namespace: _schemaNamespace)
        .firstOrNull
        ?.innerText
        .trim();
    if (addressText == null || addressText.isEmpty) {
      throw OnvifPtzException('Camera did not advertise its $serviceName service.');
    }

    final endpoint = Uri.tryParse(addressText);
    if (endpoint == null ||
        endpoint.scheme != 'http' ||
        endpoint.host != address ||
        endpoint.port != _port ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.path.isEmpty ||
        endpoint.query.isNotEmpty ||
        endpoint.fragment.isNotEmpty) {
      throw OnvifPtzException(
        'Camera advertised an unsupported $serviceName endpoint.',
      );
    }
    return endpoint;
  }

  String _profileTokenFromProfiles(String response) {
    final document = _parseXml(response);
    final profiles = document.findAllElements(
      'Profiles',
      namespace: _mediaNamespace,
    );
    for (final profile in profiles) {
      final supportsPtz = profile
          .findElements('PTZConfiguration', namespace: _schemaNamespace)
          .isNotEmpty;
      final token = profile.getAttribute('token');
      if (supportsPtz && token != null && token.isNotEmpty) return token;
    }
    throw const OnvifPtzException(
      'Camera did not return a usable PTZ profile.',
    );
  }

  XmlDocument _parseXml(String response) {
    try {
      final document = XmlDocument.parse(response);
      if (document.findAllElements('Fault').isNotEmpty) {
        throw const OnvifPtzException('Camera rejected the ONVIF request.');
      }
      return document;
    } on XmlException {
      throw const OnvifPtzException('Camera returned an invalid ONVIF response.');
    }
  }

  Future<String> _postSoap(Uri endpoint, String operation) async {
    if (_closed) {
      throw const OnvifPtzException('The PTZ connection is closed.');
    }
    final body = '''<?xml version="1.0" encoding="UTF-8"?>
      <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
        xmlns:tds="http://www.onvif.org/ver10/device/wsdl"
        xmlns:trt="http://www.onvif.org/ver10/media/wsdl"
        xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"
        xmlns:tt="$_schemaNamespace">
        <s:Body>$operation</s:Body>
      </s:Envelope>''';

    try {
      final transport = _transport;
      final response = transport == null
          ? await _sendHttp(endpoint, body)
          : await transport(endpoint, body);
      if (utf8.encode(response).length > _maximumResponseBytes) {
        throw const OnvifPtzException('Camera ONVIF response is too large.');
      }
      _parseXml(response);
      return response;
    } on OnvifPtzException {
      rethrow;
    } on SocketException {
      throw const OnvifPtzException(
        'Could not reach the camera ONVIF service on port 8899.',
      );
    } on HttpException {
      throw const OnvifPtzException('Camera returned an ONVIF transport error.');
    } on TimeoutException {
      throw const OnvifPtzException('Camera ONVIF request timed out.');
    }
  }

  Future<String> _sendHttp(Uri endpoint, String body) async {
    final request = await _httpClient.postUrl(endpoint).timeout(
      const Duration(seconds: 4),
    );
    request.followRedirects = false;
    request.headers.contentType = ContentType(
      'application',
      'soap+xml',
      charset: 'utf-8',
    );
    request.contentLength = utf8.encode(body).length;
    request.write(body);
    final response = await request.close().timeout(
      const Duration(seconds: 4),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw const OnvifPtzException(
        'Camera rejected the ONVIF request. Check PTZ support and permissions.',
      );
    }

    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 4))) {
      if (bytes.length + chunk.length > _maximumResponseBytes) {
        throw const OnvifPtzException('Camera ONVIF response is too large.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
