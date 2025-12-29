package com.nordicmesh.nordic_mesh_manager

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import no.nordicsemi.android.mcumgr.McuMgrCallback
import no.nordicsemi.android.mcumgr.McuMgrTransport
import no.nordicsemi.android.mcumgr.ble.McuMgrBleTransport
import no.nordicsemi.android.mcumgr.exception.McuMgrException
import no.nordicsemi.android.mcumgr.managers.DefaultManager
import no.nordicsemi.android.mcumgr.managers.ImageManager
import no.nordicsemi.android.mcumgr.response.img.McuMgrImageStateResponse
import no.nordicsemi.android.mcumgr.response.dflt.McuMgrResetResponse
import no.nordicsemi.android.mcumgr.transfer.TransferController
import no.nordicsemi.android.mcumgr.transfer.UploadCallback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay

class SMPPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "SMPPlugin"
        private const val CHANNEL = "smp_plugin"
        private const val EVENT_CHANNEL = "smp_plugin/events"
        private const val CONNECTION_TIMEOUT_MS = 30000L
        private const val MAX_RETRIES = 3
        private const val RETRY_DELAY_MS = 2000L
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var transport: McuMgrBleTransport? = null
    private var imageManager: ImageManager? = null
    private var defaultManager: DefaultManager? = null
    private var uploadController: TransferController? = null
    private var currentDeviceMac: String? = null

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
                connectToDevice(mac, result)
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
                uploadFirmware(mac, firmwareData, result)
            }
            "getMTU" -> {
                Log.d(TAG, "getMTU called")
                val mtu = transport?.mtu ?: 23
                result.success(mtu)
            }
            "resetDevice" -> {
                val mac = call.argument<String>("mac")
                if (mac.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "MAC address is required", null)
                    return
                }
                Log.d(TAG, "resetDevice called with mac=$mac")
                resetDevice(mac, result)
            }
            else -> {
                Log.d(TAG, "Unknown method: ${call.method}")
                result.notImplemented()
            }
        }
    }

    private fun connectToDevice(mac: String, result: MethodChannel.Result) {
        scope.launch {
            try {
                // Clean up existing connection
                disconnect()
                
                sendEvent(mapOf(
                    "type" to "progress",
                    "stage" to "connecting",
                    "deviceMac" to mac,
                    "bytesTransferred" to 0,
                    "totalBytes" to 0,
                    "percentage" to 5
                ))

                // Get Bluetooth device
                val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
                if (bluetoothAdapter == null) {
                    result.error("BLUETOOTH_UNAVAILABLE", "Bluetooth adapter not available", null)
                    return@launch
                }

                val device = bluetoothAdapter.getRemoteDevice(mac.uppercase().replace("-", ":"))
                
                // Create transport
                transport = McuMgrBleTransport(context, device)
                currentDeviceMac = mac
                
                // Initialize managers
                imageManager = ImageManager(transport!!)
                defaultManager = DefaultManager(transport!!)
                
                Log.d(TAG, "Connected to device $mac via SMP")
                result.success(true)
                
            } catch (e: Exception) {
                Log.e(TAG, "Connection failed: ${e.message}", e)
                sendError("CONNECTION_FAILED", "Failed to connect: ${e.message}")
                result.error("CONNECTION_FAILED", e.message ?: "Unknown error", null)
            }
        }
    }

    private fun uploadFirmware(mac: String, firmwareData: ByteArray, result: MethodChannel.Result) {
        scope.launch {
            var retries = 0
            var lastException: Exception? = null

            while (retries < MAX_RETRIES) {
                try {
                    // Ensure we're connected
                    if (transport == null || currentDeviceMac != mac) {
                        Log.d(TAG, "Not connected, attempting connection...")
                        val connected = withContext(Dispatchers.IO) {
                            try {
                                connectToDevice(mac, object : MethodChannel.Result {
                                    override fun success(result: Any?) {}
                                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                                    override fun notImplemented() {}
                                })
                                delay(2000) // Give connection time to establish
                                transport != null
                            } catch (e: Exception) {
                                false
                            }
                        }
                        
                        if (!connected) {
                            throw Exception("Failed to connect to device")
                        }
                    }

                    sendEvent(mapOf(
                        "type" to "progress",
                        "stage" to "uploading",
                        "deviceMac" to mac,
                        "bytesTransferred" to 0,
                        "totalBytes" to firmwareData.size,
                        "percentage" to 10
                    ))

                    Log.d(TAG, "Starting firmware upload: ${firmwareData.size} bytes")

                    // Upload firmware using ImageManager
                    uploadController = imageManager?.imageUpload(firmwareData, object : UploadCallback {
                        override fun onUploadProgressChanged(current: Int, total: Int, timestamp: Long) {
                            val percentage = 10 + ((current.toFloat() / total.toFloat()) * 70).toInt()
                            Log.d(TAG, "Upload progress: $current/$total bytes ($percentage%)")
                            
                            sendEvent(mapOf(
                                "type" to "progress",
                                "stage" to "uploading",
                                "deviceMac" to mac,
                                "bytesTransferred" to current,
                                "totalBytes" to total,
                                "percentage" to percentage
                            ))
                        }

                        override fun onUploadFailed(error: McuMgrException) {
                            Log.e(TAG, "Upload failed: ${error.message}", error)
                            sendError("UPLOAD_FAILED", error.message ?: "Upload failed")
                            result.error("UPLOAD_FAILED", error.message ?: "Unknown error", null)
                        }

                        override fun onUploadCanceled() {
                            Log.w(TAG, "Upload cancelled")
                            sendEvent(mapOf("type" to "cancelled"))
                            result.error("UPLOAD_CANCELLED", "Upload cancelled by user", null)
                        }

                        override fun onUploadCompleted() {
                            Log.d(TAG, "Upload completed successfully")
                            
                            sendEvent(mapOf(
                                "type" to "progress",
                                "stage" to "verifying",
                                "deviceMac" to mac,
                                "bytesTransferred" to firmwareData.size,
                                "totalBytes" to firmwareData.size,
                                "percentage" to 87
                            ))

                            // Verify the upload
                            verifyFirmware(mac, firmwareData, result)
                        }
                    })

                    // If we got here without exception, break retry loop
                    return@launch

                } catch (e: Exception) {
                    lastException = e
                    retries++
                    
                    if (retries < MAX_RETRIES) {
                        Log.w(TAG, "Upload attempt $retries failed, retrying in ${RETRY_DELAY_MS}ms: ${e.message}")
                        delay(RETRY_DELAY_MS * retries) // Exponential backoff
                    } else {
                        Log.e(TAG, "Upload failed after $MAX_RETRIES attempts", e)
                        sendError("UPLOAD_FAILED", "Failed after $MAX_RETRIES attempts: ${e.message}")
                        result.error("UPLOAD_FAILED", e.message ?: "Unknown error", null)
                    }
                }
            }

            // If we exhausted retries, report the last error
            if (lastException != null) {
                sendError("UPLOAD_FAILED", lastException.message ?: "Upload failed after retries")
                result.error("UPLOAD_FAILED", lastException.message ?: "Unknown error", null)
            }
        }
    }

    private fun verifyFirmware(mac: String, firmwareData: ByteArray, result: MethodChannel.Result) {
        scope.launch {
            try {
                Log.d(TAG, "Verifying firmware...")
                
                // List images to verify upload
                imageManager?.list(object : McuMgrCallback<McuMgrImageStateResponse> {
                    override fun onResponse(response: McuMgrImageStateResponse) {
                        if (response.images != null && response.images.isNotEmpty()) {
                            val uploadedImage = response.images.firstOrNull { it.slot == 1 }
                            if (uploadedImage != null) {
                                Log.d(TAG, "Firmware verified in slot 1")
                                
                                sendEvent(mapOf(
                                    "type" to "progress",
                                    "stage" to "complete",
                                    "deviceMac" to mac,
                                    "bytesTransferred" to firmwareData.size,
                                    "totalBytes" to firmwareData.size,
                                    "percentage" to 100
                                ))
                                
                                result.success(true)
                            } else {
                                val error = "No firmware found in slot 1"
                                Log.e(TAG, error)
                                sendError("VERIFICATION_FAILED", error)
                                result.error("VERIFICATION_FAILED", error, null)
                            }
                        } else {
                            val error = "No images found on device"
                            Log.e(TAG, error)
                            sendError("VERIFICATION_FAILED", error)
                            result.error("VERIFICATION_FAILED", error, null)
                        }
                    }

                    override fun onError(error: McuMgrException) {
                        Log.e(TAG, "Verification failed: ${error.message}", error)
                        sendError("VERIFICATION_FAILED", error.message ?: "Verification failed")
                        result.error("VERIFICATION_FAILED", error.message ?: "Unknown error", null)
                    }
                })
                
            } catch (e: Exception) {
                Log.e(TAG, "Verification error: ${e.message}", e)
                sendError("VERIFICATION_FAILED", e.message ?: "Verification failed")
                result.error("VERIFICATION_FAILED", e.message ?: "Unknown error", null)
            }
        }
    }

    private fun resetDevice(mac: String, result: MethodChannel.Result) {
        scope.launch {
            try {
                if (transport == null || currentDeviceMac != mac) {
                    result.error("NOT_CONNECTED", "Not connected to device", null)
                    return@launch
                }

                sendEvent(mapOf(
                    "type" to "progress",
                    "stage" to "rebooting",
                    "deviceMac" to mac,
                    "bytesTransferred" to 0,
                    "totalBytes" to 0,
                    "percentage" to 97
                ))

                Log.d(TAG, "Sending reset command to device $mac")
                
                defaultManager?.reset(object : McuMgrCallback<McuMgrResetResponse> {
                    override fun onResponse(response: McuMgrResetResponse) {
                        Log.d(TAG, "Device reset successful")
                        result.success(true)
                        
                        // Clean up after reset
                        disconnect()
                    }

                    override fun onError(error: McuMgrException) {
                        Log.e(TAG, "Reset failed: ${error.message}", error)
                        result.error("RESET_FAILED", error.message ?: "Reset failed", null)
                    }
                })
                
            } catch (e: Exception) {
                Log.e(TAG, "Reset error: ${e.message}", e)
                result.error("RESET_FAILED", e.message ?: "Unknown error", null)
            }
        }
    }

    private fun sendEvent(data: Map<String, Any>) {
        scope.launch(Dispatchers.Main) {
            try {
                eventSink?.success(data)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send event: ${e.message}")
            }
        }
    }

    private fun sendError(code: String, message: String) {
        scope.launch(Dispatchers.Main) {
            try {
                eventSink?.error(code, message, null)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send error: ${e.message}")
            }
        }
    }
try {
            uploadController?.cancel()
        } catch (e: Exception) {
            Log.w(TAG, "Error cancelling upload: ${e.message}")
        }
        uploadController = null
        
        try {
            transport?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing transport: ${e.message}")
        }ull
        
        transport?.release()
        transport = null
        
        imageManager = null
        defaultManager = null
        currentDeviceMac = null
        
        Log.d(TAG, "SMP disconnected")
    }
}
