# Development Setup Guide

## Current Status

✅ Flutter SDK installed at `/home/banders/Downloads/flutter/bin/flutter`
✅ Flutter PATH already added to `~/.bashrc`
❌ Android SDK not installed
❌ Android Studio not installed

## Quick Fix for Current Terminal Session

Run this in your current terminal to use Flutter immediately:
```bash
export PATH="$PATH:/home/banders/Downloads/flutter/bin"
```

Or simply start a new terminal to load the PATH from `.bashrc`.

## Android Development Setup

Based on your PRD and TECHNICAL specs, you need Android development tools since this app targets **Android 15+** and **iOS 16+**.

### Option 1: Install Android Studio (Recommended)

Android Studio provides the easiest setup with GUI tools:

1. **Download Android Studio:**
   ```bash
   # Download from https://developer.android.com/studio
   # Or use snap:
   sudo snap install android-studio --classic
   ```

2. **Install Android SDK Components:**
   - Open Android Studio
   - Go to **Settings** → **Appearance & Behavior** → **System Settings** → **Android SDK**
   - Install:
     - Android SDK Platform 34 (Android 14) - for compile SDK
     - Android SDK Platform 35 (Android 15+) - target platform
     - Android SDK Build-Tools 34.0.0
     - Android SDK Command-line Tools
     - Android SDK Platform-Tools
   
3. **Accept Android Licenses:**
   ```bash
   flutter doctor --android-licenses
   ```

4. **Verify Setup:**
   ```bash
   flutter doctor
   ```

### Option 2: Install Command-Line Tools Only (Lightweight)

If you don't want the full Android Studio IDE:

1. **Download Command-Line Tools:**
   ```bash
   cd ~
   mkdir -p Android/Sdk/cmdline-tools
   cd Android/Sdk/cmdline-tools
   
   # Download latest command-line tools
   wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
   unzip commandlinetools-linux-*.zip
   mv cmdline-tools latest
   rm commandlinetools-linux-*.zip
   ```

2. **Set Environment Variables:**
   Add to `~/.bashrc`:
   ```bash
   export ANDROID_HOME=$HOME/Android/Sdk
   export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
   export PATH=$PATH:$ANDROID_HOME/platform-tools
   export PATH=$PATH:$ANDROID_HOME/emulator
   ```

3. **Install SDK Components:**
   ```bash
   source ~/.bashrc
   
   sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" "cmdline-tools;latest"
   ```

4. **Accept Licenses:**
   ```bash
   flutter doctor --android-licenses
   ```

## iOS Development Setup (macOS Only)

Since you're on Linux (Pop!_OS), you **cannot develop for iOS locally**. iOS development requires:
- macOS
- Xcode 15+
- CocoaPods

**Options for iOS:**
- Use a Mac for iOS development
- Use cloud-based macOS CI/CD (GitHub Actions, Codemagic, etc.)
- Focus on Android first, add iOS later

## Verify Installation

After completing Android setup, run:

```bash
flutter doctor -v
```

Expected output:
```
[✓] Flutter (Channel stable, 3.38.4, on Pop!_OS 22.04)
[✓] Android toolchain - develop for Android devices (Android SDK version 34.0.0)
[✓] Connected device (1 available)
[✓] Network resources
```

## Project Setup

Once Flutter and Android are configured:

1. **Get Flutter Dependencies:**
   ```bash
   flutter pub get
   ```

2. **Check for Issues:**
   ```bash
   # Repo policy: treat lints (including "info") as fatal.
   flutter analyze --fatal-infos --fatal-warnings
   ```

3. **Run on Device/Emulator:**
   ```bash
   # List devices
   flutter devices
   
   # Run on connected device
   flutter run
   
   # Run on specific device
   flutter run -d <device-id>
   ```

## Required Dependencies (from TECHNICAL.md)

Add these to `pubspec.yaml` when starting development:

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

### "flutter: command not found" in new terminal
Solution: Restart terminal or run `source ~/.bashrc`

### Android licenses not accepted
Solution: Run `flutter doctor --android-licenses` and accept all

### No connected devices
Solution: 
- Enable USB debugging on Android device
- Use `adb devices` to verify connection
- Or create an emulator in Android Studio

### KVM not installed (for emulator)
Solution:
```bash
sudo apt install qemu-kvm
sudo adduser $USER kvm
# Logout and login again
```

## Next Steps

1. ✅ Fix Flutter PATH (reload terminal)
2. 📱 Install Android Studio or command-line tools
3. ✅ Run `flutter doctor` to verify
4. 📦 Run `flutter pub get` in project
5. 🏃 Test with `flutter run`

### Nordic Mesh dependency

On Android, the Nordic Mesh library is included via Maven/Gradle in `android/app/build.gradle.kts`. To change versions, update the `no.nordicsemi.android:mesh:<version>` dependency there, then run:

```bash
flutter clean
flutter pub get
flutter run -d android
```

## References

- [Flutter Installation Guide](https://docs.flutter.dev/get-started/install/linux)
- [Android Studio Download](https://developer.android.com/studio)
- [Android SDK Command-Line Tools](https://developer.android.com/studio#command-line-tools-only)
- Project PRD: [PRD.md](./PRD.md)
- Technical Spec: [TECHNICAL.md](./TECHNICAL.md)
