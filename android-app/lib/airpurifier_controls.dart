import 'dart:async';

import 'package:flutter/material.dart';

import 'airpurifier_profile.dart';
import 'airpurifier_status.dart';
import 'miio_airpurifier.dart';
import 'miio_packet.dart';
import 'token_store.dart';

/// Read and control one purifier over the local miIO/MIoT link.
class AirPurifierControls extends StatefulWidget {
  const AirPurifierControls({
    super.key,
    required this.profile,
    required this.tokenStore,
    this.onModelDetected,
  });

  final AirPurifierProfile profile;
  final TokenStore tokenStore;
  final Future<void> Function(String model)? onModelDetected;

  @override
  State<AirPurifierControls> createState() => _AirPurifierControlsState();
}

class _AirPurifierControlsState extends State<AirPurifierControls>
    with WidgetsBindingObserver {
  MiioPurifierClient? _client;
  AirPurifierStatus? _status;
  Timer? _refreshTimer;
  String? _token;
  String? _error;
  bool _connecting = true;
  bool _busy = false;
  double? _favoriteDraft;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final token = await widget.tokenStore.read(widget.profile.id);
      if (!mounted) return;
      if (token == null || token.isEmpty) {
        setState(() {
          _connecting = false;
          _error = 'Set the device token in Edit purifier first.';
        });
        return;
      }
      _token = token;
      await _connect();
    } on Object {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = 'Could not read the stored token.';
      });
    }
  }

  Future<void> _connect() async {
    if (!mounted) return;
    final token = _token;
    if (token == null) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    MiioPurifierClient? client;
    try {
      final parsed = parseMiioToken(token);
      client = MiioPurifierClient(
        address: widget.profile.address,
        token: parsed,
      );
      final info = await client.connect();
      final status = await client.readStatus();
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() {
        _client = client;
        _status = status;
        _connecting = false;
        _busy = false;
        _error = null;
        _favoriteDraft = null;
      });
      final onModelDetected = widget.onModelDetected;
      if (onModelDetected != null) {
        unawaited(onModelDetected(info.model));
      }
      _scheduleRefresh();
    } on MiioAuthException {
      await client?.close();
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _busy = false;
        _error = 'The purifier rejected the token.';
      });
    } on MiioTimeoutException catch (error) {
      await client?.close();
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _busy = false;
        _error = error.message;
      });
    } on MiioException catch (error) {
      await client?.close();
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _busy = false;
        _error = error.message;
      });
    } on Object {
      await client?.close();
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _busy = false;
        _error = 'Could not reach the purifier at ${widget.profile.address}.';
      });
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_busy) return;
    final client = _client;
    if (client == null) {
      await _connect();
      return;
    }
    setState(() {
      _busy = true;
      if (!silent) _error = null;
    });
    try {
      final status = await client.readStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _busy = false;
        _error = null;
      });
    } on MiioException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not read the purifier.';
      });
    }
  }

  Future<void> _set(String name, Object? value, {String? confirm}) async {
    final client = _client;
    if (client == null || _busy) return;
    if (confirm != null) {
      final approved = await _confirm(title: 'Confirm change', message: confirm);
      if (!approved) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await client.setProperty(name, value);
      if (!mounted) return;
      setState(() {
        _status = result.status;
        _busy = false;
        _error = result.applied
            ? null
            : (result.error ?? 'The purifier did not apply that change.');
        if (name == 'favorite_level') _favoriteDraft = null;
      });
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } on MiioException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not change the purifier.';
      });
    }
  }

  Future<void> _resetFilter() async {
    final client = _client;
    if (client == null || _busy) return;
    final life = _status?.values['filter_life'];
    final approved = await _confirm(
      title: 'Reset filter counter?',
      message:
          'This clears the filter-used counter on the device and cannot be '
          'undone. Current filter life: ${life ?? '—'} %.',
      applyLabel: 'Reset',
    );
    if (!approved) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await client.resetFilter();
      if (!mounted) return;
      setState(() {
        _status = result.status;
        _busy = false;
        _error = result.applied
            ? null
            : (result.error ?? 'The purifier did not reset the filter counter.');
      });
    } on MiioException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not reset the filter.';
      });
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    String applyLabel = 'Apply',
  }) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(applyLabel),
          ),
        ],
      ),
    );
    return approved == true;
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && _client != null && !_busy) {
        unawaited(_refresh(silent: true));
      }
    });
  }

  Future<void> _closeClient() async {
    final client = _client;
    _client = null;
    await client?.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _refreshTimer?.cancel();
      unawaited(_closeClient());
    } else if (state == AppLifecycleState.resumed &&
        _client == null &&
        _token != null) {
      unawaited(_connect());
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeClient());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : () => unawaited(_refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _deviceHeader(status),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _ErrorCard(message: _error!),
              ],
              if (status == null) ...[
                const SizedBox(height: 36),
                if (_connecting)
                  const Center(child: CircularProgressIndicator())
                else
                  _MessageCard(
                    message: 'Connect to the purifier to read its status.',
                    action: FilledButton(
                      onPressed: _connect,
                      child: const Text('Reconnect'),
                    ),
                  ),
              ] else if (!purifierModelAliases.containsKey(status.model)) ...[
                const SizedBox(height: 12),
                _GenericDeviceCard(status: status),
              ] else ...[
                const SizedBox(height: 12),
                _statusSection(status),
                const SizedBox(height: 14),
                _controlsSection(status),
                const SizedBox(height: 14),
                _filterSection(status),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceHeader(AirPurifierStatus? status) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF273536)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.air, color: Color(0xFF92E6B5)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status?.model ?? 'Not connected',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (_busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.profile.address}:54321',
            style: const TextStyle(color: Color(0xFF92A3A1), fontSize: 12),
          ),
          if (status != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (status.firmware != null) 'Firmware ${status.firmware}',
                'Updated ${_time(status.receivedAt)}',
              ].join(' · '),
              style: const TextStyle(color: Color(0xFF83918F), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusSection(AirPurifierStatus status) {
    final properties = propertiesForModel(status.model);
    final metrics = <_MetricData>[
      const _MetricData('Power', 'power'),
      const _MetricData('Mode', 'mode'),
      if (properties.containsKey('fan_level'))
        const _MetricData('Fan level', 'fan_level'),
      const _MetricData('PM2.5', 'pm25', 'µg/m³'),
      if (properties.containsKey('pm10'))
        const _MetricData('PM10', 'pm10', 'µg/m³'),
      if (properties.containsKey('air_quality'))
        const _MetricData('Air quality', 'air_quality'),
      if (properties.containsKey('temperature'))
        const _MetricData('Temperature', 'temperature', '°C'),
      if (properties.containsKey('humidity'))
        const _MetricData('Humidity', 'humidity', '%'),
      const _MetricData('Filter life', 'filter_life', '%'),
      if (properties.containsKey('average_aqi'))
        const _MetricData('Average AQI', 'average_aqi'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('Status'),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 2.3,
          children: [
            for (final metric in metrics)
              _MetricCard(
                label: metric.label,
                value: status.isUnsupported(metric.key)
                    ? 'Not supported'
                    : _formatValue(metric.key, status.values[metric.key]),
                unit: metric.unit,
              ),
          ],
        ),
      ],
    );
  }

  Widget _controlsSection(AirPurifierStatus status) {
    final values = status.values;
    final properties = propertiesForModel(status.model);
    final readOnly = !purifierModelAliases.containsKey(status.model);
    bool present(String key) => properties.containsKey(key);
    bool enabled(String key) =>
        !_busy && !readOnly && present(key) && !status.isUnsupported(key);

    final modeMax = (properties['mode']?.maximum ?? 3).toInt();
    final modeOptions = <_Choice<int>>[
      for (var value = 0; value <= modeMax; value++)
        _Choice(_modeLabel(value), value),
    ];

    final favoriteMax =
        (properties['favorite_level']?.maximum ?? 11).toInt();
    final favorite = (_favoriteDraft ??
            ((values['favorite_level'] as num?)?.toDouble() ?? 0))
        .clamp(0, favoriteMax)
        .toDouble();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF273536)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('Controls'),
          if (readOnly)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                'Unknown model: read-only. Writes are disabled.',
                style: TextStyle(color: Color(0xFFFFA18F), fontSize: 12),
              ),
            ),
          _ChoiceRow<bool>(
            label: 'Power',
            options: const [_Choice('ON', true), _Choice('OFF', false)],
            value: values['power'] is bool ? values['power'] as bool : null,
            onSelected: (value) => _set(
              'power',
              value,
              confirm: value ? null : 'Turn the purifier off?',
            ),
            enabled: enabled('power'),
          ),
          _ChoiceRow<int>(
            label: 'Mode',
            options: modeOptions,
            value: values['mode'] is int ? values['mode'] as int : null,
            onSelected: (value) => _set('mode', value),
            enabled: enabled('mode'),
          ),
          if (present('fan_level'))
            _ChoiceRow<int>(
              label: 'Fan level',
              options: const [
                _Choice('1', 1),
                _Choice('2', 2),
                _Choice('3', 3),
              ],
              value: values['fan_level'] is int
                  ? values['fan_level'] as int
                  : null,
              onSelected: (value) => _set('fan_level', value),
              enabled: enabled('fan_level'),
            ),
          if (present('favorite_level'))
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Favorite level',
                    style: TextStyle(color: Color(0xFF91A4A2), fontSize: 12),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          min: 0,
                          max: favoriteMax.toDouble(),
                          divisions: favoriteMax,
                          value: favorite,
                          label: favorite.round().toString(),
                          onChanged: enabled('favorite_level')
                              ? (value) =>
                                    setState(() => _favoriteDraft = value)
                              : null,
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        child: Text(
                          favorite.round().toString(),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: enabled('favorite_level')
                            ? () => _set('favorite_level', favorite.round())
                            : null,
                        child: const Text('Set'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (present('anion'))
            _ChoiceRow<bool>(
              label: 'Anion',
              options: const [_Choice('ON', true), _Choice('OFF', false)],
              value: values['anion'] is bool ? values['anion'] as bool : null,
              onSelected: (value) => _set('anion', value),
              enabled: enabled('anion'),
            ),
          if (present('child_lock'))
            _ChoiceRow<bool>(
              label: 'Child lock',
              options: const [_Choice('ON', true), _Choice('OFF', false)],
              value: values['child_lock'] is bool
                  ? values['child_lock'] as bool
                  : null,
              onSelected: (value) => _set('child_lock', value),
              enabled: enabled('child_lock'),
            ),
          if (present('alarm'))
            _ChoiceRow<bool>(
              label: 'Buzzer',
              options: const [_Choice('ON', true), _Choice('OFF', false)],
              value: values['alarm'] is bool ? values['alarm'] as bool : null,
              onSelected: (value) => _set('alarm', value),
              enabled: enabled('alarm'),
            ),
          if (present('screen_brightness'))
            _ChoiceRow<int>(
              label: 'Screen brightness',
              options: const [
                _Choice('Off', 0),
                _Choice('Dim', 1),
                _Choice('Normal', 2),
              ],
              value: values['screen_brightness'] is int
                  ? values['screen_brightness'] as int
                  : null,
              onSelected: (value) => _set('screen_brightness', value),
              enabled: enabled('screen_brightness'),
            ),
          if (present('temperature_unit'))
            _ChoiceRow<int>(
              label: 'Temperature unit',
              options: const [
                _Choice('Celsius', 1),
                _Choice('Fahrenheit', 2),
              ],
              value: values['temperature_unit'] is int
                  ? values['temperature_unit'] as int
                  : null,
              onSelected: (value) => _set('temperature_unit', value),
              enabled: enabled('temperature_unit'),
            ),
        ],
      ),
    );
  }

  Widget _filterSection(AirPurifierStatus status) {
    final readOnly = !purifierModelAliases.containsKey(status.model);
    final life = status.values['filter_life'];
    final used = status.values['filter_used_time'];
    final left = status.values['filter_left_time'];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF273536)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('Filter'),
          Text(
            'Life ${life ?? '—'} % · Used ${used ?? '—'} h · '
            'Left ${left ?? '—'} days',
            style: const TextStyle(color: Color(0xFFCFD8D6)),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy || readOnly ? null : _resetFilter,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Reset filter counter'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Resetting clears the filter-used counter on the device; it is '
            'confirmed first.',
            style: TextStyle(color: Color(0xFF92A3A1), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}:'
    '${value.second.toString().padLeft(2, '0')}';

String _formatValue(String key, Object? value) {
  if (value == null) return '—';
  switch (key) {
    case 'power':
    case 'anion':
    case 'alarm':
    case 'child_lock':
      return value == true ? 'ON' : 'OFF';
    case 'mode':
      return value is int ? _modeLabel(value) : '—';
    case 'air_quality':
    case 'aqi_state':
      return _labelAt(
        const ['Excellent', 'Good', 'Light', 'Moderate', 'Heavy', 'Severe'],
        value,
      );
    case 'screen_brightness':
      return _labelAt(const ['Off', 'Dim', 'Normal'], value);
    case 'temperature_unit':
      return value == 1 ? 'Celsius' : value == 2 ? 'Fahrenheit' : '—';
    case 'fault':
      return value == 0 ? 'None' : 'Fault $value';
  }
  if (value is double) return value.toStringAsFixed(1);
  return value.toString();
}

String _labelAt(List<String> labels, Object? value) {
  if (value is int && value >= 0 && value < labels.length) {
    return labels[value];
  }
  return '—';
}

String _modeLabel(int value) => switch (value) {
  0 => 'Auto',
  1 => 'Sleep',
  2 => 'Favorite',
  3 => 'Manual',
  _ => 'Mode $value',
};

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: Color(0xFF91A4A2),
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MetricData {
  const _MetricData(this.label, this.key, [this.unit]);

  final String label;
  final String key;
  final String? unit;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF273536)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFF91A4A2), fontSize: 11),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (unit != null && value != '—' && value != 'Not supported') ...[
                const SizedBox(width: 4),
                Text(
                  unit!,
                  style: const TextStyle(
                    color: Color(0xFF91A4A2),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Choice<T> {
  const _Choice(this.label, this.value);

  final String label;
  final T value;
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.options,
    required this.value,
    required this.onSelected,
    this.enabled = true,
  });

  final String label;
  final List<_Choice<T>> options;
  final T? value;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFF91A4A2), fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final option in options)
                ChoiceChip(
                  label: Text(option.label),
                  selected: value == option.value,
                  onSelected: enabled ? (_) => onSelected(option.value) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GenericDeviceCard extends StatelessWidget {
  const _GenericDeviceCard({required this.status});

  final AirPurifierStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF273536)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Xiaomi device',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Model: ${status.model}',
            style: const TextStyle(color: Color(0xFFCFD8D6)),
          ),
          if (status.firmware != null) ...[
            const SizedBox(height: 4),
            Text(
              'Firmware: ${status.firmware}',
              style: const TextStyle(color: Color(0xFF92A3A1), fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'The token is valid and the device is reachable. Local controls '
            'for this model are not implemented yet.',
            style: TextStyle(color: Color(0xFF92A3A1), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1715),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF6A3B34)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFFFFA18F), fontSize: 13),
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: const TextStyle(color: Color(0xFFCFD8D6))),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}
