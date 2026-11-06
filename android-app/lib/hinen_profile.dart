import 'package:flutter/foundation.dart';

/// A saved Hinen PS300 profile.
///
/// The Tuya local key is deliberately not part of this model or its JSON. The
/// web panel reads the key from a protected env file; this app does not write
/// or store it.
@immutable
class HinenProfile {
  const HinenProfile({
    required this.id,
    required this.name,
    required this.address,
    this.productKey = '',
    this.model = '',
    this.deviceId = '',
    this.bridgeUrl = '',
  });

  final String id;
  final String name;
  final String address;
  final String productKey;
  final String model;
  final String deviceId;
  final String bridgeUrl;

  HinenProfile copyWith({
    String? name,
    String? address,
    String? productKey,
    String? model,
    String? deviceId,
    String? bridgeUrl,
  }) => HinenProfile(
    id: id,
    name: name ?? this.name,
    address: address ?? this.address,
    productKey: productKey ?? this.productKey,
    model: model ?? this.model,
    deviceId: deviceId ?? this.deviceId,
    bridgeUrl: bridgeUrl ?? this.bridgeUrl,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'productKey': productKey,
    'model': model,
    'deviceId': deviceId,
    'bridgeUrl': bridgeUrl,
  };

  factory HinenProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final address = json['address'];
    if (id is! String || name is! String || address is! String) {
      throw const FormatException('Hinen profile fields are invalid.');
    }
    final productKey = json['productKey'];
    final model = json['model'];
    final deviceId = json['deviceId'];
    final bridgeUrl = json['bridgeUrl'];
    return HinenProfile(
      id: id,
      name: name,
      address: address,
      productKey: productKey is String ? productKey : '',
      model: model is String ? model : '',
      deviceId: deviceId is String ? deviceId : '',
      bridgeUrl: bridgeUrl is String ? bridgeUrl : '',
    );
  }
}
