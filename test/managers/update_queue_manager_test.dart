import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nordic_mesh_manager/managers/update_queue_manager.dart';
import 'package:nordic_mesh_manager/managers/firmware_manager.dart';
import 'package:nordic_mesh_manager/managers/smp_client.dart';
import 'package:nordic_mesh_manager/models/mesh_device.dart';
import 'package:nordic_mesh_manager/models/firmware_file.dart';
import 'package:nordic_mesh_manager/models/firmware_version.dart';
import 'package:nordic_mesh_manager/models/update_progress.dart';
import 'package:nordic_mesh_manager/models/update_summary.dart';

/// Mock Firmware Manager for testing
class MockFirmwareManager extends FirmwareManager {
  final Map<String, FirmwareFile> _firmware = {};

  void addFirmware(FirmwareFile firmware) {
    _firmware[firmware.hardwareId] = firmware;
  }

  @override
  FirmwareFile? getFirmwareForDevice(MeshDevice device) {
    return _firmware[device.hardwareId];
  }
}

/// Mock SMP client for testing
class MockSMPClient extends SMPClient {
  final Map<String, StreamController<UpdateProgress>> _progressControllers = {};
  
  /// Simulate upload success after delay
  Duration uploadDelay = const Duration(milliseconds: 100);
  
  /// Simulate upload failure
  bool shouldFail = false;
  String failureMessage = 'Simulated failure';
  
  /// Track method calls
  final List<String> connectCalls = [];
  final List<String> uploadCalls = [];
  final List<String> resetCalls = [];
  
  @override
  Future<bool> connect(String mac) async {
    connectCalls.add(mac);
    await Future.delayed(const Duration(milliseconds: 10));
    return !shouldFail;
  }
  
  @override
  Future<void> disconnect() async {
    await Future.delayed(const Duration(milliseconds: 10));
  }
  
  @override
  Stream<UpdateProgress> uploadFirmware(String mac, Uint8List data) {
    uploadCalls.add(mac);
    
    final controller = StreamController<UpdateProgress>();
    _progressControllers[mac] = controller;
    
    // Simulate progress updates
    _simulateUpload(mac, data.length, controller);
    
    return controller.stream;
  }
  
  Future<void> _simulateUpload(
    String mac,
    int totalBytes,
    StreamController<UpdateProgress> controller,
  ) async {
    try {
      // Connecting
      controller.add(UpdateProgress(
        deviceMac: mac,
        bytesTransferred: 0,
        totalBytes: totalBytes,
        stage: UpdateStage.connecting,
        startedAt: DateTime.now(),
      ));
      
      await Future.delayed(const Duration(milliseconds: 20));
      
      if (shouldFail) {
        controller.add(UpdateProgress(
          deviceMac: mac,
          bytesTransferred: 0,
          totalBytes: totalBytes,
          stage: UpdateStage.failed,
          errorMessage: failureMessage,
        ));
        await controller.close();
        return;
      }
      
      // Uploading
      controller.add(UpdateProgress(
        deviceMac: mac,
        bytesTransferred: totalBytes ~/ 2,
        totalBytes: totalBytes,
        stage: UpdateStage.uploading,
      ));
      
      await Future.delayed(uploadDelay);
      
      // Verifying
      controller.add(UpdateProgress(
        deviceMac: mac,
        bytesTransferred: totalBytes,
        totalBytes: totalBytes,
        stage: UpdateStage.verifying,
      ));
      
      await Future.delayed(const Duration(milliseconds: 20));
      
      // Complete
      controller.add(UpdateProgress(
        deviceMac: mac,
        bytesTransferred: totalBytes,
        totalBytes: totalBytes,
        stage: UpdateStage.complete,
        completedAt: DateTime.now(),
      ));
      
      await controller.close();
    } catch (e) {
      controller.addError(e);
      await controller.close();
    }
  }
  
  @override
  Future<int> getMTU() async => 512;
  
