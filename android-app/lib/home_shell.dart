import 'package:flutter/material.dart';

import 'airpurifier_home_page.dart';
import 'hinen_home_page.dart';

/// Minimal device hub: cameras, Xiaomi devices, and energy devices.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.cameras});

  final Widget cameras;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_index) {
        0 => widget.cameras,
        1 => const AirPurifierHomePage(),
        _ => const HinenHomePage(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.videocam_outlined),
            selectedIcon: Icon(Icons.videocam),
            label: 'Cameras',
          ),
          NavigationDestination(
            icon: Icon(Icons.devices_other),
            selectedIcon: Icon(Icons.devices_other),
            label: 'Xiaomi',
          ),
          NavigationDestination(
            icon: Icon(Icons.battery_charging_full_outlined),
            selectedIcon: Icon(Icons.battery_charging_full),
            label: 'Energy',
          ),
        ],
      ),
    );
  }
}
