import 'package:flutter_test/flutter_test.dart';
import 'package:localhome/hinen_status.dart';

void main() {
  test('unsupported status has no fake readings', () {
    const status = HinenStatus.unsupported;
    expect(status.localConfirmed, isFalse);
    expect(status.hasReadings, isFalse);
    expect(status.batteryPercent, isNull);
    expect(status.inputWatts, isNull);
    expect(status.outputWatts, isNull);
    expect(status.remainingMinutes, isNull);
    expect(status.standbySeconds, isNull);
    expect(status.switch1, isNull);
    expect(status.switch2, isNull);
    expect(status.beep, isNull);
    expect(status.acOn, isNull);
    expect(status.dcOn, isNull);
    expect(status.usbOn, isNull);
    expect(status.temperatureC, isNull);
    expect(status.alerts, isEmpty);
    expect(status.dps, isEmpty);
    expect(status.receivedAt, isNull);
  });

  test('read-only readings keep nullable fields and raw DPs', () {
    final receivedAt = DateTime(2026, 10, 31, 17);
    final status = HinenStatus(
      localConfirmed: true,
      model: 'PS300',
      firmware: '1.0.0',
      batteryPercent: 74,
      inputWatts: 0,
      outputWatts: 31.5,
      remainingMinutes: 280,
      standbySeconds: 7200,
      switch1: false,
      switch2: true,
      beep: false,
      acOn: true,
      dcOn: false,
      usbOn: null,
      temperatureC: 24.5,
      alerts: const ['BMS nominal'],
      dps: const {1: 74, 2: 31.5},
      receivedAt: receivedAt,
    );

    expect(status.localConfirmed, isTrue);
    expect(status.hasReadings, isTrue);
    expect(status.batteryPercent, 74);
    expect(status.usbOn, isNull);
    expect(status.dps[1], 74);
    expect(status.receivedAt, receivedAt);
  });

  test('fromDps maps the confirmed PS300 data points', () {
    final receivedAt = DateTime(2026, 11, 1, 13, 15);
    final status = HinenStatus.fromDps(
      const {
        1: 98,
        6: false,
        7: true,
        25: false,
        26: 7200,
        105: 90,
        106: 8,
        107: false,
        108: true,
        113: 3,
        116: 1,
        117: 5,
      },
      model: 'PS300',
      receivedAt: receivedAt,
    );

    expect(status.localConfirmed, isTrue);
    expect(status.batteryPercent, 98);
    expect(status.switch1, isFalse);
    expect(status.switch2, isTrue);
    expect(status.beep, isFalse);
    expect(status.standbySeconds, 7200);
    expect(status.lightMode, 3);
    expect(status.chargingPacks, 1);
    expect(status.acChargeLimitPercent, 90);
    expect(status.vehicleChargeCurrentA, 8);
    expect(status.fastCharging, isFalse);
    expect(status.keystrokeSound, isTrue);
    expect(status.temperatureC, isNull);
    expect(status.outputWatts, 5);
    expect(status.capacityWithoutPackWh, 2560);
    expect(status.capacityWithPacksWh, 5120);
    expect(status.remainingWhWithoutPack, closeTo(2508.8, 0.1));
    expect(status.remainingWhWithPacks, closeTo(5017.6, 0.1));
    expect(status.dps[105], 90);
    expect(status.receivedAt, receivedAt);
  });
}
