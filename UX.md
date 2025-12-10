# User Experience Specification (UX)
## Nordic BLE Mesh Manager

**Version:** 1.0  
**Date:** December 9, 2025  
**Author:** UX Design Team

---

## 1. Overview

This document defines the complete user experience for the Nordic BLE Mesh Manager application, including screen layouts, interactions, navigation patterns, and visual design specifications.

---

## 2. Design Principles

### 2.1 Core Principles
1. **Clarity Over Density:** Prioritize clear information hierarchy over cramming maximum data
2. **Action-Oriented:** Common actions (trigger, update) must be immediately accessible
3. **Status-First:** Device health (battery, update status) must be immediately visible
4. **Error Prevention:** Destructive or batch operations require confirmation
5. **Responsive Feedback:** All user actions provide immediate visual feedback

### 2.2 Target Usage Context
- **Environment:** Field operations, potentially outdoors with glare
- **Usage Duration:** Short sessions (1-5 minutes typical)
- **Interaction Style:** One-handed operation preferred
- **Attention:** Split attention (monitoring while performing other tasks)

---

## 3. Information Architecture

### 3.1 App Structure
```
Nordic Mesh Manager
├── Devices Tab (Default)
│   ├── Group Selector
│   ├── Trigger All Button
│   └── Device List
│       └── Device Entry
│           ├── Identifier
│           ├── Battery Indicator
│           ├── Update Badge
│           └── Details Dropdown (collapsed)
│               ├── Full MAC Address
│               ├── Firmware Version
│               ├── Hardware ID
│               ├── Signal Strength
│               ├── Identify Button (LED)
│               └── Debug Terminal
└── Updates Tab
    ├── Firmware Management
    │   ├── Load Firmware Button
    │   └── Loaded Firmware List
    ├── Update All Button
    └── Updateable Devices List
        └── Device Entry
            ├── Identifier
            ├── Version Comparison
            ├── Update Button
            └── Progress Bar
```

### 3.2 Navigation Pattern
- **Two-tab structure:** Devices | Updates
- **Default view:** Devices tab
- **Tab persistence:** Remember last selected tab (session only)
- **No nested navigation:** All functions accessible from two primary screens

---

## 4. Screen Specifications

## 4.1 Devices Tab

### 4.1.1 Layout Structure

```
┌─────────────────────────────────────────┐
│ [Group Dropdown ▾]    [Trigger All]     │ ← Header (fixed)
├─────────────────────────────────────────┤
│ Device List (scrollable)                │
│ ┌─────────────────────────────────────┐ │
│ │ ●● AB:CD:EF  🔋🟢  [⚠️ Update]  ▾   │ │ ← Device entry
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ ●● 12:34:56  🔋🟠               ▾   │ │
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ ●● FE:DC:BA  🔋🔴  [⚠️ Update]  ▾   │ │
│ └─────────────────────────────────────┘ │
│                                         │
└─────────────────────────────────────────┘
│ [Devices]  [Updates]                    │ ← Bottom tabs
└─────────────────────────────────────────┘
```

### 4.1.2 Component Details

#### Group Selector Dropdown
- **Position:** Top-left of header
- **Width:** 60% of screen width
- **Height:** 48dp (touch target)
- **Style:** Material dropdown button with border
- **Content:** Group name/ID (e.g., "Default" for 0xC000, user-created groups)
- **States:**
  - **Default:** Shows currently selected group
  - **Expanded:** Shows all discovered groups
  - **No groups:** Shows "No Groups Found" (disabled). Groups must be created via multi-select in the Devices list.
  - **Multi-select mode:** Changes to "Move to ▾" with group list

#### Trigger All Button
- **Position:** Top-right of header
- **Width:** 35% of screen width
- **Height:** 48dp
- **Style:** Primary action button (filled)
- **States:**
  - **Enabled:** Group selected with devices
  - **Disabled:** No group selected or no devices in group
  - **Pressed:** Haptic feedback + visual press state
  - **Loading:** Spinner + "Triggering..."

