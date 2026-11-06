import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hinen_controls.dart';
import 'hinen_profile.dart';
import 'local_net.dart';

/// The Energy tab: Hinen PS300 discovery profiles and controls.
///
/// The shell records the station's private address and Tuya product key. Reads
/// are local; confirmed writes use the host bridge. The Tuya local key never
/// ships in the profile or APK.
class HinenHomePage extends StatefulWidget {
  const HinenHomePage({super.key});

  @override
  State<HinenHomePage> createState() => _HinenHomePageState();
}

class _HinenHomePageState extends State<HinenHomePage> {
  static const _profilesKey = 'hinen_profiles';

  List<HinenProfile> _profiles = const [];
  bool _loaded = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final encoded = preferences.getString(_profilesKey);
      List<HinenProfile> profiles;
      if (encoded == null) {
        profiles = const [];
      } else {
        final decoded = jsonDecode(encoded);
        if (decoded is! List) {
          throw const FormatException('Energy profile data is invalid.');
        }
        profiles = decoded
            .map(
              (entry) => HinenProfile.fromJson(
                Map<String, dynamic>.from(entry as Map),
              ),
            )
            .toList();
      }
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _loaded = true;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load energy profiles from this device.';
        _loaded = true;
      });
    }
  }

  Future<void> _saveProfiles(List<HinenProfile> profiles) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _profilesKey,
      jsonEncode(profiles.map((profile) => profile.toJson()).toList()),
    );
    if (mounted) setState(() => _profiles = profiles);
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _addDevice() async {
    final draft = await showDialog<_HinenDraft>(
      context: context,
      builder: (context) => const _HinenProfileDialog(),
    );
    if (draft == null) return;
    try {
      await _saveProfiles([
        ..._profiles,
        HinenProfile(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: draft.name,
          address: draft.address,
          productKey: draft.productKey,
          model: draft.model,
          deviceId: draft.deviceId,
          bridgeUrl: draft.bridgeUrl,
        ),
      ]);
    } on Object {
      _showError('Could not save the energy device.');
    }
  }

  Future<void> _editDevice(HinenProfile original) async {
    final draft = await showDialog<_HinenDraft>(
      context: context,
      builder: (context) => _HinenProfileDialog(profile: original),
    );
    if (draft == null) return;
    try {
      await _saveProfiles([
        for (final item in _profiles)
          if (item.id == original.id)
            original.copyWith(
              name: draft.name,
              address: draft.address,
              productKey: draft.productKey,
              model: draft.model,
              deviceId: draft.deviceId,
              bridgeUrl: draft.bridgeUrl,
            )
          else
            item,
      ]);
    } on Object {
      _showError('Could not save the energy device.');
    }
  }

  Future<void> _removeDevice(HinenProfile profile) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove device?'),
        content: Text('Remove ${profile.name} from this app?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    await _saveProfiles(
      _profiles.where((item) => item.id != profile.id).toList(),
    );
  }

  void _openDevice(HinenProfile profile) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HinenControls(profile: profile),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LocalHome')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loaded ? _addDevice : null,
        icon: const Icon(Icons.add),
        label: const Text('Add device'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
          children: [
            const Text(
              'ENERGY · TUYA LAN 3.4',
              style: TextStyle(
                color: Color(0xFF91A4A2),
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Your energy devices',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '${_profiles.length}',
                  style: const TextStyle(
                    color: Color(0xFF92E6B5),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Add the Hinen PS300 by private IPv4. Reads stay local; '
              'confirmed writes use the host bridge.',
              style: TextStyle(color: Color(0xFF92A3A1), fontSize: 12),
            ),
            const SizedBox(height: 14),
            if (!_loaded)
              const Center(child: CircularProgressIndicator())
            else if (_loadError != null)
              _MessageCard(message: _loadError!)
            else if (_profiles.isEmpty)
              const _MessageCard(
                message:
                    'No energy devices yet. Use Add device with the station’s '
                    'private IPv4.',
              )
            else
              for (final profile in _profiles) ...[
                _HinenProfileCard(
                  profile: profile,
                  onOpen: () => _openDevice(profile),
                  onEdit: () => _editDevice(profile),
                  onRemove: () => _removeDevice(profile),
                ),
                const SizedBox(height: 10),
              ],
            const SizedBox(height: 16),
            const _EnergyFeatures(),
          ],
        ),
      ),
    );
  }
}

class _HinenDraft {
  const _HinenDraft({
    required this.name,
    required this.address,
    required this.productKey,
    required this.model,
    required this.deviceId,
    required this.bridgeUrl,
  });

  final String name;
  final String address;
  final String productKey;
  final String model;
  final String deviceId;
  final String bridgeUrl;
}

class _HinenProfileDialog extends StatefulWidget {
  const _HinenProfileDialog({this.profile});

  final HinenProfile? profile;

  @override
  State<_HinenProfileDialog> createState() => _HinenProfileDialogState();
}

