import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_endpoint.dart';
import 'camera_profile.dart';
import 'debug_hinen_import.dart';
import 'debug_token_import.dart';
import 'grid_viewer.dart';
import 'home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (kDebugMode) {
    await importDebugTokenIfPresent();
    await importDebugHinenKeyIfPresent();
  }
  runApp(const HiMostApp());
}

class HiMostApp extends StatefulWidget {
  const HiMostApp({super.key});

  @override
  State<HiMostApp> createState() => _HiMostAppState();
}

class _HiMostAppState extends State<HiMostApp> {
  static const _deepLinkChannel = MethodChannel('localhome/deeplink');
  static const _profilesKey = 'camera_profiles';
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _deepLinkChannel.setMethodCallHandler(_handleDeepLink);
  }

  @override
  void dispose() {
    _deepLinkChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handleDeepLink(MethodCall call) async {
    if (call.method != 'openCamera') return;
    final target = call.arguments;
    if (target is! String || target.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_profilesKey);
    if (encoded == null) return;
    final decoded = jsonDecode(encoded);
    if (decoded is! List) return;
    CameraProfile? profile;
    for (final entry in decoded) {
      if (entry is! Map) continue;
      try {
        final candidate = CameraProfile.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (candidate.id == target ||
            candidate.address == target ||
            candidate.name == target) {
          profile = candidate;
          break;
        }
      } on Object {
        continue;
      }
    }
    if (profile == null) return;
    final selected = profile;
    void open() {
      _navigatorKey.currentState?.push<void>(
        MaterialPageRoute(
          builder: (_) => GridViewerPage(
            profiles: [selected],
            singleCamera: true,
          ),
        ),
      );
    }

    if (_navigatorKey.currentState == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => open());
    } else {
      open();
    }
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF92E6B5);
    return MaterialApp(
      title: 'LocalHome',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
          surface: const Color(0xFF10191A),
        ),
        scaffoldBackgroundColor: const Color(0xFF091112),
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF142021),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF273738)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: accent, width: 1.5),
          ),
        ),
      ),
      home: const HomeShell(cameras: CameraHomePage()),
    );
  }
}

class CameraHomePage extends StatefulWidget {
  const CameraHomePage({super.key});

  @override
  State<CameraHomePage> createState() => _CameraHomePageState();
}

class _CameraHomePageState extends State<CameraHomePage> {
  static const _profilesKey = 'camera_profiles';

