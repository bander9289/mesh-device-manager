# Product Requirements Document (PRD)
## Nordic BLE Mesh Manager

**Version:** 1.0  
**Date:** December 9, 2025  
**Author:** System Architecture Team

---

## 1. Executive Summary

Nordic BLE Mesh Manager is a cross-platform mobile application designed to manage Nordic nRF52-based BLE Mesh devices. The application enables group-based device management, battery monitoring, and firmware updates through a streamlined interface optimized for field operations.

### 1.1 Product Vision
Provide field technicians and administrators with a reliable, efficient tool for managing fleets of Nordic mesh-enabled devices without requiring extensive technical knowledge or complex provisioning workflows.

### 1.2 Success Metrics
- Successful group-based triggering of devices (>99% reliability)
- Firmware update completion rate (>95% success rate)
- Battery monitoring accuracy (within 5% of actual values)
- Multi-device firmware updates (support 10+ concurrent updates)

---

## 2. Product Overview

### 2.1 Target Users
- **Primary:** Field technicians managing installed mesh networks
- **Secondary:** System administrators monitoring device health
- **Tertiary:** Installation teams verifying device functionality

### 2.2 Target Devices
- **Hardware:** Nordic nRF52 series chipsets
- **State:** Pre-provisioned mesh nodes (provisioning not in scope)
- **Capabilities:** BLE Mesh Light model, Battery Service (BAS), SMP DFU

### 2.3 Target Platforms
- **Android:** Version 15 and above
- **iOS:** Version 16 and above

---

## 3. Core Features

### 3.1 Device Discovery and Filtering
**Priority:** P0 (Must Have)

#### Requirements
- **FR-3.1.1:** Continuous BLE scanning while app is in foreground (iOS background limitations)
- **FR-3.1.2:** Filter devices by BOTH conditions:
  - Has Mesh Proxy Service (UUID 0x1828)
  - AND advertising name starts with "KMv"
- **FR-3.1.3:** Parse device advertising format: `KMv<hardware_id>-major.minor.revision-hash`
- **FR-3.1.4:** Extract battery level from manufacturer data in advertisements
- **FR-3.1.5:** Calculate device unicast address from MAC (last 2 bytes)
- **FR-3.1.6:** Display device identifier using last 6 MAC address nibbles
- **FR-3.1.7:** No persistent device storage (dynamic discovery only)
- **FR-3.1.8:** Pause scanning when connecting to mesh proxy (BLE resource management)

#### Non-Requirements
- Provisioning of new devices
- Displaying unprovisioned devices
- Managing non-Kantmiss mesh devices
- Historical device tracking
- Background scanning on iOS

### 3.2 Group Management
**Priority:** P0 (Must Have)

#### Requirements
- **FR-3.2.1:** Automatic group discovery on app startup:
  - On first device discovered, send GenericOnOffGet to Default group (0xC000)
  - Parse GenericOnOffStatus responses to identify group members
  - Auto-populate device.groupId for responders
- **FR-3.2.2:** Display dropdown selector showing discovered mesh groups; include an "Unknown" entry to list devices with no group assignment and default to the Default group (0xC000)
- **FR-3.2.3:** Filter device list by selected group immediately after group discovery completes
- **FR-3.2.4:** Support long-press multi-select for device group changes
- **FR-3.2.5:** Transform group selector to "Move to [Group]" when devices selected
- **FR-3.2.6:** Require confirmation before moving devices to new group
- **FR-3.2.7:** Use hardcoded app key for group operations (not user-configurable)
- **FR-3.2.8:** Single mesh network support (differentiated by group ID only)
- **FR-3.2.9:** Persistent storage of user-created groups (future enhancement)

#### Mesh Credentials
The following credentials must be hardcoded in the application:
- App Key (128-bit)
- Network Key (128-bit)
- IV Index
- Unicast address range or allocation strategy

### 3.3 Group Triggering
**Priority:** P0 (Must Have)

#### Requirements
- **FR-3.3.1:** "Trigger All" button visible when group selected
- **FR-3.3.2:** Dynamic proxy connection lifecycle:
  - Pause scanning
  - Connect to first device in group as proxy
  - Configure proxy filter with all device unicast addresses
  - Send GenericOnOffSet group message
  - Wait for GenericOnOffStatus responses
  - Disconnect from proxy
  - Resume scanning