class _HinenProfileDialogState extends State<_HinenProfileDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _productKeyController;
  late final TextEditingController _modelController;
  late final TextEditingController _deviceIdController;
  late final TextEditingController _bridgeUrlController;
  String? _error;

  bool get _isEditing => widget.profile != null;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _nameController = TextEditingController(text: profile?.name ?? '');
    _addressController = TextEditingController(text: profile?.address ?? '');
    _productKeyController = TextEditingController(
      text: profile?.productKey ?? '',
    );
    _modelController = TextEditingController(text: profile?.model ?? '');
    _deviceIdController = TextEditingController(
      text: profile?.deviceId ?? '',
    );
    _bridgeUrlController = TextEditingController(
      text: profile?.bridgeUrl ?? '',
    );
  }

  void _save() {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    final productKey = _productKeyController.text.trim();
    final model = _modelController.text.trim();
    final deviceId = _deviceIdController.text.trim();
    final bridgeUrl = _bridgeUrlController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a device name.');
      return;
    }
    if (!isPrivateIpv4(address)) {
      setState(() {
        _error =
            'Enter a numeric private IPv4 address (10/8, 172.16/12, or '
            '192.168/16).';
      });
      return;
    }
    if (productKey.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9]{16}$').hasMatch(productKey)) {
      setState(() {
        _error = 'Enter the 16-character Tuya product key, or leave it blank.';
      });
      return;
    }
    if (deviceId.isNotEmpty &&
        !RegExp(r'^[A-Za-z0-9]{20,22}$').hasMatch(deviceId)) {
      setState(() {
        _error = 'Enter the 20-22 character Tuya Virtual ID, or leave it blank.';
      });
      return;
    }
    if (bridgeUrl.isNotEmpty) {
      final uri = Uri.tryParse(
        bridgeUrl.contains('://') ? bridgeUrl : 'http://$bridgeUrl',
      );
      if (uri == null || uri.host.isEmpty) {
        setState(() => _error = 'Enter a valid host bridge URL, or leave it blank.');
        return;
      }
    }
    Navigator.of(context).pop(
      _HinenDraft(
        name: name,
        address: address,
        productKey: productKey,
        model: model,
        deviceId: deviceId,
        bridgeUrl: bridgeUrl,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _productKeyController.dispose();
    _modelController.dispose();
    _deviceIdController.dispose();
    _bridgeUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Edit energy device' : 'Add energy device'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Device name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addressController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Private IPv4 address',
                hintText: '192.168.1.50',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _productKeyController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Tuya product key (optional)',
                hintText: 'YOURPRODUCTKEY00',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Model (optional)',
                hintText: 'PS3000 / PS300',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceIdController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Tuya Virtual ID (optional)',
                hintText: 'from Hinen Device Information',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _bridgeUrlController,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Host bridge URL (optional)',
                hintText: 'http://192.168.1.10:8092',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFFA18F)),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _HinenProfileCard extends StatelessWidget {
  const _HinenProfileCard({
    required this.profile,
    required this.onOpen,
    required this.onEdit,
    required this.onRemove,
  });

  final HinenProfile profile;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF273536)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.battery_charging_full,
            color: Color(0xFF92E6B5),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  '${profile.address}:6668',
                  style: const TextStyle(
                    color: Color(0xFF92A3A1),
                    fontSize: 12,
                  ),
                ),
                if (profile.productKey.isNotEmpty)
                  Text(
                    profile.productKey,
                    style: const TextStyle(
                      color: Color(0xFF83918F),
                      fontSize: 10,
                    ),
                  ),
                if (profile.deviceId.isNotEmpty)
                  Text(
                    'ID ${profile.deviceId.length > 6 ? '${profile.deviceId.substring(0, 6)}…' : profile.deviceId}',
                    style: const TextStyle(
                      color: Color(0xFF83918F),
                      fontSize: 10,
                    ),
                  ),
                if (profile.model.isNotEmpty)
                  Text(
                    profile.model,
                    style: const TextStyle(
                      color: Color(0xFF83918F),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open station',
            onPressed: onOpen,
            icon: const Icon(Icons.play_circle_outline),
          ),
          IconButton(
            tooltip: 'Edit station',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Remove station',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _EnergyFeatures extends StatelessWidget {
  const _EnergyFeatures();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Local energy link',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 4),
        Text(
          'Reads are local; confirmed writes go through the host bridge.',
          style: TextStyle(color: Color(0xFF92A3A1), fontSize: 12),
        ),
        SizedBox(height: 12),
        _FeatureRow(
          icon: Icons.lan_outlined,
          title: 'Tuya LAN 3.4',
          detail: 'TCP 6668 on the station’s private address',
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.key_outlined,
          title: 'Local key in Keystore',
          detail: 'Used for DP queries; never in the profile or APK',
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.shield_outlined,
          title: 'Confirmed writes only',
          detail: 'Allowlisted DPs; every write is read back from the station',
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.wifi_outlined,
          title: 'Wi-Fi / Tuya cloud',
          detail: 'Smart Life is cloud-first; LocalHome controls stay on the local bridge',
        ),
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFF273536)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF92E6B5), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFCFD8D6),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Color(0xFF83918F),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF10191A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(message, style: const TextStyle(color: Color(0xFFCFD8D6))),
    );
  }
}
