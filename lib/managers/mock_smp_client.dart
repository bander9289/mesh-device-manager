import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/update_progress.dart';
import 'smp_client.dart';

/// Mock implementation of SMPClient for testing
/// Simulates firmware upload with realistic delays and progress updates
class MockSMPClient implements SMPClient {
  static const Duration _connectionDelay = Duration(seconds: 1);
  static const Duration _uploadSimulationInterval = Duration(milliseconds: 100);
  static const int _bytesPerInterval = 4096; // Simulate 40KB/s upload speed

  bool _isConnected = false;
  String? _connectedMac;
  StreamController<UpdateProgress>? _uploadController;
  Timer? _uploadTimer;
  int _bytesTransferred = 0;
  int _totalBytes = 0;
  DateTime? _uploadStartTime;
  final bool _shouldFail;
  final double _failureRate; // Probability of random failure (0.0 - 1.0)

  MockSMPClient({bool shouldFail = false, double failureRate = 0.0})
      : _shouldFail = shouldFail,
        _failureRate = failureRate;

  @override
  Future<bool> connect(String mac) async {
    if (kDebugMode) {
      debugPrint('MockSMPClient: connecting to $mac');
    }

    // Simulate connection delay
    await Future.delayed(_connectionDelay);

    // Simulate random connection failures
    if (_shouldFail || (_failureRate > 0 && _random.nextDouble() < _failureRate)) {
      if (kDebugMode) {
        debugPrint('MockSMPClient: connection failed (simulated)');
      }
      return false;
    }

    _isConnected = true;
    _connectedMac = mac;

    if (kDebugMode) {
      debugPrint('MockSMPClient: connected to $mac');
    }

    return true;
  }

  @override
  Future<void> disconnect() async {
    if (kDebugMode) {
      debugPrint('MockSMPClient: disconnecting');
    }

    _uploadTimer?.cancel();
    _uploadTimer = null;
    _uploadController?.close();
    _uploadController = null;
    _isConnected = false;
    _connectedMac = null;
    _bytesTransferred = 0;
    _totalBytes = 0;
    _uploadStartTime = null;

    // Small delay to simulate cleanup
    await Future.delayed(const Duration(milliseconds: 100));

    if (kDebugMode) {
      debugPrint('MockSMPClient: disconnected');
    }
  }

  @override
  Stream<UpdateProgress> uploadFirmware(String mac, Uint8List data) {
    if (_uploadController != null) {
      throw StateError('Upload already in progress');
    }

    if (!_isConnected || _connectedMac != mac) {
      throw StateError('Not connected to device $mac');
    }

    _uploadStartTime = DateTime.now();
    _bytesTransferred = 0;
    _totalBytes = data.length;
    _uploadController = StreamController<UpdateProgress>();

    if (kDebugMode) {
      debugPrint('MockSMPClient: starting upload to $mac (${data.length} bytes)');
    }

    // Start simulated upload
    _simulateUpload(mac);

    return _uploadController!.stream;
  }

  void _simulateUpload(String mac) async {
    try {
      // Stage 1: Connecting
      _sendProgress(mac, UpdateStage.connecting);
      await Future.delayed(const Duration(milliseconds: 500));

      // Check for early failure
      if (_shouldFail || (_failureRate > 0 && _random.nextDouble() < _failureRate)) {
        throw Exception('Connection failed during upload');
      }

      // Stage 2: Uploading
      _sendProgress(mac, UpdateStage.uploading);

      // Simulate chunked upload
      _uploadTimer = Timer.periodic(_uploadSimulationInterval, (timer) {
        _bytesTransferred += _bytesPerInterval;

        if (_bytesTransferred >= _totalBytes) {
          _bytesTransferred = _totalBytes;
          timer.cancel();
          _onUploadComplete(mac);
        } else {
          _sendProgress(mac, UpdateStage.uploading);
        }
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('MockSMPClient: upload failed: $e');
      }
      _sendError(mac, e.toString());
    }
  }

  void _onUploadComplete(String mac) async {
    try {
      // Stage 3: Verifying
      _sendProgress(mac, UpdateStage.verifying);
      await Future.delayed(const Duration(seconds: 2));

      // Check for verification failure
      if (_shouldFail || (_failureRate > 0 && _random.nextDouble() < _failureRate)) {
        throw Exception('Signature verification failed');
      }

      // Stage 4: Complete
      _sendProgress(mac, UpdateStage.complete);
      
      if (kDebugMode) {
        debugPrint('MockSMPClient: upload completed successfully');
      }

      // Close the stream
      _uploadController?.close();
      _uploadController = null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('MockSMPClient: verification failed: $e');
      }
      _sendError(mac, e.toString());
    }
  }

  void _sendProgress(String mac, UpdateStage stage) {
    final progress = UpdateProgress(
      deviceMac: mac,
      bytesTransferred: _bytesTransferred,
      totalBytes: _totalBytes,
      stage: stage,
      startedAt: _uploadStartTime,
      completedAt: stage == UpdateStage.complete ? DateTime.now() : null,
    );

    _uploadController?.add(progress);
  }

  void _sendError(String mac, String message) {
    final progress = UpdateProgress(
      deviceMac: mac,
      bytesTransferred: _bytesTransferred,
      totalBytes: _totalBytes,
      stage: UpdateStage.failed,
      errorMessage: message,
      startedAt: _uploadStartTime,
      completedAt: DateTime.now(),
    );

    _uploadController?.add(progress);
    _uploadController?.addError(Exception(message));
    _uploadController?.close();
    _uploadController = null;
    _uploadTimer?.cancel();
    _uploadTimer = null;
  }

  @override
  Future<int> getMTU() async {
    // Simulate typical MTU
    return 244; // Common MTU for BLE
  }

  @override
  Future<bool> resetDevice(String mac) async {
    if (!_isConnected || _connectedMac != mac) {
      if (kDebugMode) {
        debugPrint('MockSMPClient: not connected to device $mac');
      }
      return false;
    }

    if (kDebugMode) {
      debugPrint('MockSMPClient: resetting device $mac');
    }

    // Simulate reset delay
    await Future.delayed(const Duration(milliseconds: 500));

    // Disconnect after reset
    await disconnect();

    return true;
  }

  // Helper for random number generation
  static final _random = _Random();
}

/// Simple random number generator for testing
class _Random {
  int _seed = DateTime.now().millisecondsSinceEpoch;

  double nextDouble() {
    _seed = (1103515245 * _seed + 12345) & 0x7fffffff;
    return _seed / 0x7fffffff;
  }
}
