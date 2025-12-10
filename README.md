# Nordic BLE Mesh Manager

A cross-platform mobile application for managing Nordic nRF52-based BLE Mesh devices with group management, battery monitoring, and firmware updates.

![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS-blue)
![Android](https://img.shields.io/badge/Android-15%2B-green)
![iOS](https://img.shields.io/badge/iOS-16%2B-lightgrey)
![Flutter](https://img.shields.io/badge/Flutter-3.2%2B-02569B?logo=flutter)

---

## 📋 Overview

Nordic BLE Mesh Manager provides field technicians and administrators with an efficient tool for managing fleets of Nordic mesh-enabled devices. The app supports:

- **Device Discovery:** Continuous BLE scanning for provisioned mesh devices
- **Group Management:** Filter devices by mesh group and change group membership
- **Battery Monitoring:** Real-time battery level indicators using BLE Battery Service
- **Firmware Updates:** Multi-device concurrent firmware updates via SMP DFU
- **Group Triggering:** Send mesh commands to all devices in a group

---

## ✨ Key Features

### Device Management
- Continuous device discovery with real-time updates
- Display devices organized by mesh group
- Show device identifier (last 6 MAC nibbles)
- Battery level indicators (green/orange/red)
- Signal strength monitoring (RSSI)

### Group Operations
- Filter devices by mesh group (groups are created by the user and start empty)
- Trigger all devices in selected group (Nordic Mesh Light model)
- Multi-select devices to move between groups or create a new one
- Create Default group: the first created group uses address 0xC000 and is labeled "Default"

### Firmware Updates
- Load multiple firmware files for different hardware versions
- Automatic version comparison and update detection
- Concurrent multi-device updates (10+ simultaneous)
- Real-time progress tracking per device
- Force update option

---

## 🏗️ Architecture

### Technology Stack
- **Framework:** Flutter 3.2+
- **State Management:** Provider
- **BLE Communication:** flutter_blue_plus
- **Target Hardware:** Nordic nRF52 series
- **Protocols:** BLE Mesh, BAS (Battery Service), SMP DFU

### Project Structure
```
lib/
├── main.dart                 # App entry point
├── models/                   # Data models
│   ├── mesh_device.dart
│   ├── firmware_version.dart
│   └── mesh_group.dart
├── services/                 # Business logic
│   ├── mesh_client.dart      # BLE Mesh operations
│   ├── battery_service.dart  # Battery level reading
│   ├── smp_client.dart       # Firmware update (SMP DFU)
│   └── ble_scanner.dart      # Device discovery
├── managers/                 # State management
│   ├── device_manager.dart   # Device state
│   ├── firmware_manager.dart # Firmware handling
│   └── group_manager.dart    # Group operations
├── screens/                  # UI screens
│   ├── devices_screen.dart   # Main device list
│   └── updates_screen.dart   # Firmware updates
└── widgets/                  # Reusable UI components
    ├── device_list_tile.dart
    ├── battery_indicator.dart
    └── firmware_card.dart
```

---

## 🚀 Getting Started

### Prerequisites

1. **Flutter SDK:** Version 3.2.0 or higher
   ```bash
   flutter --version
   ```

2. **Development Tools:**
   - **Android:** Android Studio with Android SDK (API 26+)
   - **iOS:** Xcode 14+ (macOS only)

3. **Hardware Requirements:**
   - Nordic nRF52 development boards or devices with mesh firmware
   - Android 15+ device or iOS 16+ device for testing

### Installation

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd phone-manager-app
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Configure mesh credentials:**
   Edit hardcoded mesh credentials in `lib/managers/device_manager.dart`:
   ```dart
   // Replace values in DeviceManager constructor: setMeshCredentials()
   await deviceManager.setMeshCredentials({'netKey': '<your network key>', 'appKey': '<your app key>'});
   ```


4. **Run the app:**
   ```bash
   # Android
   flutter run -d android
   
   # iOS
   flutter run -d ios
   ```

---

## 📱 Platform Configuration

### Android Setup

**Minimum Requirements:**
- Min SDK: 26 (Android 8.0)
- Target SDK: 34 (Android 14)

**Permissions:**
The app requires Bluetooth and location permissions. These are requested at runtime.

**Build:**
```bash
flutter build apk --release
# or
flutter build appbundle --release
```

### iOS Setup

**Minimum Requirements:**
- iOS 16.0+
- Xcode 14+

**Configuration:**
Bluetooth and location usage descriptions are already configured in `Info.plist`.

**Build:**
```bash
flutter build ios --release
```

Open `ios/Runner.xcworkspace` in Xcode to configure signing and deployment.

---

## 🔧 Configuration

### Mesh Network Credentials

Mesh credentials must be hardcoded in the application. Update these values in `lib/services/mesh_client.dart`:

```dart
class MeshClient {
  // Network Key (128-bit)
  static const meshNetworkKey = [
    0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
    0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10,
  ];
  
  // App Key (128-bit)
  static const meshAppKey = [
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
  ];
  
  // IV Index
  static const meshIvIndex = 0x00000000;
}
```

⚠️ **Security Note:** Consider using code obfuscation for release builds to protect credentials.

### Battery Level Thresholds

Battery indicator thresholds can be adjusted in `lib/models/mesh_device.dart`:

```dart
enum BatteryLevel {
  green(threshold: 50),   // >= 50%
  orange(threshold: 25),  // 25-49%
  red(threshold: 0);      // < 25%
}
```

---

## 📝 Usage

### Device Discovery

1. Launch the app
2. Grant Bluetooth and location permissions when prompted
3. Devices automatically appear as they're discovered
4. Select a group from the dropdown to filter devices (note: device masking by selected group only applies after the app has confirmed group membership by triggering and observing device changes; the 'Unknown' option shows devices without a group assignment immediately)

### Triggering Devices

1. Select a group from the dropdown
2. Tap "Trigger All" button
3. Confirm the action
4. All devices in the group receive the mesh command

### Firmware Updates

1. Switch to the "Updates" tab
2. Tap "Load Firmware File"
3. Select a firmware file with format: `<hw_id>-major.minor.revision-hash.signed.bin`
4. Devices requiring updates appear in the list
5. Tap "Update All" or select individual devices (long-press for multi-select)
6. Monitor progress for each device

### Group Management

1. Long-press a device in the Devices tab to enter multi-select mode
2. Select one or more devices
3. Use the "Create Group" button to create a new group (first group is Default with address 0xC000) or choose a target group from the dropdown (now shows "Move to ▾")
4. Confirm the group change

---

## 🧪 Testing

### Run Unit Tests
```bash
flutter test
```

### Run Integration Tests
```bash
flutter test integration_test/
```

### Manual Testing

**Required Hardware:**
- Multiple Nordic nRF52 devices with mesh firmware
- Devices configured in different mesh groups
- Devices with varying battery levels

**Test Scenarios:**
1. Device discovery with 10+ devices in range
2. Group filtering and triggering
3. Battery level display accuracy
4. Single device firmware update
5. Multi-device concurrent updates (5-10 devices)
6. Group membership changes
7. Error handling (connection loss, invalid firmware)

---

## 📚 Documentation

- **[PRD.md](PRD.md)** - Product Requirements Document
- **[UX.md](UX.md)** - User Experience Specification
- **[TECHNICAL.md](TECHNICAL.md)** - Technical Architecture and Implementation Details

---

## 🔐 Security

### Mesh Credentials
- Mesh network and app keys are hardcoded
- Use code obfuscation for release builds
- No credential export functionality
- Credentials not displayed in UI or logs

### Firmware Updates
- Firmware files must be signed (`.signed.bin` extension)
- Signature verification performed before upload
- Only Nordic-signed firmware accepted

### Permissions
- Minimal permissions requested
- Runtime permission handling with clear explanations
- No data collection or analytics

---

## 🐛 Troubleshooting

### Bluetooth Permission Denied
**Symptom:** No devices discovered  
**Solution:** Grant Bluetooth and location permissions in device settings

### Devices Not Appearing
**Symptom:** Empty device list  
**Solution:**
- Ensure devices are powered on and in range
- Verify devices are already provisioned (unprovisioned devices not shown)
- Check Bluetooth is enabled

### Firmware Update Failed
**Symptom:** Update progress stops or shows error  
**Solution:**
- Verify firmware file format matches: `<hw_id>-major.minor.revision-hash.signed.bin`
- Check device connection (move closer)
- Ensure device has sufficient battery
- Try updating one device at a time

### Group Trigger Not Working
**Symptom:** Devices don't respond to trigger command  
**Solution:**
- Verify devices are in the selected group
- Check mesh network credentials are correct
- Ensure devices are in range

---

## 🛣️ Roadmap

### Phase 1: Core Functionality (Current)
- [x] Device discovery and listing
- [x] Battery monitoring
- [x] Group filtering
- [x] Group triggering
- [x] Firmware updates

### Phase 2: Enhanced Features (Planned)
- [ ] LED identification (device-specific)
- [ ] Debug terminal via SMP
- [ ] Device search and filtering
- [ ] Update history logging

### Phase 3: Advanced Features (Future)
- [ ] Mesh network visualization
- [ ] Advanced diagnostics
- [ ] Device activity logs
- [ ] Custom mesh message types

---

## 📄 License

[Specify your license here]

---

## 🤝 Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📧 Support

For issues, questions, or suggestions:
- Open an issue on GitHub
- Contact: [your-email@example.com]

---

## 🙏 Acknowledgments

- **Nordic Semiconductor** for nRF52 series and mesh technology
- **Flutter team** for the excellent cross-platform framework
- **flutter_blue_plus** maintainers for BLE support

---

## 📊 Project Status

**Current Version:** 1.0.0  
**Status:** In Development  
**Last Updated:** December 9, 2025

---

**Built with ❤️ using Flutter**
