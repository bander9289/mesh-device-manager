import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'managers/device_manager.dart';
import 'managers/firmware_manager.dart';
import 'screens/devices_screen.dart';
import 'screens/updates_screen.dart';

void main() {
  runApp(const NordicMeshManagerApp());
}

class NordicMeshManagerApp extends StatelessWidget {
  const NordicMeshManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DeviceManager()),
        ChangeNotifierProvider(create: (_) => FirmwareManager()),
      ],
      child: MaterialApp(
        title: 'Nordic Mesh Manager',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        ),
        home: const MainTabs(),
      ),
    );
  }
}

// Backwards-compatible alias used by widget tests.
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const NordicMeshManagerApp();
}

class MainTabs extends StatelessWidget {
  const MainTabs({super.key});
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Nordic Mesh Manager'),
          bottom: const TabBar(tabs: [Tab(text: 'Devices'), Tab(text: 'Updates')]),
        ),
        body: const TabBarView(children: [DevicesScreen(), UpdatesScreen()]),
      ),
    );
  }
}
