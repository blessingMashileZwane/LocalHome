import 'package:flutter/foundation.dart';

/// A read-only Hinen PS300 snapshot.
///
/// Every reading is nullable until a local read succeeds and the DP is mapped.
/// [unsupported] is the honest initial state: no fake values, no controls, no
/// cloud fallback.
@immutable
class HinenStatus {
  const HinenStatus({
    required this.localConfirmed,
    this.model,
    this.firmware,
    this.batteryPercent,
    this.inputWatts,
    this.outputWatts,
    this.remainingMinutes,
    this.standbySeconds,
    this.switch1,
    this.switch2,
    this.beep,
    this.lightMode,
    this.chargingPacks,
    this.acChargeLimitPercent,
    this.vehicleChargeCurrentA,
    this.fastCharging,
    this.keystrokeSound,
    this.acOn,
    this.dcOn,
    this.usbOn,
    this.temperatureC,
    this.alerts = const [],
    this.dps = const {},
    this.receivedAt,
  });

  final bool localConfirmed;
  final String? model;
  final String? firmware;
  final int? batteryPercent;
  final double? inputWatts;
  final double? outputWatts;
  final int? remainingMinutes;
  final int? standbySeconds;
  final bool? switch1;
  final bool? switch2;
  final bool? beep;
  final int? lightMode;
  final int? chargingPacks;
  final int? acChargeLimitPercent;
  final int? vehicleChargeCurrentA;
  final bool? fastCharging;
  final bool? keystrokeSound;
  final bool? acOn;
  final bool? dcOn;
  final bool? usbOn;
  final double? temperatureC;
  final List<String> alerts;

  /// Raw Tuya data points, keyed by DP id.
  final Map<int, Object?> dps;
  final DateTime? receivedAt;

  static const unsupported = HinenStatus(localConfirmed: false);

  static const double baseCapacityWh = 2560;
  static const double packCapacityWh = 2560;

  bool get hasReadings => dps.isNotEmpty;

  double get capacityWithoutPackWh => baseCapacityWh;

  double? get capacityWithPacksWh {
    final packs = chargingPacks;
    if (packs == null) return null;
    return baseCapacityWh + packs * packCapacityWh;
  }

  double? get remainingWhWithoutPack {
    final percent = batteryPercent;
    if (percent == null) return null;
    return baseCapacityWh * percent / 100;
  }

  double? get remainingWhWithPacks {
    final capacity = capacityWithPacksWh;
    final percent = batteryPercent;
    if (capacity == null || percent == null) return null;
    return capacity * percent / 100;
  }

  /// Maps the DPs confirmed against the target unit.
  ///
  /// DP 1 is battery percentage, DP 6/7 are the two local switches, DP 25 is
  /// the beep, and DP 26 is the device standby time in seconds. DPs 105-116
  /// remain raw until their product specification is confirmed.
  factory HinenStatus.fromDps(
    Map<int, Object?> dps, {
    String? model,
    String? firmware,
    DateTime? receivedAt,
  }) {
    return HinenStatus(
      localConfirmed: true,
      model: model,
      firmware: firmware,
      batteryPercent: _int(dps[1]),
      switch1: _bool(dps[6]),
      switch2: _bool(dps[7]),
      beep: _bool(dps[25]),
      lightMode: _int(dps[113]),
      chargingPacks: _int(dps[116]),
      acChargeLimitPercent: _int(dps[105]),
      vehicleChargeCurrentA: _int(dps[106]),
      fastCharging: _bool(dps[107]),
      keystrokeSound: _bool(dps[108]),
      standbySeconds: _int(dps[26]),
      outputWatts: _double(dps[117]),
      dps: Map<int, Object?>.unmodifiable(dps),
      receivedAt: receivedAt ?? DateTime.now(),
    );
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static bool? _bool(Object? value) {
    if (value is bool) return value;
    return null;
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
