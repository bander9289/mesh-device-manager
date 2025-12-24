# MethodChannel Contract (Dart ⇄ Android)

This document defines the **authoritative contract** for the Flutter `MethodChannel` used by the Nordic BLE Mesh Manager app.

- Channel name: `mesh_plugin`
- Android implementation: `android/app/src/main/kotlin/com/nordicmesh/nordic_mesh_manager/MeshPlugin.kt`
- Dart client: `lib/managers/real_mesh_client.dart` (`PlatformMeshClient`)

## Conventions

### Types
- `int`: Dart `int` ⇄ Kotlin `Int`
- `bool`: Dart `bool` ⇄ Kotlin `Boolean`
- `String`: Dart `String` ⇄ Kotlin `String`
- `List<int>`: Dart `List<int>` values **0–255** ⇄ Kotlin `ByteArray`/`List<Int>`
- `Map<String, dynamic>`: JSON-like object

### MAC address normalization
- **Canonical form in payloads:** lowercase, colon-separated: `aa:bb:cc:dd:ee:ff`
- Dart normalizes incoming payload MACs by lowercasing and converting `-` → `:`.
- Android currently normalizes connection MACs as uppercase `AA:BB:...` internally. For arguments, any of the following are acceptable:
  - `aa:bb:cc:dd:ee:ff`
  - `AA:BB:CC:DD:EE:FF`
  - `aa-bb-cc-dd-ee-ff`

### Null vs empty
- `null` means “not supported / not implemented natively (yet)”
- Empty list/map means “supported, but no results”

### Errors
Android returns failures using `result.error(code, message, details)`.

Dart will observe these as `PlatformException(code: ..., message: ...)`.

If Android calls `result.notImplemented()` for a method, Dart will throw `MissingPluginException`.

## Methods (Dart → Android)

### `isAvailable`
- Args: none
- Returns: `bool`
  - `true` if the Android plugin is present and registered.
- Errors: none expected

### `initialize`
- Args: `Map` (all keys optional)
  - `netKey`: `String?` (hex string)
  - `appKey`: `String?` (hex string)
  - `ivIndex`: `int?` (**ignored by Android currently**)
- Returns: `bool`
  - `true` always on success.
- Errors:
  - `INIT_ERROR`

Notes:
- If both `netKey` and `appKey` are provided, Android currently delegates to `setMeshCredentials`.

### `setMeshCredentials`
- Args: `Map`
  - `netKey`: `String` (hex string) **OR** `networkKey`: `String` (hex string) (compat)
  - `appKey`: `String` (hex string)
- Returns: `bool` (`true` on success)
- Errors:
  - `MESH_SETUP_ERROR`

Side effects:
- Android replaces existing NetKey/AppKey at index 0 in the in-memory mesh network and ensures group `0xC000` (“Default”) exists.

### `ensureProxyConnection`
- Args: `Map`
  - `mac`: `String` (proxy candidate MAC)
  - `deviceUnicasts`: `List<int>?` (**accepted by Dart, currently ignored by Android**)
- Returns: `bool`
  - `true` if connected to a BLE device exposing Mesh Proxy service (0x1828)
  - `false` on failure
- Errors:
  - `PROXY_CONN_ERROR`

### `sendGroupMessage`
- Args: `Map`
  - `groupId`: `int` (defaults to `0xC000` on Android)
  - `macs`: `List<String>?` list of proxy candidates (required if not currently connected)
  - `on`: `bool?` (defaults to `true` on Android; **Dart currently does not pass this**)
- Returns: `bool`
  - `true` if the PDU is created and queued for send via the connected Mesh Proxy
- Errors:
  - `PROXY_CONNECTION_FAILED` (no proxy connection and candidate connection failed)
  - `SEND_ERROR`

### `triggerGroup`
- Args: `Map`
  - `groupAddress`: `int` (required)
  - `state`: `bool?` (defaults to `true`)
- Returns: `bool`
- Errors:
  - `TRIGGER_ERROR`

### `discoverGroupMembers`
- Args: `Map`
  - `groupAddress`: `int?` (defaults to `0xC000`)
  - `currentState`: `bool?` (defaults to `false`)
  - `deviceUnicasts`: `List<int>?` (**accepted by Dart, currently ignored by Android**)
