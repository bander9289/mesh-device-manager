# Development Setup Guide

## Prerequisites Check

Before starting, verify what's already installed:

```bash
# Check Flutter installation
which flutter
flutter --version

# Check Android SDK
echo $ANDROID_HOME
ls -la ~/Android/Sdk 2>/dev/null || echo "Android SDK not installed"

# Check Java (required for Android builds)
java -version
```

## Flutter SDK Setup

This app targets **Android 15+** and **iOS 16+** (see PRD.md and TECHNICAL.md).

### Install Flutter

1. **Download Flutter SDK:**
   ```bash
   cd ~
   git clone https://github.com/flutter/flutter.git -b stable
   ```

2. **Add Flutter to PATH:**
   
   Add to `~/.bashrc`:
   ```bash
   export PATH="$PATH:$HOME/flutter/bin"
   ```

3. **Apply changes:**
   ```bash
   source ~/.bashrc
   # OR start a new terminal
   ```

4. **Run Flutter doctor:**
   ```bash
   flutter doctor
   ```

5. **Disable analytics (optional):**
   ```bash
   flutter config --no-analytics
   ```

## Android Command-Line Tools Setup

**This setup uses command-line tools only** (no Android Studio IDE required).

### Install Java Development Kit and Build Tools

```bash
sudo apt update
sudo apt install openjdk-17-jdk ninja-build
java -version  # Verify installation
ninja --version  # Verify installation
```

**Note:** `ninja-build` is required for Android native code compilation (CMake builds).

### Install Android Command-Line Tools

1. **Create SDK directory and download tools:**
   ```bash
   mkdir -p ~/Android/Sdk/cmdline-tools
   cd ~/Android/Sdk/cmdline-tools
   
   # Download latest command-line tools
   # Check https://developer.android.com/studio#command-line-tools-only for latest version
   wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
   unzip commandlinetools-linux-*.zip
   mv cmdline-tools latest
   rm commandlinetools-linux-*.zip
   ```

2. **Configure environment variables:**
   
   Add to `~/.bashrc`:
   ```bash
   export ANDROID_HOME=$HOME/Android/Sdk
   export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
   export PATH=$PATH:$ANDROID_HOME/platform-tools
   export PATH=$PATH:$ANDROID_HOME/build-tools/34.0.0
   ```

3. **Apply environment changes:**
   ```bash
   source ~/.bashrc
   ```

4. **Install required SDK components:**
   ```bash
   # Accept licenses
   yes | sdkmanager --licenses
   
   # Install SDK components for Android 15+ (API 34+)
   sdkmanager "platform-tools" \
     "platforms;android-34" \
     "platforms;android-35" \
     "build-tools;34.0.0" \
     "cmdline-tools;latest"
   ```

5. **Accept Flutter Android licenses:**
   ```bash
   flutter doctor --android-licenses
   ```

## iOS Development Setup

**Requirements:** macOS with Xcode 15+ (iOS development cannot be done on Linux)

### Install Xcode

1. **Download and install Xcode:**
   - Open App Store on macOS
   - Search for "Xcode"
   - Install Xcode 15 or later
   - Launch Xcode and accept license agreements

2. **Install Xcode command-line tools:**
   ```bash
   sudo xcode-select --install
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   ```

3. **Verify Xcode installation:**
   ```bash
   xcodebuild -version
   ```

### Install CocoaPods

CocoaPods manages iOS dependencies (required for this project):

```bash
# Install CocoaPods
sudo gem install cocoapods

# Verify installation
pod --version
```

### Setup iOS Simulator

```bash
# List available simulators
xcrun simctl list devices

# Launch a simulator (example: iPhone 15)
open -a Simulator
```

### Install iOS Dependencies

```bash
cd ios
pod install
cd ..
```

### Verify iOS Setup

```bash
flutter doctor
```

Expected iOS section:
```
[✓] Xcode - develop for iOS and macOS (Xcode 15.x)
```

### Run on iOS

```bash
# List iOS devices/simulators
flutter devices

# Run on iOS simulator
flutter run -d ios

# Run on connected iPhone/iPad (requires Apple Developer account)
flutter run -d <device-id>
```

### iOS Development Options for Linux Users

Since iOS development requires macOS, Linux users have these options:
- **Remote Mac:** Use a Mac mini or MacBook for iOS builds
- **Cloud CI/CD:** Use GitHub Actions (macOS runners), Codemagic, or Bitrise
- **Focus on Android first:** Complete Android development, add iOS later
- **Hackintosh/VM:** Not recommended (unstable, violates Apple EULA)

## Verify Complete Setup

After installing Flutter and Android SDK (and optionally iOS tools), run:

```bash
flutter doctor -v
```

**Expected output (Linux with Android only):**
```
[✓] Flutter (Channel stable)
[✓] Android toolchain - develop for Android devices (Android SDK version 34.0.0)
[✓] Network resources
```

**Expected output (macOS with Android and iOS):**
```
[✓] Flutter (Channel stable)
[✓] Android toolchain - develop for Android devices (Android SDK version 34.0.0)
[✓] Xcode - develop for iOS and macOS (Xcode 15.x)
[✓] Network resources
```

## Project Setup

### Install Project Dependencies

```bash
cd /home/banders/src/willis/mesh-device-manager
flutter pub get
```

### Analyze Code Quality

```bash
# Repo policy: treat lints (including "info") as fatal
flutter analyze --fatal-infos --fatal-warnings
```

**Note:** Analyzer configuration is in `analysis_options.yaml`. Quote glob patterns starting with `*` (e.g. `"**/*.g.dart"`) to avoid YAML alias parsing errors. Excludes are intentionally broad for platform/build/generated outputs (e.g. `android/`, `ios/`, `linux/`, `build/`, `.dart_tool/`, and `**/generated/**`) so analysis focuses on our Dart sources.

