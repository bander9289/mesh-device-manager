# Technical Specification
## Nordic BLE Mesh Manager

**Version:** 1.0  
**Date:** December 9, 2025  
**Author:** Engineering Team

---

## 1. Technical Overview

### 1.1 Architecture Summary
The Nordic BLE Mesh Manager is a cross-platform mobile application built with Flutter, targeting Android 15+ and iOS 16+. The application provides BLE Mesh device management, battery monitoring via BAS (Battery Service), and firmware updates using SMP (Simple Management Protocol) DFU.

### 1.2 Key Technical Components
1. **BLE Mesh Layer:** Device discovery, group management, and mesh messaging
2. **BLE Services Layer:** Battery Service (BAS) and SMP Service integration
3. **Firmware Management:** Version parsing, validation, and multi-device DFU
4. **UI Layer:** Flutter Material Design implementation with state management
5. **Platform Integration:** Native BLE permissions and capabilities

---

## 2. System Architecture

### 2.1 High-Level Architecture (UPDATED)

```
┌─────────────────────────────────────────────────────────┐
│                     Presentation Layer                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Devices View │  │ Updates View │  │ Common Widgets│ │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│                   Business Logic Layer                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ Device State │  │ Firmware Mgr │  │ Group Manager│  │
│  │   Manager    │  │              │  │              │  │
│  │              │  │              │  │              │  │
│  │ ┌──────────┐ │  │              │  │              │  │
│  │ │ Scan/    │ │  │              │  │              │  │
│  │ │ Connect  │ │  │              │  │              │  │
│  │ │ State    │ │  │              │  │              │  │
│  │ │ Machine  │ │  │              │  │              │  │
│  │ └──────────┘ │  │              │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│                    Service Layer                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  Mesh Proxy  │  │  BAS Client  │  │  SMP Client  │  │
│  │  Manager     │  │              │  │              │  │
│  │  + Proxy     │  │              │  │              │  │
│  │    Filter    │  │              │  │              │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│                   Platform Layer                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │flutter_blue_ │  │ file_picker  │  │ permission_  │  │
│  │    plus      │  │              │  │  handler     │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│                   Native Platform                       │
│  ┌──────────────┐              ┌──────────────┐        │
│  │   Android    │              │     iOS      │        │
│  │  BLE Stack   │              │  CoreBluetooth│       │
│  │  + Nordic    │              │  + Nordic    │        │
│  │    Mesh SDK  │              │    Mesh SDK  │        │
│  └──────────────┘              └──────────────┘        │
└─────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow

#### **NEW: Startup and Discovery Flow (Background Scanning Architecture)**

```
1. App Launch
   ↓
2. Initialize Nordic Mesh SDK with credentials
   ↓
3. Request BLE permissions
   ↓
4. Start CONTINUOUS BLE scanning
   - Filter: Service UUID 0x1828 (Mesh Proxy) AND name starts with "KMv"
   - Mode: Foreground scanning (background on iOS is limited)
   - Updates device list in real-time
   ↓
5. First Device Discovered → TRIGGER PROXY CONNECTION
   ↓
