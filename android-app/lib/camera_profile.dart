import 'package:flutter/foundation.dart';

@immutable
class CameraProfile {
  const CameraProfile({
    required this.id,
    required this.name,
    required this.address,
    required this.path,
    this.lanPassword = '',
  });

  final String id;
  final String name;
  final String address;
  final String path;

  /// Device LAN password (field 8 of the camera QR), used for local talkback.
  final String lanPassword;

  CameraProfile copyWith({
    String? name,
    String? address,
    String? path,
    String? lanPassword,
  }) => CameraProfile(
    id: id,
    name: name ?? this.name,
    address: address ?? this.address,
    path: path ?? this.path,
    lanPassword: lanPassword ?? this.lanPassword,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'path': path,
    'lanPassword': lanPassword,
  };

  factory CameraProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final address = json['address'];
    final path = json['path'];
    if (id is! String ||
        name is! String ||
        address is! String ||
        path is! String) {
      throw const FormatException('Camera profile fields are invalid.');
    }
    final lanPassword = json['lanPassword'];
    return CameraProfile(
      id: id,
      name: name,
      address: address,
      path: path,
      lanPassword: lanPassword is String ? lanPassword : '',
    );
  }
}
