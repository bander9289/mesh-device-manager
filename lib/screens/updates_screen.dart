import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../managers/device_manager.dart';
import '../managers/firmware_manager.dart';
import '../models/mesh_device.dart';
import '../models/firmware_file.dart';
import '../models/update_progress.dart';
import '../widgets/firmware_list_section.dart';
import '../widgets/update_controls_section.dart';
import '../widgets/device_update_card.dart';

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  DeviceSelectionMode _selectionMode = DeviceSelectionMode.outOfDate;
  final Set<String> _selectedDevices = {};
  final Map<String, UpdateProgress> _updateProgress = {};
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    // Listen to firmware manager changes to update selection
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final firmwareManager = context.read<FirmwareManager>();
      firmwareManager.addListener(_updateDeviceSelection);
    });
  }

  @override
  void dispose() {
    final firmwareManager = context.read<FirmwareManager>();
    firmwareManager.removeListener(_updateDeviceSelection);
    super.dispose();
  }

  void _updateDeviceSelection() {
    if (_selectionMode != DeviceSelectionMode.manual) {
      setState(() {
        _applySelectionMode(_selectionMode);
      });
    }
  }

  void _applySelectionMode(DeviceSelectionMode mode) {
    final deviceManager = context.read<DeviceManager>();
    final firmwareManager = context.read<FirmwareManager>();
    final devicesWithFirmware = _getDevicesWithMatchingFirmware();

    _selectedDevices.clear();

    switch (mode) {
      case DeviceSelectionMode.all:
        _selectedDevices.addAll(
          devicesWithFirmware.map((d) => d.macAddress),
        );
        break;

      case DeviceSelectionMode.none:
        // Already cleared
        break;

      case DeviceSelectionMode.outOfDate:
        // Select devices that need updates
        for (final device in devicesWithFirmware) {
          if (firmwareManager.needsUpdate(device)) {
            _selectedDevices.add(device.macAddress);
          }
        }
        break;

      case DeviceSelectionMode.manual:
        // Keep current selection
        break;
    }
  }

  List<MeshDevice> _getDevicesWithMatchingFirmware() {
    final deviceManager = context.read<DeviceManager>();
    final firmwareManager = context.read<FirmwareManager>();

    return deviceManager.devices.where((device) {
      return firmwareManager.getFirmwareForDevice(device) != null;
    }).toList();
  }

  Future<void> _loadFirmware() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['bin'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final file = result.files.first;
      if (file.path == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not access file')),
          );
        }
        return;
      }

      // Check filename ends with .signed.bin
      if (!file.name.endsWith('.signed.bin')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Only .signed.bin files are supported'),
            ),
          );
        }
        return;
      }

      final firmwareManager = context.read<FirmwareManager>();
      await firmwareManager.loadFirmware(file.path!);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Loaded firmware: ${file.name}'),
            backgroundColor: Colors.green,
          ),
        );

        // Update selection after loading
        setState(() {
          _applySelectionMode(_selectionMode);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load firmware: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _removeFirmware(String hardwareId) {
    final firmwareManager = context.read<FirmwareManager>();
    firmwareManager.removeFirmware(hardwareId);

    setState(() {
      // Remove devices with this hardware ID from selection
      final deviceManager = context.read<DeviceManager>();
      _selectedDevices.removeWhere((mac) {
        final device = deviceManager.devices
            .where((d) => d.macAddress == mac)
            .firstOrNull;
        return device != null && device.hardwareId == hardwareId;
      });
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed firmware for $hardwareId')),
    );
  }

  void _updateSelected() {
    // TODO: Implement update logic with SMP client
    // For now, show a message
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Starting update for ${_selectedDevices.length} device(s)'),
      ),
    );
  }

  void _updateAll() {
    setState(() {
      _applySelectionMode(DeviceSelectionMode.all);
    });
    _updateSelected();
  }

  void _reflashDevice(MeshDevice device) {
    // TODO: Implement reflash logic
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Re-flashing device ${device.macAddress}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deviceManager = context.watch<DeviceManager>();
    final firmwareManager = context.watch<FirmwareManager>();
    final devicesWithFirmware = _getDevicesWithMatchingFirmware();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Firmware Updates'),
      ),
      body: Column(
        children: [
          // Firmware files section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: FirmwareListSection(
              firmware: firmwareManager.loadedFirmware,
              onLoadFirmware: _loadFirmware,
              onRemoveFirmware: _removeFirmware,
            ),
          ),

          // Update controls
          if (firmwareManager.loadedFirmware.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: UpdateControlsSection(
                selectionMode: _selectionMode,
                onSelectionModeChanged: (mode) {
                  setState(() {
                    _selectionMode = mode;
                    _applySelectionMode(mode);
                  });
                },
                allowDowngrade: firmwareManager.allowDowngrade,
                onAllowDowngradeChanged: (value) {
                  firmwareManager.allowDowngrade = value;
                  // Re-apply selection to include/exclude downgrade candidates
                  setState(() {
                    _applySelectionMode(_selectionMode);
                  });
                },
                selectedDeviceCount: _selectedDevices.length,
                totalDeviceCount: devicesWithFirmware.length,
                onUpdateSelected: _selectedDevices.isNotEmpty ? _updateSelected : null,
                onUpdateAll: devicesWithFirmware.isNotEmpty ? _updateAll : null,
                isUpdating: _isUpdating,
              ),
            ),

          const SizedBox(height: 16),

          // Device list
          Expanded(
            child: _buildDeviceList(devicesWithFirmware, firmwareManager),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceList(
    List<MeshDevice> devicesWithFirmware,
    FirmwareManager firmwareManager,
  ) {
    if (firmwareManager.loadedFirmware.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.system_update_alt,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Load a firmware file to see available updates',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    if (devicesWithFirmware.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.devices_other,
              size: 64,
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No devices found for loaded firmware',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Make sure devices are powered on and in range',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant
                        .withOpacity(0.7),
                  ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      itemCount: devicesWithFirmware.length,
      itemBuilder: (context, index) {
        final device = devicesWithFirmware[index];
        final firmware = firmwareManager.getFirmwareForDevice(device)!;
        final isSelected = _selectedDevices.contains(device.macAddress);
        final progress = _updateProgress[device.macAddress];
        final canReflash = firmwareManager.canReflash(device, firmware);

        return DeviceUpdateCard(
          device: device,
          firmware: firmware,
          isSelected: isSelected,
          showCheckbox: _selectionMode == DeviceSelectionMode.manual,
          progress: progress,
          onSelectionChanged: (selected) {
            setState(() {
              if (selected) {
                _selectedDevices.add(device.macAddress);
              } else {
                _selectedDevices.remove(device.macAddress);
              }
            });
          },
          onReflash: canReflash ? () => _reflashDevice(device) : null,
        );
      },
    );
  }
}
