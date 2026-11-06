import 'dart:async';

import 'package:flutter/material.dart';

import 'camera_profile.dart';
import 'lan_light.dart';

/// ON / AUTO / OFF control for the camera's white floodlight.
///
/// Uses the camera's local IOT session (TCP 8089) and its LAN password. The
/// control is intentionally unavailable without a LAN password; it never falls
/// back to a vendor cloud path.
class LightControls extends StatefulWidget {
  const LightControls({super.key, required this.profile});

  final CameraProfile profile;

  @override
  State<LightControls> createState() => _LightControlsState();
}

class _LightControlsState extends State<LightControls>
    with WidgetsBindingObserver {
  LanLightClient? _client;
  LightState? _state;
  LightMode? _pending;
  bool _connecting = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    if (widget.profile.lanPassword.isEmpty) {
      setState(() {
        _error =
            'Set the camera LAN password (QR field 8) in Edit camera first.';
      });
      return;
    }
    final client = await _connect();
    if (client == null || !mounted) return;
    try {
      final state = await client.readState();
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() {
        _state = state;
        _connecting = false;
      });
    } on LanLightException catch (error) {
      await client.close();
      if (!mounted) return;
      setState(() {
        _client = null;
        _connecting = false;
        _error = error.message;
      });
    } on Object {
      await client.close();
      if (!mounted) return;
      setState(() {
        _client = null;
        _connecting = false;
        _error = 'Could not read the camera light state.';
      });
    }
  }

  Future<LanLightClient?> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    final client = LanLightClient(
      address: widget.profile.address,
      password: widget.profile.lanPassword,
    );
    try {
      await client.connect();
      if (!mounted) {
        await client.close();
        return null;
      }
      setState(() {
        _client = client;
      });
      return client;
    } on LanLightException catch (error) {
      await client.close();
      if (!mounted) return null;
      setState(() {
        _connecting = false;
        _error = error.message;
      });
      return null;
    } on Object {
      await client.close();
      if (!mounted) return null;
      setState(() {
        _connecting = false;
        _error = 'Could not reach the camera light.';
      });
      return null;
    }
  }

  Future<void> _select(LightMode mode) async {
    if (_busy || _connecting) return;
    var client = _client;
    if (client == null) {
      client = await _connect();
      if (client == null) return;
    }
    setState(() {
      _busy = true;
      _pending = mode;
      _error = null;
    });
    try {
      final state = await client.setMode(mode);
      if (!mounted) return;
      setState(() {
        _state = state;
        _busy = false;
        _connecting = false;
        _pending = null;
      });
    } on LanLightException catch (error) {
      await client.close();
      if (!mounted) return;
      setState(() {
        _client = null;
        _busy = false;
        _connecting = false;
        _pending = null;
        _error = error.message;
      });
    } on Object {
      await client.close();
      if (!mounted) return;
      setState(() {
        _client = null;
        _busy = false;
        _connecting = false;
        _pending = null;
        _error = 'Could not change the camera light.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_close());
    }
  }

  Future<void> _close() async {
    final client = _client;
    _client = null;
    await client?.close();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _pending ?? _state?.mode;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: const Color(0xE610191A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF516363)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lightbulb_outline,
                size: 16,
                color: Color(0xFF92E6B5),
              ),
              const SizedBox(width: 5),
              const Text(
                'Camera light',
                style: TextStyle(
                  color: Color(0xFFD4E0DD),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF263637),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  selected?.name.toUpperCase() ?? '—',
                  style: const TextStyle(
                    color: Color(0xFF92E6B5),
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in const [
                LightMode.on,
                LightMode.auto,
                LightMode.off,
              ])
                _modeButton(mode, selected),
            ],
          ),
          if (_connecting || _busy)
            const Padding(
              padding: EdgeInsets.only(top: 5),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFFFA18F), fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  Widget _modeButton(LightMode mode, LightMode? selected) {
    final active = selected == mode;
    final enabled = !_busy && !_connecting;
    return Semantics(
      button: true,
      selected: active,
      label: 'Camera light ${mode.name}',
      child: InkWell(
        onTap: enabled ? () => unawaited(_select(mode)) : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 54,
          height: 32,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? const Color(0xFF47715C) : const Color(0xFF263637),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            mode.name.toUpperCase(),
            style: TextStyle(
              color: enabled ? Colors.white : const Color(0xFF6D7A78),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
