import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'airpurifier_controls.dart';
import 'airpurifier_profile.dart';
import 'local_net.dart';
import 'miio_packet.dart';
import 'token_store.dart';

class AirPurifierHomePage extends StatefulWidget {
  const AirPurifierHomePage({super.key});

  @override
  State<AirPurifierHomePage> createState() => _AirPurifierHomePageState();
}

class _AirPurifierHomePageState extends State<AirPurifierHomePage> {
  static const _profilesKey = 'airpurifier_profiles';

  final TokenStore _tokenStore = SecureTokenStore();
  List<AirPurifierProfile> _profiles = const [];
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
      List<AirPurifierProfile> profiles;
      if (encoded == null) {
        profiles = const [];
      } else {
        final decoded = jsonDecode(encoded);
        if (decoded is! List) {
          throw const FormatException('Purifier profile data is invalid.');
        }
        profiles = decoded
            .map(
              (entry) => AirPurifierProfile.fromJson(
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
        _loadError = 'Could not load device profiles from this device.';
        _loaded = true;
      });
    }
  }

  Future<void> _saveProfiles(List<AirPurifierProfile> profiles) async {
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

  Future<void> _addPurifier() async {
    final draft = await showDialog<_PurifierDraft>(
      context: context,
      builder: (context) => const _PurifierProfileDialog(),
    );
    if (draft == null || draft.token == null) return;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    try {
      await _tokenStore.write(id, draft.token!);
      await _saveProfiles([
        ..._profiles,
        AirPurifierProfile(id: id, name: draft.name, address: draft.address),
      ]);
    } on Object {
      _showError('Could not save the device token.');
    }
  }

  Future<void> _editPurifier(AirPurifierProfile original) async {
    final draft = await showDialog<_PurifierDraft>(
      context: context,
      builder: (context) => _PurifierProfileDialog(profile: original),
    );
    if (draft == null) return;
    try {
      if (draft.token != null) {
        await _tokenStore.write(original.id, draft.token!);
      }
      await _saveProfiles([
        for (final item in _profiles)
          if (item.id == original.id)
            original.copyWith(name: draft.name, address: draft.address)
          else
            item,
      ]);
    } on Object {
      _showError('Could not save the device profile.');
    }
  }

  Future<void> _removePurifier(AirPurifierProfile profile) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove device?'),
        content: Text('Remove ${profile.name} and its stored token?'),
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
    try {
      await _tokenStore.delete(profile.id);
    } on Object {
      // The profile is still removed; a stale keystore entry is harmless.
    }
    await _saveProfiles(
      _profiles.where((item) => item.id != profile.id).toList(),
    );
  }

  Future<void> _rememberModel(String id, String model) async {
    AirPurifierProfile? current;
    for (final profile in _profiles) {
      if (profile.id == id) {
        current = profile;
        break;
      }
    }
    if (current == null || current.modelId == model) return;
    await _saveProfiles([
      for (final profile in _profiles)
        if (profile.id == id) profile.copyWith(modelId: model) else profile,
    ]);
  }

  Future<void> _openPurifier(AirPurifierProfile profile) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AirPurifierControls(
          profile: profile,
          tokenStore: _tokenStore,
          onModelDetected: (model) => _rememberModel(profile.id, model),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LocalHome')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loaded ? _addPurifier : null,
        icon: const Icon(Icons.add),
        label: const Text('Add device'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
          children: [
            const Text(
              'XIAOMI DEVICES · LOCAL MIOT',
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
                    'Your Xiaomi devices',
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
              'Add Xiaomi devices by local IP and device token. Status and '
              'control stay on the private LAN.',
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
                    'No Xiaomi devices yet. Use Add device with the local IP '
                    'and token.',
              )
            else
              for (final profile in _profiles) ...[
                _PurifierProfileCard(
                  profile: profile,
                  onOpen: () => _openPurifier(profile),
                  onEdit: () => _editPurifier(profile),
                  onRemove: () => _removePurifier(profile),
                ),
                const SizedBox(height: 10),
              ],
            const SizedBox(height: 16),
            const _PurifierFeatures(),
          ],
        ),
      ),
    );
  }
}

class _PurifierDraft {
  const _PurifierDraft({
    required this.name,
    required this.address,
    this.token,
  });

  final String name;
  final String address;
  final String? token;
}

class _PurifierProfileDialog extends StatefulWidget {
  const _PurifierProfileDialog({this.profile});

  final AirPurifierProfile? profile;

  @override
  State<_PurifierProfileDialog> createState() => _PurifierProfileDialogState();
}

class _PurifierProfileDialogState extends State<_PurifierProfileDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _tokenController;
  String? _error;

  bool get _isEditing => widget.profile != null;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _nameController = TextEditingController(text: profile?.name ?? '');
    _addressController = TextEditingController(text: profile?.address ?? '');
    _tokenController = TextEditingController();
  }

  void _save() {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    final token = _tokenController.text.trim();
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
    if (!_isEditing && token.isEmpty) {
      setState(() => _error = 'Enter the device token (32 hex characters).');
      return;
    }
    if (token.isNotEmpty) {
      try {
        parseMiioToken(token);
      } on MiioException catch (error) {
        setState(() => _error = error.message);
        return;
      }
    }
    Navigator.of(context).pop(
      _PurifierDraft(
        name: name,
        address: address,
        token: token.isEmpty ? null : token,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Edit Xiaomi device' : 'Add Xiaomi device'),
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
              controller: _tokenController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: _isEditing
                    ? 'Device token (leave blank to keep)'
                    : 'Device token (32 hex)',
                hintText: 'stored in the Android keystore',
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

class _PurifierProfileCard extends StatelessWidget {
  const _PurifierProfileCard({
    required this.profile,
    required this.onOpen,
    required this.onEdit,
    required this.onRemove,
  });

  final AirPurifierProfile profile;
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
          const Icon(Icons.devices_other, color: Color(0xFF92E6B5)),
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
                  '${profile.address}:54321',
                  style: const TextStyle(
                    color: Color(0xFF92A3A1),
                    fontSize: 12,
                  ),
                ),
                if (profile.modelId.isNotEmpty)
                  Text(
                    profile.modelId,
                    style: const TextStyle(
                      color: Color(0xFF83918F),
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open purifier',
            onPressed: onOpen,
            icon: const Icon(Icons.play_circle_outline),
          ),
          IconButton(
            tooltip: 'Edit purifier',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Remove purifier',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _PurifierFeatures extends StatelessWidget {
  const _PurifierFeatures();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Local Xiaomi link',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 4),
        Text(
          'No Xiaomi account or cloud call is used.',
          style: TextStyle(color: Color(0xFF92A3A1), fontSize: 12),
        ),
        SizedBox(height: 12),
        _FeatureRow(
          icon: Icons.lan_outlined,
          title: 'Local miIO',
          detail: 'UDP 54321 on the device’s private address',
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.check_circle_outline,
          title: 'Verified writes',
          detail: 'Every change is read back from the device',
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.key_outlined,
          title: 'Token storage',
          detail: 'Android keystore, never in the profile JSON',
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
