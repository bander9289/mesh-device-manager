# Nordic BLE Mesh Manager - Copilot Instructions

## Project Overview
Mobile application for managing Nordic nRF52 BLE Mesh devices with group management, battery monitoring (BAS), and firmware updates via SMP DFU.

## Technology Stack
- **Framework**: Flutter for cross-platform (Android/iOS)
- **Target Platforms**: Android 15+, iOS 16+
- **BLE Mesh**: Nordic Bluetooth Mesh
- **Target Hardware**: nRF52 series devices

## Key Features
1. BLE Mesh group management with app key
2. Battery level monitoring (BAS)
3. SMP DFU firmware updates
4. Device discovery and filtering
5. Group-based device triggering

## Development Guidelines
- Follow Flutter best practices and material design
- Ensure cross-platform compatibility
- Keep business logic separate from UI
- Use proper error handling for BLE operations
- Follow security best practices for mesh credentials

## File Naming Conventions
- Firmware files: `<hardware_id>-major.minor.revision-hash.signed.bin`
- Device advertising: `<hardware_id>-major.minor.revision-hash`

## Testing Requirements
- Test on Android 15+ devices
- Test on recent iOS devices
- Verify BLE mesh operations
- Test firmware update flows