#### Device List Entry (Collapsed)
- **Height:** 72dp minimum
- **Touch target:** Entire row (tap to expand/collapse)
- **Long-press:** Enters multi-select mode (haptic feedback)
- **Left section (60%):**
  - **Line 1:** Device identifier (last 6 MAC nibbles) - 18sp, bold
    - Format: `AB:CD:EF` (colons between pairs)
  - **Line 2:** Secondary info (signal strength, group if applicable) - 14sp, grey
- **Right section (40%):**
  - **Battery indicator:** Circular icon with color
    - 🟢 Green (≥50%)
    - 🟠 Orange (25-49%)
    - 🔴 Red (<25%)
  - **Update badge:** Small warning icon if update available
  - **Expand icon:** Chevron down/up based on state

#### Device List Entry (Expanded)
- **Height:** Auto (minimum 200dp)
- **Content sections:**
  1. **Device Information** (top section)
     - Full MAC address
     - Hardware ID (from advertising)
     - Firmware version (major.minor.revision-hash)
     - Signal strength (RSSI in dBm)
  2. **Actions** (button section)
     - "Identify Device" button (LED flash) - disabled with "(TBD)" label
     - "Debug Terminal" button (SMP) - disabled with "(TBD)" label
  3. **Additional details** (as needed)

### 4.1.3 Interaction States

#### Normal Mode (Default)
- Tap device → Expand/collapse details
- Tap "Trigger All" → Confirmation dialog → Send group message
- Select group dropdown → Show group list → Filter devices

#### Multi-Select Mode (Long-press activated)
- **Entry:** Long-press any device (haptic feedback)
- **Visual changes:**
  - Checkboxes appear on left of each device
  - Group dropdown → "Move to ▾" dropdown
  - "Trigger All" → "Cancel" button
  - Selected devices have highlighted background
- **Actions:**
  - Tap devices to toggle selection
  - Select "Move to [Group]" → Confirmation dialog → Move devices
  - Tap "Cancel" → Exit multi-select mode
- **Exit:** Tap "Cancel" or complete action

#### Empty State
- **No devices found:**
  - Large icon (mesh network graphic)
  - Text: "No devices detected"
  - Subtext: "Make sure devices are powered on and in range"
- **No group selected:**
  - Text: "Select a group to view devices"

---

## 4.2 Updates Tab

### 4.2.1 Layout Structure

```
┌─────────────────────────────────────────┐
│ Loaded Firmware Files                   │ ← Header section (scrollable)
│ ┌─────────────────────────────────────┐ │
│ │ HW-0A3F v2.1.5-a3d9c               × │ │ ← Firmware chip
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ HW-0B12 v1.8.3-f42ac               × │ │
│ └─────────────────────────────────────┘ │
│ [+ Load Firmware File]                  │
├─────────────────────────────────────────┤
│ [Update All (3)]                        │ ← Action bar (fixed)
├─────────────────────────────────────────┤
│ Devices Requiring Updates (scrollable)  │
│ ┌─────────────────────────────────────┐ │
│ │ AB:CD:EF  v2.1.3 → v2.1.5  [Update] │ │ ← Update entry
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ 12:34:56  v1.8.1 → v1.8.3  [Update] │ │
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ FE:DC:BA  v2.1.4 → v2.1.5  [Update] │ │
│ │ ▓▓▓▓▓▓▓▓░░░░░░░░░░░░ 45%            │ │ ← Updating with progress
│ └─────────────────────────────────────┘ │
│                                         │
└─────────────────────────────────────────┘
│ [Devices]  [Updates]                    │ ← Bottom tabs
└─────────────────────────────────────────┘
```

### 4.2.2 Component Details

#### Firmware Files Section
- **Position:** Top of screen (scrollable if >3 files)
- **Max visible:** 3 files before scrolling
- **Background:** Light grey card/section

#### Firmware File Chip
- **Height:** 48dp
- **Style:** Material chip with border
- **Content:**
  - Left: Hardware ID (bold) + Version (regular)
  - Right: Remove button (× icon)
