import 'package:flutter/foundation.dart';

/// A saved Xiaomi air purifier profile.
///
/// The device token is deliberately not part of this model or its JSON; it is
/// kept in [TokenStore] backed by the platform keystore.
@immutable
class AirPurifierProfile {
  const AirPurifierProfile({
    required this.id,
    required this.name,
    required this.address,
    this.modelId = '',
  });

  final String id;
  final String name;
  final String address;
  final String modelId;

  AirPurifierProfile copyWith({
    String? name,
    String? address,
    String? modelId,
  }) => AirPurifierProfile(
    id: id,
    name: name ?? this.name,
    address: address ?? this.address,
    modelId: modelId ?? this.modelId,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'modelId': modelId,
  };

  factory AirPurifierProfile.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final address = json['address'];
    if (id is! String || name is! String || address is! String) {
      throw const FormatException('Purifier profile fields are invalid.');
    }
    final modelId = json['modelId'];
    return AirPurifierProfile(
      id: id,
      name: name,
      address: address,
      modelId: modelId is String ? modelId : '',
    );
  }
}
