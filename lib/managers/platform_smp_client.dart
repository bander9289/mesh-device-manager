import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/update_progress.dart';
import 'smp_client.dart';

/// Platform channel implementation of SMPClient
/// Communicates with Android SMPPlugin via MethodChannel
class PlatformSMPClient implements SMPClient {
  static const MethodChannel _channel = MethodChannel('smp_plugin');
  static const EventChannel _eventChannel = EventChannel('smp_plugin/events');
  
  StreamSubscription? _eventSubscription;
  StreamController<UpdateProgress>? _uploadController;
  String? _currentDeviceMac;
  DateTime? _uploadStartTime;

  PlatformSMPClient() {
    // Listen to event channel for upload progress
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        _handleEvent(event.cast<String, dynamic>());
      }
    }, onError: (error) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: event channel error: $error');
      }
      _uploadController?.addError(error);
    });
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (kDebugMode) {
      debugPrint('PlatformSMPClient: received event type=$type, data=$event');
    }

    switch (type) {
      case 'progress':
        final deviceMac = event['deviceMac'] as String? ?? _currentDeviceMac ?? '';
        final bytesTransferred = event['bytesTransferred'] as int? ?? 0;
        final totalBytes = event['totalBytes'] as int? ?? 0;
        final stageStr = event['stage'] as String? ?? 'idle';
        
        // Parse stage from string
        final stage = _parseUpdateStage(stageStr);
        
        final progress = UpdateProgress(
          deviceMac: deviceMac,
          bytesTransferred: bytesTransferred,
          totalBytes: totalBytes,
          stage: stage,
          startedAt: _uploadStartTime,
        );
        
        _uploadController?.add(progress);
        break;
        
      case 'completed':
        if (_currentDeviceMac != null) {
          final progress = UpdateProgress(
            deviceMac: _currentDeviceMac!,
            bytesTransferred: 0,
            totalBytes: 0,
            stage: UpdateStage.complete,
            startedAt: _uploadStartTime,
            completedAt: DateTime.now(),
          );
          _uploadController?.add(progress);
        }
        _uploadController?.close();
        _uploadController = null;
        _currentDeviceMac = null;
        _uploadStartTime = null;
        break;
        
      case 'error':
        final message = event['message'] as String? ?? 'Unknown error';
        if (_currentDeviceMac != null) {
          final progress = UpdateProgress(
            deviceMac: _currentDeviceMac!,
            bytesTransferred: 0,
            totalBytes: 0,
            stage: UpdateStage.failed,
            errorMessage: message,
            startedAt: _uploadStartTime,
            completedAt: DateTime.now(),
          );
          _uploadController?.add(progress);
        }
        _uploadController?.addError(Exception('Upload failed: $message'));
        _uploadController?.close();
        _uploadController = null;
        _currentDeviceMac = null;
        _uploadStartTime = null;
        break;
        
      case 'cancelled':
        if (_currentDeviceMac != null) {
          final progress = UpdateProgress(
            deviceMac: _currentDeviceMac!,
            bytesTransferred: 0,
            totalBytes: 0,
            stage: UpdateStage.failed,
            errorMessage: 'Upload cancelled',
            startedAt: _uploadStartTime,
            completedAt: DateTime.now(),
          );
          _uploadController?.add(progress);
        }
        _uploadController?.addError(Exception('Upload cancelled'));
        _uploadController?.close();
        _uploadController = null;
        _currentDeviceMac = null;
        _uploadStartTime = null;
        break;
    }
  }

  UpdateStage _parseUpdateStage(String stageStr) {
    switch (stageStr.toLowerCase()) {
      case 'connecting':
        return UpdateStage.connecting;
      case 'uploading':
        return UpdateStage.uploading;
      case 'verifying':
        return UpdateStage.verifying;
      case 'rebooting':
        return UpdateStage.rebooting;
      case 'complete':
        return UpdateStage.complete;
      case 'failed':
        return UpdateStage.failed;
      default:
        return UpdateStage.idle;
    }
  }

  @override
  Future<bool> connect(String mac) async {
    try {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: connecting to $mac');
      }
      
      final result = await _channel.invokeMethod<bool>('connectSMP', {
        'mac': mac,
      });
      
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: connection result=$result');
      }
      
      return result ?? false;
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: connection failed: ${e.message}');
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: unexpected error during connect: $e');
      }
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: disconnecting');
      }
      
      await _channel.invokeMethod('disconnectSMP');
      
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: disconnected');
      }
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: disconnect failed: ${e.message}');
      }
      rethrow;
    }
  }

  @override
  Stream<UpdateProgress> uploadFirmware(String mac, Uint8List data) {
    if (_uploadController != null) {
      throw StateError('Upload already in progress');
    }

    _currentDeviceMac = mac;
    _uploadStartTime = DateTime.now();
    _uploadController = StreamController<UpdateProgress>();

    // Send initial progress
    _uploadController!.add(UpdateProgress(
      deviceMac: mac,
      bytesTransferred: 0,
      totalBytes: data.length,
      stage: UpdateStage.idle,
      startedAt: _uploadStartTime,
    ));

    // Start the upload in the background
    _startUpload(mac, data);

    return _uploadController!.stream;
  }

  Future<void> _startUpload(String mac, Uint8List data) async {
    try {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: starting upload to $mac (${data.length} bytes)');
      }

      // This call will trigger progress events via the event channel
      await _channel.invokeMethod('uploadFirmware', {
        'mac': mac,
        'firmwareData': data,
      });

    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: upload failed: ${e.message}');
      }
      
      if (_currentDeviceMac != null) {
        final progress = UpdateProgress(
          deviceMac: _currentDeviceMac!,
          bytesTransferred: 0,
          totalBytes: data.length,
          stage: UpdateStage.failed,
          errorMessage: e.message ?? 'Upload failed',
          startedAt: _uploadStartTime,
          completedAt: DateTime.now(),
        );
        _uploadController?.add(progress);
      }
      
      _uploadController?.addError(Exception('Upload failed: ${e.message}'));
      _uploadController?.close();
      _uploadController = null;
      _currentDeviceMac = null;
      _uploadStartTime = null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: unexpected upload error: $e');
      }
      
      if (_currentDeviceMac != null) {
        final progress = UpdateProgress(
          deviceMac: _currentDeviceMac!,
          bytesTransferred: 0,
          totalBytes: data.length,
          stage: UpdateStage.failed,
          errorMessage: e.toString(),
          startedAt: _uploadStartTime,
          completedAt: DateTime.now(),
        );
        _uploadController?.add(progress);
      }
      
      _uploadController?.addError(e);
      _uploadController?.close();
      _uploadController = null;
      _currentDeviceMac = null;
      _uploadStartTime = null;
    }
  }

  @override
  Future<int> getMTU() async {
    try {
      final result = await _channel.invokeMethod<int>('getMTU');
      return result ?? 23; // Default MTU
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: getMTU failed: ${e.message}');
      }
      return 23; // Default MTU
    }
  }

  @override
  Future<bool> resetDevice(String mac) async {
    try {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: resetting device $mac');
      }
      
      final result = await _channel.invokeMethod<bool>('resetDevice', {
        'mac': mac,
      });
      
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: reset result=$result');
      }
      
      return result ?? false;
    } on PlatformException catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: reset failed: ${e.message}');
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: unexpected error during reset: $e');
      }
      return false;
    }
  }

  /// Clean up resources
  void dispose() {
    _eventSubscription?.cancel();
    _uploadController?.close();
    _currentDeviceMac = null;
    _uploadStartTime = null;
  }
}
