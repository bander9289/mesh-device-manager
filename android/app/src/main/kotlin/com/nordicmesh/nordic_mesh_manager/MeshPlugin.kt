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
import no.nordicsemi.android.mesh.transport.ProxyConfigSetFilterType
import no.nordicsemi.android.mesh.transport.ProxyConfigAddAddressToFilter
import no.nordicsemi.android.mesh.utils.ProxyFilterType
import no.nordicsemi.android.mesh.utils.AddressArray
import no.nordicsemi.android.mesh.provisionerstates.UnprovisionedMeshNode
import java.util.UUID
import kotlin.random.Random
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

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
    private var isConnected = false
    private var proxyFilterConfigured = false
    private var lastProxyFilterAddresses: Set<Int> = emptySet()
    private var currentProxyUnicast: Int? = null

    private fun normalizeMac(macAddress: String): String = macAddress.uppercase().replace("-", ":")

    /**
     * PRD/TR: Calculate unicast address from MAC last 2 bytes.
     * Spec expects: ((byte4 << 8) | byte5) & 0x7FFF
     */
    private fun macToUnicast(macAddress: String): Int? {
        return try {
            val normalized = normalizeMac(macAddress)
            val parts = normalized.split(":")
            if (parts.size != 6) return null
            val byte4 = parts[4].toInt(16)
            val byte5 = parts[5].toInt(16)
            val unmasked = (byte4 shl 8) or byte5
            val unicast = unmasked and 0x7FFF
            if (unicast == 0) 0x0001 else unicast
        } catch (_: Exception) {
            null
        }
    }

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
            "sendUnicastMessage" -> sendUnicastMessage(call, result)
            "sendUnicastGet" -> sendUnicastGet(call, result)
            "configureProxyFilter" -> configureProxyFilter(call, result)
            "getNodeSubscriptions" -> getNodeSubscriptions(result)
            "resetMeshNetwork" -> resetMeshNetwork(result)
            else -> result.notImplemented()
        }
    }

    private fun parseMeshAddress(value: Any?): Int? {
        return try {
            when (value) {
                null -> null
                is Int -> value
                is Long -> value.toInt()
                is String -> {
                    val s = value.trim().lowercase()
                    if (s.startsWith("0x")) s.substring(2).toInt(16) else s.toInt()
                }
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Return mesh node subscription data derived from the persisted mesh network database.
     * This avoids relying solely on runtime status responses (e.g. GenericOnOffStatus),
     * which some nodes may not publish.
     *
     * Shape:
     * [{"unicastAddress": 0x1234, "name": "Node", "subscriptions": [0xC000, ...]}, ...]
     */
    private fun getNodeSubscriptions(result: MethodChannel.Result) {
        scope.launch {
            try {
                val json = meshManagerApi.exportMeshNetwork()
                if (json.isNullOrEmpty()) {
                    result.success(emptyList<Map<String, Any>>())
                    return@launch
                }

                val root = JSONObject(json)
                val nodesArray = root.optJSONArray("nodes") ?: JSONArray()
                val out = mutableListOf<Map<String, Any>>()

                for (i in 0 until nodesArray.length()) {
                    val nodeObj = nodesArray.optJSONObject(i) ?: continue

                    val unicast = nodeObj.optInt("unicastAddress", -1)
                    if (unicast <= 0) continue

                    val name = nodeObj.optString("name", "")
                    val subs = mutableSetOf<Int>()

                    val elements = nodeObj.optJSONArray("elements") ?: JSONArray()
                    for (e in 0 until elements.length()) {
                        val elementObj = elements.optJSONObject(e) ?: continue
                        val models = elementObj.optJSONArray("models") ?: JSONArray()
                        for (m in 0 until models.length()) {
                            val modelObj = models.optJSONObject(m) ?: continue
                            val subscribeArr = modelObj.optJSONArray("subscribe") ?: JSONArray()
                            for (s in 0 until subscribeArr.length()) {
                                val addr = parseMeshAddress(subscribeArr.opt(s))
                                if (addr != null && addr > 0) subs.add(addr)
                            }
                        }
                    }

                    out.add(
                        mapOf(
                            "unicastAddress" to unicast,
                            "name" to name,
                            "subscriptions" to subs.toList()
                        )
                    )
                }

                result.success(out)
            } catch (e: Exception) {
                android.util.Log.e("MeshPlugin", "getNodeSubscriptions error: ${e.message}", e)
                result.success(emptyList<Map<String, Any>>())
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
                // Nordic SDK expects the negotiated ATT MTU (not payload size).
                return bleManager?.getGattMtu() ?: 23
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
                // Ensure we have a provisioner (required for sending/receiving messages)
                if (network.selectedProvisioner == null && network.provisioners.isEmpty()) {
                    android.util.Log.d("MeshPlugin", "No provisioner found - creating default provisioner")
                    val provisioner = network.createProvisioner("Kantmiss Provisioner")
                    network.selectProvisioner(provisioner)
                    android.util.Log.d("MeshPlugin", "Created and selected provisioner: ${provisioner.provisionerName}")
                } else if (network.selectedProvisioner == null) {
                    network.selectProvisioner(network.provisioners.first())
                    android.util.Log.d("MeshPlugin", "Selected existing provisioner: ${network.selectedProvisioner?.provisionerName}")
                }
                
                // CRITICAL: Add provisioner as a node so it can receive GenericOnOffStatus messages
                val provisionerUnicast = 0x0001
                val provisionerNode = network.nodes.firstOrNull { it.unicastAddress == provisionerUnicast }
                if (provisionerNode == null) {
                    android.util.Log.w("MeshPlugin", "Provisioner node not found! Creating stub node at 0x0001 with GenericOnOffClient")
                    try {
                        // Create a provisioner node using JSON import (hack but works)
                        // The Nordic SDK doesn't have a public API to create nodes programmatically,
                        // so we'll import a minimal node definition
                        val success = createProvisionerNode(network, provisionerUnicast)
                        if (!success) {
                            android.util.Log.e("MeshPlugin", "Failed to create provisioner node - import failed")
                        }
                    } catch (e: Exception) {
                        android.util.Log.e("MeshPlugin", "Failed to create provisioner node: ${e.message}", e)
                    }
                } else {
                    android.util.Log.d("MeshPlugin", "Provisioner node already exists at 0x${provisionerUnicast.toString(16)}")
                }
                // Ensure mesh network keys match provided credentials.
                // Important: Don't remove/re-add keys if they already match - this preserves sequence numbers

                val netKeyToAdd = NetworkKey(0, netKeyBytes)
                val appKeyToAdd = ApplicationKey(0, appKeyBytes)

                // Check if network key already exists and matches
                val existingNetKey = network.netKeys.firstOrNull { it.keyIndex == 0 }
                if (existingNetKey == null) {
                    network.addNetKey(netKeyToAdd)
                    android.util.Log.d("MeshPlugin", "Added Network Key to meshNetwork")
                } else if (!existingNetKey.key.contentEquals(netKeyBytes)) {
                    android.util.Log.w("MeshPlugin", "Network key mismatch - updating")
                    network.removeNetKey(existingNetKey)
                    network.addNetKey(netKeyToAdd)
                } else {
                    android.util.Log.d("MeshPlugin", "Network key already configured correctly")
                }

                // Check if app key already exists and matches
                val existingAppKey = network.appKeys.firstOrNull { it.keyIndex == 0 }
                if (existingAppKey == null) {
                    network.addAppKey(appKeyToAdd)
                    android.util.Log.d("MeshPlugin", "Added Application Key to meshNetwork")
                } else if (!existingAppKey.key.contentEquals(appKeyBytes)) {
                    android.util.Log.w("MeshPlugin", "Application key mismatch - updating")
                    network.removeAppKey(existingAppKey)
                    network.addAppKey(appKeyToAdd)
                } else {
                    android.util.Log.d("MeshPlugin", "Application key already configured correctly")
                }

                // Programmatically add group 0xC000 if it doesn't exist
                if (network.groups.none { it.address == 0xC000 }) {
                    val provisioner = network.selectedProvisioner ?: network.provisioners.firstOrNull()
                    if (provisioner != null) {
                        val defaultGroup = network.createGroup(provisioner, 0xC000, "Default")
                        android.util.Log.d("MeshPlugin", "Created group 0xC000 (Default)")
                    }
                }

                // Log current sequence number status (for debugging)
                // Provisioner typically uses 0x0001 as unicast address
                val provisionerAddress = 0x0001
                val currentSeq = network.sequenceNumbers.get(provisionerAddress, 0)
                android.util.Log.i("MeshPlugin", "Provisioner (0x${provisionerAddress.toString(16)}) current sequence: $currentSeq (managed by Nordic SDK)")

                android.util.Log.d("MeshPlugin", "Mesh network configured: nodes=${network.nodes.size}, groups=${network.groups.size}")
            }

            result.success(true)
        } catch (e: Exception) {
            result.error("MESH_SETUP_ERROR", e.message, null)
        }
    }

    /**
     * Best-effort helper to ensure the provisioner exists as a node in the imported mesh JSON.
     *
     * This is intentionally defensive: if JSON import fails due to schema differences, we log
     * and return false without crashing or corrupting runtime state.
     */
    private fun createProvisionerNode(network: MeshNetwork, unicastAddress: Int): Boolean {
        return try {
            val json = meshManagerApi.exportMeshNetwork()
            if (json.isNullOrEmpty()) {
                android.util.Log.e("MeshPlugin", "Cannot create provisioner node: exportMeshNetwork() returned empty")
                return false
            }

            val root = JSONObject(json)
            val nodesArray = root.optJSONArray("nodes") ?: JSONArray()

            for (i in 0 until nodesArray.length()) {
                val nodeObj = nodesArray.optJSONObject(i) ?: continue
                if (nodeObj.optInt("unicastAddress", -1) == unicastAddress) {
                    return true
                }
            }

            // Minimal node definition matching what we read elsewhere in this plugin.
            // If the Nordic SDK requires more fields, import will fail and we'll return false.
            val provisionerNodeJson = JSONObject().apply {
                put("UUID", UUID.randomUUID().toString().replace("-", ""))
                put("name", "Provisioner")
                put("unicastAddress", unicastAddress)
                put("deviceKey", "00000000000000000000000000000000")
                put(
                    "elements",
                    JSONArray().put(
                        JSONObject().apply {
                            put("index", 0)
                            put("location", "0000")
                            put(
                                "models",
                                JSONArray().apply {
                                    // Configuration Server
                                    put(
                                        JSONObject().apply {
                                            put("modelId", "0000")
                                            put("subscribe", JSONArray())
                                            put("bind", JSONArray())
                                        }
                                    )
                                    // Health Server
                                    put(
                                        JSONObject().apply {
                                            put("modelId", "0002")
                                            put("subscribe", JSONArray())
                                            put("bind", JSONArray())
                                        }
                                    )
                                    // Generic OnOff Client (to receive statuses)
                                    put(
                                        JSONObject().apply {
                                            put("modelId", "1001")
                                            put("subscribe", JSONArray())
                                            put("bind", JSONArray().put(0))
                                        }
                                    )
                                }
                            )
                        }
                    )
                )
            }

            nodesArray.put(provisionerNodeJson)
            root.put("nodes", nodesArray)

            val modifiedJson = root.toString()
            android.util.Log.i("MeshPlugin", "Attempting mesh JSON import with added provisioner node")
            meshManagerApi.importMeshNetworkJson(modifiedJson)
            meshNetwork = meshManagerApi.meshNetwork

            val verifyNode = meshNetwork?.nodes?.firstOrNull { it.unicastAddress == unicastAddress }
            verifyNode != null
        } catch (e: Exception) {
            android.util.Log.e("MeshPlugin", "createProvisionerNode failed: ${e.message}", e)
            false
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
                val deviceUnicasts = call.argument<List<Int>>("deviceUnicasts") ?: emptyList()
                val connected = ensureProxyConnection(mac)
                
                if (connected && deviceUnicasts.isNotEmpty()) {
                    // Configure proxy filter after connection
                    android.util.Log.d("MeshPlugin", "Configuring proxy filter for ${deviceUnicasts.size} devices")
                    configureProxyFilterInternal(deviceUnicasts)
                }
                
                result.success(connected)
            } catch (e: Exception) {
                result.error("PROXY_CONN_ERROR", e.message, null)
            }
        }
    }

    private suspend fun ensureProxyConnection(macAddress: String): Boolean {
        if (isConnected) {
            android.util.Log.d("MeshPlugin", "Already connected to proxy")
            return true
        }
        
        android.util.Log.d("MeshPlugin", "Connecting to proxy: $macAddress")
        val normalizedMac = normalizeMac(macAddress)
        
        // Calculate unicast address from MAC (last 2 bytes)
        currentProxyUnicast = macToUnicast(normalizedMac)
        if (currentProxyUnicast != null) {
            android.util.Log.d("MeshPlugin", "Calculated proxy unicast: 0x${currentProxyUnicast?.toString(16)}")
        } else {
            android.util.Log.w("MeshPlugin", "Failed to calculate proxy unicast from MAC: $normalizedMac")
        }
        val bluetoothAdapter = android.bluetooth.BluetoothAdapter.getDefaultAdapter()
        val device = bluetoothAdapter.getRemoteDevice(normalizedMac)
        
        bleManager = MeshBleManager(context)
        val connectionResult = kotlinx.coroutines.CompletableDeferred<Boolean>()
        
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
        
        val connected = kotlinx.coroutines.withTimeoutOrNull(20000) {
            connectionResult.await()
        } ?: false
        
        android.util.Log.d("MeshPlugin", "Proxy connection result: $connected")
        return connected
    }

    private fun disconnectFromDevice(result: MethodChannel.Result) {
        scope.launch {
            try {
                bleManager?.disconnect()?.enqueue()
                bleManager = null
                isConnected = false
                proxyFilterConfigured = false
                lastProxyFilterAddresses = emptySet()
                currentProxyUnicast = null
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
                    val connected = ensureProxyConnection(macs.first())
                    if (!connected) {
                        result.error("PROXY_CONNECTION_FAILED", "Failed to connect to mesh proxy device", null)
                        return@launch
                    }
                }
                
                // CRITICAL: Configure proxy filter to receive responses
                if (!proxyFilterConfigured && !macs.isNullOrEmpty()) {
                    android.util.Log.d("MeshPlugin", "Configuring proxy filter for ${macs.size} devices (MACs: ${macs.joinToString(", ")})")
                    // Calculate unicast addresses from MACs
                    val deviceUnicasts = macs.mapNotNull { mac ->
                        try {
                            val unicast = macToUnicast(mac)
                            if (unicast != null) {
                                android.util.Log.d("MeshPlugin", "MAC $mac → unicast 0x${unicast.toString(16)}")
                            }
                            unicast
                        } catch (e: Exception) {
                            android.util.Log.w("MeshPlugin", "Failed to parse MAC $mac: ${e.message}")
                            null
                        }
                    }
                    if (deviceUnicasts.isNotEmpty()) {
                        configureProxyFilterInternal(deviceUnicasts, extraGroupAddresses = listOf(groupId))
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
                    // Use acknowledged Set so we can count/respond to GenericOnOffStatus (PRD FR-3.3.4)
                    val message = GenericOnOffSet(appKey, state, tId)
                    android.util.Log.d("MeshPlugin", "GenericOnOffSet(ACK): groupAddress=0x${groupAddress.toString(16)}, state=$state, tId=$tId")
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
                val deviceUnicasts = call.argument<List<Int>>("deviceUnicasts") ?: emptyList()
                
                android.util.Log.d("MeshPlugin", "discoverGroupMembers: sending GenericOnOffGet to group 0x${groupAddress.toString(16)}")
                
                // Check if connected to proxy
                if (!isConnected) {
                    android.util.Log.e("MeshPlugin", "Cannot discover group members: no proxy connection")
                    result.error("NO_PROXY", "Must connect to proxy device before discovering groups", null)
                    return@launch
                }

                // Ensure proxy filter includes the group + expected responders (TECHNICAL: proxy drops otherwise)
                if (deviceUnicasts.isNotEmpty()) {
                    configureProxyFilterInternal(deviceUnicasts, extraGroupAddresses = listOf(groupAddress))
                }
                
                meshNetwork?.appKeys?.firstOrNull()?.let { appKey ->
                    val message = GenericOnOffGet(appKey)
                    android.util.Log.d("MeshPlugin", "Sending GenericOnOffGet to group 0x${groupAddress.toString(16)}")
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
    
    private fun configureProxyFilter(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val deviceUnicasts = call.argument<List<Int>>("deviceUnicasts")
                    ?: throw IllegalArgumentException("deviceUnicasts required")
                
                configureProxyFilterInternal(deviceUnicasts)
                result.success(true)
            } catch (e: Exception) {
                android.util.Log.e("MeshPlugin", "configureProxyFilter error: ${e.message}", e)
                result.error("FILTER_CONFIG_ERROR", e.message, null)
            }
        }
    }
    
    /**
     * Configure the proxy filter to forward status messages for specific device unicast addresses.
     * This is CRITICAL - without this, the proxy drops all incoming status messages.
     */
    private fun configureProxyFilterInternal(deviceUnicasts: List<Int>, extraGroupAddresses: List<Int> = emptyList()) {
        if (!isConnected) {
            android.util.Log.w("MeshPlugin", "Cannot configure filter: not connected to proxy")
            return
        }

        // Proxy filtering is based on destination addresses.
        // Always include the provisioner (so replies addressed to us are forwarded) and Default group.
        // Include extra group addresses for current operations, and include device unicasts because
        // some firmwares publish status to unicast (not to the group / provisioner).
        val defaultGroupAddress = 0xC000
        val provisionerUnicast = 0x0001
        val desiredAddresses = (listOf(provisionerUnicast, defaultGroupAddress) + extraGroupAddresses + deviceUnicasts)
            .distinct()
            .toSet()

        if (proxyFilterConfigured && desiredAddresses == lastProxyFilterAddresses) {
            android.util.Log.d("MeshPlugin", "Proxy filter already configured for same address set")
            return
        }
        
        try {
            android.util.Log.d(
                "MeshPlugin",
                "Configuring proxy filter for ${desiredAddresses.size} addresses (prov=0x${provisionerUnicast.toString(16)}, group=0x${defaultGroupAddress.toString(16)})"
            )
            
            // Find the proxy node in the mesh network
            val proxyNode = meshNetwork?.nodes?.firstOrNull { node ->
                // The proxy is the device we're currently connected to
                // We need to match it by unicast address
                currentProxyUnicast?.let { it == node.unicastAddress } ?: false
            }
            
            if (proxyNode == null) {
                // If we can't find proxy node by unicast, try to use the first node
                // or create a lightweight node entry for the proxy
                android.util.Log.w("MeshPlugin", "Proxy node not found in network, attempting filter config anyway")
                
                // We'll send the config messages to the proxy's presumed unicast address
                // Extract from the current BLE connection if possible
                val targetUnicast = currentProxyUnicast
                    ?: throw IllegalStateException("currentProxyUnicast is null; cannot configure proxy filter")
                
                // Step 1: Set filter type to WHITELIST (INCLUSION_LIST)
                val filterSetup = ProxyConfigSetFilterType(ProxyFilterType(ProxyFilterType.INCLUSION_LIST_FILTER))
                meshManagerApi.createMeshPdu(targetUnicast, filterSetup)
                android.util.Log.d("MeshPlugin", "Sent ProxyConfigSetFilterType(INCLUSION_LIST) to 0x${targetUnicast.toString(16)}")
                
                // Step 2: Add device addresses in batches (max ~10 per message)
                val batches = desiredAddresses.toList().chunked(10)
                for (batch in batches) {
                    val addressList = batch.map { addr ->
                        val b1 = ((addr shr 8) and 0xFF).toByte()
                        val b2 = (addr and 0xFF).toByte()
                        AddressArray(b1, b2)
                    }
                    val addAddresses = ProxyConfigAddAddressToFilter(addressList)
                    meshManagerApi.createMeshPdu(targetUnicast, addAddresses)
                    android.util.Log.d("MeshPlugin", "Added ${batch.size} addresses to filter: ${batch.map { "0x" + it.toString(16) }.joinToString(", ")}")
                }
            } else {
                // Found proxy node - use it
                val targetUnicast = proxyNode.unicastAddress
                android.util.Log.d("MeshPlugin", "Configuring filter on proxy node: ${proxyNode.nodeName} (0x${targetUnicast.toString(16)})")
                
                // Step 1: Set filter type to WHITELIST (INCLUSION_LIST)
                val filterSetup = ProxyConfigSetFilterType(ProxyFilterType(ProxyFilterType.INCLUSION_LIST_FILTER))
                meshManagerApi.createMeshPdu(targetUnicast, filterSetup)
                android.util.Log.d("MeshPlugin", "Sent ProxyConfigSetFilterType(INCLUSION_LIST)")
                
                // Step 2: Add device addresses in batches
                val batches = desiredAddresses.toList().chunked(10)
                for (batch in batches) {
                    val addressList = batch.map { addr ->
                        val b1 = ((addr shr 8) and 0xFF).toByte()
                        val b2 = (addr and 0xFF).toByte()
                        AddressArray(b1, b2)
                    }
                    val addAddresses = ProxyConfigAddAddressToFilter(addressList)
                    meshManagerApi.createMeshPdu(targetUnicast, addAddresses)
                    android.util.Log.d("MeshPlugin", "Added ${batch.size} addresses to filter: ${batch.map { "0x" + it.toString(16) }.joinToString(", ")}")
                }
            }
            
            proxyFilterConfigured = true
            lastProxyFilterAddresses = desiredAddresses
            android.util.Log.i("MeshPlugin", "✓ Proxy filter configured for ${deviceUnicasts.size} devices (extraGroups=${extraGroupAddresses.size})")
            
        } catch (e: Exception) {
            android.util.Log.e("MeshPlugin", "Failed to configure proxy filter", e)
            proxyFilterConfigured = false
            lastProxyFilterAddresses = emptySet()
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

    private fun sendUnicastGet(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val unicastAddress = call.argument<Int>("unicastAddress")
                    ?: throw IllegalArgumentException("unicastAddress required")
                val proxyMac = call.argument<String>("proxyMac")

                android.util.Log.d("MeshPlugin", "sendUnicastGet to 0x${unicastAddress.toString(16)}, proxyMac=$proxyMac")

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
                    val message = GenericOnOffGet(appKey)
                    meshManagerApi.createMeshPdu(unicastAddress, message)
                    result.success(true)
                } ?: run {
                    result.error("NO_APP_KEY", "No app key configured", null)
                }
            } catch (e: Exception) {
                android.util.Log.e("MeshPlugin", "sendUnicastGet error: ${e.message}", e)
                result.error("UNICAST_GET_ERROR", e.message, null)
            }
        }
    }

    /**
     * Reset mesh network to clear replay protection issues.
     * 
     * IMPORTANT: This is a nuclear option. The proper BLE Mesh way is:
     * 1. Let the Nordic SDK manage sequence numbers automatically (persisted to DB)
     * 2. If devices are rejecting messages, perform an IV Index update (network-wide operation)
     * 3. Only use this reset if you need to completely start over
     * 
     * This will:
     * - Clear all mesh network state
     * - Reset sequence numbers to 0
     * - Require re-provisioning all devices
     */
    private fun resetMeshNetwork(result: MethodChannel.Result) {
        try {
            android.util.Log.w("MeshPlugin", "Resetting mesh network - all state will be lost!")
            meshManagerApi.resetMeshNetwork()
            meshNetwork = meshManagerApi.meshNetwork
            result.success(true)
        } catch (e: Exception) {
            android.util.Log.e("MeshPlugin", "Failed to reset mesh network", e)
            result.error("RESET_ERROR", e.message, null)
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

        private var negotiatedMtu: Int = 23
        private var lastBatteryLevel: Int? = null

        // BLE Mesh Proxy PDUs may be segmented across multiple notifications.
        // Reassemble segments (SAR=First/Continuation/Last) into a complete PDU.
        private var rxProxyPduType: Int? = null
        private var rxProxyPduBuffer: ByteArrayOutputStream? = null
        
        // Callback to notify when connection is ready
        var onConnectionReady: (() -> Unit)? = null
        var onConnectionFailed: (() -> Unit)? = null

        fun getGattMtu(): Int = negotiatedMtu

        fun getBatteryLevel(): Int? = lastBatteryLevel

        fun sendPdu(pdu: ByteArray) {
            val target = proxyDataIn
            if (target == null) {
                android.util.Log.e("MeshPlugin", "sendPdu: proxyDataIn characteristic is null")
                return
            }
            if (pdu.isEmpty()) return

            // Mesh Proxy PDUs are written to the Proxy Data In characteristic.
            // Best-effort: write without blocking.
            try {
                writeCharacteristic(target, pdu)
                    .fail { _, status ->
                        android.util.Log.e("MeshPlugin", "sendPdu write failed: $status")
                    }
                    .enqueue()
            } catch (e: Exception) {
                android.util.Log.e("MeshPlugin", "sendPdu exception: ${e.message}", e)
            }
        }

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
                val hasProxyChars = this@MeshBleManager.proxyDataIn != null && this@MeshBleManager.proxyDataOut != null
                android.util.Log.d("MeshPlugin", "isRequiredServiceSupported returning: true (hasProxyChars=$hasProxyChars)")
                return true // Always accept connection to see what services are available
            }

            override fun onServicesInvalidated() {
                this@MeshBleManager.proxyDataIn = null
                this@MeshBleManager.proxyDataOut = null
                this@MeshBleManager.batteryLevelChar = null
                rxProxyPduType = null
                rxProxyPduBuffer = null
                negotiatedMtu = 23
                lastBatteryLevel = null
            }

            override fun onMtuChanged(@NonNull gatt: BluetoothGatt, mtu: Int) {
                negotiatedMtu = mtu
                android.util.Log.d("MeshPlugin", "ATT MTU changed: $mtu")
            }

            override fun initialize() {
                android.util.Log.d("MeshPlugin", "BleManager.initialize() called")
                requestMtu(517).enqueue()

                // Best-effort initial Battery Level read (optional).
                batteryLevelChar?.let { batteryChar ->
                    try {
                        readCharacteristic(batteryChar)
                            .with(DataReceivedCallback { _, data ->
                                val bytes = data.value
                                if (bytes != null && bytes.isNotEmpty()) {
                                    lastBatteryLevel = bytes[0].toInt() and 0xFF
                                }
                            })
                            .enqueue()
                    } catch (_: Exception) {
                        // ignore
                    }
                }
                
                proxyDataOut?.let { char ->
                    android.util.Log.d("MeshPlugin", "Enabling notifications on proxy data out")
                    val onDataReceived = DataReceivedCallback { device, data ->
                        val bytes = data.value ?: byteArrayOf()
                        val hexString = bytes.joinToString(" ") { "%02X".format(it) }
                        android.util.Log.d("MeshPlugin", "Received ${bytes.size} bytes from proxy: $hexString")
                        
                        if (bytes.isEmpty()) return@DataReceivedCallback

                        val header = bytes[0].toInt() and 0xFF
                        val sar = (header ushr 6) and 0x03
                        val pduType = header and 0x3F

                        // Log PDU type for debugging (type is lower 6 bits; SAR is upper 2).
                        when (pduType) {
                            0x00 -> android.util.Log.i("MeshPlugin", "↓ Network PDU (sar=$sar)")
                            0x01 -> android.util.Log.d("MeshPlugin", "↓ Mesh beacon (sar=$sar)")
                            0x02 -> android.util.Log.d("MeshPlugin", "↓ Proxy configuration (sar=$sar)")
                            0x03 -> android.util.Log.d("MeshPlugin", "↓ Provisioning PDU (sar=$sar)")
                            else -> android.util.Log.d("MeshPlugin", "↓ Unknown Proxy PDU type=0x${pduType.toString(16)} (sar=$sar)")
                        }

                        fun deliverToSdk(fullPdu: ByteArray) {
                            if (fullPdu.isEmpty()) return
                            // Only deliver Network PDUs to avoid Nordic SDK crashes when parsing
                            // Proxy Configuration PDUs (observed NPE in DefaultNoOperationMessageState).
                            val fullType = fullPdu[0].toInt() and 0x3F
                            if (fullType != 0x00) return
                            try {
                                meshManagerApi.handleNotifications(getGattMtu(), fullPdu)
                            } catch (e: Exception) {
                                android.util.Log.e("MeshPlugin", "handleNotifications failed (ignored): ${e.message}", e)
                            }
                        }

                        when (sar) {
                            0 -> {
                                // Complete PDU
                                deliverToSdk(bytes)
                            }
                            1 -> {
                                // First segment
                                rxProxyPduType = pduType
                                rxProxyPduBuffer = ByteArrayOutputStream().apply {
                                    if (bytes.size > 1) write(bytes, 1, bytes.size - 1)
                                }
                            }
                            2 -> {
                                // Continuation segment
                                if (rxProxyPduType == pduType && rxProxyPduBuffer != null) {
                                    if (bytes.size > 1) rxProxyPduBuffer?.write(bytes, 1, bytes.size - 1)
                                } else {
                                    // Unexpected continuation; reset.
                                    rxProxyPduType = null
                                    rxProxyPduBuffer = null
                                }
                            }
                            3 -> {
                                // Last segment
                                if (rxProxyPduType == pduType && rxProxyPduBuffer != null) {
                                    if (bytes.size > 1) rxProxyPduBuffer?.write(bytes, 1, bytes.size - 1)
                                    val payload = rxProxyPduBuffer?.toByteArray() ?: byteArrayOf()
                                    val completeHeader = (0 shl 6) or (pduType and 0x3F)
                                    val full = ByteArray(1 + payload.size)
                                    full[0] = completeHeader.toByte()
                                    if (payload.isNotEmpty()) {
                                        System.arraycopy(payload, 0, full, 1, payload.size)
                                    }
                                    deliverToSdk(full)
                                }
                                rxProxyPduType = null
                                rxProxyPduBuffer = null
                            }
                        }
                    }

                    setNotificationCallback(char).with(onDataReceived)
                    enableNotifications(char)
                        .done {
                            android.util.Log.d("MeshPlugin", "Proxy notifications enabled")
                            this@MeshPlugin.isConnected = true
                            onConnectionReady?.invoke()
                        }
                        .fail { _, status ->
                            android.util.Log.e("MeshPlugin", "Failed to enable proxy notifications: $status")
                            this@MeshPlugin.isConnected = false
                            onConnectionFailed?.invoke()
                        }
                        .enqueue()
                } ?: run {
                    android.util.Log.e("MeshPlugin", "Proxy Data Out characteristic is null; cannot enable notifications")
                    this@MeshPlugin.isConnected = false
                    onConnectionFailed?.invoke()
                }
            }
        }
    }
}