### Build for Android

```bash
# Debug build
flutter build apk --debug

# Release build (requires signing configuration)
flutter build apk --release

# Build app bundle (for Play Store)
flutter build appbundle --release
```

### Install and Run on Android Device

```bash
# Enable USB debugging on your Android device first

# Check device is connected
adb devices

# Install the APK
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# Launch the app
adb shell am start -n com.nordicmesh.nordic_mesh_manager/.MainActivity

# View logs
adb logcat -c  # Clear previous logs
adb logcat | grep -E "(flutter|Flutter|Nordic)"  # Watch app logs
```

### Run from Flutter (Alternative)

```bash
# List available devices
flutter devices

# Run on connected device
flutter run

# Run on specific device
flutter run -d <device-id>

# Run with custom mesh credentials
flutter run --dart-define=MESH_APP_KEY=your_key_here
```

## Required Dependencies (from TECHNICAL.md)

These are already in `pubspec.yaml`:

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
```

## Troubleshooting

### "flutter: command not found"
**Solution:** 
```bash
source ~/.bashrc  # Reload shell configuration
# OR start a new terminal
which flutter  # Verify Flutter is in PATH
```

### "sdkmanager: command not found"
**Solution:**
```bash
echo $ANDROID_HOME  # Should show ~/Android/Sdk
source ~/.bashrc  # Reload environment
which sdkmanager  # Should show path to sdkmanager
```

### Android licenses not accepted
**Solution:**
```bash
flutter doctor --android-licenses
# Accept all licenses by typing 'y'
```

### No connected devices / ADB not recognizing device
**Solution:**
```bash
# 1. Enable Developer Options and USB Debugging on Android device
# 2. Connect device via USB
# 3. Check connection
adb devices

# If device not listed, restart ADB
adb kill-server
adb start-server
adb devices

# Check USB permissions (Linux)
lsusb  # Find your device
# May need to add udev rules for your device vendor ID
```

### Build errors: "Gradle build failed"
**Solution:**
```bash
# Clean project and rebuild
flutter clean
flutter pub get
flutter build apk --debug

# Check Java version (needs JDK 17)
java -version

# Check Gradle wrapper permissions
chmod +x android/gradlew
```

### Build error: "Could not find Ninja on PATH"
**Error:** `[CXX1416] Could not find Ninja on PATH or in SDK CMake bin folders.`

**Solution:**
```bash
# Install ninja build system (required for CMake/native builds)
sudo apt install ninja-build
ninja --version  # Verify installation

# Rebuild
flutter clean
flutter build apk --debug
```

### iOS: CocoaPods installation issues
**Solution:**
```bash
# Update Ruby gems
sudo gem update --system

# Reinstall CocoaPods
sudo gem uninstall cocoapods
sudo gem install cocoapods

# Clean and reinstall pods
cd ios
rm -rf Pods Podfile.lock
pod install
cd ..
```

### iOS: "Xcode license not accepted"
**Solution:**
```bash
sudo xcodebuild -license accept
```

## Quick Reference

### Setup Checklist

**Linux (Android development):**
- [ ] Install Flutter SDK
- [ ] Install Java JDK 17 and ninja-build
- [ ] Install Android command-line tools
- [ ] Configure ANDROID_HOME and PATH
- [ ] Run `flutter doctor` (Android toolchain should be green)
- [ ] Run `flutter pub get` in project
- [ ] Build and test: `flutter build apk --debug`

**macOS (Android + iOS development):**
- [ ] Install Flutter SDK
- [ ] Install Java JDK 17
- [ ] Install Android command-line tools
- [ ] Install Xcode 15+
- [ ] Install CocoaPods
- [ ] Run `flutter doctor` (both Android and iOS toolchains green)
- [ ] Run `flutter pub get` in project
- [ ] Install iOS pods: `cd ios && pod install && cd ..`
- [ ] Test both platforms

### Nordic Mesh Dependency

The Nordic Mesh library is included via Maven/Gradle in [android/app/build.gradle.kts](android/app/build.gradle.kts).

**To update Nordic Mesh version:**
1. Edit `android/app/build.gradle.kts`
2. Change: `implementation("no.nordicsemi.android:mesh:<version>")`
3. Rebuild:
   ```bash
   flutter clean
   flutter pub get
   flutter build apk
   ```

### Mesh Credentials Configuration

Mesh credentials (app key, network key) are configured at build time using `--dart-define`. See [MESH_CREDENTIALS.md](MESH_CREDENTIALS.md) for details.

```bash
# Example: Build with custom mesh credentials
flutter build apk --dart-define=MESH_APP_KEY=your_app_key
```

## References

### Official Documentation
- [Flutter Installation - Linux](https://docs.flutter.dev/get-started/install/linux)
- [Flutter Installation - macOS](https://docs.flutter.dev/get-started/install/macos)
- [Android Command-Line Tools](https://developer.android.com/studio#command-line-tools-only)
- [Xcode Download](https://developer.apple.com/xcode/)
- [CocoaPods Installation](https://guides.cocoapods.org/using/getting-started.html)

### Project Documentation
- [PRD.md](./PRD.md) - Product requirements
- [TECHNICAL.md](./TECHNICAL.md) - Technical architecture
- [MESH_CREDENTIALS.md](./MESH_CREDENTIALS.md) - Mesh credential configuration
- [METHOD_CHANNEL_CONTRACT.md](./METHOD_CHANNEL_CONTRACT.md) - Platform channel interface
- [UX.md](./UX.md) - User experience guidelines