- **Actions:**
  - Tap × → Remove firmware file (confirmation if devices pending)

#### Load Firmware Button
- **Style:** Outlined button
- **Action:** Open file picker → Validate filename → Add to list or show error
- **Error handling:** Toast message with validation failure reason

#### Update All Button
- **Position:** Below firmware section, above device list
- **Width:** Full width (with margin)
- **Height:** 56dp
- **Style:** Primary action button
- **Label:** "Update All ([count])" - count = number of updateable devices
- **States:**
  - **Enabled:** Firmware loaded + devices need updates + no updates in progress
  - **Disabled:** No firmware / no devices / updates in progress
  - **Long-press:** Force update option (bypasses version check)

#### Update Device Entry (Idle)
- **Height:** 72dp minimum
- **Long-press:** Multi-select mode (same as Devices tab)
- **Left section (70%):**
  - **Line 1:** Device identifier (last 6 MAC nibbles) - 18sp, bold
  - **Line 2:** Version comparison - 14sp
    - Format: `v2.1.3 → v2.1.5` (current → target)
    - Colors: Grey (current) → Primary color (target)
- **Right section (30%):**
  - **Update button:** "Update" text button or icon button

#### Update Device Entry (Updating)
- **Height:** 96dp (expanded for progress)
- **Additional content:**
  - **Progress bar:** Horizontal determinate progress (0-100%)
  - **Status text:** Percentage + state
    - "Uploading... 45%"
    - "Verifying... 98%"
    - "Rebooting..."
  - **Cancel button:** × icon (if supported by protocol)

#### Update Device Entry (Complete)
- **Height:** 72dp
- **Changes:**
  - Green checkmark icon
  - Updated version displayed
  - "Updated" label
  - Auto-remove from list after 3 seconds

#### Update Device Entry (Failed)
- **Height:** 96dp
- **Changes:**
  - Red error icon
  - Error message (e.g., "Connection lost", "Verification failed")
  - "Retry" button
  - Remains in list until retry or manual dismissal

### 4.2.3 Interaction States

#### Normal Mode
- Tap "Load Firmware" → File picker → Validate → Add to list
- Tap individual "Update" → Start single device update
- Tap "Update All" → Confirmation dialog → Start all updates
- Long-press "Update All" → Force update confirmation → Start all (force)

#### Multi-Select Mode
- Same as Devices tab, but for selecting specific devices to update
- Actions limited to: Update selected, Cancel

#### Empty States

**No Firmware Loaded:**
- Large icon (document/file)
- Text: "No firmware files loaded"
- Subtext: "Tap 'Load Firmware File' to begin"

**No Updates Available:**
- Large icon (checkmark)
- Text: "All devices up to date"
- Subtext: "No firmware updates needed"

**No Matching Hardware:**
- Text: "No devices match loaded firmware"
- Subtext: "Load firmware for [detected hardware IDs]"

---

## 5. Visual Design Specifications

### 5.1 Color Palette

#### Primary Colors
- **Primary:** #0066CC (Nordic blue)
- **Primary Variant:** #0052A3
- **Secondary:** #FFA000 (Amber - for warnings)
- **Secondary Variant:** #FF8F00

#### Status Colors
- **Success/Green:** #4CAF50 (Battery ≥50%, success states)
- **Warning/Orange:** #FF9800 (Battery 25-49%, warnings)
- **Error/Red:** #F44336 (Battery <25%, errors)
- **Info/Blue:** #2196F3 (Informational messages)

#### Neutral Colors
- **Background:** #FFFFFF (light theme)
- **Surface:** #F5F5F5 (cards, elevated elements)
- **Divider:** #E0E0E0
- **Text Primary:** #212121
- **Text Secondary:** #757575
- **Text Disabled:** #BDBDBD

### 5.2 Typography

#### Font Family
- **Primary:** Roboto (Android) / San Francisco (iOS)
- **Monospace:** Roboto Mono (for MAC addresses, versions)

