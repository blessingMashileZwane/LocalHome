import 'local_net.dart' as local_net;

class CameraEndpoint {
  const CameraEndpoint._();

  static Uri parse({required String address, required String path}) {
    if (!isPrivateIpv4(address)) {
      throw const FormatException(
        'Enter a numeric private IPv4 address (10/8, 172.16/12, or 192.168/16).',
      );
    }
    if (!_isRtspPath(path)) {
      throw const FormatException(
        'Enter the camera RTSP path beginning with /. Do not include a URL, '
        'credentials, port, query, or fragment.',
      );
    }

    final uri = Uri.parse('rtsp://$address:554$path');
    if (uri.scheme != 'rtsp' ||
        uri.host != address ||
        uri.port != 554 ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('The local RTSP address is not valid.');
    }
    return uri;
  }

  static bool isPrivateIpv4(String address) =>
      local_net.isPrivateIpv4(address);

  static bool _isRtspPath(String path) {
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('/../') ||
        path.endsWith('/..')) {
      return false;
    }
    return RegExp(r"^/[A-Za-z0-9._~!$&'()*+,;=:@/-]*$").hasMatch(path);
  }
}

bool isLiveRtspSeekError(String message) {
  return message.startsWith('Cannot seek in this stream') ||
      message.startsWith("You can force it with '--force-seekable=yes'");
}
