package com.nordicmesh.nordic_mesh_manager

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.content.Context
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import no.nordicsemi.android.ble.callback.DataReceivedCallback
import no.nordicsemi.android.mesh.ApplicationKey
import no.nordicsemi.android.mesh.MeshManagerApi
import no.nordicsemi.android.mesh.MeshManagerCallbacks
import no.nordicsemi.android.mesh.MeshNetwork
import no.nordicsemi.android.mesh.NetworkKey
import no.nordicsemi.android.mesh.MeshStatusCallbacks
import no.nordicsemi.android.mesh.transport.GenericOnOffSet
import no.nordicsemi.android.mesh.transport.GenericOnOffGet
import no.nordicsemi.android.mesh.transport.GenericOnOffStatus
import no.nordicsemi.android.mesh.transport.MeshMessage
import no.nordicsemi.android.mesh.provisionerstates.UnprovisionedMeshNode
import java.util.UUID
import kotlin.random.Random

class MeshPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "mesh_plugin"
        private val MESH_PROXY_UUID = UUID.fromString("00001828-0000-1000-8000-00805F9B34FB")
        private val MESH_PROXY_DATA_IN = UUID.fromString("00002ADD-0000-1000-8000-00805F9B34FB")
        private val MESH_PROXY_DATA_OUT = UUID.fromString("00002ADE-0000-1000-8000-00805F9B34FB")
        private val BATTERY_SERVICE_UUID = UUID.fromString("0000180F-0000-1000-8000-00805F9B34FB")
        private val BATTERY_LEVEL_CHAR_UUID = UUID.fromString("00002A19-0000-1000-8000-00805F9B34FB")
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var meshManagerApi: MeshManagerApi
    private var bleManager: MeshBleManager? = null
    private var meshNetwork: MeshNetwork? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    // True only when we have an active BLE connection to a device that exposes the Mesh Proxy service.
    private var isConnected = false

    // Ensures proxy connection attempts are serialized. Without this, overlapping calls (e.g. a
    // background ensureProxyConnection and a trigger send) can race and overwrite bleManager.
    private val proxyConnectMutex = Mutex()
    private var inFlightProxyConnect: kotlinx.coroutines.CompletableDeferred<Boolean>? = null
    private var inFlightProxyMac: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler(this)

        // Initialize Mesh Manager API
        meshManagerApi = MeshManagerApi(context)
        setupMeshCallbacks()
        meshManagerApi.loadMeshNetwork()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        bleManager?.disconnect()?.enqueue()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        android.util.Log.d("MeshPlugin", "onMethodCall: ${call.method}")
        when (call.method) {
            "isAvailable" -> result.success(true)
            "initialize" -> initialize(call, result)
            "setMeshCredentials" -> setMeshCredentials(call, result)
            "ensureProxyConnection" -> ensureProxyConnectionCall(call, result)
            "connectToDevice" -> connectToDevice(call, result)
            "disconnectFromDevice" -> disconnectFromDevice(result)
            "triggerGroup" -> triggerGroup(call, result)
            "sendGroupMessage" -> sendGroupMessage(call, result)
            "readBatteryLevel" -> readBatteryLevel(result)
            "getLightStates" -> getLightStates(call, result)
            "getBatteryLevels" -> getBatteryLevels(call, result)
            "subscribeToCharacteristics" -> subscribeToCharacteristics(call, result)
            "isDeviceConnected" -> isDeviceConnected(call, result)
            "disconnectDevice" -> disconnectDevice(call, result)
            "discoverServices" -> discoverServices(call, result)
            "readCharacteristic" -> readCharacteristic(call, result)
            "writeCharacteristic" -> writeCharacteristic(call, result)
            "setNotify" -> setNotify(call, result)
            "discoverGroupMembers" -> discoverGroupMembers(call, result)
            "getNodeSubscriptions" -> getNodeSubscriptions(call, result)
            "sendUnicastMessage" -> sendUnicastMessage(call, result)
            "sendUnicastGet" -> sendUnicastGet(call, result)
            "configureProxyFilter" -> configureProxyFilter(call, result)
            else -> result.notImplemented()
        }
    }

    private fun sendUnicastGet(call: MethodCall, result: MethodChannel.Result) {
        // Intentionally stubbed.
        // The redesign calls for GenericOnOffGet support, but this is tracked separately.
        // Returning false avoids MissingPluginException on the Dart side and makes
        // capability-checking possible.
        result.success(false)
    }

    private fun configureProxyFilter(call: MethodCall, result: MethodChannel.Result) {
        // Intentionally stubbed.
        // Proxy filter configuration will be implemented as part of the redesign work.
        // Returning false avoids MissingPluginException on the Dart side.
        result.success(false)
    }

    private fun getNodeSubscriptions(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val network = meshNetwork ?: meshManagerApi.meshNetwork
                if (network == null) {
                    result.success(emptyList<Any>())
                    return@launch
                }

                // Best-effort: return the known nodes. Subscription parsing can be added later.
                val nodes = network.nodes.map { node ->
                    mapOf(
                        "unicastAddress" to node.unicastAddress,
                        "name" to (node.nodeName ?: ""),
                        "subscriptions" to emptyList<Int>()
                    )
                }

                result.success(nodes)
            } catch (e: Exception) {
                result.error("NODE_SUBSCRIPTIONS_ERROR", e.message, null)
            }
        }
    }

    private fun setupMeshCallbacks() {
        meshManagerApi.setMeshManagerCallbacks(object : MeshManagerCallbacks {
            override fun onNetworkLoaded(network: MeshNetwork?) {
                meshNetwork = network
            }

            override fun onNetworkUpdated(network: MeshNetwork?) {
                meshNetwork = network
            }

            override fun onNetworkLoadFailed(error: String?) {
                // Network doesn't exist yet - will be created on first use
            }

            override fun onNetworkImported(network: MeshNetwork?) {
                meshNetwork = network
            }

            override fun onNetworkImportFailed(error: String?) {
                // Handle error
            }

            override fun sendProvisioningPdu(node: UnprovisionedMeshNode?, pdu: ByteArray?) {
                pdu?.let { bleManager?.sendPdu(it) }
            }

            override fun onMeshPduCreated(pdu: ByteArray?) {
                if (pdu != null) {
                    android.util.Log.d("MeshPlugin", "onMeshPduCreated: sending ${pdu.size} bytes via BLE proxy")
                    bleManager?.sendPdu(pdu)
                } else {
                    android.util.Log.w("MeshPlugin", "onMeshPduCreated: received null PDU")
                }
            }

            override fun getMtu(): Int {
                return bleManager?.getMaximumPacketSize() ?: 20
            }
        })
        
        // Set up status message callbacks to receive device responses
        meshManagerApi.setMeshStatusCallbacks(object : MeshStatusCallbacks {
            override fun onMeshMessageReceived(src: Int, meshMessage: MeshMessage) {
                android.util.Log.d("MeshPlugin", "Mesh message received from 0x${src.toString(16)}: ${meshMessage.javaClass.simpleName}")
                
                when (meshMessage) {
                    is GenericOnOffStatus -> {
                        val state = meshMessage.presentState
                        val targetState = meshMessage.targetState
                        android.util.Log.d("MeshPlugin", "GenericOnOffStatus from 0x${src.toString(16)}: state=$state, target=$targetState")
                        
                        // Notify Dart layer about device status
                        scope.launch(Dispatchers.Main) {
                            methodChannel.invokeMethod("onDeviceStatus", mapOf(
                                "unicastAddress" to src,
                                "state" to state,
                                "targetState" to targetState
                            ))
                        }
                    }
                }
            }
            
            override fun onMeshMessageProcessed(dst: Int, meshMessage: MeshMessage) {
                // Message sent successfully
            }
            
            override fun onTransactionFailed(dst: Int, hasIncompleteTimerExpired: Boolean) {
                android.util.Log.w("MeshPlugin", "Transaction failed for 0x${dst.toString(16)}")
            }
            
            override fun onUnknownPduReceived(src: Int, accessPayload: ByteArray?) {
                android.util.Log.w("MeshPlugin", "Unknown PDU from 0x${src.toString(16)}, payload size: ${accessPayload?.size ?: 0}")
            }
            
            override fun onBlockAcknowledgementProcessed(dst: Int, message: no.nordicsemi.android.mesh.transport.ControlMessage) {
                android.util.Log.d("MeshPlugin", "Block ACK processed for 0x${dst.toString(16)}")
            }
            override fun onBlockAcknowledgementReceived(src: Int, message: no.nordicsemi.android.mesh.transport.ControlMessage) {
                android.util.Log.d("MeshPlugin", "Block ACK received from 0x${src.toString(16)}")
            }
            override fun onHeartbeatMessageReceived(src: Int, message: no.nordicsemi.android.mesh.transport.ControlMessage) {
                android.util.Log.d("MeshPlugin", "Heartbeat received from 0x${src.toString(16)}")
            }
            override fun onMessageDecryptionFailed(meshLayer: String?, errorMessage: String?) {
                android.util.Log.e("MeshPlugin", "Decryption failed at $meshLayer: $errorMessage")
            }
        })
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        try {
            val netKey = call.argument<String>("netKey")
            val appKey = call.argument<String>("appKey")
            
            if (netKey != null && appKey != null) {
                setMeshCredentials(call, result)
            } else {
                result.success(true)
            }
        } catch (e: Exception) {
            result.error("INIT_ERROR", e.message, null)
        }
    }

    private fun setMeshCredentials(call: MethodCall, result: MethodChannel.Result) {
        try {
            // Dart sends "netKey" not "networkKey" - check both for compatibility
            val netKeyHex = call.argument<String>("netKey") ?: call.argument<String>("networkKey") ?: ""
            val appKeyHex = call.argument<String>("appKey") ?: ""
            
            val netKeyBytes = netKeyHex
                .chunked(2)
                .map { it.toInt(16).toByte() }
                .toByteArray()

            val appKeyBytes = appKeyHex
                .chunked(2)
                .map { it.toInt(16).toByte() }
                .toByteArray()

            // Get or create mesh network
            if (meshNetwork == null) {
                meshNetwork = meshManagerApi.meshNetwork
            }

            meshNetwork?.let { network ->
                // Ensure mesh network keys match provided credentials.
                // Minimized logging: only warn/errors emitted below.

                // Force-replace existing application keys first (unbinds app keys from net keys)
                if (network.appKeys.isNotEmpty()) {
                    android.util.Log.w("MeshPlugin", "meshNetwork has existing appKeys - removing before replacing keys")
                    val existingAppKeys = network.appKeys.toList()
                    existingAppKeys.forEach { ak ->
                        try {
                            network.removeAppKey(ak)
                            android.util.Log.d("MeshPlugin", "Removed existing appKey: $ak")
                        } catch (e: Exception) {
                            android.util.Log.w("MeshPlugin", "Failed to remove appKey via API: ${e.message}")
                        }
                    }
                }

                // Now remove existing network keys
                if (network.netKeys.isNotEmpty()) {
                    android.util.Log.w("MeshPlugin", "meshNetwork has existing netKeys - removing before adding provided key")
                    val existingNetKeys = network.netKeys.toList()
                    existingNetKeys.forEach { nk ->
                        try {
                            network.removeNetKey(nk)
                            android.util.Log.d("MeshPlugin", "Removed existing netKey: $nk")
                        } catch (e: Exception) {
                            android.util.Log.w("MeshPlugin", "Failed to remove netKey via API: ${e.message}")
                        }
                    }
                }

                // Add provided network key
                try {
                    val netKey = NetworkKey(0, netKeyBytes)
                    network.addNetKey(netKey)
                    android.util.Log.d("MeshPlugin", "Added provided Network Key to meshNetwork")
                } catch (e: Exception) {
                    android.util.Log.e("MeshPlugin", "Failed to add provided Network Key: ${e.message}")
                }

                // Add provided application key
                try {
                    val appKey = ApplicationKey(0, appKeyBytes)
                    network.addAppKey(appKey)
                    android.util.Log.d("MeshPlugin", "Added provided Application Key to meshNetwork")
                } catch (e: Exception) {
                    android.util.Log.e("MeshPlugin", "Failed to add provided Application Key: ${e.message}")
                }

                // Programmatically add group 0xC000 if it doesn't exist
                if (network.groups.none { it.address == 0xC000 }) {
                    val provisioner = network.selectedProvisioner ?: network.provisioners.firstOrNull()
                    if (provisioner != null) {
                        val defaultGroup = network.createGroup(provisioner, 0xC000, "Default")
                        android.util.Log.d("MeshPlugin", "Created group 0xC000 (Default)")
                    }
                }

                android.util.Log.d("MeshPlugin", "Mesh network configured: nodes=${network.nodes.size}, groups=${network.groups.size}")
            }

            result.success(true)
        } catch (e: Exception) {
            result.error("MESH_SETUP_ERROR", e.message, null)
        }
    }

    private fun connectToDevice(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val deviceAddress = call.argument<String>("address")
                    ?: throw IllegalArgumentException("Device address required")

                // Create BLE manager instance
                bleManager = MeshBleManager(context)
                
                // Connect using BluetoothAdapter to get device
                val bluetoothAdapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter()
                val device = bluetoothAdapter.getRemoteDevice(deviceAddress)
                
                bleManager?.connect(device)
                    ?.useAutoConnect(false)
                    ?.timeout(10000)
                    ?.retry(3, 100)
                    ?.enqueue()

                result.success(true)
            } catch (e: Exception) {
                result.error("CONNECTION_ERROR", e.message, null)
            }
        }
    }

    private fun ensureProxyConnectionCall(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val mac = call.argument<String>("mac") ?: throw IllegalArgumentException("mac required")
                val connected = ensureProxyConnection(mac)
                result.success(connected)
            } catch (e: Exception) {
                result.error("PROXY_CONN_ERROR", e.message, null)
            }
        }
    }

    private suspend fun ensureProxyConnectionFromCandidates(candidates: List<String>): Boolean {
        if (isConnected) return true

        // Try each candidate until we find a device that actually exposes the Mesh Proxy service.
        for (candidate in candidates) {
            try {
                if (ensureProxyConnection(candidate)) {
                    return true
                }
            } catch (e: Exception) {
                android.util.Log.w("MeshPlugin", "Proxy candidate failed: $candidate -> ${e.message}")
            }
        }
        return false
    }

    private suspend fun ensureProxyConnection(macAddress: String): Boolean {
        return proxyConnectMutex.withLock {
            if (isConnected) {
                android.util.Log.d("MeshPlugin", "Already connected to proxy")
                return@withLock true
            }

            val normalizedMac = macAddress.uppercase().replace("-", ":")

            // If another connection attempt is already in-flight, wait for it to settle first.
            val inFlight = inFlightProxyConnect
            if (inFlight != null) {
                val settled = kotlinx.coroutines.withTimeoutOrNull(25000) {
                    inFlight.await()
                } ?: false

                if (isConnected) {
                    android.util.Log.d("MeshPlugin", "Proxy already connected after waiting for in-flight connect")
                    return@withLock true
                }

                // If the in-flight attempt was for the same device, return its result.
                if (inFlightProxyMac == normalizedMac) {
                    android.util.Log.d("MeshPlugin", "In-flight proxy connect to $normalizedMac settled=$settled")
                    return@withLock settled
                }
            }

            android.util.Log.d("MeshPlugin", "Connecting to proxy: $macAddress")
            val bluetoothAdapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter()
            val device = bluetoothAdapter.getRemoteDevice(normalizedMac)

            // Tear down any previous manager before starting a new attempt.
            try {
                bleManager?.disconnect()?.enqueue()
            } catch (_: Exception) {
                // Ignore
            }
            bleManager = MeshBleManager(context)

            val connectionResult = kotlinx.coroutines.CompletableDeferred<Boolean>()
            inFlightProxyConnect = connectionResult
            inFlightProxyMac = normalizedMac

            bleManager?.onConnectionReady = { connectionResult.complete(true) }
            bleManager?.onConnectionFailed = { connectionResult.complete(false) }

            bleManager?.connect(device)
                ?.useAutoConnect(false)
                ?.retry(3, 100)
                ?.timeout(10000)
                ?.fail { _, status ->
                    android.util.Log.e("MeshPlugin", "Proxy connection failed with status: $status")
                    connectionResult.complete(false)
                }
                ?.enqueue()

            val connected = kotlinx.coroutines.withTimeoutOrNull(25000) {
                connectionResult.await()
            } ?: false

            android.util.Log.d("MeshPlugin", "Proxy connection result: $connected")

            // Clear in-flight state if this call created it.
            if (inFlightProxyConnect === connectionResult) {
                inFlightProxyConnect = null
                inFlightProxyMac = null
            }

            if (!connected) {
                // Defensive cleanup: ensure we don't leave an unusable manager around.
                try {
                    bleManager?.disconnect()?.enqueue()
                } catch (_: Exception) {
                    // Ignore
                }
                bleManager = null
                isConnected = false
            }

            return@withLock connected
        }
    }

    private fun disconnectFromDevice(result: MethodChannel.Result) {
        scope.launch {
            try {
                bleManager?.disconnect()?.enqueue()
                bleManager = null
                result.success(true)
            } catch (e: Exception) {
                result.error("DISCONNECT_ERROR", e.message, null)
            }
        }
    }

    private fun sendGroupMessage(call: MethodCall, result: MethodChannel.Result) {
        android.util.Log.d("MeshPlugin", "sendGroupMessage called")
        scope.launch {
            try {
                val groupId = call.argument<Int>("groupId") ?: 0xC000
                val macs = call.argument<List<String>>("macs")
                val on = call.argument<Boolean>("on") ?: true
                
                android.util.Log.d("MeshPlugin", "sendGroupMessage: groupId=$groupId, macs=${macs?.size}, on=$on, isConnected=$isConnected")
                
                // Ensure proxy connection
                if (!isConnected) {
                    if (macs.isNullOrEmpty()) {
                        throw IllegalStateException("No connected mesh proxy and no device MACs provided")
                    }
                    val connected = ensureProxyConnectionFromCandidates(macs)
                    if (!connected) {
                        result.error("PROXY_CONNECTION_FAILED", "Failed to connect to mesh proxy device", null)
                        return@launch
                    }
                }
                
                android.util.Log.d("MeshPlugin", "Creating mesh PDU for group $groupId (0x${groupId.toString(16)}) with ACK")
                
                // Diagnostic: Check mesh network configuration
                meshNetwork?.let { network ->
                    android.util.Log.d("MeshPlugin", "Mesh network nodes: ${network.nodes.size}")
                    network.nodes.forEach { node ->
                        android.util.Log.d("MeshPlugin", "  Node: ${node.nodeName ?: "unnamed"} unicast=0x${node.unicastAddress.toString(16)}")
                    }
                    android.util.Log.d("MeshPlugin", "Mesh network groups: ${network.groups.size}")
                    network.groups.forEach { group ->
                        android.util.Log.d("MeshPlugin", "  Group: ${group.name} address=0x${group.address.toString(16)}")
                    }
                }
                
                meshNetwork?.appKeys?.firstOrNull()?.let { appKey ->
                    val tId = Random.nextInt(256)
                    // GenericOnOffSet opcode 0x8202 is inherently acknowledged (vs 0x8203 unacknowledged)
                    val message = GenericOnOffSet(appKey, on, tId)
                    android.util.Log.d("MeshPlugin", "GenericOnOffSet: state=$on, tId=$tId (acknowledged by opcode)")
                    // This will trigger onMeshPduCreated callback which sends via bleManager
                    meshManagerApi.createMeshPdu(groupId, message)
                    android.util.Log.d("MeshPlugin", "createMeshPdu completed successfully")
                    result.success(true)
                } ?: run {
                    android.util.Log.e("MeshPlugin", "No app key configured in mesh network")
                    throw IllegalStateException("No app key configured")
                }
            } catch (e: Exception) {
                android.util.Log.e("MeshPlugin", "sendGroupMessage error: ${e.message}", e)
                result.error("SEND_ERROR", e.message, null)
            }
        }
    }

    private fun triggerGroup(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val groupAddress = call.argument<Int>("groupAddress")
                    ?: throw IllegalArgumentException("Group address required")
                val state = call.argument<Boolean>("state") ?: true

                meshNetwork?.appKeys?.firstOrNull()?.let { appKey ->
                    val tId = Random.nextInt(256)
                    // GenericOnOffSet opcode 0x8202 is inherently acknowledged
                    val message = GenericOnOffSet(appKey, state, tId)
                    android.util.Log.d("MeshPlugin", "GenericOnOffSet: groupAddress=0x${groupAddress.toString(16)}, state=$state, tId=$tId (acknowledged)")
                    // Send to group address - meshManagerApi will call onMeshPduCreated callback
                    meshManagerApi.createMeshPdu(groupAddress, message)
                    
                    result.success(true)
                } ?: throw IllegalStateException("No app key configured")
            } catch (e: Exception) {
                result.error("TRIGGER_ERROR", e.message, null)
            }
        }
    }

    private fun readBatteryLevel(result: MethodChannel.Result) {
        scope.launch {
            try {
                val batteryLevel = bleManager?.getBatteryLevel()
                result.success(batteryLevel)
            } catch (e: Exception) {
                result.error("BATTERY_READ_ERROR", e.message, null)
            }
        }
    }

    private fun getLightStates(call: MethodCall, result: MethodChannel.Result) {
        // Light states in BLE Mesh cannot be read - mesh is command-based, not state-query
        // To get states, you'd need to implement mesh status messages (future enhancement)
        result.success(null)
    }

    private fun getBatteryLevels(call: MethodCall, result: MethodChannel.Result) {
        // Battery levels should be read via GATT (BAS service 0x180F)
        // This native plugin focuses on mesh - battery reading delegated to Dart GATT layer
        result.success(null)
    }

    private fun subscribeToCharacteristics(call: MethodCall, result: MethodChannel.Result) {
        // Subscriptions (battery, notifications) handled by Dart GATT layer
        result.success(false)
    }

    private fun isDeviceConnected(call: MethodCall, result: MethodChannel.Result) {
        result.success(false)
    }

    private fun disconnectDevice(call: MethodCall, result: MethodChannel.Result) {
        result.success(false)
    }

    private fun discoverServices(call: MethodCall, result: MethodChannel.Result) {
        result.success(null)
    }

    private fun readCharacteristic(call: MethodCall, result: MethodChannel.Result) {
        result.success(null)
    }

    private fun writeCharacteristic(call: MethodCall, result: MethodChannel.Result) {
        result.success(false)
    }

    private fun setNotify(call: MethodCall, result: MethodChannel.Result) {
        result.success(false)
    }
    
    private fun discoverGroupMembers(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val groupAddress = call.argument<Int>("groupAddress") ?: 0xC000
                val currentState = call.argument<Boolean>("currentState") ?: false
                
                android.util.Log.d("MeshPlugin", "discoverGroupMembers: probing group 0x${groupAddress.toString(16)} with state=$currentState")
                
                // Check if connected to proxy
                if (!isConnected) {
                    android.util.Log.e("MeshPlugin", "Cannot discover group members: no proxy connection")
                    result.error("NO_PROXY", "Must connect to proxy device before discovering groups", null)
                    return@launch
                }
                
                meshNetwork?.appKeys?.firstOrNull()?.let { appKey ->
                    val tId = Random.nextInt(256)
                    // Send discovery message with acknowledgment to get status responses
                    val message = GenericOnOffSet(appKey, currentState, tId)
                    android.util.Log.d("MeshPlugin", "Sending discovery message to group 0x${groupAddress.toString(16)}")
                    meshManagerApi.createMeshPdu(groupAddress, message)
                    
                    // Return immediately - status messages will arrive via onMeshMessageReceived callback
                    result.success(true)
                } ?: run {
                    result.error("NO_APP_KEY", "No app key configured", null)
                }
            } catch (e: Exception) {
                android.util.Log.e("MeshPlugin", "discoverGroupMembers error: ${e.message}", e)
                result.error("DISCOVERY_ERROR", e.message, null)
            }
        }
    }
    
    private fun sendUnicastMessage(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val unicastAddress = call.argument<Int>("unicastAddress") 
                    ?: throw IllegalArgumentException("unicastAddress required")
                val state = call.argument<Boolean>("state") ?: true
                val proxyMac = call.argument<String>("proxyMac")
                
                android.util.Log.d("MeshPlugin", "sendUnicastMessage to 0x${unicastAddress.toString(16)}, state=$state, proxyMac=$proxyMac")
                
                // Ensure proxy connection
                if (!isConnected && proxyMac != null) {
                    val connected = ensureProxyConnection(proxyMac)
                    if (!connected) {
                        result.error("PROXY_CONNECTION_FAILED", "Failed to connect to proxy device", null)
                        return@launch
                    }
                }
                
                if (!isConnected) {
                    result.error("NO_PROXY", "No proxy connection available", null)
                    return@launch
                }
                
                meshNetwork?.appKeys?.firstOrNull()?.let { appKey ->
                    val tId = Random.nextInt(256)
                    val message = GenericOnOffSet(appKey, state, tId)
                    android.util.Log.d("MeshPlugin", "GenericOnOffSet unicast: dst=0x${unicastAddress.toString(16)}, tId=$tId")
                    meshManagerApi.createMeshPdu(unicastAddress, message)
                    result.success(true)
                } ?: run {
                    result.error("NO_APP_KEY", "No app key configured", null)
                }
            } catch (e: Exception) {
                android.util.Log.e("MeshPlugin", "sendUnicastMessage error: ${e.message}", e)
                result.error("UNICAST_ERROR", e.message, null)
            }
        }
    }

    /**
     * BLE Manager for Mesh Proxy connections
     * Based on Nordic's BleMeshManager sample implementation
     */
    inner class MeshBleManager(context: Context) : no.nordicsemi.android.ble.BleManager(context) {
        private var proxyDataIn: BluetoothGattCharacteristic? = null
        private var proxyDataOut: BluetoothGattCharacteristic? = null
        private var batteryLevelChar: BluetoothGattCharacteristic? = null

        private var hasProxyChars: Boolean = false
        
        // Callback to notify when connection is ready
        var onConnectionReady: (() -> Unit)? = null
        var onConnectionFailed: (() -> Unit)? = null

        @NonNull
        override fun getGattCallback(): BleManagerGattCallback = object : BleManagerGattCallback() {
            override fun isRequiredServiceSupported(@NonNull gatt: BluetoothGatt): Boolean {
                android.util.Log.d("MeshPlugin", "isRequiredServiceSupported: checking services")
                android.util.Log.d("MeshPlugin", "Available services: ${gatt.services.map { it.uuid }}")
                
                val meshProxyService = gatt.getService(MESH_PROXY_UUID)
                if (meshProxyService != null) {
                    android.util.Log.d("MeshPlugin", "Found Mesh Proxy service")
                    this@MeshBleManager.proxyDataIn = meshProxyService.getCharacteristic(MESH_PROXY_DATA_IN)
                    this@MeshBleManager.proxyDataOut = meshProxyService.getCharacteristic(MESH_PROXY_DATA_OUT)
                } else {
                    android.util.Log.w("MeshPlugin", "Mesh Proxy service (0x1828) NOT found - device may not be acting as proxy")
                }

                val batteryService = gatt.getService(BATTERY_SERVICE_UUID)
                if (batteryService != null) {
                    android.util.Log.d("MeshPlugin", "Found Battery service")
                    this@MeshBleManager.batteryLevelChar = batteryService.getCharacteristic(BATTERY_LEVEL_CHAR_UUID)
                }

                // Accept connection even without proxy service - we'll report error later if needed
                hasProxyChars = this@MeshBleManager.proxyDataIn != null && this@MeshBleManager.proxyDataOut != null
                android.util.Log.d("MeshPlugin", "isRequiredServiceSupported returning: true (hasProxyChars=$hasProxyChars)")
                return true // Always accept connection to see what services are available
            }

            override fun initialize() {
                android.util.Log.d("MeshPlugin", "BleManager.initialize() called")
                requestMtu(517).enqueue()
                
                proxyDataOut?.let { char ->
                    android.util.Log.d("MeshPlugin", "Enabling notifications on proxy data out")
                    val onDataReceived = DataReceivedCallback { device, data ->
                        val bytes = data.value ?: byteArrayOf()
                        val hexString = bytes.joinToString(" ") { "%02X".format(it) }
                        android.util.Log.d("MeshPlugin", "Received ${bytes.size} bytes from proxy: $hexString")
                        meshManagerApi.handleNotifications(getMaximumPacketSize(), bytes)
                    }
                    setNotificationCallback(char).with(onDataReceived)
                    enableNotifications(char).enqueue()
                } ?: run {
                    android.util.Log.w("MeshPlugin", "No proxy data out characteristic - device not configured as mesh proxy")
                }
                
                // Always call ready even if mesh proxy service not found
                // This allows us to still use the device for other GATT operations
                android.util.Log.d("MeshPlugin", "BleManager.initialize() completed")
            }
            
            override fun onDeviceReady() {
                super.onDeviceReady()
                if (!hasProxyChars) {
                    android.util.Log.w(
                        "MeshPlugin",
                        "BLE device ready but Mesh Proxy characteristics missing; not a proxy, disconnecting"
                    )
                    this@MeshPlugin.isConnected = false
                    onConnectionFailed?.invoke()
                    // Disconnect to allow trying the next candidate.
                    disconnect().enqueue()
                    return
                }

                android.util.Log.d("MeshPlugin", "BLE device ready - mesh proxy connection established")
                this@MeshPlugin.isConnected = true
                onConnectionReady?.invoke()
            }
            
            override fun onDeviceDisconnected() {
                super.onDeviceDisconnected()
                android.util.Log.d("MeshPlugin", "BLE device disconnected")
                this@MeshPlugin.isConnected = false
            }

            override fun onServicesInvalidated() {
                proxyDataIn = null
                proxyDataOut = null
                batteryLevelChar = null
                hasProxyChars = false
            }
        }

        fun sendPdu(pdu: ByteArray) {
            if (!isConnected) {
                android.util.Log.w("MeshPlugin", "sendPdu: not connected, cannot send ${pdu.size} bytes")
                return
            }
            
            android.util.Log.d("MeshPlugin", "sendPdu: sending ${pdu.size} bytes to proxy device")
            proxyDataIn?.let { char ->
                writeCharacteristic(char, pdu, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
                    .split()
                    .enqueue()
                android.util.Log.d("MeshPlugin", "sendPdu: write enqueued successfully")
            } ?: run {
                android.util.Log.e("MeshPlugin", "sendPdu: proxyDataIn characteristic is null!")
            }
        }

        fun getMaximumPacketSize(): Int {
            return mtu - 3
        }

        fun getBatteryLevel(): Int? {
            var level: Int? = null
            batteryLevelChar?.let { char ->
                readCharacteristic(char)
                    .with { _, data ->
                        level = data.value?.get(0)?.toInt()?.and(0xFF)
                    }
                    .enqueue()
            }
            return level
        }
    }
}
