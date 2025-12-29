import 'dart:typed_data';
import '../models/update_progress.dart';

/// Abstract interface for SMP (Simple Management Protocol) operations
/// Used for firmware updates via Nordic McuMgr
abstract class SMPClient {
  /// Connect to a device via SMP
  /// 
  /// [mac] - MAC address of the target device (e.g., "AA:BB:CC:DD:EE:FF")
  /// Returns true if connection successful, false otherwise
  Future<bool> connect(String mac);

  /// Disconnect from the current SMP session
  Future<void> disconnect();

  /// Upload firmware to the connected device
  /// 
  /// [mac] - MAC address of the target device
  /// [data] - Firmware binary data
  /// Returns a stream of UpdateProgress events
  Stream<UpdateProgress> uploadFirmware(String mac, Uint8List data);

  /// Get the current MTU (Maximum Transmission Unit) size
  /// Returns the MTU size in bytes
  Future<int> getMTU();

  /// Reset the device after firmware upload
  /// 
  /// [mac] - MAC address of the target device
  /// Returns true if reset successful, false otherwise
  Future<bool> resetDevice(String mac);
}