#### Type Scale
- **H1 (Screen Titles):** 24sp, Medium, Letter spacing 0
- **H2 (Section Headers):** 20sp, Medium, Letter spacing 0.15
- **Body 1 (Primary Text):** 16sp, Regular, Letter spacing 0.5
- **Body 2 (Secondary Text):** 14sp, Regular, Letter spacing 0.25
- **Button:** 14sp, Medium, All caps, Letter spacing 1.25
- **Caption:** 12sp, Regular, Letter spacing 0.4
- **Identifier (MAC/ID):** 18sp, Bold, Monospace, Letter spacing 0

### 5.3 Spacing System

#### Base Unit: 8dp

- **Tiny:** 4dp (0.5×)
- **Small:** 8dp (1×)
- **Medium:** 16dp (2×)
- **Large:** 24dp (3×)
- **XLarge:** 32dp (4×)

#### Component Spacing
- **List item padding:** 16dp horizontal, 12dp vertical
- **Card margin:** 8dp
- **Section padding:** 16dp
- **Button padding:** 16dp horizontal, 12dp vertical

### 5.4 Iconography

#### Icon Set
- Material Icons (primary)
- Custom icons for:
  - Battery states (with percentage indicators)
  - Mesh network
  - Firmware package

#### Icon Sizes
- **Small:** 18dp (inline with text)
- **Medium:** 24dp (list items, buttons)
- **Large:** 48dp (empty states)

### 5.5 Elevation & Shadows

- **Level 0 (Flat):** Background, dividers
- **Level 1 (2dp):** Cards, list items
- **Level 2 (4dp):** App bar, bottom navigation
- **Level 3 (8dp):** Dropdowns, menus
- **Level 4 (16dp):** Dialogs, modals

---

## 6. Interaction Patterns

### 6.1 Touch Targets
- **Minimum size:** 48dp × 48dp
- **Preferred size:** 56dp × 56dp for primary actions
- **Spacing between targets:** Minimum 8dp

### 6.2 Gestures
- **Tap:** Select, activate, expand/collapse
- **Long-press:** Enter multi-select mode (500ms threshold)
- **Swipe:** No swipe gestures (avoid accidental actions)
- **Pull-to-refresh:** Not implemented (continuous scanning)

### 6.3 Feedback
- **Haptic feedback:**
  - Long-press (entering multi-select)
  - Successful group trigger
  - Error conditions
- **Visual feedback:**
  - Ripple effect on all tappable elements
  - State changes (pressed, focused, disabled)
  - Loading spinners for async operations
- **Audio feedback:** None (field environment may be noisy)

---

## 7. Dialogs & Confirmations

### 7.1 Trigger All Confirmation

```
┌───────────────────────────────────┐
│  Trigger Group 3?                 │
│                                   │
│  This will trigger all 12 devices │
│  in the selected group.           │
│                                   │
│           [Cancel]  [Trigger]     │
└───────────────────────────────────┘
```

- **Style:** Material dialog
- **Primary action:** "Trigger" (right, filled button)
- **Secondary action:** "Cancel" (left, text button)

### 7.2 Move Devices Confirmation

```
┌───────────────────────────────────┐
│  Move 3 Devices?                  │
│                                   │
│  Move selected devices to:        │
│  Group 5                          │
│                                   │
│           [Cancel]  [Move]        │
└───────────────────────────────────┘
```

### 7.3 Update All Confirmation

```
┌───────────────────────────────────┐
│  Update 8 Devices?                │
│                                   │
│  This will update all devices     │
│  with available firmware.         │
│  Updates take ~5 minutes each.    │
│                                   │
│  □ Force update (ignore version)  │
│                                   │
│           [Cancel]  [Update]      │
└───────────────────────────────────┘
```

- **Force option:** Checkbox (unchecked by default)
- **Warning:** Time estimate included

### 7.4 Remove Firmware Confirmation