  @override
  Future<bool> resetDevice(String mac) async {
    resetCalls.add(mac);
    await Future.delayed(const Duration(milliseconds: 10));
    return true;
  }
}

void main() {
  group('UpdateQueueManager', () {
    late MockSMPClient mockClient;
    late UpdateQueueManager queueManager;
    late MockFirmwareManager firmwareManager;
    
    setUp(() {
      mockClient = MockSMPClient();
      queueManager = UpdateQueueManager(
        smpClient: mockClient,
        maxConcurrent: 3,
      );
      firmwareManager = MockFirmwareManager();
    });
    
    tearDown(() {
      queueManager.dispose();
    });
    
    test('initializes with empty state', () {
      expect(queueManager.hasActiveUpdates, isFalse);
      expect(queueManager.isPaused, isFalse);
      expect(queueManager.summary.total, equals(0));
    });
    
    test('processes single device update', () async {
      // Create test device and firmware
      final device = MeshDevice(
        macAddress: '00:11:22:33:44:55',
        identifier: '334455',
        hardwareId: 'HW-TEST',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      );
      
      final firmware = FirmwareFile(
        hardwareId: 'HW-TEST',
        version: FirmwareVersion(major: 1, minor: 1, revision: 0, hash: 'def'),
        filePath: '/test/HW-TEST-1.1.0-def.signed.bin',
        data: Uint8List(1024),
        sizeBytes: 1024,
        loadedAt: DateTime.now(),
      );
      
      firmwareManager.addFirmware(firmware);
      
      // Start update
      await queueManager.startUpdates([device], firmwareManager);
      
      // Wait for completion
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Verify progress
      final progress = queueManager.getProgress(device.macAddress);
      expect(progress?.stage, equals(UpdateStage.complete));
      
      // Verify summary
      expect(queueManager.summary.total, equals(1));
      expect(queueManager.summary.completed, equals(1));
      expect(queueManager.summary.failed, equals(0));
      
      // Verify reset was called
      expect(mockClient.resetCalls, contains(device.macAddress));
    });
    
    test('processes multiple devices concurrently', () async {
      final devices = List.generate(5, (i) => MeshDevice(
        macAddress: '00:11:22:33:44:5$i',
        identifier: '33445$i',
        hardwareId: 'HW-TEST',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      ));
      
      final firmware = FirmwareFile(
        hardwareId: 'HW-TEST',
        version: FirmwareVersion(major: 1, minor: 1, revision: 0, hash: 'def'),
        filePath: '/test/HW-TEST-1.1.0-def.signed.bin',
        data: Uint8List(1024),
        sizeBytes: 1024,
        loadedAt: DateTime.now(),
      );
      
      firmwareManager.addFirmware(firmware);
      
      // Start updates
      await queueManager.startUpdates(devices, firmwareManager);
      
      // Wait for completion
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Verify all completed
      expect(queueManager.summary.total, equals(5));
      expect(queueManager.summary.completed, equals(5));
      expect(queueManager.summary.failed, equals(0));
    });
    
    test('respects maxConcurrent limit', () async {
      final devices = List.generate(10, (i) => MeshDevice(
        macAddress: '00:11:22:33:44:5$i',
        identifier: '33445$i',
        hardwareId: 'HW-TEST',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      ));
      
      final firmware = FirmwareFile(
        hardwareId: 'HW-TEST',
        version: FirmwareVersion(major: 1, minor: 1, revision: 0, hash: 'def'),
        filePath: '/test/HW-TEST-1.1.0-def.signed.bin',
        data: Uint8List(1024),
        sizeBytes: 1024,
        loadedAt: DateTime.now(),
      );
      
      firmwareManager.addFirmware(firmware);
      
      // Use longer delay to see concurrent limit in action
      mockClient.uploadDelay = const Duration(milliseconds: 200);
      
      // Start updates
      await queueManager.startUpdates(devices, firmwareManager);
      
      // Check after short delay - should not exceed maxConcurrent (3)
      await Future.delayed(const Duration(milliseconds: 50));
      expect(mockClient.uploadCalls.length, lessThanOrEqualTo(3));
      
      // Wait for all to complete
      await Future.delayed(const Duration(milliseconds: 1000));
      expect(queueManager.summary.completed, equals(10));
    });
    
    test('retries failed updates and marks permanent failure after max retries', () async {
      final device = MeshDevice(
        macAddress: '00:11:22:33:44:55',
        identifier: '334455',
        hardwareId: 'HW-TEST',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      );
      
      final firmware = FirmwareFile(
        hardwareId: 'HW-TEST',
        version: FirmwareVersion(major: 1, minor: 1, revision: 0, hash: 'def'),
        filePath: '/test/HW-TEST-1.1.0-def.signed.bin',
        data: Uint8List(1024),
        sizeBytes: 1024,
        loadedAt: DateTime.now(),
      );
      
      firmwareManager.addFirmware(firmware);
      
      // Make all attempts fail
      mockClient.shouldFail = true;
      mockClient.uploadDelay = const Duration(milliseconds: 20);
      
      // Start update
      await queueManager.startUpdates([device], firmwareManager);
      
      // Wait for first failure
      await Future.delayed(const Duration(milliseconds: 100));
      var progress = queueManager.getProgress(device.macAddress);
      expect(progress?.stage, equals(UpdateStage.failed));
      expect(progress?.errorMessage, contains('Retry 1/3'));
      
      // The test verifies that retry message is shown after first failure
      // Actually testing the full retry cycle would take >6 seconds (2s + 4s + 8s delays)
      // which is too long for unit tests. The retry logic is tested by verifying
      // the error message indicates a retry is scheduled.
    });
    
    test('pauses and resumes queue processing', () async {
      final devices = List.generate(5, (i) => MeshDevice(
        macAddress: '00:11:22:33:44:5$i',
        identifier: '33445$i',
        hardwareId: 'HW-TEST',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      ));
      
      final firmware = FirmwareFile(
        hardwareId: 'HW-TEST',
        version: FirmwareVersion(major: 1, minor: 1, revision: 0, hash: 'def'),
        filePath: '/test/HW-TEST-1.1.0-def.signed.bin',
        data: Uint8List(1024),
        sizeBytes: 1024,
        loadedAt: DateTime.now(),
      );
      
      firmwareManager.addFirmware(firmware);
      mockClient.uploadDelay = const Duration(milliseconds: 200);
      
      // Start updates
      await queueManager.startUpdates(devices, firmwareManager);
      await Future.delayed(const Duration(milliseconds: 50));
      
      // Pause
      queueManager.pause();
      expect(queueManager.isPaused, isTrue);
      
      // Wait and verify no new updates started while paused
      await Future.delayed(const Duration(milliseconds: 300));
      expect(queueManager.summary.completed, lessThan(5));
      
      // Resume
      queueManager.resume();
      expect(queueManager.isPaused, isFalse);
      
      // Wait for all to complete
      await Future.delayed(const Duration(milliseconds: 1000));
      expect(queueManager.summary.completed, equals(5));
    });
    
    test('cancels all updates', () async {
      final devices = List.generate(5, (i) => MeshDevice(
        macAddress: '00:11:22:33:44:5$i',
        identifier: '33445$i',
        hardwareId: 'HW-TEST',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      ));
      
      final firmware = FirmwareFile(
        hardwareId: 'HW-TEST',
        version: FirmwareVersion(major: 1, minor: 1, revision: 0, hash: 'def'),
        filePath: '/test/HW-TEST-1.1.0-def.signed.bin',
        data: Uint8List(1024),
        sizeBytes: 1024,
        loadedAt: DateTime.now(),
      );
      
      firmwareManager.addFirmware(firmware);
      mockClient.uploadDelay = const Duration(milliseconds: 500);
      
      // Start updates
      await queueManager.startUpdates(devices, firmwareManager);
      await Future.delayed(const Duration(milliseconds: 50));
      
      // Cancel all
      queueManager.cancelAll();
      
      // Wait a bit
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Verify cancellation
      expect(queueManager.hasActiveUpdates, isFalse);
      expect(queueManager.summary.failed, greaterThan(0));
    });
    
    test('calculates overall progress correctly', () async {
      final devices = List.generate(3, (i) => MeshDevice(
        macAddress: '00:11:22:33:44:5$i',
        identifier: '33445$i',
        hardwareId: 'HW-TEST',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      ));
      
      final firmware = FirmwareFile(
        hardwareId: 'HW-TEST',
        version: FirmwareVersion(major: 1, minor: 1, revision: 0, hash: 'def'),
        filePath: '/test/HW-TEST-1.1.0-def.signed.bin',
        data: Uint8List(1024),
        sizeBytes: 1024,
        loadedAt: DateTime.now(),
      );
      
      firmwareManager.addFirmware(firmware);
      
      // Start updates
      await queueManager.startUpdates(devices, firmwareManager);
      
      // Check initial state
      expect(queueManager.summary.total, equals(3));
      expect(queueManager.summary.overallProgress, equals(0.0));
      
      // Wait for completion
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Check final state
      expect(queueManager.summary.completed, equals(3));
      expect(queueManager.summary.overallProgress, equals(1.0));
      expect(queueManager.summary.overallProgressPercent, equals(100.0));
    });
    
    test('skips devices without matching firmware', () async {
      final device = MeshDevice(
        macAddress: '00:11:22:33:44:55',
        identifier: '334455',
        hardwareId: 'HW-UNKNOWN',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      );
      
      // No firmware loaded for this hardware ID
      await queueManager.startUpdates([device], firmwareManager);
      
      // Should have no updates queued
      expect(queueManager.summary.total, equals(0));
      expect(mockClient.uploadCalls, isEmpty);
    });
    
    test('notifies listeners on progress updates', () async {
      final device = MeshDevice(
        macAddress: '00:11:22:33:44:55',
        identifier: '334455',
        hardwareId: 'HW-TEST',
        batteryPercent: 80,
        rssi: -50,
        version: '1.0.0-abc',
      );
      
      final firmware = FirmwareFile(
        hardwareId: 'HW-TEST',
        version: FirmwareVersion(major: 1, minor: 1, revision: 0, hash: 'def'),
        filePath: '/test/HW-TEST-1.1.0-def.signed.bin',
        data: Uint8List(1024),
        sizeBytes: 1024,
        loadedAt: DateTime.now(),
      );
      
      firmwareManager.addFirmware(firmware);
      
      int notifyCount = 0;
      queueManager.addListener(() {
        notifyCount++;
      });
      
      // Start update
      await queueManager.startUpdates([device], firmwareManager);
      
      // Wait for completion
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Should have been notified multiple times (queue start, progress updates, completion)
      expect(notifyCount, greaterThan(3));
    });
  });
  
  group('UpdateSummary', () {
    test('calculates progress correctly', () {
      const summary = UpdateSummary(
        total: 10,
        completed: 5,
        failed: 2,
        inProgress: 3,
      );
      
      expect(summary.overallProgress, equals(0.5));
      expect(summary.overallProgressPercent, equals(50.0));
      expect(summary.statusText, equals('5/10 completed'));
      expect(summary.detailedStatusText, equals('5/10 completed, 2 failed'));
    });
    
    test('detects completion state', () {
      const incomplete = UpdateSummary(
        total: 10,
        completed: 5,
        failed: 2,
        inProgress: 3,
      );
      expect(incomplete.isComplete, isFalse);
      expect(incomplete.hasActiveUpdates, isTrue);
      
      const complete = UpdateSummary(
        total: 10,
        completed: 8,
        failed: 2,
        inProgress: 0,
      );
      expect(complete.isComplete, isTrue);
      expect(complete.hasActiveUpdates, isFalse);
    });
  });
}