- **FR-3.3.3:** Target all devices in currently selected group
- **FR-3.3.4:** Display count of responding devices (confirmed triggers)
- **FR-3.3.5:** Provide visual feedback on trigger action (scanning paused, connecting, messaging)
- **FR-3.3.6:** Handle trigger failures gracefully with user notification
- **FR-3.3.7:** Trigger timeout: 3 seconds for status responses

### 3.4 Battery Monitoring
**Priority:** P0 (Must Have)

#### Requirements
- **FR-3.4.1:** Display battery level using BAS (Battery Service)
- **FR-3.4.2:** Visual indicator with three states:
  - **Green:** ≥50% battery
  - **Orange:** 25-49% battery
  - **Red:** <25% battery
- **FR-3.4.3:** Update battery level during continuous scanning
- **FR-3.4.4:** Display battery indicator on each device list entry

### 3.5 Firmware Update Management
**Priority:** P0 (Must Have)

#### Requirements
- **FR-3.5.1:** Dedicated "Updates" tab in tabbed interface
- **FR-3.5.2:** Support loading multiple firmware files for different hardware IDs
- **FR-3.5.3:** Firmware file format: `<hardware_id>-major.minor.revision-hash.signed.bin`
- **FR-3.5.4:** Parse and validate firmware filename format on load
- **FR-3.5.5:** Display helpful error if filename doesn't match expected format
- **FR-3.5.6:** Compare device version with loaded firmware (major.minor.revision-hash)
- **FR-3.5.7:** Automatically identify devices requiring updates
- **FR-3.5.8:** Display "update available" indicator on devices tab
- **FR-3.5.9:** Support multi-device concurrent firmware updates (10+ devices)
- **FR-3.5.10:** Long-press multi-select for choosing specific devices to update
- **FR-3.5.11:** "Update All" button for batch firmware updates
- **FR-3.5.12:** Force update option (bypass version comparison)
- **FR-3.5.13:** Per-device progress indicator during updates
- **FR-3.5.14:** Automatic device reboot after successful update
- **FR-3.5.15:** Display updated version after device reboots and re-advertises
- **FR-3.5.16:** Use SMP (Simple Management Protocol) for DFU operations

### 3.6 Device Detail Menu
**Priority:** P1 (Should Have)

#### Requirements
- **FR-3.6.1:** Dropdown/expandable menu on each device entry
- **FR-3.6.2:** Display detailed device information
- **FR-3.6.3:** LED identification button (functionality TBD)
- **FR-3.6.4:** Debug terminal access via SMP (implementation TBD)
- **FR-3.6.5:** Additional utilities (specify as needed)

---

## 4. User Interface Structure

### 4.1 Main Screen (Devices Tab)
- **Top Section:**
  - Group selector dropdown (defaults to "Default" 0xC000, includes an "Unknown" option to show devices without group assignments)
  - "Trigger All" button (when a valid group is selected)
- **Device List:**
  - Device identifier (last 6 MAC nibbles)
  - Battery indicator (green/orange/red)
  - Update available indicator
  - Expandable detail menu
- **Selection Mode:**
  - Long-press to enter multi-select
  - Group dropdown becomes "Move to [Group]" selector
  - Confirmation dialog before group change

### 4.2 Updates Tab
- **Top Section:**
  - "Load Firmware" button
  - "Update All" button
  - Loaded firmware files list with version info
- **Device List:**
  - Only devices with available updates
  - Device identifier
  - Current version → Target version
  - Individual update button
  - Progress indicator (when updating)
- **Selection Mode:**
  - Long-press multi-select for batch updates

---

## 5. Technical Requirements

### 5.1 BLE Mesh Requirements
- **TR-5.1.1:** Nordic Bluetooth Mesh SDK integration
- **TR-5.1.2:** Support for Mesh Light model messages
- **TR-5.1.3:** Group address management
- **TR-5.1.4:** Hardcoded mesh credentials (app key, network key, IV index)

### 5.2 BLE Services
- **TR-5.2.1:** Battery Service (BAS) support
- **TR-5.2.2:** SMP Service for DFU operations
- **TR-5.2.3:** Device Information Service (optional)

### 5.3 Firmware Update
- **TR-5.3.1:** SMP DFU protocol implementation
- **TR-5.3.2:** Signed binary validation
- **TR-5.3.3:** Multi-device concurrent update support (10+ devices)
- **TR-5.3.4:** Update progress tracking per device
- **TR-5.3.5:** Retry logic for failed updates
- **TR-5.3.6:** File format validation and parsing