```
┌───────────────────────────────────┐
│  Remove Firmware?                 │
│                                   │
│  HW-0A3F v2.1.5-a3d9c             │
│                                   │
│  3 devices are pending update     │
│  with this firmware.              │
│                                   │
│           [Cancel]  [Remove]      │
└───────────────────────────────────┘
```

- **Conditional:** Only show device count if updates pending

### 7.5 Invalid Firmware Dialog

```
┌───────────────────────────────────┐
│  Invalid Firmware File            │
│                                   │
│  Filename must match format:      │
│  <hw_id>-major.minor.rev-hash     │
│       .signed.bin                 │
│                                   │
│  Example:                         │
│  HW-0A3F-2.1.5-a3d9c.signed.bin   │
│                                   │
│                      [OK]         │
└───────────────────────────────────┘
```

---

## 8. Error States & Messages

### 8.1 Error Message Principles
- **Clear:** Explain what went wrong
- **Actionable:** Suggest next steps
- **Concise:** Maximum 2 sentences
- **Non-technical:** Avoid jargon

### 8.2 Common Error Messages

#### BLE Permission Denied
```
Bluetooth Permission Required

Grant Bluetooth permission in Settings to scan for devices.

[Open Settings]  [Cancel]
```

#### Location Permission Denied (Android)
```
Location Permission Required

Android requires location access for Bluetooth scanning.

[Open Settings]  [Cancel]
```

#### Bluetooth Disabled
```
Bluetooth is Disabled

Enable Bluetooth to connect to devices.

[Enable Bluetooth]  [Cancel]
```

#### Group Trigger Failed
```
Trigger Failed

Could not send message to Group 3. Check device connection.

[Retry]  [Dismiss]
```

#### Firmware Update Failed
```
Update Failed: AB:CD:EF

Connection lost during update. Device may need power cycle.

[Retry]  [Dismiss]
```

#### No Firmware for Hardware
```
No Matching Firmware

Device HW-0C44 found, but no firmware loaded for this hardware.

[Load Firmware]  [Dismiss]
```

---

## 9. Loading & Progress States

### 9.1 Scanning Indicator
- **Type:** Subtle animated icon in app bar
- **Style:** Small rotating mesh icon
- **Behavior:** Continuous while scanning
- **No blocking overlay:** Users can interact during scanning

### 9.2 Trigger All Progress
- **Type:** Inline loading indicator
- **Duration:** Brief (1-2 seconds typical)
- **Button state:** "Triggering..." with spinner
- **Success:** Brief success message (toast)

### 9.3 Firmware Update Progress
- **Type:** Determinate progress bar
- **Granularity:** 1% increments
- **Stages:**
  - Connecting (0-10%)
  - Uploading (10-80%)
  - Verifying (80-95%)
  - Rebooting (95-100%)
- **Time remaining:** Not shown (unreliable)

### 9.4 Multi-Device Update Progress
- **Individual progress bars:** Per device
- **Overall progress:** Not shown (devices complete at different times)
- **Completion:** Devices removed from list after success

---

## 10. Accessibility

### 10.1 Requirements
- **WCAG 2.1 Level AA compliance**
- **Screen reader support:** All elements labeled
- **Minimum contrast ratios:**
  - Normal text: 4.5:1
  - Large text: 3:1
  - UI components: 3:1
- **Focus indicators:** Visible on all interactive elements
- **Text scaling:** Support up to 200% zoom

### 10.2 Screen Reader Labels

| Element | Label |
|---------|-------|
| Battery indicator | "Battery level [green/orange/red], [percentage]%" |
| Update badge | "Firmware update available" |
| Device entry | "Device [identifier], battery [status], [update status]" |
| Trigger button | "Trigger all devices in [group name]" |
| Expand icon | "Expand details" / "Collapse details" |

### 10.3 Dynamic Content Announcements
- "Group changed to [group name], [count] devices found"
- "Device [identifier] triggered successfully"
- "[count] devices selected"
- "Firmware update started for [identifier]"
- "Update complete for [identifier]"

---

## 11. Platform-Specific Considerations

