import 'package:flutter/material.dart';

import 'hinen_host_bridge.dart';
import 'hinen_key_store.dart';
import 'hinen_profile.dart';
import 'hinen_quick_controls.dart';
import 'hinen_settings_page.dart';
import 'hinen_status.dart';
import 'tuya_lan.dart';

/// Dashboard and host-bridged controls for a Hinen PS300.
///
/// Reads prefer the direct Tuya LAN path, then fall back to the LocalHome host
/// bridge. Writes are only accepted through the host bridge, are limited to the
/// confirmed DPs, require confirmation, and are verified by reading the station
/// back. The Tuya local key never leaves the host for bridge writes.
class HinenControls extends StatefulWidget {
  const HinenControls({super.key, required this.profile, this.keyStore});

  final HinenProfile profile;
  final HinenKeyStore? keyStore;

  @override
  State<HinenControls> createState() => _HinenControlsState();
}

class _HinenControlsState extends State<HinenControls> {
  late final HinenKeyStore _keyStore =
      widget.keyStore ?? SecureHinenKeyStore();
  HinenStatus _status = HinenStatus.unsupported;
  bool _loading = true;
  bool _busy = false;
  bool _hasKey = false;
  String? _source;
  String? _error;

  bool get _canWrite =>
      widget.profile.bridgeUrl.isNotEmpty && _status.hasReadings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _source = null;
      });
    }
    try {
      final key = await _keyStore.read(widget.profile.id);
      final hasKey = key != null && key.length == 16;
      if (mounted) setState(() => _hasKey = hasKey);
      Object? directError;
      if (hasKey && widget.profile.deviceId.isNotEmpty) {
        try {
          final dps = await HinenTuyaClient(
            address: widget.profile.address,
            deviceId: widget.profile.deviceId,
            localKey: key,
          ).readStatus();
          _applyDps(dps, 'Direct LAN');
          return;
        } on Object catch (error) {
          directError = error;
        }
      } else {
        directError = const TuyaException(
          'Direct LAN needs the local key and Tuya Virtual ID.',
        );
      }
      if (widget.profile.bridgeUrl.isEmpty) {
        _setError(
          directError is TuyaException
              ? directError.message
              : 'Could not read the station directly.',
        );
        return;
      }
      try {
        final dps = await HinenHostBridge(
          baseUrl: widget.profile.bridgeUrl,
        ).readStatus(address: widget.profile.address);
        _applyDps(dps, 'Host bridge');
      } on Object catch (bridgeError) {
        _setError(
          'Direct LAN: ${directError is TuyaException ? directError.message : 'unavailable'}. '
          'Host bridge: ${bridgeError is HinenHostBridgeException ? bridgeError.message : 'unavailable'}.',
        );
      }
    } on Object {
      _setError('Could not read the station.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyDps(Map<int, Object?> dps, String source) {
    if (!mounted) return;
    setState(() {
      _status = HinenStatus.fromDps(
        dps,
        model: widget.profile.model.isEmpty ? null : widget.profile.model,
        receivedAt: DateTime.now(),
      );
      _source = source;
      _error = null;
    });
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _status = HinenStatus.unsupported;
      _error = message;
      _source = null;
    });
  }

  Future<Map<int, Object?>?> _writeDp(int dp, Object value, String label) async {
    if (_busy) return null;
    if (!_canWrite) {
      _snack('Writes require the host bridge and a current reading.');
      return null;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label?'),
        content: Text(
          dp == 6 || dp == 7
              ? 'This writes a mains-power output on the station. Make sure '
                    'the connected load is safe before continuing.'
              : 'Write DP $dp and read the station back to verify the change.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return null;
    setState(() => _busy = true);
    try {
      final dps = await HinenHostBridge(
        baseUrl: widget.profile.bridgeUrl,
      ).setDp(
        address: widget.profile.address,
        dp: dp,
        value: value,
      );
      _applyDps(dps, 'Host bridge');
      _snack('DP $dp updated and verified.');
      return dps;
    } on Object catch (error) {
      _snack(
        error is HinenHostBridgeException
            ? error.message
            : 'The write failed.',
      );
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pinCard() async {
    final enabled = await HinenQuickControls.enableCard();
    _snack(
      enabled
          ? 'PS300 control card pinned to notifications.'
          : 'Could not pin the PS300 control card.',
    );
  }

  Future<void> _addTile() async {
    final added = await HinenQuickControls.addTile();
    _snack(
      added
          ? 'Add the LocalHome tile from the control-center edit screen.'
          : 'Could not request the LocalHome tile.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name),
        actions: [
          IconButton(
            tooltip: 'Station settings',
            onPressed: _loading || _busy
                ? null
                : () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => HinenSettingsPage(
                        profile: widget.profile,
                        status: _status,
                        onWrite: _writeDp,
                      ),
                    ),
                  ),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'Refresh station',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
            children: [
              _HeroCard(
                profile: widget.profile,
                status: _status,
                source: _source,
                error: _error,
                loading: _loading,
                busy: _busy,
                onRefresh: _load,
              ),
              const SizedBox(height: 14),
              if (_status.hasReadings) ...[
                _StatusTiles(status: _status),
                const SizedBox(height: 14),
                _CapacityCard(status: _status),
                const SizedBox(height: 14),
                _ControlCard(
                  status: _status,
                  enabled: _canWrite && !_busy,
                  onSwitch: (dp, value, label) async {
                    await _writeDp(dp, value, label);
                  },
                ),
                const SizedBox(height: 14),
                _QuickControlsCard(
                  onPinCard: _pinCard,
                  onAddTile: _addTile,
                ),
                const SizedBox(height: 14),
              ],
              _TransportCard(
                profile: widget.profile,
                status: _status,
                source: _source,
                hasKey: _hasKey,
              ),
              const SizedBox(height: 14),
              const _SafetyCard(),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.profile,
    required this.status,
    required this.source,
    required this.error,
    required this.loading,
    required this.busy,
    required this.onRefresh,
  });

  final HinenProfile profile;
  final HinenStatus status;
  final String? source;
  final String? error;
  final bool loading;
  final bool busy;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final battery = status.batteryPercent;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF122A24), Color(0xFF0A1513)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF2A4B40)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      error != null
                          ? 'Station unavailable'
                          : source == null
                          ? 'Connecting to station'
                          : 'Live · $source',
                      style: TextStyle(
                        color: error != null
                            ? const Color(0xFFFFA18F)
                            : const Color(0xFF8FB4A8),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (busy || loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _BatteryRing(percent: battery),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Pill(
                      icon: error == null
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      text: error == null ? 'Read verified' : 'Needs attention',
                      warning: error != null,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _standbyLabel(status.standbySeconds),
                      style: const TextStyle(
                        color: Color(0xFFDDE9E4),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Device standby',
                      style: TextStyle(
                        color: const Color(0xFF8FB4A8).withValues(alpha: 0.8),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (status.acChargeLimitPercent != null)
                          'AC limit ${status.acChargeLimitPercent}%',
                        if (status.chargingPacks != null)
                          '${status.chargingPacks} pack',
                        if (status.outputWatts != null)
                          '${status.outputWatts!.toStringAsFixed(0)} W out',
                      ].join(' · '),
                      style: const TextStyle(
                        color: Color(0xFF8FB4A8),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        error!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFFFA18F),
                          fontSize: 10,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _standbyLabel(int? seconds) {
    if (seconds == null) return '—';
    if (seconds >= 86400) return '${seconds ~/ 86400} d';
    if (seconds >= 3600) return '${seconds ~/ 3600} h';
    return '${seconds ~/ 60} min';
  }
}

class _BatteryRing extends StatelessWidget {
  const _BatteryRing({required this.percent});

  final int? percent;

  @override
  Widget build(BuildContext context) {
    final value = percent == null ? 0.0 : (percent! / 100).clamp(0.0, 1.0);
    return SizedBox(
      width: 112,
      height: 112,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 112,
            height: 112,
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: 9,
              strokeCap: StrokeCap.round,
              backgroundColor: const Color(0xFF1D342D),
              valueColor: AlwaysStoppedAnimation<Color>(
                value < 0.2 ? const Color(0xFFFFA18F) : const Color(0xFF92E6B5),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                percent == null ? '—' : '$percent%',
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
              const Text(
                'BATTERY',
                style: TextStyle(
                  color: Color(0xFF8FB4A8),
                  fontSize: 9,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusTiles extends StatelessWidget {
  const _StatusTiles({required this.status});

  final HinenStatus status;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            icon: Icons.power_settings_new_rounded,
            label: 'AC output',
            value: _state(status.switch1),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatTile(
            icon: Icons.electrical_services_rounded,
            label: 'DC output',
            value: _state(status.switch2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatTile(
            icon: Icons.lightbulb_outline_rounded,
            label: 'Light',
            value: _lightLabel(status.lightMode),
          ),
        ),
      ],
    );
  }

  static String _state(bool? value) {
    if (value == null) return '—';
    return value ? 'On' : 'Off';
  }

  static String _lightLabel(int? mode) => switch (mode) {
    1 => 'Low',
    2 => 'Med',
    3 => 'High',
    4 => 'SOS',
    0 => 'Off',
    _ => '—',
  };
}

class _CapacityCard extends StatelessWidget {
  const _CapacityCard({required this.status});

  final HinenStatus status;

  @override
  Widget build(BuildContext context) {
    final packs = status.chargingPacks;
    final withPackCapacity = status.capacityWithPacksWh;
    final withPackRemaining = status.remainingWhWithPacks;
    final packLabel = packs == null
        ? 'With pack'
        : packs == 1
        ? 'With 1 pack'
        : 'With $packs packs';
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Battery capacity',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              const _Pill(
                icon: Icons.battery_charging_full_rounded,
                text: 'PS3000 · LiFePO4',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            packs == null
                ? 'Pack count not reported by this station.'
                : 'DP 116 reports $packs PS2500B expansion '
                      '${packs == 1 ? 'pack' : 'packs'} connected.',
            style: const TextStyle(color: Color(0xFF8FB4A8), fontSize: 11),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _CapacityColumn(
                  label: 'Without pack',
                  capacityWh: status.capacityWithoutPackWh,
                  remainingWh: status.remainingWhWithoutPack,
                  percent: status.batteryPercent,
                  accent: const Color(0xFF8FB4A8),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CapacityColumn(
                  label: packLabel,
                  capacityWh: withPackCapacity,
                  remainingWh: withPackRemaining,
                  percent: status.batteryPercent,
                  accent: const Color(0xFF92E6B5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Nominal capacity. State of charge is DP 1; the pack is a '
            'PS2500B 2,560 Wh module.',
            style: TextStyle(color: Color(0xFF8FB4A8), fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _CapacityColumn extends StatelessWidget {
  const _CapacityColumn({
    required this.label,
    required this.capacityWh,
    required this.remainingWh,
    required this.percent,
    required this.accent,
  });

  final String label;
  final double? capacityWh;
  final double? remainingWh;
  final int? percent;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1513),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF29453C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8FB4A8),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            _formatWh(capacityWh),
            style: TextStyle(
              color: accent,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'nominal',
            style: TextStyle(color: Color(0xFF8FB4A8), fontSize: 9),
          ),
          const SizedBox(height: 9),
          Text(
            '${_formatWh(remainingWh)} left',
            style: const TextStyle(
              color: Color(0xFFDDE9E4),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            percent == null ? '—' : '$percent% charged',
            style: const TextStyle(color: Color(0xFF8FB4A8), fontSize: 9),
          ),
        ],
      ),
    );
  }

  static String _formatWh(double? value) {
    if (value == null) return '—';
    final digits = value.round().toString();
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(digits[index]);
    }
    return '$buffer Wh';
  }
}

class _ControlCard extends StatelessWidget {
  const _ControlCard({
    required this.status,
    required this.enabled,
    required this.onSwitch,
  });

  final HinenStatus status;
  final bool enabled;
  final Future<void> Function(int dp, Object value, String label) onSwitch;

  static const _standbyOptions = <int, String>{
    1800: '30 minutes',
    3600: '1 hour',
    7200: '2 hours',
    14400: '4 hours',
    28800: '8 hours',
    43200: '12 hours',
    86400: '24 hours',
  };
  static const _acStandbyOptions = <int, String>{
    1800: '30 minutes',
    3600: '1 hour',
    7200: '2 hours',
    14400: '4 hours',
  };
  static const _screenOptions = <int, String>{
    300: '5 minutes',
    600: '10 minutes',
    1800: '30 minutes',
    3600: '1 hour',
  };

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Controls',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              _Pill(
                icon: enabled ? Icons.bolt : Icons.lock_outline,
                text: enabled ? 'Host bridge' : 'Locked',
                warning: !enabled,
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Confirmed DPs only. Every write is read back from the station.',
            style: TextStyle(color: Color(0xFF8FB4A8), fontSize: 11),
          ),
          const SizedBox(height: 12),
          _SwitchRow(
            title: 'AC output',
            subtitle: 'DP 6 · AC',
            value: status.switch1,
            enabled: enabled && status.switch1 != null,
            onChanged: (value) => onSwitch(6, value, 'AC output'),
          ),
          _SwitchRow(
            title: 'DC output',
            subtitle: 'DP 7 · 12V DC',
            value: status.switch2,
            enabled: enabled && status.switch2 != null,
            onChanged: (value) => onSwitch(7, value, 'DC output'),
          ),
          _SwitchRow(
            title: 'Beep',
            subtitle: status.dps.containsKey(25)
                ? 'DP 25 · station beep'
                : 'DP 25 · not reported by this station',
            value: status.beep,
            enabled: enabled && status.beep != null,
            onChanged: (value) => onSwitch(25, value, 'Beep'),
          ),
          _SwitchRow(
            title: 'Fast charging',
            subtitle: 'DP 107 · read-only; change in Smart Life',
            value: status.fastCharging,
            enabled: false,
            onChanged: (_) {},
          ),
          _SwitchRow(
            title: 'Keystroke sound',
            subtitle: 'DP 108 · panel sound',
            value: status.keystrokeSound,
            enabled: enabled && status.keystrokeSound != null,
            onChanged: (value) => onSwitch(108, value, 'Keystroke sound'),
          ),
          const SizedBox(height: 14),
          _LightModeRow(
            value: status.lightMode,
            enabled: enabled,
            onChanged: (mode) => onSwitch(
              113,
              mode,
              'Light ${const ['Off', 'Low', 'Medium', 'High', 'SOS'][mode]}',
            ),
          ),
          const SizedBox(height: 14),
          _TimerRow(
            title: 'AC charging limit',
            subtitle: 'DP 105 · percent',
            value: status.acChargeLimitPercent,
            options: const {
              50: '50%',
              60: '60%',
              70: '70%',
              80: '80%',
              90: '90%',
              100: '100%',
            },
            enabled: enabled,
            onChanged: (value) =>
                onSwitch(105, value, 'AC charging limit'),
          ),
          _TimerRow(
            title: 'Vehicle current limit',
            subtitle: 'DP 106 · amps',
            value: status.vehicleChargeCurrentA,
            options: const {
              6: '6 A',
              8: '8 A',
              10: '10 A',
              12: '12 A',
              16: '16 A',
            },
            enabled: enabled,
            onChanged: (value) =>
                onSwitch(106, value, 'Vehicle current limit'),
          ),
          const Divider(height: 24, color: Color(0xFF203A32)),
          _TimerRow(
            title: 'Device standby',
            subtitle: 'DP 26',
            value: status.standbySeconds,
            options: _standbyOptions,
            enabled: enabled,
            onChanged: (value) =>
                onSwitch(26, value, 'Device standby time'),
          ),
          _TimerRow(
            title: 'AC standby',
            subtitle: 'DP 109',
            value: _intDp(status.dps[109]),
            options: _acStandbyOptions,
            enabled: enabled,
            onChanged: (value) => onSwitch(109, value, 'AC standby time'),
          ),
          _TimerRow(
            title: 'Screen off',
            subtitle: 'DP 110',
            value: _intDp(status.dps[110]),
            options: _screenOptions,
            enabled: enabled,
            onChanged: (value) => onSwitch(110, value, 'Screen off time'),
          ),
        ],
      ),
    );
  }

  static int? _intDp(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class _LightModeRow extends StatelessWidget {
  const _LightModeRow({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final int? value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  static const _labels = ['Off', 'Low', 'Medium', 'High', 'SOS'];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.lightbulb_outline_rounded,
              size: 18,
              color: Color(0xFF8FB4A8),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Light',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              value == null
                  ? '—'
                  : _labels[value!.clamp(0, _labels.length - 1)],
              style: const TextStyle(
                color: Color(0xFF8FB4A8),
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (var index = 0; index < _labels.length; index++)
              ChoiceChip(
                label: Text(_labels[index]),
                selected: value == index,
                showCheckmark: false,
                onSelected: enabled && value != index
                    ? (_) => onChanged(index)
                    : null,
                selectedColor: const Color(0x2E92E6B5),
                backgroundColor: const Color(0xFF0B1513),
                side: BorderSide(
                  color: value == index
                      ? const Color(0xFF4F8F73)
                      : const Color(0xFF29453C),
                ),
                labelStyle: TextStyle(
                  color: value == index
                      ? const Color(0xFF92E6B5)
                      : const Color(0xFF8FB4A8),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool? value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: Color(0xFF8FB4A8), fontSize: 10),
      ),
      value: value ?? false,
      onChanged: enabled ? onChanged : null,
    );
  }
}

class _TimerRow extends StatelessWidget {
  const _TimerRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final int? value;
  final Map<int, String> options;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final values = <int>{...options.keys, ?value}.toList()
      ..sort();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF8FB4A8),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          DropdownButton<int>(
            value: value != null && values.contains(value) ? value : null,
            hint: const Text('—'),
            underline: const SizedBox.shrink(),
            dropdownColor: const Color(0xFF12211D),
            items: [
              for (final option in values)
                DropdownMenuItem(
                  value: option,
                  child: Text(options[option] ?? '$option s'),
                ),
            ],
            onChanged: enabled
                ? (next) {
                    if (next != null && next != value) onChanged(next);
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

class _QuickControlsCard extends StatelessWidget {
  const _QuickControlsCard({
    required this.onPinCard,
    required this.onAddTile,
  });

  final VoidCallback onPinCard;
  final VoidCallback onAddTile;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.widgets_outlined,
                size: 20,
                color: Color(0xFF8FB4A8),
              ),
              SizedBox(width: 8),
              Text(
                'Notification & control center',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'One notification card shows the PS300 energy controls and cameras. '
            'The LocalHome tile opens a compact sheet with Cameras and PS300 '
            'energy; Open LocalHome in the sheet opens the full app.',
            style: TextStyle(
              color: Color(0xFF8FB4A8),
              fontSize: 11,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPinCard,
                  icon: const Icon(Icons.notifications_active_outlined, size: 18),
                  label: const Text('Pin card'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onAddTile,
                  icon: const Icon(Icons.add_box_outlined, size: 18),
                  label: const Text('Add LocalHome tile'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TransportCard extends StatelessWidget {
  const _TransportCard({
    required this.profile,
    required this.status,
    required this.source,
    required this.hasKey,
  });

  final HinenProfile profile;
  final HinenStatus status;
  final String? source;
  final bool hasKey;

  @override
  Widget build(BuildContext context) {
    final dps = status.dps.keys.toList()..sort();
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Transport & data',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          _InfoRow(
            icon: Icons.key_outlined,
            title: 'Local key',
            value: hasKey ? 'Android Keystore' : 'Not in this app',
          ),
          _InfoRow(
            icon: Icons.hub_outlined,
            title: 'Host bridge',
            value: profile.bridgeUrl.isEmpty
                ? 'Not configured'
                : profile.bridgeUrl,
          ),
          _InfoRow(
            icon: Icons.lan_outlined,
            title: 'Direct LAN',
            value: source == 'Direct LAN' ? 'Working' : 'Falls back to bridge',
          ),
          _InfoRow(
            icon: Icons.schedule,
            title: 'Last read',
            value: status.receivedAt == null
                ? '—'
                : _formatTime(status.receivedAt!),
          ),
          if (dps.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Energy history, solar, car-charge, and AC-energy totals are '
              'Smart Life cloud statistics; the local DP set exposes live '
              'state only.',
              style: TextStyle(
                color: Color(0xFF8FB4A8),
                fontSize: 10,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 4),
            Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: const Text(
                  'Raw data points',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${dps.length} DPs · ${profile.address}',
                  style: const TextStyle(
                    color: Color(0xFF8FB4A8),
                    fontSize: 10,
                  ),
                ),
                children: [
                  for (final dp in dps)
                    _RawDpRow(
                      dp: dp,
                      label: _label(dp),
                      value: status.dps[dp].toString(),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _label(int dp) => switch (dp) {
    1 => 'battery_percentage',
    6 => 'AC switch',
    7 => 'DC switch',
    25 => 'beep',
    26 => 'standby_time',
    105 => 'temperature °F',
    109 => 'AC standby',
    110 => 'screen off',
    113 => 'light mode',
    116 => 'charging packs',
    117 => 'output power',
    _ => 'unmapped',
  };

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard();

  @override
  Widget build(BuildContext context) {
    return _Panel(
      color: const Color(0xFF1B1710),
      borderColor: const Color(0xFF4B3E1C),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.shield_outlined, color: Color(0xFFFFD166), size: 20),
              SizedBox(width: 8),
              Text(
                'Mains-power boundary',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'AC output and DC output write mains-power/12V outputs. Light '
            'modes are DP 113. Confirm the connected load before applying. '
            'Every write is read back; a verification failure is reported '
            'instead of assumed.',
            style: TextStyle(color: Color(0xFFF4E2B8), fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            'Controls go through the host bridge; no cloud fallback, no '
            'automation, no firmware, no UPS/charge-limit/P-boost writes.',
            style: TextStyle(
              color: const Color(0xFFF4E2B8).withValues(alpha: 0.72),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.child,
    this.color = const Color(0xFF101D19),
    this.borderColor = const Color(0xFF29453C),
  });

  final Widget child;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: borderColor),
      ),
      child: child,
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      decoration: BoxDecoration(
        color: const Color(0xFF101D19),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF29453C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: const Color(0xFF8FB4A8)),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8FB4A8),
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: const Color(0xFF8FB4A8)),
          const SizedBox(width: 9),
          SizedBox(
            width: 92,
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFF8FB4A8),
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFDDE9E4),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RawDpRow extends StatelessWidget {
  const _RawDpRow({
    required this.dp,
    required this.label,
    required this.value,
  });

  final int dp;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              'DP $dp',
              style: const TextStyle(
                color: Color(0xFF8FB4A8),
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF8FB4A8),
                fontSize: 10,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFFDDE9E4),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
    this.warning = false,
  });

  final IconData icon;
  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning ? const Color(0xFFFFD166) : const Color(0xFF92E6B5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
