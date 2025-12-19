package com.nordicmesh.nordic_mesh_manager

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.content.Context
import android.util.SparseIntArray
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
    private var lastProvisionerSeqPersistMs: Long = 0

    // Heuristics for automatic replay protection repair.
    private var lastRxPduMs: Long = 0
    private var lastDecryptionFailureMs: Long = 0
    private var lastAutoReplayRepairMs: Long = 0
    private var pendingUnicast: PendingUnicast? = null

    private data class PendingUnicast(
        val dst: Int,
        val state: Boolean?,
        val isGet: Boolean,
        val createdAtMs: Long,
        val attempts: Int,
    )

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

    private fun ensureProvisionerAddress(network: MeshNetwork): Int {
        val selected = network.selectedProvisioner ?: network.provisioners.firstOrNull()

        if (selected == null) {
            android.util.Log.w("MeshPlugin", "No provisioner present; creating and adding default provisioner")
            val created = network.createProvisioner("Kantmiss Provisioner")
            val address = created.allocatedUnicastRanges.firstOrNull()?.lowAddress ?: 0x0001
            created.assignProvisionerAddress(address)
            network.addProvisioner(created)
            network.selectProvisioner(created)
            return address
        }

        network.selectProvisioner(selected)
        val existingAddress = selected.provisionerAddress
        if (existingAddress != null) return existingAddress

        val address = selected.allocatedUnicastRanges.firstOrNull()?.lowAddress ?: 0x0001
        android.util.Log.w(
            "MeshPlugin",
            "Selected provisioner has no address; assigning 0x${address.toString(16)} and updating"
        )
        selected.assignProvisionerAddress(address)
        network.updateProvisioner(selected)
        return address
    }

    private fun persistProvisionerSequenceIfNeeded(reason: String) {
        val network = meshNetwork ?: return
        val provisioner = network.selectedProvisioner ?: network.provisioners.firstOrNull() ?: return
        val provisionerAddress = provisioner.provisionerAddress ?: return

        // Throttle to avoid hammering Room DB when we send many proxy config PDUs.
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastProvisionerSeqPersistMs < 750) return
        lastProvisionerSeqPersistMs = now

        try {
            // Workaround for Nordic Mesh library behavior:
            // - Sequence numbers for group-address sends may not be persisted because MeshManagerApi updates DB using dst node.
            // - Calling updateProvisioner() forces the provisioner's node entry to get updated with the latest sequence.
            network.updateProvisioner(provisioner)
            val seq = network.sequenceNumbers.get(provisionerAddress, 0)
            android.util.Log.d(
                "MeshPlugin",
                "Persisted provisioner seq=$seq for 0x${provisionerAddress.toString(16)} ($reason)"
            )
        } catch (e: Exception) {
            android.util.Log.w("MeshPlugin", "Failed to persist provisioner sequence ($reason): ${e.message}")
        }
    }

    private fun persistProvisionerSequenceNow(reason: String) {
        val network = meshNetwork ?: return
        val provisioner = network.selectedProvisioner ?: network.provisioners.firstOrNull() ?: return
        val provisionerAddress = provisioner.provisionerAddress ?: return
        try {
            network.updateProvisioner(provisioner)
            val seq = network.sequenceNumbers.get(provisionerAddress, 0)
            android.util.Log.d(
                "MeshPlugin",
                "Persisted provisioner seq=$seq for 0x${provisionerAddress.toString(16)} ($reason)"
            )
        } catch (e: Exception) {
            android.util.Log.w("MeshPlugin", "Failed to persist provisioner sequence ($reason): ${e.message}")
        }
    }

    private fun ensureMinimumProvisionerSequence(minimum: Int, reason: String) {
        val network = meshNetwork ?: return
        val provisioner = network.selectedProvisioner ?: network.provisioners.firstOrNull() ?: return
        val provisionerAddress = provisioner.provisionerAddress ?: return

        val current = network.sequenceNumbers.get(provisionerAddress, 0)
        if (current >= minimum) return

        val maxSeq = 0xFFFFFF
        val target = minimum.coerceAtMost(maxSeq)
        val seqs: SparseIntArray = network.sequenceNumbers
        seqs.put(provisionerAddress, target)
        network.setSequenceNumbers(seqs)
        persistProvisionerSequenceNow("ensureMinimumProvisionerSequence:$reason")
        android.util.Log.w(
            "MeshPlugin",
            "Bumped provisioner seq 0x${provisionerAddress.toString(16)}: $current -> $target ($reason)"
        )
    }

    private fun isValidUnicast(address: Int): Boolean = address in 0x0001..0x7FFF

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
            "resetMeshNetwork" -> resetMeshNetwork(result)
            "repairReplayProtection" -> repairReplayProtection(call, result)
            else -> result.notImplemented()
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
                    // Persist sequence numbers so devices don't flag replay after app restarts.
                    // Especially important for group dst, where Nordic SDK may not persist SRC sequence.
                    persistProvisionerSequenceIfNeeded("onMeshPduCreated")
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
                maybeAutoRepairReplayAndRetry(dst)
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
                lastDecryptionFailureMs = android.os.SystemClock.elapsedRealtime()
            }
        })
    }

    private fun maybeAutoRepairReplayAndRetry(dst: Int) {
        val pending = pendingUnicast ?: return
        if (pending.dst != dst) return
        if (!isValidUnicast(dst)) return
        if (!isConnected) return

        val now = android.os.SystemClock.elapsedRealtime()

        // If we recently saw decryption failures, this is likely key/iv mismatch (seq bump won't help).
        if (now - lastDecryptionFailureMs < 10_000) {
            android.util.Log.w("MeshPlugin", "Skip auto replay repair: recent decryption failure")
            return
        }

        // If we aren't receiving anything from the proxy, this is more likely connection/filter than replay.
        if (now - lastRxPduMs > 12_000) {
            android.util.Log.w("MeshPlugin", "Skip auto replay repair: no recent RX from proxy")
            return
        }

        // Avoid rapid loops.
        if (now - lastAutoReplayRepairMs < 8_000) return
        if (pending.attempts >= 2) return

        val network = meshNetwork ?: return
        val provisioner = network.selectedProvisioner ?: network.provisioners.firstOrNull() ?: return
        val provisionerAddress = provisioner.provisionerAddress ?: return

        val current = network.sequenceNumbers.get(provisionerAddress, 0)
        val maxSeq = 0xFFFFFF
        val step = 200_000 * (pending.attempts + 1)
        val target = maxOf(current + step, 3_000_000).coerceAtMost(maxSeq)

        val seqs: SparseIntArray = network.sequenceNumbers
        seqs.put(provisionerAddress, target)
        network.setSequenceNumbers(seqs)
        persistProvisionerSequenceNow("autoReplayRepair")

        android.util.Log.w(
            "MeshPlugin",
            "Auto replay repair: bumped seq for 0x${provisionerAddress.toString(16)} $current -> $target; retrying dst=0x${dst.toString(16)}"
        )

        lastAutoReplayRepairMs = now

        try {
            val appKey = meshNetwork?.appKeys?.firstOrNull { it.keyIndex == 0 }
                ?: meshNetwork?.appKeys?.firstOrNull()
                ?: return

            if (pending.isGet) {
                val msg = GenericOnOffGet(appKey)
                meshManagerApi.createMeshPdu(dst, msg)
                pendingUnicast = pending.copy(attempts = pending.attempts + 1)
            } else {
                val state = pending.state ?: return
                val tId = Random.nextInt(256)
                val msg = GenericOnOffSet(appKey, state, tId)
                meshManagerApi.createMeshPdu(dst, msg)
                pendingUnicast = pending.copy(attempts = pending.attempts + 1)
            }
        } catch (e: Exception) {
            android.util.Log.w("MeshPlugin", "Auto replay retry failed: ${e.message}")
        }
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
                // Ensure we have a selected provisioner with an assigned address.
                // This address becomes the SRC for access messages, and status replies are typically sent back to it.
                val provisionerUnicast = ensureProvisionerAddress(network)
                // Ensure provisioner has an associated node entry so its sequence number can be persisted.
                network.selectedProvisioner?.let { network.updateProvisioner(it) }
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
                val currentSeq = network.sequenceNumbers.get(provisionerUnicast, 0)
                android.util.Log.i(
                    "MeshPlugin",
                    "Provisioner (0x${provisionerUnicast.toString(16)}) current sequence: $currentSeq (managed by Nordic SDK)"
                )

                // Persist the provisioner node after credential setup to ensure sequence survives restarts.
                persistProvisionerSequenceIfNeeded("setMeshCredentials")

                // Automatic replay mitigation:
                // We can't read the device's replay cache, so we proactively ensure we never start from a low
                // sequence number after an app restart.
                // 24-bit max is 16,777,215, so 3,000,000 leaves plenty of headroom.
                ensureMinimumProvisionerSequence(3_000_000 + Random.nextInt(10_000), "credentials")

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
                        configureProxyFilterInternal(deviceUnicasts)
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
                
                val appKey = meshNetwork?.appKeys?.firstOrNull { it.keyIndex == 0 }
                    ?: meshNetwork?.appKeys?.firstOrNull()
                appKey?.let { appKey ->
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

                val appKey = meshNetwork?.appKeys?.firstOrNull { it.keyIndex == 0 }
                    ?: meshNetwork?.appKeys?.firstOrNull()
                appKey?.let { appKey ->
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
                    configureProxyFilterInternal(deviceUnicasts)
                }
                
                val appKey = meshNetwork?.appKeys?.firstOrNull { it.keyIndex == 0 }
                    ?: meshNetwork?.appKeys?.firstOrNull()
                appKey?.let { appKey ->
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
    private fun configureProxyFilterInternal(deviceUnicasts: List<Int>) {
        if (!isConnected) {
            android.util.Log.w("MeshPlugin", "Cannot configure filter: not connected to proxy")
            return
        }

        // Include default group address so we can receive published statuses to the group.
        val defaultGroupAddress = 0xC000
        // Use the *actual* selected provisioner address; status replies are typically destined here.
        val provisionerUnicast = meshNetwork?.let { network ->
            network.selectedProvisioner?.provisionerAddress
                ?: network.provisioners.firstOrNull()?.provisionerAddress
        } ?: 0x0001
        val desiredAddresses = (listOf(provisionerUnicast, defaultGroupAddress) + deviceUnicasts).distinct().toSet()

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
                
                // Step 2: Add addresses.
                // NOTE: Work around a known length-calculation bug in the upstream Nordic
                // ProxyConfigAddAddressToFilter implementation (it may pad with zeros and some
                // devices reject it with "Failed to decode Proxy Configuration (err -22)").
                // Sending 1 address per message avoids the malformed length.
                val batches = desiredAddresses.toList().chunked(1)
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
                
                // Step 2: Add addresses (1 per message) to avoid malformed ProxyConfigAddAddressToFilter payload lengths.
                val batches = desiredAddresses.toList().chunked(1)
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
            android.util.Log.i("MeshPlugin", "✓ Proxy filter configured for ${deviceUnicasts.size} devices")
            
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
                
                val appKey = meshNetwork?.appKeys?.firstOrNull { it.keyIndex == 0 }
                    ?: meshNetwork?.appKeys?.firstOrNull()
                appKey?.let { appKey ->
                    val tId = Random.nextInt(256)
                    val message = GenericOnOffSet(appKey, state, tId)
                    android.util.Log.d("MeshPlugin", "GenericOnOffSet unicast: dst=0x${unicastAddress.toString(16)}, tId=$tId")

                    pendingUnicast = PendingUnicast(
                        dst = unicastAddress,
                        state = state,
                        isGet = false,
                        createdAtMs = android.os.SystemClock.elapsedRealtime(),
                        attempts = 0
                    )

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

                val appKey = meshNetwork?.appKeys?.firstOrNull { it.keyIndex == 0 }
                    ?: meshNetwork?.appKeys?.firstOrNull()
                appKey?.let { appKey ->
                    val message = GenericOnOffGet(appKey)

                    pendingUnicast = PendingUnicast(
                        dst = unicastAddress,
                        state = null,
                        isGet = true,
                        createdAtMs = android.os.SystemClock.elapsedRealtime(),
                        attempts = 0
                    )

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
     * If devices log replay errors (e.g. "Replay: src 0x0001 ..."), the mesh stack is rejecting
     * our messages because the source address is reusing an old (too-low) sequence number.
     *
     * This method bumps the provisioner sequence number to a high watermark and persists it.
     *
     * Args:
     * - targetSeq (optional): desired minimum sequence number (default 1,000,000)
     */
    private fun repairReplayProtection(call: MethodCall, result: MethodChannel.Result) {
        try {
            val network = meshNetwork ?: throw IllegalStateException("Mesh network not loaded")
            val provisionerAddress = ensureProvisionerAddress(network)
            val provisioner = network.selectedProvisioner ?: throw IllegalStateException("No provisioner selected")

            val targetSeq = call.argument<Int>("targetSeq") ?: 1_000_000
            if (targetSeq < 0) throw IllegalArgumentException("targetSeq must be >= 0")

            val current = network.sequenceNumbers.get(provisionerAddress, 0)
            val bumped = maxOf(current, targetSeq)

            val seqs: SparseIntArray = network.sequenceNumbers
            seqs.put(provisionerAddress, bumped)
            network.setSequenceNumbers(seqs)
            network.updateProvisioner(provisioner)

            android.util.Log.w(
                "MeshPlugin",
                "Replay repair: provisioner 0x${provisionerAddress.toString(16)} seq $current -> $bumped"
            )
            result.success(mapOf(
                "provisionerAddress" to provisionerAddress,
                "previousSeq" to current,
                "newSeq" to bumped
            ))
        } catch (e: Exception) {
            android.util.Log.e("MeshPlugin", "repairReplayProtection failed", e)
            result.error("REPLAY_REPAIR_ERROR", e.message, null)
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
        private var connectionReadySignaled: Boolean = false
        
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
                connectionReadySignaled = false

                if (!hasProxyChars || proxyDataIn == null || proxyDataOut == null) {
                    android.util.Log.e(
                        "MeshPlugin",
                        "Mesh Proxy service/characteristics missing; failing proxy connection"
                    )
                    this@MeshPlugin.isConnected = false
                    onConnectionFailed?.invoke()
                    disconnect().enqueue()
                    return
                }

                val char = proxyDataOut!!
                android.util.Log.d("MeshPlugin", "Enabling notifications on proxy data out")
                val onDataReceived = DataReceivedCallback { _, data ->
                    val bytes = data.value ?: byteArrayOf()
                    lastRxPduMs = android.os.SystemClock.elapsedRealtime()
                    val hexString = bytes.joinToString(" ") { "%02X".format(it) }
                    android.util.Log.d("MeshPlugin", "Received ${bytes.size} bytes from proxy: $hexString")

                    // Log PDU type for debugging
                    if (bytes.isNotEmpty()) {
                        when (bytes[0].toInt() and 0xFF) {
                            0x00 -> android.util.Log.i("MeshPlugin", "↓ Network PDU - should contain GenericOnOffStatus")
                            0x01 -> android.util.Log.d("MeshPlugin", "↓ Mesh beacon")
                            0x02 -> android.util.Log.d("MeshPlugin", "↓ Proxy configuration")
                            0x03 -> android.util.Log.d("MeshPlugin", "↓ Provisioning PDU")
                        }
                    }

                    // Nordic Mesh expects the negotiated ATT MTU.
                    meshManagerApi.handleNotifications(getGattMtu(), bytes)
                }
                setNotificationCallback(char).with(onDataReceived)

                beginAtomicRequestQueue()
                    .add(requestMtu(517))
                    .add(enableNotifications(char))
                    .done {
                        android.util.Log.d("MeshPlugin", "Proxy notifications enabled; connection ready")
                        this@MeshPlugin.isConnected = true
                        this@MeshPlugin.proxyFilterConfigured = false
                        this@MeshPlugin.lastProxyFilterAddresses = emptySet()
                        connectionReadySignaled = true
                        onConnectionReady?.invoke()
                    }
                    .fail { _, status ->
                        android.util.Log.e("MeshPlugin", "Failed to enable proxy notifications: $status")
                        this@MeshPlugin.isConnected = false
                        if (!connectionReadySignaled) onConnectionFailed?.invoke()
                    }
                    .enqueue()

                android.util.Log.d("MeshPlugin", "BleManager.initialize() completed")
            }
            
            override fun onDeviceReady() {
                super.onDeviceReady()
                android.util.Log.d("MeshPlugin", "BLE device ready")
            }
            
            override fun onDeviceDisconnected() {
                super.onDeviceDisconnected()
                android.util.Log.d("MeshPlugin", "BLE device disconnected")
                this@MeshPlugin.isConnected = false
                this@MeshPlugin.proxyFilterConfigured = false
                this@MeshPlugin.lastProxyFilterAddresses = emptySet()
                if (!connectionReadySignaled) onConnectionFailed?.invoke()
            }

            override fun onServicesInvalidated() {
                proxyDataIn = null
                proxyDataOut = null
                batteryLevelChar = null
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

        fun getGattMtu(): Int = mtu

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