### 11.1 Android
- **Material Design 3:** Follow latest Material guidelines
- **System navigation:** Support gesture navigation
- **Dark theme:** Not required (field use in daylight)
- **Adaptive layouts:** Support tablets (same layout, larger touch targets)

### 11.2 iOS
- **Human Interface Guidelines:** Follow Apple HIG
- **System navigation:** Respect iOS navigation patterns
- **Safe areas:** Account for notch and home indicator
- **Haptic feedback:** Use UIImpactFeedbackGenerator appropriately

### 11.3 Cross-Platform Consistency
- **Prioritize:** Functional consistency over pixel-perfect matching
- **Platform controls:** Use native controls where appropriate
- **Custom components:** Match platform aesthetics
- **Navigation:** Respect platform conventions (back button behavior)

---

## 12. Performance Considerations

### 12.1 List Performance
- **Virtualization:** Use lazy loading for device lists (>50 items)
- **Smooth scrolling:** 60 FPS minimum
- **Update throttling:** Max 10 list updates per second

### 12.2 Animation Performance
- **Duration:** 200-300ms for most animations
- **Easing:** Material standard easing curves
- **Hardware acceleration:** Use for transforms and opacity
- **Avoid:** Animating layout properties on large lists

### 12.3 Battery Impact
- **Continuous scanning:** Optimize scan intervals
- **Background behavior:** Pause scanning when app backgrounded
- **Screen timeout:** Respect system settings

---

## 13. Future UX Considerations

### 13.1 Potential Enhancements
- **Search/filter:** Find devices by identifier
- **Sorting:** Sort by battery, signal strength, update status
- **Device nicknames:** User-assigned friendly names
- **Activity log:** Recent triggers and updates
- **Network visualization:** Mesh topology view
- **Batch operations:** More granular selection tools

### 13.2 Debug Features
- **LED identification:** Visual device identification
- **Debug terminal:** SMP-based console access
- **Signal strength map:** Real-time RSSI visualization
- **Mesh health:** Network quality metrics

---

## 14. Design Assets Needed

### 14.1 Icons
- [ ] App icon (1024×1024, adaptive)
- [ ] Mesh network icon (custom)
- [ ] Battery indicator states (green/orange/red)
- [ ] Firmware package icon
- [ ] Empty state illustrations

### 14.2 Images
- [ ] Splash screen (optional)
- [ ] Onboarding graphics (future)

### 14.3 Animations
- [ ] Scanning indicator
- [ ] Success confirmation (optional)

---

## 15. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-09 | UX Design Team | Initial UX specification |

---

## 16. Appendix: Wireframe References

### A1. Devices Tab - Normal State
(Refer to ASCII wireframe in section 4.1.1)

### A2. Devices Tab - Multi-Select State
```
┌─────────────────────────────────────────┐
│ [Move to ▾]              [Cancel]       │ ← Changed header
├─────────────────────────────────────────┤
│ ☑ AB:CD:EF  🔋🟢  [⚠️ Update]          │ ← Checkboxes visible
│ ☑ 12:34:56  🔋🟠                        │
│ ☐ FE:DC:BA  🔋🔴  [⚠️ Update]          │
│                                         │
└─────────────────────────────────────────┘
```

### A3. Updates Tab - Active Updates
```
┌─────────────────────────────────────────┐
│ Loaded Firmware Files                   │
│ HW-0A3F v2.1.5-a3d9c               ×    │
│ [+ Load Firmware File]                  │
├─────────────────────────────────────────┤
│ [Update All (2)] ← Only non-updating    │
├─────────────────────────────────────────┤
│ AB:CD:EF  v2.1.3 → v2.1.5               │
│ ▓▓▓▓▓▓▓▓░░░░░░░░░░░░ 45% Uploading...  │ ← In progress
│                                         │
│ 12:34:56  v2.1.4 → v2.1.5  [Update]     │ ← Still idle
│                                         │
│ FE:DC:BA  v2.1.2 → v2.1.5  ✓ Updated    │ ← Completed
└─────────────────────────────────────────┘
```

---

**End of UX Specification**
