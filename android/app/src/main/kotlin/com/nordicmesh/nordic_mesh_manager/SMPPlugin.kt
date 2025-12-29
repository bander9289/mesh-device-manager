package com.nordicmesh.nordic_mesh_manager

import android.content.Context
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SMPPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "SMPPlugin"
        private const val CHANNEL = "smp_plugin"
        private const val EVENT_CHANNEL = "smp_plugin/events"
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // TODO: These will be initialized once McuMgr dependencies are properly resolved
    // private var transport: McuMgrBleTransport? = null
    // private var imageManager: ImageManager? = null
    // private var defaultManager: DefaultManager? = null
    // private var uploadController: TransferController? = null

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        methodChannel = MethodChannel(flutterPluginBinding.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler(this)
        
        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
                Log.d(TAG, "Event channel listener attached")
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                Log.d(TAG, "Event channel listener cancelled")
            }
        })
        
        Log.d(TAG, "SMPPlugin attached to engine")
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        disconnect()
        Log.d(TAG, "SMPPlugin detached from engine")
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        when (call.method) {
            "connectSMP" -> {
                val mac = call.argument<String>("mac")
                if (mac.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "MAC address is required", null)
                    return
                }
                Log.d(TAG, "connectSMP called with mac=$mac")
                // TODO: Implement actual connection once McuMgr is available
                result.success(true)
            }
            "disconnectSMP" -> {
                Log.d(TAG, "disconnectSMP called")
                disconnect()
                result.success(true)
            }
            "uploadFirmware" -> {
                val mac = call.argument<String>("mac")
                val firmwareData = call.argument<ByteArray>("firmwareData")
                if (mac.isNullOrEmpty() || firmwareData == null) {
                    result.error("INVALID_ARGS", "MAC address and firmware data are required", null)
                    return
                }
                Log.d(TAG, "uploadFirmware called with mac=$mac, size=${firmwareData.size}")
                // TODO: Implement actual upload once McuMgr is available
                result.error("NOT_IMPLEMENTED", "McuMgr implementation pending", null)
            }
            "getMTU" -> {
                Log.d(TAG, "getMTU called")
                // Return default MTU for now
                result.success(23)
            }
            "resetDevice" -> {
                val mac = call.argument<String>("mac")
                if (mac.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "MAC address is required", null)
                    return
                }
                Log.d(TAG, "resetDevice called with mac=$mac")
                // TODO: Implement actual reset once McuMgr is available
                result.error("NOT_IMPLEMENTED", "McuMgr implementation pending", null)
            }
            else -> {
                Log.d(TAG, "Unknown method: ${call.method}")
                result.notImplemented()
            }
        }
    }

    private fun disconnect() {
        // TODO: Implement cleanup once McuMgr is available
        // uploadController?.cancel()
        // transport?.release()
        Log.d(TAG, "SMP disconnected")
    }
}