6. PAUSE scanning (BLE can't scan + connect simultaneously)
   ↓
7. Connect to first device as Mesh Proxy
   - Connect GATT
   - Discover Mesh Proxy Service (0x1828)
   - Enable notifications on Proxy Data Out (0x2ADE)
   - Configure Proxy Filter with ALL discovered device unicast addresses
   ↓
8. Send GenericOnOffGet to DEFAULT group (0xC000)
   - Wait for GenericOnOffStatus responses
   - Parse unicast addresses from status messages
   - Map unicast → MAC using MeshDevice.unicastAddress formula
   - Update device.groupId for responders
   ↓
9. DISCONNECT from proxy
   ↓
10. RESUME scanning to discover more devices
    ↓
11. User creates additional groups → store in SharedPreferences
    ↓
12. User triggers group → RECONNECT to proxy, send message, DISCONNECT
    ↓
13. Loop: Scan → Discover → Connect → Query → Disconnect → Scan
```

#### **Critical Proxy Filter Configuration (MISSING in current implementation)**

```kotlin
// After connecting to proxy, MUST configure proxy filter to forward messages
// for all known device unicast addresses:

fun configureProxyFilter(deviceUnicasts: List<Int>) {
    val filterSetup = ConfigProxyFilterSetup(
        filterType = ProxyFilterType.WHITELIST
    )
    meshManagerApi.sendConfigProxyFilterSetup(proxyNode, filterSetup)
    
    // Add each device unicast to the filter
    for (unicast in deviceUnicasts) {
        val addAddress = ConfigProxyFilterAddAddress(
            listOf(unicast)  // Add device to whitelist
        )
        meshManagerApi.sendConfigProxyFilterAddAddress(proxyNode, addAddress)
    }
}
```

**Why this is critical:**
- Without proxy filter configuration, the proxy forwards NOTHING except beacons
- Your log shows: "Received 23 bytes from proxy" → this is ONLY the beacon, no status messages
- GenericOnOffStatus messages are being sent by devices but proxy drops them
- Nordic SDK creates/sends the PDU correctly, but responses are filtered out

#### Device Discovery Flow (UPDATED)
```
1. App starts → Request permissions
2. Initialize BLE scanning (CONTINUOUS, foreground)
3. Filter advertisements by:
   a. Service UUID contains 0x1828 (Mesh Proxy)
   b. AND advertising name starts with "KMv"
   c. Parse name: "KMv<hardware_id>-major.minor.revision-hash"
4. For each matching advertisement:
   - Extract MAC address
   - Calculate unicast address from MAC (last 2 bytes)
   - Parse hardware ID and version from name
   - Extract battery level from manufacturer data (if present)
   - Add/update device in StateManager
5. Update UI device list in real-time
6. Devices remain in list while being advertised (no timeout)
7. REMOVED: Per-device connection for battery (use advertisement data instead)
8. REMOVED: Persistent device storage (always dynamic discovery)
```

**Advertisement Filtering Logic:**
```dart
bool _isKantmissDevice(ScanResult r) {
  // BOTH conditions must be met:
  // 1. Has Mesh Proxy Service
  final uuids = r.advertisementData.serviceUuids
    .map((u) => u.toString().toLowerCase());
  final hasMeshService = uuids.any((u) => 
    u.contains('1828') || u == '00001828-0000-1000-8000-00805f9b34fb'
  );
  
  // 2. Name starts with "KMv"
  final name = r.advertisementData.advName.isNotEmpty 
    ? r.advertisementData.advName 
    : r.device.platformName;
  final hasKmPrefix = name.toLowerCase().startsWith('kmv');
  
  return hasMeshService && hasKmPrefix;
}
```

#### Group Discovery Flow (NEW)
```
1. User opens app → scanning discovers devices
2. First device found → automatically trigger group discovery
3. PAUSE scanning
4. Connect to first device as mesh proxy:
   a. Connect GATT to device
   b. Discover Mesh Proxy Service (0x1828)
   c. Enable notifications on Proxy Data Out (0x2ADE)
   d. Configure Proxy Filter:
      - Set filter type: WHITELIST
      - Add ALL discovered device unicast addresses
      - This allows proxy to forward status messages
5. Send GenericOnOffGet to DEFAULT group (0xC000):
   - Opcode: 0x8201 (Generic OnOff Get)
   - Destination: 0xC000 (group address)
   - Expected response: GenericOnOffStatus from each group member
6. Wait 2-3 seconds for responses
7. Process GenericOnOffStatus messages:
   - Extract source unicast address from each status
   - Match unicast to device using unicastAddress calculation
   - Set device.groupId = 0xC000 for responders
   - Update UI to show group membership
8. DISCONNECT from proxy
9. RESUME scanning
10. UI now shows devices filtered by Default group
```

**Proxy Filter Configuration (CRITICAL):**
```kotlin
// In MeshPlugin.kt after proxy connection established:

private fun configureProxyFilterForDevices(devices: List<Int>) {
    val proxyNode = meshNetwork.nodes.firstOrNull { 
        it.bluetoothAddress == currentProxyMac 
    } ?: return
    
    // 1. Set filter type to WHITELIST
    val filterSetup = ConfigProxyFilterSetup(
        ProxyFilterType.WHITELIST_FILTER
    )
    meshManagerApi.createMeshPdu(proxyNode.unicastAddress, filterSetup)
    
    // 2. Add all device unicast addresses
    val addAddresses = ConfigProxyFilterAddAddress(devices)
    meshManagerApi.createMeshPdu(proxyNode.unicastAddress, addAddresses)
    
    Log.d(TAG, "Configured proxy filter for ${devices.size} devices")
}

// Call this after proxy connection in ensureProxyConnection():
override fun onDeviceReady(device: BluetoothDevice) {
    super.onDeviceReady(device)
    val deviceUnicasts = getKnownDeviceUnicasts() // from Dart
    configureProxyFilterForDevices(deviceUnicasts)
}
```

#### Group Trigger Flow (UPDATED)
```
1. User selects group and taps "Trigger All" button
2. PAUSE scanning (critical - can't scan while connected)
3. Connect to mesh proxy:
   a. Pick first device in group as proxy (prefer last used)
   b. Connect GATT
   c. Configure proxy filter with all device unicasts
4. Create GenericOnOffSet message:
   - Opcode: 0x8202 (Generic OnOff Set Acknowledged)
   - Destination: group address (e.g., 0xC000)
   - State: Toggle current state or set to ON
   - TID: Increment transaction counter
5. Send via Nordic SDK → meshManagerApi.createMeshPdu()
6. Nordic SDK encrypts and segments PDU
7. Write PDU to Proxy Data In characteristic (0x2ADD)
8. Proxy broadcasts to mesh network
9. Wait for GenericOnOffStatus responses:
   - Read from Proxy Data Out notifications (0x2ADE)
   - Nordic SDK decrypts and parses
   - Extract source unicast from each status
   - Confirm group membership
   - Update device.lightOn state
10. DISCONNECT from proxy (important - free BLE resources)
11. RESUME scanning
12. UI displays confirmation with count of responding devices
```

**Why Disconnect After Each Operation:**
- BLE stack cannot scan while maintaining connection on most platforms
- Frees resources for other operations
- Prevents stale connections
- Allows proxy device to be discovered by other apps
- Connection is fast (~1-2 seconds) so reconnecting is acceptable
```

#### Firmware Update Flow
```
1. User loads firmware file via file picker
2. Parse filename: <hw_id>-major.minor.revision-hash.signed.bin
3. Validate format and store in FirmwareManager
4. Compare device versions with loaded firmware
5. Identify devices needing updates
6. On "Update All" or individual update:
   a. Connect to device
   b. Establish SMP service connection
   c. Send firmware image in chunks (MTU-sized)
   d. Update progress indicator
   e. Device validates signature and applies update
   f. Device reboots
   g. Re-scan to verify new version
```

---

## 3. Module Specifications

### 3.1 Device State Manager

**Responsibilities:**
- Maintain list of discovered devices
- Track device properties (MAC, hardware ID, version, battery, RSSI)
- Manage device lifecycle (discovered, connected, disconnected)
- Provide filtered views (by group, update availability)

**Data Model:**
```dart
class MeshDevice {
  final String macAddress;          // Full MAC (e.g., "AB:CD:EF:12:34:56")
  final String identifier;           // Last 6 nibbles (e.g., "12:34:56")
  final String hardwareId;           // From advertising (e.g., "HW-0A3F")
  final FirmwareVersion version;     // Parsed version
  final int? groupId;                // Mesh group assignment (null = no group)
  final BatteryLevel batteryLevel;   // Green/Orange/Red + percentage
  final int rssi;                    // Signal strength in dBm
  final DateTime lastSeen;           // For stale device cleanup
  final bool isConnected;
  final String? connectionError;
  
  // Computed properties
  bool get needsUpdate;              // Compare with loaded firmware
  String get displayName;            // Formatted identifier
}

class FirmwareVersion {
  final int major;
  final int minor;
  final int revision;
  final String hash;                 // Short hash from filename
  
  // Comparison operators for version checking
  bool operator >(FirmwareVersion other);
  bool operator ==(FirmwareVersion other);
}

enum BatteryLevel {
  green(threshold: 50),   // >= 50%
  orange(threshold: 25),  // 25-49%
  red(threshold: 0);      // < 25%
  
  final int threshold;
}
```

**State Management:**
- Use `ChangeNotifier` with `Provider` pattern
- Expose streams for real-time updates
- Implement device timeout/cleanup (remove after 30s not seen)
- Periodic state polling: the manager polls `getLightStates` from the `MeshClient` every 5 seconds while scanning to detect per-device OnOff states and update the UI spinner indicator.

### 3.2 Mesh Client

**Responsibilities:**
- Manage BLE Mesh network connection
- Send/receive mesh messages
- Handle group addressing
- Manage mesh credentials

**Key Operations:**
```dart
class MeshClient {
  // Configuration
  static const meshNetworkKey = [...];  // 128-bit key (hardcoded)
  static const meshAppKey = [...];      // 128-bit key (hardcoded)
  static const meshIvIndex = 0x00000000;
  
  // Initialize mesh network
  Future<void> initialize();
  
  // Scan for mesh devices
  Stream<MeshDevice> scanForDevices();
  
  // Group operations
  Future<void> sendGenericOnOffSet({
    required int groupAddress,
    required bool onOff,
    int? transitionTime,
    int? delay,
  });
  
  // Device operations
  Future<void> setDeviceGroup({
    required String deviceAddress,
    required int groupId,
  });
  
  Future<int?> getDeviceGroup(String deviceAddress);
  
  // Cleanup
  Future<void> dispose();
}
```

**Mesh Message Format (Generic OnOff):**
```
Opcode: 0x8202 (Generic OnOff Set Unacknowledged)
Parameters:
  - OnOff: 1 byte (0x00 = off, 0x01 = on)
  - TID: 1 byte (transaction identifier)
  - Transition Time: 1 byte (optional)
  - Delay: 1 byte (optional)
  
Destination: Group address (0xC000 + group_id)
```

**Implementation Notes:**
- May require native platform channels if no Flutter BLE Mesh library exists
- Consider using Nordic's nRF Mesh library via platform channels
- Fallback: Use Generic Attribute Profile (GATT) proxy for mesh access
- Note: `sendGroupMessage` (implemented on `MeshClient`) supports an optional list of MAC addresses to target specific devices for single-device toggling; `DeviceManager` exposes a helper `triggerDevices(List<String> macs)` which uses this capability.

### 3.3 BAS (Battery Service) Client

**Responsibilities:**
- Read battery level from BLE devices
- Cache battery values
- Periodically refresh battery status

**Implementation:**
```dart
class BatteryServiceClient {
  // Standard BLE Battery Service UUID
  static const batteryServiceUUID = "0000180F-0000-1000-8000-00805F9B34FB";
  static const batteryLevelCharUUID = "00002A19-0000-1000-8000-00805F9B34FB";
  
  // Read battery level
  Future<int?> readBatteryLevel(String deviceAddress);
  
  // Subscribe to battery notifications (if supported)
  Stream<int> subscribeToBatteryUpdates(String deviceAddress);
  
  // Classify battery level
  BatteryLevel classifyBatteryLevel(int percentage) {
    if (percentage >= 50) return BatteryLevel.green;
    if (percentage >= 25) return BatteryLevel.orange;
    return BatteryLevel.red;
  }
}
```

**Battery Update Strategy:**
- Read battery on device discovery
- Refresh every 60 seconds for visible devices
- On-demand refresh when device details expanded

### 3.4 SMP (Simple Management Protocol) Client

**Responsibilities:**
- Establish SMP connection over BLE
- Upload firmware images
- Monitor update progress
- Handle update errors and retries

**Key Operations:**
```dart
class SMPClient {
  // Standard Nordic SMP Service UUID
  static const smpServiceUUID = "8D53DC1D-1DB7-4CD3-868B-8A527460AA84";
  static const smpCharUUID = "DA2E7828-FBCE-4E01-AE9E-261174997C48";
  
  // Connect and initialize SMP
  Future<void> connect(String deviceAddress);
  
  // Upload firmware
  Stream<UpdateProgress> uploadFirmware({
    required String deviceAddress,
    required Uint8List firmwareData,
  });
  
  // Reset device (post-update)
  Future<void> resetDevice(String deviceAddress);
  
  // Disconnect
  Future<void> disconnect();
}

class UpdateProgress {
  final int bytesTransferred;
  final int totalBytes;
  final UpdateStage stage;
  final String? error;
  
  double get percentage => (bytesTransferred / totalBytes) * 100;
}

enum UpdateStage {
  connecting,    // 0-10%
  uploading,     // 10-80%
  verifying,     // 80-95%
  rebooting,     // 95-100%
  complete,
  failed,
}
```

**SMP Protocol Details:**
- **Transport:** BLE GATT characteristic (write with response)
- **Packet size:** MTU - 3 bytes (typically 244 bytes)
- **Message format:** CBOR-encoded
- **Commands:**
  - Image Upload: Split firmware into chunks
  - Image State: Query current/pending images
  - Image Confirm: Confirm new image after test
  - Core Reset: Trigger device reboot

**Concurrency:**
- Use `StreamController` for per-device progress
- Limit concurrent uploads (recommend 10 simultaneous)
- Queue additional updates
- Implement retry logic (3 attempts with exponential backoff)

### 3.5 Firmware Manager

**Responsibilities:**
- Manage loaded firmware files
- Parse and validate firmware filenames
- Match firmware to devices
- Determine update availability

**Implementation:**
```dart
class FirmwareManager extends ChangeNotifier {
  final Map<String, FirmwareFile> _loadedFirmware = {};
  
  // Load firmware from file
  Future<void> loadFirmware(String filePath) async {
    final filename = path.basename(filePath);
    final parsed = _parseFilename(filename);
    
    if (parsed == null) {
      throw FirmwareFileException(
        'Invalid filename format. Expected: '
        '<hw_id>-major.minor.revision-hash.signed.bin'
      );
    }
    
    final data = await File(filePath).readAsBytes();
    _loadedFirmware[parsed.hardwareId] = FirmwareFile(
      hardwareId: parsed.hardwareId,
      version: parsed.version,
      filePath: filePath,
      data: data,
    );
    notifyListeners();
  }
  
  // Remove loaded firmware
  void removeFirmware(String hardwareId) {
    _loadedFirmware.remove(hardwareId);
    notifyListeners();
  }
  
  // Check if device needs update
  bool needsUpdate(MeshDevice device, {bool force = false}) {
    if (force) return true;
    
    final firmware = _loadedFirmware[device.hardwareId];
    if (firmware == null) return false;
    
    return firmware.version > device.version;
  }
  
  // Get firmware for device
  FirmwareFile? getFirmware(String hardwareId) {
    return _loadedFirmware[hardwareId];
  }
  
  // Parse filename
  _FilenameComponents? _parseFilename(String filename) {
    // Regex: <hw_id>-<major>.<minor>.<revision>-<hash>.signed.bin
    final regex = RegExp(
      r'^([A-Z0-9\-]+)-(\d+)\.(\d+)\.(\d+)-([a-f0-9]+)\.signed\.bin$',
      caseSensitive: false,
    );
    
    final match = regex.firstMatch(filename);
    if (match == null) return null;
    
    return _FilenameComponents(
      hardwareId: match.group(1)!,
      version: FirmwareVersion(
        major: int.parse(match.group(2)!),
        minor: int.parse(match.group(3)!),
        revision: int.parse(match.group(4)!),
        hash: match.group(5)!,
      ),
    );
  }
}

class FirmwareFile {
  final String hardwareId;
  final FirmwareVersion version;
  final String filePath;
  final Uint8List data;
  
  String get displayName => '$hardwareId v$version';
}
```

### 3.6 Group Manager

**Responsibilities:**
- Track discovered groups
- Manage group membership
- Send group-targeted messages

Note: The UI group dropdown defaults to the "Default" group (0xC000). An "Unknown" selection is provided (internal id -1) to show devices with no group assignment; filtering by a selected group only applies once the app has confirmed group membership (e.g., after triggering and observing device state changes).

**Implementation:**
```dart
class GroupManager extends ChangeNotifier {
  final MeshClient _meshClient;
  final Map<int, MeshGroup> _groups = {};
  
  // Discover groups from devices
  void updateFromDevices(List<MeshDevice> devices) {
    _groups.clear();
    for (final device in devices) {
      if (device.groupId != null) {
        _groups.putIfAbsent(
          device.groupId!,
          () => MeshGroup(id: device.groupId!, devices: []),
        ).devices.add(device);
      }
    }
    notifyListeners();
  }
  
  // Get all groups
  List<MeshGroup> get groups => _groups.values.toList();
  
  // Get devices in group
  List<MeshDevice> getDevicesInGroup(int groupId) {
    return _groups[groupId]?.devices ?? [];
  }
  
  // Trigger group
  Future<void> triggerGroup(int groupId) async {
    await _meshClient.sendGenericOnOffSet(
      groupAddress: 0xC000 + groupId,
      onOff: true,  // Toggle or specific state?
    );
  }
  
  // Move devices to new group
  Future<void> moveDevicesToGroup(
    List<MeshDevice> devices,
    int targetGroupId,
  ) async {
    for (final device in devices) {
      await _meshClient.setDeviceGroup(
        deviceAddress: device.macAddress,
        groupId: targetGroupId,
      );
    }
    notifyListeners();
  }
}

class MeshGroup {
  final int id;
  final List<MeshDevice> devices;
  
  String get name => 'Group $id';
  int get deviceCount => devices.length;
}
```

---

## 4. Platform Integration

### 4.1 Flutter Dependencies

```yaml
dependencies:
  flutter:
    sdk: flutter
  
  # BLE Communication
  flutter_blue_plus: ^1.31.0
  
  # State Management
  provider: ^6.1.1
  
  # File Access
  file_picker: ^6.1.1
  
  # Permissions
  permission_handler: ^11.1.0
  
  # Utilities
  path: ^1.8.3
  collection: ^1.18.0
  
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.1
  mockito: ^5.4.4
```

**Additional Libraries (if needed):**
- `nordic_nrf_mesh`: Nordic BLE Mesh library (check availability)
- `cbor`: CBOR encoding for SMP protocol
- `crypto`: Signature verification

### 4.2 Android Platform Configuration

**Minimum SDK Version:** 26 (Android 8.0)  
**Target SDK Version:** 34 (Android 14)  
**Compile SDK Version:** 34

**Permissions (AndroidManifest.xml):**
```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" 
                 android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

<uses-feature android:name="android.hardware.bluetooth_le" 
              android:required="true"/>
```

**Runtime Permission Handling:**
```dart
Future<bool> requestBluetoothPermissions() async {
  if (Platform.isAndroid) {
    final status = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    
    return status.values.every((s) => s.isGranted);
  }
  return true; // iOS handles in Info.plist
}
```

### 4.3 iOS Platform Configuration

**Minimum iOS Version:** 16.0  
**Target iOS Version:** Latest

**Permissions (Info.plist):**
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app needs Bluetooth to communicate with Nordic Mesh devices</string>

<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app needs Bluetooth to communicate with Nordic Mesh devices</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs location access for Bluetooth device scanning</string>
```

**Background Modes (if needed):**
```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

**Note:** iOS has limitations on background BLE scanning. App should primarily operate in foreground.

---

## 5. Data Persistence

### 5.1 Strategy
**No persistent storage** for device data (as per requirements). All data is ephemeral and discovery-based.

### 5.2 Session-Only Storage
- **Loaded firmware files:** Keep in memory during app session
- **Hardcoded credentials:** Embedded in code (consider obfuscation)
- **App preferences:** None required currently

### 5.3 Secure Storage (for credentials)
If credential obfuscation needed:
```dart
// Use flutter_secure_storage for encrypted storage
final storage = FlutterSecureStorage();

// Store (on first run or build time)
await storage.write(key: 'mesh_net_key', value: base64NetKey);
await storage.write(key: 'mesh_app_key', value: base64AppKey);

// Retrieve
final netKey = await storage.read(key: 'mesh_net_key');
final appKey = await storage.read(key: 'mesh_app_key');
```

**Recommendation:** Hardcode keys during build, use ProGuard/obfuscation tools.

---

## 6. Error Handling & Logging

### 6.1 Error Categories

1. **BLE Errors:**
   - Bluetooth disabled
   - Permissions denied
   - Device connection failed
   - Connection timeout
   - Characteristic read/write failed

2. **Mesh Errors:**
   - Message send failed
   - Group address invalid
   - Device not responding

3. **Firmware Errors:**
   - Invalid file format
   - Signature verification failed
   - Upload interrupted
   - Device rejected update
   - Timeout during update

4. **System Errors:**
   - File access denied
   - Out of memory
   - Network unreachable (future)

### 6.2 Error Handling Strategy

```dart
class AppException implements Exception {
  final String message;
  final String? details;
  final ErrorSeverity severity;
  
  AppException(this.message, {this.details, this.severity = ErrorSeverity.error});
}

enum ErrorSeverity {
  info,     // Informational, no action needed
  warning,  // Action recommended but not required
  error,    // Action required, operation failed
  critical, // App functionality compromised
}

// Custom exceptions
class BLEException extends AppException { ... }
class MeshException extends AppException { ... }
class FirmwareException extends AppException { ... }
```

**User-Facing Errors:**
- Display via `SnackBar` for non-critical
- Display via `Dialog` for critical/actionable
- Provide actionable next steps
- Use error messages from UX spec

### 6.3 Logging

```dart
import 'package:logger/logger.dart';

final logger = Logger(
  printer: PrettyPrinter(
    methodCount: 2,
    errorMethodCount: 8,
    lineLength: 120,
    colors: true,
    printEmojis: true,
    printTime: true,
  ),
);

// Usage
logger.d('Device discovered: $deviceId');
logger.i('Firmware upload started: $deviceId');
logger.w('Battery level low: $deviceId - $percentage%');
logger.e('Connection failed: $deviceId', error, stackTrace);
```

**Log Levels:**
- **Debug:** Detailed diagnostic information
- **Info:** General informational messages
- **Warning:** Potentially problematic situations
- **Error:** Error events that allow app to continue
- **Critical:** Severe errors requiring immediate attention

**Production Logging:**
- Disable debug logs in release builds
- Consider crash reporting (Firebase Crashlytics)
- Anonymize sensitive data (MAC addresses, etc.)

---

## 7. Performance Optimization

### 7.1 BLE Scanning Optimization

```dart
class OptimizedScanner {
  // Scan settings
  static const scanInterval = Duration(milliseconds: 100);
  static const scanWindow = Duration(milliseconds: 50);
  static const scanTimeout = Duration(seconds: 30);
  
  // Throttle device updates
  final _deviceUpdateThrottle = Duration(seconds: 1);
  final Map<String, DateTime> _lastUpdate = {};
  
  void onDeviceDiscovered(MeshDevice device) {
    final now = DateTime.now();
    final lastSeen = _lastUpdate[device.macAddress];
    
    if (lastSeen == null || 
        now.difference(lastSeen) > _deviceUpdateThrottle) {
      _updateDeviceList(device);
      _lastUpdate[device.macAddress] = now;
    }
  }
  
  // Cleanup stale devices
  void cleanupStaleDevices() {
    final now = DateTime.now();
    final staleThreshold = Duration(seconds: 30);
    
    _lastUpdate.removeWhere((address, lastSeen) =>
      now.difference(lastSeen) > staleThreshold
    );
  }
}
```

### 7.2 UI Optimization

**List Rendering:**
```dart
// Use ListView.builder for efficient rendering
ListView.builder(
  itemCount: devices.length,
  itemBuilder: (context, index) {
    final device = devices[index];
    return DeviceListTile(
      key: ValueKey(device.macAddress), // Stable key for efficient updates
      device: device,
    );
  },
);

// Implement shouldRebuild for custom widgets
@override
bool shouldRebuild(DeviceListTile oldWidget) {
  return oldWidget.device != device; // Compare device state
}
```

**State Management:**
```dart
// Use Selector for granular rebuilds
Selector<DeviceStateManager, List<MeshDevice>>(
  selector: (_, manager) => manager.devicesInSelectedGroup,
  builder: (_, devices, __) {
    return DeviceList(devices: devices);
  },
);
```

### 7.3 Memory Management

- Dispose resources properly (BLE connections, streams)
- Limit device history (no persistent storage)
- Stream firmware data in chunks (don't load entire file in memory)
- Use weak references for cached data

```dart
@override
void dispose() {
  _scanSubscription?.cancel();
  _meshClient.dispose();
  _smpClient.dispose();
  super.dispose();
}
```

---

## 8. Testing Strategy

### 8.1 Unit Tests

**Test Coverage Targets:**
- **Business Logic:** 80%+ coverage
- **Utilities:** 90%+ coverage
- **UI Widgets:** 60%+ coverage

**Key Test Areas:**
```dart
// Firmware version parsing
test('parse valid firmware filename', () {
  final version = FirmwareManager.parseFilename(
    'HW-0A3F-2.1.5-a3d9c.signed.bin'
  );
  expect(version.hardwareId, 'HW-0A3F');
  expect(version.major, 2);
  expect(version.minor, 1);
  expect(version.revision, 5);
  expect(version.hash, 'a3d9c');
});

// Version comparison
test('newer version detected', () {
  final current = FirmwareVersion(2, 1, 3, 'abc');
  final newer = FirmwareVersion(2, 1, 5, 'def');
  expect(newer > current, true);
});

// Battery classification
test('battery level classification', () {
  expect(BatteryServiceClient.classify(75), BatteryLevel.green);
  expect(BatteryServiceClient.classify(40), BatteryLevel.orange);
  expect(BatteryServiceClient.classify(15), BatteryLevel.red);
});
```

### 8.2 Integration Tests

**Test Scenarios:**
1. Device discovery and filtering
2. Group selection and triggering
3. Firmware loading and validation
4. Update progress tracking
5. Multi-device concurrent updates

**Mock BLE Devices:**
```dart
class MockBLEDevice {
  final String address;
  final String advertisingName;
  final int batteryLevel;
  final int groupId;
  
  // Simulate BLE characteristics
  Future<int> readBatteryLevel() async {
    await Future.delayed(Duration(milliseconds: 100));
    return batteryLevel;
  }
  
  // Simulate firmware update
  Stream<UpdateProgress> updateFirmware(Uint8List data) async* {
    for (int i = 0; i <= 100; i += 10) {
      await Future.delayed(Duration(milliseconds: 500));
      yield UpdateProgress(
        bytesTransferred: (data.length * i / 100).toInt(),
        totalBytes: data.length,
        stage: _getStage(i),
      );
    }
  }
}
```

### 8.3 Widget Tests

**Test Components:**
- Device list tile rendering
- Battery indicator colors
- Update badge visibility
- Group dropdown interaction
- Multi-select mode

```dart
testWidgets('device tile shows battery indicator', (tester) async {
  final device = MeshDevice(
    macAddress: '00:11:22:33:44:55',
    batteryLevel: BatteryLevel.green,
    // ... other properties
  );
  
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DeviceListTile(device: device),
      ),
    ),
  );
  
  expect(find.byIcon(Icons.battery_full), findsOneWidget);
  expect(find.text('11:22:33'), findsOneWidget);
});
```

### 8.4 Manual Testing

**Test Devices:**
- Real nRF52 hardware (preferred)
- Nordic DK boards with mesh firmware
- Mock BLE peripherals (if real hardware unavailable)

**Test Scenarios:**
1. **Discovery:** 10+ devices in range
2. **Battery:** Various battery levels (50%, 30%, 10%)
3. **Updates:** Serial and concurrent (1, 5, 10 devices)
4. **Error conditions:** Connection loss during update
5. **Edge cases:** No devices, no groups, invalid firmware

**Testing Checklist:**
- [ ] Permissions requested and handled correctly
- [ ] Continuous scanning without excessive battery drain
- [ ] Device list updates in real-time
- [ ] Group filtering works correctly
- [ ] Trigger all sends mesh message
- [ ] Battery levels display with correct colors
- [ ] Firmware filename validation
- [ ] Update progress accurate
- [ ] Multiple concurrent updates complete successfully
- [ ] Group membership changes persist
- [ ] Multi-select mode functions properly
- [ ] Error messages clear and actionable

---

## 9. Security Considerations

### 9.1 Mesh Credentials

**Storage:**
- Hardcode credentials in Dart code
- Use code obfuscation (ProGuard for Android, Bitcode for iOS)
- Consider encrypting credentials at rest (flutter_secure_storage)

**Access Control:**
- No UI for viewing/editing credentials
- No export functionality
- No logging of credential values

### 9.2 Firmware Security

**Signature Verification:**
```dart
class FirmwareValidator {
  // Verify firmware signature
  Future<bool> verifySignature(Uint8List firmwareData) async {
    // Extract signature from firmware file
    final signature = _extractSignature(firmwareData);
    final payload = _extractPayload(firmwareData);
    
    // Verify using Nordic's public key
    final publicKey = _nordicPublicKey;
    final isValid = await _verifySHA256RSA(
      payload: payload,
      signature: signature,
      publicKey: publicKey,
    );
    
    return isValid;
  }
}
```

**File Validation:**
- Verify filename format before parsing
- Check file size (reasonable limits: 100KB - 1MB)
- Validate file extension (.signed.bin)
- Verify signature before uploading to device

### 9.3 Communication Security

**BLE Security:**
- Use BLE pairing/bonding if required by device
- Validate device identity (check service UUIDs)
- Timeout connections after inactivity

**Mesh Security:**
- Use network and app keys for message encryption
- Validate message authenticity
- Implement replay protection (transaction IDs)

### 9.4 Data Privacy

**No Personal Data:**
- No user accounts
- No cloud synchronization
- No analytics (or anonymized only)

**Device Identifiers:**
- Display only last 6 MAC nibbles (not full address in UI)
- Don't log full MAC addresses in production
- Anonymize crash reports

---

## 10. Build & Deployment

### 10.1 Build Configuration

**Debug Build:**
```bash
flutter build apk --debug
flutter build ios --debug
```

**Release Build:**
```bash
flutter build apk --release --obfuscate --split-debug-info=./debug-info
flutter build ios --release --obfuscate --split-debug-info=./debug-info
```

**Build Variants:**
- **Debug:** Logging enabled, no obfuscation
- **Profile:** Performance profiling enabled
- **Release:** Optimized, obfuscated, logging minimal

### 10.2 Code Signing

**Android:**
```properties
# android/key.properties
storePassword=<password>
keyPassword=<password>
keyAlias=<alias>
storeFile=<path-to-keystore>
```

**iOS:**
- Configure in Xcode
- Use Apple Developer account provisioning profiles
- Distribution certificate for App Store

### 10.3 Versioning

**Format:** `major.minor.patch+build`

Example: `1.0.0+1`

**Update Strategy:**
- **Major:** Breaking changes, major feature additions
- **Minor:** New features, non-breaking changes
- **Patch:** Bug fixes, minor improvements
- **Build:** Increment on each build

### 10.4 Distribution

**Android:**
- **Internal testing:** Google Play Internal Testing
- **Beta:** Google Play Beta track
- **Production:** Google Play Production track
- **Alternative:** Direct APK distribution (if not Play Store)

**iOS:**
- **Internal testing:** TestFlight internal testers
- **Beta:** TestFlight external testers
- **Production:** App Store release

---

## 11. Development Roadmap

### 11.1 Phase 1: Core Functionality (MVP)
**Duration:** 4-6 weeks

**Deliverables:**
- [ ] BLE scanning and device discovery
- [ ] Device list with battery indicators
- [ ] Group filtering (basic)
- [ ] Trigger all functionality
- [ ] Basic firmware loading and version comparison
- [ ] Single device firmware update

**Milestones:**
- Week 2: Device discovery working
- Week 4: Group triggering operational
- Week 6: Single device firmware update complete

### 11.2 Phase 2: Advanced Features
**Duration:** 3-4 weeks

**Deliverables:**
- [ ] Multi-device concurrent firmware updates
- [ ] Group membership changes (long-press multi-select)
- [ ] Enhanced error handling and retry logic
- [ ] Update progress indicators
- [ ] Force update option

**Milestones:**
- Week 2: Multi-device updates working
- Week 4: Group management complete

### 11.3 Phase 3: Polish & Optimization
**Duration:** 2-3 weeks

**Deliverables:**
- [ ] UI/UX refinements
- [ ] Performance optimization
- [ ] Comprehensive testing
- [ ] Documentation
- [ ] Bug fixes

**Milestones:**
- Week 2: All tests passing
- Week 3: Ready for beta release

### 11.4 Future Enhancements (Post-MVP)

**Short-term:**
- LED identification implementation
- Debug terminal (SMP console)
- Device detail expansion with more info

**Medium-term:**
- Search/filter devices
- Sort by battery, signal, etc.
- Device activity log
- Batch operations improvements

**Long-term:**
- Mesh network visualization
- Advanced diagnostics
- Cloud integration (if needed)
- Multi-mesh network support

---

## 12. Known Limitations & Risks

### 12.1 Technical Limitations

1. **BLE Mesh Library Availability:**
   - **Risk:** Limited Flutter libraries for Nordic BLE Mesh
   - **Mitigation:** Use platform channels to native Nordic SDK
   - **Alternative:** Implement mesh over GATT proxy

2. **iOS Background Limitations:**
   - **Risk:** iOS restricts background BLE scanning
   - **Mitigation:** Document requirement for foreground operation
   - **Impact:** User must keep app open during operations

3. **Concurrent Update Limits:**
   - **Risk:** Too many concurrent BLE connections may fail
   - **Mitigation:** Implement queue with max 10 concurrent
   - **Testing:** Validate with real hardware

4. **Mesh Reliability:**
   - **Risk:** Mesh message delivery not guaranteed
   - **Mitigation:** Implement retry logic, user feedback
   - **Testing:** Test in noisy RF environments

### 12.2 Operational Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Device firmware incompatible with SMP | Medium | High | Document compatible firmware versions |
| BLE range limitations | High | Medium | User education, signal strength indicator |
| Battery drain from continuous scanning | Medium | Medium | Optimize scan parameters, monitor usage |
| Concurrent update failures | Medium | High | Implement robust retry and queue logic |
| Mesh network congestion | Low | Medium | Rate limiting, back-off strategy |

### 12.3 Development Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Platform channel complexity | Medium | High | Early prototype, allocate extra time |
| Nordic SDK integration issues | High | High | Evaluate alternatives (GATT proxy) |
| Limited testing hardware | Medium | Medium | Partner with Nordic for dev kits |
| Bluetooth permission changes (OS updates) | Low | Medium | Monitor platform updates, test betas |

---

## 13. Dependencies & Third-Party Libraries

### 13.1 Critical Dependencies

| Library | Version | Purpose | License | Risk |
|---------|---------|---------|---------|------|
| flutter_blue_plus | 1.31.0 | BLE communication | BSD-3 | Low - actively maintained |
| provider | 6.1.1 | State management | MIT | Low - stable |
| file_picker | 6.1.1 | Firmware file selection | MIT | Low - stable |
| permission_handler | 11.1.0 | Runtime permissions | MIT | Low - stable |

### 13.2 Potential Additional Libraries

| Library | Purpose | Status |
|---------|---------|--------|
| nordic_nrf_mesh | BLE Mesh protocol | Evaluate availability |
| cbor | SMP message encoding | Required if no SMP lib |
| crypto | Signature verification | May be needed |
| logger | Enhanced logging | Optional |

### 13.3 Platform Channels (if needed)

**Android:**
```kotlin
// Platform channel for Nordic Mesh SDK
class MeshPlugin : FlutterPlugin, MethodCallHandler {
  override fun onMethodCall(call: MethodCall, result: Result) {
    when (call.method) {
      "sendMeshMessage" -> sendMeshMessage(call, result)
      "setDeviceGroup" -> setDeviceGroup(call, result)
      // ...
    }
  }
}
```

**iOS:**
```swift
// Platform channel for Nordic Mesh SDK
@objc class MeshPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "mesh_plugin", 
                                       binaryMessenger: registrar.messenger())
    let instance = MeshPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }
  
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Implement mesh operations
  }
}
```

---

## 14. Maintenance & Support

### 14.1 Monitoring

**Key Metrics:**
- App crash rate
- BLE connection success rate
- Firmware update success rate
- Average update duration
- User engagement (sessions, duration)

**Monitoring Tools:**
- Firebase Crashlytics (crash reporting)
- Firebase Analytics (usage metrics)
- Custom logging for BLE operations

### 14.2 Update Strategy

**Regular Updates:**
- Bug fixes: As needed
- Security patches: Immediate
- Feature updates: Quarterly
- Dependency updates: Monthly review

**Compatibility:**
- Support current and previous major Android/iOS versions
- Deprecated features: 6-month notice

### 14.3 User Support

**Documentation:**
- In-app help (future)
- User manual / quick start guide
- FAQ for common issues
- Troubleshooting guide

**Support Channels:**
- GitHub issues (if open source)
- Email support
- Knowledge base / wiki

---

## 15. Glossary

| Term | Definition |
|------|------------|
| **BLE** | Bluetooth Low Energy |
| **BAS** | Battery Service - standard BLE service for battery level |
| **SMP** | Simple Management Protocol - Nordic's firmware update protocol |
| **DFU** | Device Firmware Update |
| **MAC** | Media Access Control address - unique device identifier |
| **GATT** | Generic Attribute Profile - BLE data structure |
| **MTU** | Maximum Transmission Unit - max BLE packet size |
| **RSSI** | Received Signal Strength Indicator |
| **Mesh** | Network topology allowing many-to-many communication |
| **Group Address** | Mesh address targeting multiple devices |
| **Provisioning** | Process of adding a device to a mesh network |
| **App Key** | Cryptographic key for application-level mesh messages |
| **Network Key** | Cryptographic key for network-level mesh encryption |
| **IV Index** | Initialization Vector index for mesh encryption |

---

## 16. References

### 16.1 Technical Documentation

- [Nordic nRF52 Series Documentation](https://infocenter.nordicsemi.com/topic/struct_nrf52/struct/nrf52.html)
- [Bluetooth Mesh Specification](https://www.bluetooth.com/specifications/mesh-specifications/)
- [Nordic Mesh SDK](https://www.nordicsemi.com/Products/Development-software/nrf5-sdk-for-mesh)
- [SMP Protocol Specification](https://github.com/apache/mynewt-mcumgr)
- [Battery Service Specification](https://www.bluetooth.com/specifications/specs/battery-service-1-0/)

### 16.2 Flutter Resources

- [Flutter Documentation](https://flutter.dev/docs)
- [flutter_blue_plus Documentation](https://pub.dev/packages/flutter_blue_plus)
- [Provider Package](https://pub.dev/packages/provider)
- [Platform Channels Guide](https://flutter.dev/docs/development/platform-integration/platform-channels)

### 16.3 Development Tools

- [Android Studio](https://developer.android.com/studio)
- [Xcode](https://developer.apple.com/xcode/)
- [nRF Connect for Mobile](https://www.nordicsemi.com/Products/Development-tools/nrf-connect-for-mobile) - BLE debugging

---

## 17. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-09 | Engineering Team | Initial technical specification |

---

**End of Technical Specification**
