# Mesh Credentials Configuration

## Overview
The app requires BLE Mesh network credentials (`netKey` and `appKey`) to communicate with mesh devices. These are configured at build time using Flutter's `--dart-define` feature to keep secrets out of the codebase.

## Configuration Methods

### 1. Command Line (Development)
Pass credentials directly when running or building:

```bash
flutter run \
  --dart-define=MESH_NET_KEY=78806728531AE9EDC4241E68749219AC \
  --dart-define=MESH_APP_KEY=5AC5425AA36136F2513436EA29C358D5
```

Or for release builds:
```bash
flutter build apk \
  --dart-define=MESH_NET_KEY=<your_net_key> \
  --dart-define=MESH_APP_KEY=<your_app_key>
```

### 2. Environment Variables (CI/CD)
Set environment variables and reference them:

```bash
export MESH_NET_KEY=78806728531AE9EDC4241E68749219AC
export MESH_APP_KEY=5AC5425AA36136F2513436EA29C358D5

flutter run \
  --dart-define=MESH_NET_KEY=$MESH_NET_KEY \
  --dart-define=MESH_APP_KEY=$MESH_APP_KEY
```

### 3. VS Code Configuration
Add to `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Flutter (with mesh credentials)",
      "request": "launch",
      "type": "dart",
      "args": [
        "--dart-define=MESH_NET_KEY=78806728531AE9EDC4241E68749219AC",
        "--dart-define=MESH_APP_KEY=5AC5425AA36136F2513436EA29C358D5"
      ]
    }
  ]
}
```

### 4. Build Script
Create a `build.sh` script:

```bash
#!/bin/bash
# build.sh - Build with mesh credentials

# Source credentials from .env file (add .env to .gitignore!)
if [ -f .env ]; then
  export $(cat .env | xargs)
fi

flutter build apk \
  --dart-define=MESH_NET_KEY=${MESH_NET_KEY} \
  --dart-define=MESH_APP_KEY=${MESH_APP_KEY}
```

## Default Testing Credentials

For development/testing with Nordic mesh test networks, you can use:
- **Network Key**: `78806728531AE9EDC4241E68749219AC`
- **App Key**: `5AC5425AA36136F2513436EA29C358D5`

**⚠️ WARNING**: Never commit production credentials to version control!

## Missing Credentials Behavior

If credentials are not provided:
- App will start but show a warning in debug mode
- Mesh operations will fail gracefully
- Empty credentials will be passed to `meshClient.initialize()`
- Check logs for: `⚠️  WARNING: Mesh credentials not configured!`

## Security Best Practices

1. **Never commit credentials to git**
   - Add `.env` files to `.gitignore`
   - Use secret management in CI/CD (GitHub Secrets, etc.)

2. **Rotate credentials regularly**
   - Rebuild and redeploy when credentials change
   - No need to modify code

3. **Use different credentials per environment**
   - Dev: Use test network credentials
   - Production: Use secured production credentials

## Troubleshooting

**Problem**: App connects but can't control devices
- **Cause**: Wrong credentials or no credentials provided
- **Solution**: Verify `MESH_NET_KEY` and `MESH_APP_KEY` match your mesh network

**Problem**: Warning appears in logs
- **Cause**: Credentials not provided at build time
- **Solution**: Add `--dart-define` flags to your build command

**Problem**: Can't find where to set credentials in code
- **Solution**: Don't! Credentials are injected at build time, not in code. Use `--dart-define` only.

## Technical Details

The app uses `String.fromEnvironment()` to read build-time constants:
```dart
const netKey = String.fromEnvironment('MESH_NET_KEY', defaultValue: '');
const appKey = String.fromEnvironment('MESH_APP_KEY', defaultValue: '');
```

These values are compiled into the binary at build time and cannot be changed without rebuilding the app.

## Integration Point

All credentials are passed through `DeviceManager.setMeshCredentials()`:
- Called once during `DeviceManager` initialization
- Initializes `meshClient` with provided credentials
- Credentials stored in memory only (never persisted to disk)
