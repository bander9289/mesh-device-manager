import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'smp_client.dart';

/// Platform channel implementation of SMPClient
/// Communicates with Android SMPPlugin via MethodChannel
class PlatformSMPClient implements SMPClient {
  static const MethodChannel _channel = MethodChannel('smp_plugin');
  static const EventChannel _eventChannel = EventChannel('smp_plugin/events');
  
  StreamSubscription? _eventSubscription;
  StreamController<UpdateProgress>? _uploadController;

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
      debugPrint('PlatformSMPClient: received event type=$type');
    }

    switch (type) {
      case 'progress':
        final current = event['current'] as int? ?? 0;
        final total = event['total'] as int? ?? 0;
        final percentage = event['percentage'] as int? ?? 0;
        _uploadController?.add(UpdateProgress(
          current: current,
          total: total,
          percentage: percentage,
        ));
        break;
      case 'completed':
        _uploadController?.close();
        _uploadController = null;
        break;
      case 'error':
        final message = event['message'] as String? ?? 'Unknown error';
        _uploadController?.addError(Exception('Upload failed: $message'));
        _uploadController?.close();
        _uploadController = null;
        break;
      case 'cancelled':
        _uploadController?.addError(Exception('Upload cancelled'));
        _uploadController?.close();
        _uploadController = null;
        break;
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

    _uploadController = StreamController<UpdateProgress>();

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
      _uploadController?.addError(Exception('Upload failed: ${e.message}'));
      _uploadController?.close();
      _uploadController = null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlatformSMPClient: unexpected upload error: $e');
      }
      _uploadController?.addError(e);
      _uploadController?.close();
      _uploadController = null;
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
  }
}