### 5.4 Performance
- **TR-5.4.1:** Continuous BLE scanning without significant battery drain
- **TR-5.4.2:** UI responsiveness during scanning (<100ms input response)
- **TR-5.4.3:** Firmware update speed: full update within 5 minutes per device
- **TR-5.4.4:** Support scanning range of 10+ meters

### 5.5 Security
- **TR-5.5.1:** Hardcoded mesh credentials stored securely (encrypted storage)
- **TR-5.5.2:** Firmware signature verification before installation
- **TR-5.5.3:** No credential export functionality
- **TR-5.5.4:** Secure SMP communication

---

## 6. Out of Scope

### 6.1 Explicitly Excluded
- Device provisioning workflows
- Unprovisioned device management
- Network key configuration/changes
- App key configuration/changes
- Device factory reset
- Historical data logging
- Cloud synchronization
- Multi-mesh network support
- Device removal/de-provisioning

### 6.2 Future Considerations
- LED identification implementation
- Debug terminal SMP protocol definition
- Advanced device diagnostics
- Device activity logs
- Custom mesh message types

---

## 7. Dependencies

### 7.1 External Dependencies
- Nordic nRF Mesh SDK or equivalent Flutter package
- Flutter Blue Plus (or similar BLE package)
- SMP protocol implementation library
- File picker for firmware selection

### 7.2 Platform Dependencies
- Android: BLE permissions (location, Bluetooth scan/connect)
- iOS: Bluetooth usage permissions
- Both: Background BLE scanning capabilities

---

## 8. Constraints

### 8.1 Technical Constraints
- No provisioning = devices must be pre-provisioned
- Single mesh network per app instance
- No offline operation (requires active BLE)
- No data persistence (discovery-based only)

### 8.2 Business Constraints
- Must support Android 15+ (primary platform)
- iOS support required but secondary priority
- Cross-platform codebase required (minimize platform-specific code)

---

## 9. Acceptance Criteria

### 9.1 Functional Acceptance
- [ ] Continuous device discovery working
- [ ] Group filtering operational (dropdown defaults to Default, 'Unknown' option available, filtering only applies after confirmation)
- [ ] Group triggering sends correct mesh messages
- [ ] Battery levels display with correct thresholds
- [ ] Multi-device firmware updates complete successfully
- [ ] Version comparison correctly identifies update availability
- [ ] Group membership changes persist after app restart (on devices)
- [ ] Long-press multi-select functions properly

### 9.2 Non-Functional Acceptance
- [ ] App runs on Android 15+ devices
- [ ] App runs on iOS 16+ devices
- [ ] No critical security vulnerabilities
- [ ] UI responsive (<100ms input lag)
- [ ] Firmware updates complete within 5 minutes
- [ ] Supports 10+ concurrent firmware updates

---

## 10. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Nordic Mesh SDK unavailable for Flutter | Medium | High | Evaluate platform channels or alternative mesh libraries |
| SMP DFU library compatibility issues | Medium | High | Early prototype with Nordic reference implementation |
| Concurrent updates cause BLE congestion | High | Medium | Implement update queue with rate limiting |
| Battery service not available on all devices | Low | Medium | Graceful degradation with "unknown" state |
| iOS background scanning limitations | Medium | Medium | Document limitations; require foreground operation |
| Firmware signature validation complexity | Medium | Medium | Use Nordic's standard validation tools |

---

## 11. Open Questions

1. **Q:** What specific mesh credentials (network key, app key, IV index) should be hardcoded?  
   **A:** To be provided by mesh network administrator.

2. **Q:** What is the expected device density in typical deployments?  
   **A:** TBD - affects scanning and UI performance requirements.

3. **Q:** Should the app support saving firmware files locally for reuse?  
   **A:** No - files selected each session from phone storage.

4. **Q:** What retry logic for failed firmware updates?  
   **A:** Recommend 3 automatic retries, then manual retry option.

5. **Q:** LED identification mesh message format?  
   **A:** TBD - requires device firmware specification.

---

## 12. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-09 | System Architecture | Initial PRD creation |

---

## 13. Approvals

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Product Owner | | | |
| Technical Lead | | | |
| UX Lead | | | |