- Returns: `bool`
  - `true` when the discovery message is queued
- Errors:
  - `NO_PROXY` (must already be connected)
  - `NO_APP_KEY` (no app key configured)
  - `DISCOVERY_ERROR`

### `sendUnicastMessage`
- Args: `Map`
  - `unicastAddress`: `int` (required)
  - `state`: `bool?` (defaults to `true`)
  - `proxyMac`: `String?` (optional; if provided, Android will attempt to connect)
- Returns: `bool`
- Errors:
  - `PROXY_CONNECTION_FAILED`
  - `NO_PROXY`
  - `NO_APP_KEY`
  - `UNICAST_ERROR`

### `getNodeSubscriptions`
- Args: none
- Returns: `List<Map>`
  - Each entry:
    - `unicastAddress`: `int`
    - `name`: `String` (may be empty)
    - `subscriptions`: `List<int>` (currently always empty)
- Errors:
  - `NODE_SUBSCRIPTIONS_ERROR`

### `connectToDevice` (currently unused by Dart)
- Args: `Map`
  - `address`: `String` (required; remote device address)
- Returns: `bool`
- Errors:
  - `CONNECTION_ERROR`

### `disconnectFromDevice` (currently unused by Dart)
- Args: none
- Returns: `bool`
- Errors:
  - `DISCONNECT_ERROR`

### `readBatteryLevel` (best-effort)
- Args: none
- Returns: `int?`
  - May be `null` because Android enqueues an async GATT read and returns before the callback runs.
- Errors:
  - `BATTERY_READ_ERROR`

### Stubbed / not-implemented-yet methods
These are handled by Android, but currently return a fixed stub value:

- `getLightStates`
  - Args: `{ macs: List<String> }`
  - Returns: `null`
- `getBatteryLevels`
  - Args: `{ macs: List<String> }`
  - Returns: `null`
- `subscribeToCharacteristics`
  - Args: `{ mac: String, uuids: List<String> }`
  - Returns: `false`
- `isDeviceConnected`
  - Args: `{ mac: String }`
  - Returns: `false`
- `disconnectDevice`
  - Args: `{ mac: String }`
  - Returns: `false`
- `discoverServices`
  - Args: `{ mac: String }`
  - Returns: `null`
- `readCharacteristic`
  - Args: `{ mac: String, uuid: String }`
  - Returns: `null`
- `writeCharacteristic`
  - Args: `{ mac: String, uuid: String, value: List<int>, withResponse: bool }`
  - Returns: `false`
- `setNotify`
  - Args: `{ mac: String, uuid: String, enabled: bool }`
  - Returns: `false`

### Dart-only methods (NOT implemented on Android)
These methods are invoked by Dart but are **not present** in Android’s `onMethodCall` switch today; Android returns `notImplemented()`, and Dart will throw `MissingPluginException`.

- `configureProxyFilter`
  - Dart args: `{ deviceUnicasts: List<int> }`
  - Intended return: `bool`
- `sendUnicastGet`
  - Dart args: `{ unicastAddress: int, proxyMac?: String }`
  - Intended return: `bool`

## Events / callbacks (Android → Dart)
Android sends these by calling `methodChannel.invokeMethod(name, payload)`.

### `onDeviceStatus` (implemented)
- Payload: `Map`
  - `unicastAddress`: `int`
  - `state`: `bool`
  - `targetState`: `bool?`
- Timing:
  - May arrive multiple times for the same device
  - Delivered on the Android main thread (posted via `Dispatchers.Main`)

### Reserved events (not emitted by Android today)
These event names are reserved for future platform work. Android does not emit them today.
As of 2025-12-24, Dart does not rely on them for core flows.

- `onMeshPduCreated` payload (Dart expectation): `{ macs: List<String>, groupId: int, fallback: bool }`
  - Decision: on Android, PDUs are sent directly via the mesh proxy manager, so this event is currently **unused**.
- `onCharacteristicNotification` payload (Dart expectation): `{ mac: String, uuid: String, value: List<int> }`
- `onBatteryLevel` payload (Dart expectation): `{ mac: String, battery: int }`
- `onSubscriptionReady` payload (Dart expectation): `{ mac: String }`