  List<CameraProfile> _profiles = const [];
  bool _loaded = false;
  final bool _riskAccepted = true;
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
      List<CameraProfile> profiles;
      if (encoded == null) {
        profiles = _migrateProfiles(preferences);
        await _saveProfiles(profiles, preferences: preferences);
      } else {
        final decoded = jsonDecode(encoded);
        if (decoded is! List) {
          throw const FormatException('Camera profile data is invalid.');
        }
        profiles = decoded
            .map(
              (entry) => CameraProfile.fromJson(
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
    } on Object catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load camera profiles from this device.';
        _loaded = true;
      });
    }
  }

  List<CameraProfile> _migrateProfiles(SharedPreferences preferences) {
    const defaults = [
      CameraProfile(
        id: 'camera-1',
        name: 'Camera 1',
        address: '192.168.1.100',
        path: '/live/ch00_0',
      ),
      CameraProfile(
        id: 'camera-2',
        name: 'Camera 2',
        address: '192.168.1.101',
        path: '/live/ch00_0',
      ),
      CameraProfile(
        id: 'camera-3',
        name: 'Camera 3',
        address: '192.168.1.102',
        path: '/live/ch00_0',
      ),
    ];
    return List.generate(defaults.length, (index) {
      final profile = defaults[index];
      return profile.copyWith(
        address:
            preferences.getString('camera_address_$index') ??
            (index == 0 ? preferences.getString('camera_address') : null) ??
            profile.address,
        path:
            preferences.getString('camera_path_$index') ??
            (index == 0 ? preferences.getString('camera_rtsp_path') : null) ??
            profile.path,
      );
    });
  }

  Future<void> _saveProfiles(
    List<CameraProfile> profiles, {
    SharedPreferences? preferences,
  }) async {
    final store = preferences ?? await SharedPreferences.getInstance();
    await store.setString(
      _profilesKey,
      jsonEncode(profiles.map((profile) => profile.toJson()).toList()),
    );
  }

  Future<void> _addCamera() async {
    final profile = await showDialog<CameraProfile>(
      context: context,
      builder: (context) => const _CameraProfileDialog(),
    );
    if (profile == null) return;
    final updated = [..._profiles, profile];
    await _saveProfiles(updated);
    if (mounted) setState(() => _profiles = updated);
  }

  Future<void> _editCamera(CameraProfile original) async {
    final profile = await showDialog<CameraProfile>(
      context: context,
      builder: (context) => _CameraProfileDialog(profile: original),
    );
    if (profile == null) return;
    final updated = [
      for (final item in _profiles)
        if (item.id == profile.id) profile else item,
    ];
    await _saveProfiles(updated);
    if (mounted) setState(() => _profiles = updated);
  }

  Future<void> _removeCamera(CameraProfile profile) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove camera?'),
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
    final updated = _profiles.where((item) => item.id != profile.id).toList();
    await _saveProfiles(updated);
    if (mounted) setState(() => _profiles = updated);
  }

  void _openGrid() {
    if (!_riskAccepted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GridViewerPage(profiles: _profiles),
      ),
    );
  }

  void _openCamera(CameraProfile profile) {
    if (!_riskAccepted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GridViewerPage(profiles: [profile], singleCamera: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalHome'),
        actions: [
          TextButton.icon(
            onPressed: _riskAccepted && _profiles.isNotEmpty
                ? () => _openGrid()
                : null,
            icon: const Icon(Icons.grid_view_rounded),
            label: const Text('View all'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loaded ? _addCamera : null,
        icon: const Icon(Icons.add),
        label: const Text('Add camera'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
          children: [
            const Text(
              'CAMERAS · DIRECT LAN',
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
                    'Your cameras',
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
              'Add cameras by local IP. Open one feed or view them together.',
              style: TextStyle(color: Color(0xFF92A3A1), fontSize: 12),
            ),
            const SizedBox(height: 14),
            if (!_loaded)
              const Center(child: CircularProgressIndicator())
            else if (_loadError != null)
              _MessageCard(message: _loadError!)
            else if (_profiles.isEmpty)
              const _MessageCard(
                message: 'No cameras yet. Use Add camera to create a profile.',
              )
            else
              for (final profile in _profiles) ...[
                _CameraProfileCard(
                  profile: profile,
                  canOpen: _riskAccepted,
                  onOpen: () => _openCamera(profile),
                  onEdit: () => _editCamera(profile),
                  onRemove: () => _removeCamera(profile),
                ),
                const SizedBox(height: 10),
              ],
            const SizedBox(height: 16),
            const _CameraFeatures(),
          ],
        ),
      ),
    );
  }
}

class _CameraProfileDialog extends StatefulWidget {
  const _CameraProfileDialog({this.profile});

  final CameraProfile? profile;

  @override
  State<_CameraProfileDialog> createState() => _CameraProfileDialogState();
}

class _CameraProfileDialogState extends State<_CameraProfileDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _pathController;
  late final TextEditingController _lanPasswordController;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _nameController = TextEditingController(text: profile?.name ?? '');
    _addressController = TextEditingController(text: profile?.address ?? '');
    _pathController = TextEditingController(
      text: profile?.path ?? '/live/ch00_0',
    );
    _lanPasswordController = TextEditingController(
      text: profile?.lanPassword ?? '',
    );
  }

  void _save() {
    final name = _nameController.text.trim();
    final address = _addressController.text.trim();
    final path = _pathController.text.trim();
    final lanPassword = _lanPasswordController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a camera name.');
      return;
    }
    try {
      CameraEndpoint.parse(address: address, path: path);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.of(context).pop(
      CameraProfile(
        id:
            widget.profile?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        address: address,
        path: path,
        lanPassword: lanPassword,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _pathController.dispose();
    _lanPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.profile == null ? 'Add camera' : 'Edit camera'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Camera name'),
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
                hintText: '192.168.1.101',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pathController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'RTSP path',
                hintText: '/live/ch00_0',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lanPasswordController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Camera LAN password (talk and light)',
                hintText: 'QR field 8',
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

class _CameraProfileCard extends StatelessWidget {
  const _CameraProfileCard({
    required this.profile,
    required this.canOpen,
    required this.onOpen,
    required this.onEdit,
    required this.onRemove,
  });

  final CameraProfile profile;
  final bool canOpen;
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
          const Icon(Icons.videocam_outlined, color: Color(0xFF92E6B5)),
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
                  '${profile.address}:554',
                  style: const TextStyle(
                    color: Color(0xFF92A3A1),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'View camera',
            onPressed: canOpen ? onOpen : null,
            icon: const Icon(Icons.play_circle_outline),
          ),
          IconButton(
            tooltip: 'Edit camera',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Remove camera',
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _CameraFeatures extends StatelessWidget {
  const _CameraFeatures();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Camera features',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 4),
        Text(
          'Verified against the cameras on this network.',
          style: TextStyle(color: Color(0xFF92A3A1), fontSize: 12),
        ),
        SizedBox(height: 12),
        _FeatureRow(
          icon: Icons.videocam_outlined,
          title: 'Live view',
          detail: 'RTSP stream over the local network',
          confirmed: true,
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.lightbulb_outline,
          title: 'Camera light',
          detail: 'ON / AUTO / OFF over the local LAN session',
          confirmed: true,
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.control_camera_outlined,
          title: 'PTZ',
          detail: 'Local ONVIF pan and tilt confirmed',
          confirmed: true,
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.mic_none_rounded,
          title: 'Talkback',
          detail: 'LAN audio sends; camera playback not confirmed',
        ),
        SizedBox(height: 8),
        _FeatureRow(
          icon: Icons.video_library_outlined,
          title: 'Recordings',
          detail: 'Not confirmed on this firmware',
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
    this.confirmed = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool confirmed;

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
          Icon(
            icon,
            color: confirmed
                ? const Color(0xFF92E6B5)
                : const Color(0xFF71817F),
            size: 20,
          ),
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
          Icon(
            confirmed ? Icons.check_circle_outline : Icons.lock_outline,
            color: confirmed
                ? const Color(0xFF92E6B5)
                : const Color(0xFF687775),
            size: 16,
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
