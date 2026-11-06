import 'package:flutter/material.dart';

import 'hinen_profile.dart';
import 'hinen_status.dart';

/// Station settings mirroring the Smart Life layout.
///
/// Only DPs confirmed writable are actionable. Cloud-only settings are shown as
/// read-only with an explicit explanation rather than as fake controls.
class HinenSettingsPage extends StatefulWidget {
  const HinenSettingsPage({
    super.key,
    required this.profile,
    required this.status,
    required this.onWrite,
  });

  final HinenProfile profile;
  final HinenStatus status;
  final Future<Map<int, Object?>?> Function(int dp, Object value, String label)
  onWrite;

  @override
  State<HinenSettingsPage> createState() => _HinenSettingsPageState();
}

class _HinenSettingsPageState extends State<HinenSettingsPage> {
  late HinenStatus _status = widget.status;
  bool _busy = false;

  Future<void> _write(int dp, Object value, String label) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final dps = await widget.onWrite(dp, value, label);
      if (!mounted || dps == null) return;
      setState(() {
        _status = HinenStatus.fromDps(
          dps,
          model: widget.profile.model.isEmpty ? null : widget.profile.model,
          receivedAt: DateTime.now(),
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Station settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            _Section(
              title: 'General',
              children: [
                _InfoRow(
                  title: 'Charge/Discharge Limited',
                  value: '0%–100%',
                  note: 'Smart Life cloud setting; not exposed by local DPs',
                  icon: Icons.battery_charging_full_outlined,
                  onTap: () => _showCloudOnly(
                    context,
                    'Charge/Discharge Limited',
                    'The PS300 does not report this setting as a local DP. '
                        'Smart Life changes it in the Tuya cloud. LocalHome only '
                        'writes confirmed local DPs, so this row is read-only '
                        'rather than sending a guessed value.',
                  ),
                ),
                _DropdownRow(
                  title: 'AC Charging Power Limits',
                  icon: Icons.speed_rounded,
                  value: _status.acChargeLimitPercent,
                  unit: '%',
                  options: const [50, 60, 70, 80, 90, 100],
                  enabled: !_busy,
                  onChanged: (value) =>
                      _write(105, value, 'AC charging power limit'),
                ),
                _DropdownRow(
                  title: 'Vehicle Charging Current Limitation',
                  icon: Icons.electric_car_outlined,
                  value: _status.vehicleChargeCurrentA,
                  unit: 'A',
                  options: const [6, 8, 10, 12, 16],
                  enabled: !_busy,
                  onChanged: (value) =>
                      _write(106, value, 'Vehicle charging current'),
                ),
                _InfoRow(
                  title: 'Inverter Frequency',
                  value: '50Hz',
                  note: 'Smart Life cloud setting; not exposed by local DPs',
                  icon: Icons.show_chart_rounded,
                  onTap: () => _showCloudOnly(
                    context,
                    'Inverter Frequency',
                    'Switching this between 50Hz and 60Hz in Smart Life did not '
                        'change any local DP. It is a cloud setting on this '
                        'station, so LocalHome cannot write it locally.',
                  ),
                ),
                _SwitchRow(
                  title: 'Keystroke Sound',
                  icon: Icons.volume_up_outlined,
                  value: _status.keystrokeSound,
                  enabled: !_busy && _status.keystrokeSound != null,
                  onChanged: (value) => _write(108, value, 'Keystroke Sound'),
                ),
                _InfoRow(
                  title: 'Restore settings',
                  value: '',
                  note: 'Cloud-only action; not sent by LocalHome',
                  icon: Icons.restore_rounded,
                  onTap: () => _showCloudOnly(
                    context,
                    'Restore settings',
                    'This is a cloud-only action. LocalHome does not send a '
                        'restore command because it is not exposed by the local '
                        'DP protocol and is potentially destructive.',
                  ),
                ),
                _SwitchRow(
                  title: 'Fast Charging Switch',
                  icon: Icons.bolt_rounded,
                  value: _status.fastCharging,
                  enabled: false,
                  note: 'Read-only locally; the station rejects this write',
                  onChanged: (_) {},
                ),
              ],
            ),
            _Section(
              title: 'Standby Time',
              children: [
                _DropdownRow(
                  title: 'Device Standby Time',
                  icon: Icons.timelapse_rounded,
                  value: _status.standbySeconds,
                  options: const [1800, 3600, 7200, 14400, 28800, 43200, 86400],
                  enabled: !_busy,
                  label: _duration,
                  onChanged: (value) =>
                      _write(26, value, 'Device standby time'),
                ),
                _DropdownRow(
                  title: 'AC Standby Time',
                  icon: Icons.hourglass_empty_rounded,
                  value: _intDp(_status.dps[109]),
                  options: const [1800, 3600, 7200, 14400],
                  enabled: !_busy,
                  label: _duration,
                  onChanged: (value) => _write(109, value, 'AC standby time'),
                ),
                _DropdownRow(
                  title: 'Screen Off Time',
                  icon: Icons.hide_image_outlined,
                  value: _intDp(_status.dps[110]),
                  options: const [300, 600, 1800, 3600],
                  enabled: !_busy,
                  label: _duration,
                  onChanged: (value) => _write(110, value, 'Screen-off time'),
                ),
              ],
            ),
            _Section(
              title: 'Other',
              children: [
                _ActionRow(
                  title: 'Equipment Specification',
                  icon: Icons.tune_rounded,
                  onTap: () => _showSpecification(context),
                ),
                _InfoRow(
                  title: 'Temperature Unit',
                  value: '°C',
                  note: 'Not used; the local DP set has no temperature',
                  icon: Icons.thermostat_outlined,
                  onTap: () => _showCloudOnly(
                    context,
                    'Temperature Unit',
                    'The station’s local DP set has no temperature value. Smart '
                        'Life displays a cloud-reported temperature, so the app '
                        'does not show a fake local reading.',
                  ),
                ),
                _ActionRow(
                  title: 'More',
                  icon: Icons.more_horiz_rounded,
                  onTap: () => _showMore(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static int? _intDp(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String _duration(int value) {
    if (value >= 86400) return '${value ~/ 86400} days';
    if (value >= 3600) {
      final hours = value ~/ 3600;
      return '$hours ${hours == 1 ? 'hour' : 'hours'}';
    }
    return '${value ~/ 60} mins';
  }

  void _showSpecification(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Equipment Specification'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Name: ${widget.profile.name}'),
            Text('Model: ${widget.profile.model.isEmpty ? 'PS3000' : widget.profile.model}'),
            Text('Address: ${widget.profile.address}'),
            Text('Product key: ${widget.profile.productKey.isEmpty ? 'not recorded' : widget.profile.productKey}'),
            Text('Device ID: ${_prefix(widget.profile.deviceId)}'),
            Text('DPs: ${_status.dps.length}'),
            Text('Capacity: 2,560 Wh base / 5,120 Wh with 1 pack'),
            Text('Pack count: ${_status.chargingPacks ?? 'unknown'}'),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  void _showCloudOnly(BuildContext context, String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showMore(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('More'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Local: AC/DC, light, AC charging limit, vehicle current, keystroke sound, standby and screen-off.'),
            SizedBox(height: 8),
            Text('Cloud-only: Charge/Discharge Limited, Inverter Frequency, Restore settings, and Fast Charging.'),
            SizedBox(height: 8),
            Text('No cloud call is made by LocalHome; change cloud-only settings in Smart Life.'),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  static String _prefix(String value) =>
      value.isEmpty ? 'not recorded' : '${value.substring(0, value.length > 6 ? 6 : value.length)}…';
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFF8FB4A8),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            color: const Color(0xFF101D19),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: Color(0xFF29453C)),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.title,
    required this.value,
    required this.note,
    required this.icon,
    this.onTap,
  });
  final String title;
  final String value;
  final String note;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF8FB4A8), size: 21),
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(note, style: const TextStyle(color: Color(0xFF8FB4A8), fontSize: 10)),
      trailing: Text(value, style: const TextStyle(color: Color(0xFFCFD8D6), fontSize: 12)),
      onTap: onTap,
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.title, required this.icon, required this.onTap});
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF8FB4A8), size: 21),
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFF8FB4A8)),
      onTap: onTap,
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.icon,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.note,
  });
  final String title;
  final IconData icon;
  final bool? value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      secondary: Icon(icon, color: const Color(0xFF8FB4A8), size: 21),
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: note == null ? null : Text(note!, style: const TextStyle(color: Color(0xFF8FB4A8), fontSize: 10)),
      value: value ?? false,
      onChanged: enabled ? onChanged : null,
    );
  }
}

class _DropdownRow extends StatelessWidget {
  const _DropdownRow({
    required this.title,
    required this.icon,
    required this.value,
    required this.options,
    required this.enabled,
    required this.onChanged,
    this.unit = '',
    this.label,
  });
  final String title;
  final IconData icon;
  final int? value;
  final List<int> options;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final String unit;
  final String Function(int)? label;

  @override
  Widget build(BuildContext context) {
    final values = <int>{...options, if (value != null) value!}.toList()..sort();
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF8FB4A8), size: 21),
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      trailing: DropdownButton<int>(
        value: value != null && values.contains(value) ? value : null,
        hint: const Text('—'),
        underline: const SizedBox.shrink(),
        dropdownColor: const Color(0xFF12211D),
        items: [
          for (final option in values)
            DropdownMenuItem(
              value: option,
              child: Text(label?.call(option) ?? '$option$unit'),
            ),
        ],
        onChanged: enabled
            ? (next) {
                if (next != null && next != value) onChanged(next);
              }
            : null,
      ),
    );
  }
}
