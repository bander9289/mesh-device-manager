import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../managers/device_manager.dart';
import '../managers/firmware_manager.dart';
import '../managers/gatt_mesh_client.dart';
import '../managers/update_queue_manager.dart';
import '../models/mesh_device.dart';
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
  final Map<String, String> _deviceErrors = {};
  bool _isUpdating = false;
  UpdateQueueManager? _queueManager;

  @override
  void initState() {
    super.initState();
    // Listen to firmware manager changes to update selection
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final firmwareManager = context.read<FirmwareManager>();
      firmwareManager.addListener(_updateDeviceSelection);
      
      // Initialize queue manager
      final deviceManager = context.read<DeviceManager>();
      final meshClient = deviceManager.meshClient;
      if (meshClient is GattMeshClient) {
        _queueManager = UpdateQueueManager(
          smpClient: meshClient.smpClient,
          maxConcurrent: 10,
        );
        _queueManager!.addListener(_onQueueUpdate);
      }
    });
  }

  @override
  void dispose() {
    context.read<FirmwareManager>().removeListener(_updateDeviceSelection);
    _queueManager?.removeListener(_onQueueUpdate);
    _queueManager?.dispose();
    super.dispose();
  }

  void _onQueueUpdate() {
    if (mounted && _queueManager != null) {
      setState(() {
        // Sync queue manager's progress to local state
        _updateProgress.clear();
        _updateProgress.addAll(_queueManager!.allProgress);
      });
    }
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

  Future<void> _updateSelected() async {
    if (_queueManager == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Firmware updates not available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final selectedDevices = _getSelectedDevices();
    if (selectedDevices.isEmpty) return;

    // Show confirmation dialog
    final confirmed = await _showUpdateConfirmation(selectedDevices);
    if (!confirmed || !mounted) return;

    setState(() {
      _isUpdating = true;
      _deviceErrors.clear();
    });

    // Use UpdateQueueManager for automatic retry
    final firmwareManager = context.read<FirmwareManager>();
    await _queueManager!.startUpdates(selectedDevices, firmwareManager);

    setState(() => _isUpdating = false);

    // Show completion message
    if (mounted) {
      final summary = _queueManager!.summary;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Updates complete: ${summary.completed}/${summary.total} successful',
          ),
          backgroundColor: summary.failed == 0 ? Colors.green : Colors.orange,
        ),
      );
    }
  }

  List<MeshDevice> _getSelectedDevices() {
    if (!mounted) return [];
    final deviceManager = context.read<DeviceManager>();
    return deviceManager.devices
        .where((d) => _selectedDevices.contains(d.macAddress))
        .toList();
  }

  void _retryDevice(MeshDevice device) {
    if (_queueManager == null) return;
    
    final firmwareManager = context.read<FirmwareManager>();
    setState(() => _isUpdating = true);
    _queueManager!.startUpdates([device], firmwareManager);
  }

  Future<bool> _showUpdateConfirmation(List<MeshDevice> devices) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm Firmware Update'),
            content: Text(
              'Update firmware on ${devices.length} device(s)?\n\n'
              'This will take several minutes and devices will reboot.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Update'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _updateAll() {
    setState(() {
      _applySelectionMode(DeviceSelectionMode.all);
    });
    _updateSelected();
  }

  Future<void> _reflashDevice(MeshDevice device) async {
    if (_queueManager == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Firmware updates not available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final firmwareManager = context.read<FirmwareManager>();
    final firmware = firmwareManager.getFirmwareForDevice(device);
    if (firmware == null) return;

    // Show confirmation
    final confirmed = await _showReflashConfirmation(device);
    if (!confirmed || !mounted) return;

    setState(() => _isUpdating = true);

    // Use UpdateQueueManager for reflash
    await _queueManager!.startUpdates([device], firmwareManager);

    if (mounted) {
      final progress = _updateProgress[device.macAddress];
      if (progress != null && progress.stage == UpdateStage.complete) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Re-flash complete for ${device.macAddress}'),
            backgroundColor: Colors.green,
          ),
        );
      } else if (progress != null && progress.stage == UpdateStage.failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Re-flash failed: ${progress.errorMessage}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }

    setState(() => _isUpdating = false);
  }

  Future<bool> _showReflashConfirmation(MeshDevice device) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm Re-flash'),
            content: Text(
              'Re-flash firmware on device ${device.macAddress}?\n\n'
              'This will reinstall the same firmware version. '
              'The device will reboot.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Re-flash'),
              ),
            ],
          ),
        ) ??
        false;
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
          onRetry: (progress != null && progress.stage == UpdateStage.failed)
              ? () => _retryDevice(device)
              : null,
        );
      },
    );
  }
}
