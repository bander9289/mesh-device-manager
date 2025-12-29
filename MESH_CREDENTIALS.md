# Mesh Credentials Configuration

## Overview
The app requires BLE Mesh network credentials (`netKey` and `appKey`) to communicate with mesh devices. These are configured at build time using Flutter's `--dart-define` feature to keep secrets out of the codebase.

## Configuration Methods

### 1. Command Line (Development)
Load credentials from environment variables:

```bash
# Load from .env file
export $(cat .env | xargs)
flutter run \
  --dart-define=MESH_NET_KEY=$MESH_NET_KEY \
  --dart-define=MESH_APP_KEY=$MESH_APP_KEY
```

Or for release builds:
```bash
# Load production credentials
export $(cat .env.production | xargs)
flutter build apk \
  --dart-define=MESH_NET_KEY=$MESH_NET_KEY \
  --dart-define=MESH_APP_KEY=$MESH_APP_KEY
```

### 2. Environment Variables (Recommended)
Set environment variables from a secure source and reference them:

```bash
# Load from .env file (add .env to .gitignore!)
export $(cat .env | xargs)

flutter run \
  --dart-define=MESH_NET_KEY=$MESH_NET_KEY \
  --dart-define=MESH_APP_KEY=$MESH_APP_KEY
```

### 3. VS Code Configuration
Add to `.vscode/launch.json` to load credentials from environment:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Flutter (with mesh credentials)",
      "request": "launch",
      "type": "dart",
      "args": [
        "--dart-define=MESH_NET_KEY=${env:MESH_NET_KEY}",
        "--dart-define=MESH_APP_KEY=${env:MESH_APP_KEY}"
      ]
    }
  ]
}
```

**Note:** Load your environment variables before launching VS Code:
```bash
export $(cat .env | xargs)
code .
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

**⚠️ IMPORTANT**: These are TEST credentials only (the same ones previously hard-coded). 
**Never commit PRODUCTION credentials to version control!**

## Secure Credential Distribution

### For Developers

**Option 1: Team Password Manager** (Recommended)
- Store production credentials in 1Password, LastPass, Bitwarden, etc.
- Create a shared vault for "Nordic Mesh Production Keys"
- Each developer retrieves and creates their local `.env` file
- Credentials never touch git

**Option 2: Secure Documentation**
- Store in company wiki/docs with access control
- Use encryption for the document
- Track who has access
- Rotate credentials when team members leave

**Option 3: Encrypted Sharing**
- Share via encrypted email or secure chat
- Use tools like GPG, age, or sops
- Delete messages after receipt
- Each developer creates local `.env` from shared info

**Best Practice Setup:**
```bash
# Each developer does this once:
cp .env.example .env
# Then edit .env with production credentials from team password manager
# .env is in .gitignore so it won't be committed
```

### For CI/CD Systems

**GitHub Actions:**
```yaml
# .github/workflows/build.yml
- name: Build APK
  run: |
    flutter build apk \
      --dart-define=MESH_NET_KEY=${{ secrets.MESH_NET_KEY }} \
      --dart-define=MESH_APP_KEY=${{ secrets.MESH_APP_KEY }}
```
Store secrets in: Settings → Secrets and variables → Actions

**GitLab CI:**
```yaml
# .gitlab-ci.yml
build:
  script:
    - flutter build apk
      --dart-define=MESH_NET_KEY=$MESH_NET_KEY
      --dart-define=MESH_APP_KEY=$MESH_APP_KEY
```
Store variables in: Settings → CI/CD → Variables (mark as "Masked" and "Protected")

**Jenkins:**
```groovy
withCredentials([
  string(credentialsId: 'mesh-net-key', variable: 'MESH_NET_KEY'),
  string(credentialsId: 'mesh-app-key', variable: 'MESH_APP_KEY')
]) {
  sh '''
    flutter build apk \
      --dart-define=MESH_NET_KEY=$MESH_NET_KEY \
      --dart-define=MESH_APP_KEY=$MESH_APP_KEY
  '''
}
```
Store in: Credentials → System → Global credentials

**Azure DevOps:**
```yaml
# azure-pipelines.yml
- script: |
    flutter build apk \
      --dart-define=MESH_NET_KEY=$(MESH_NET_KEY) \
      --dart-define=MESH_APP_KEY=$(MESH_APP_KEY)
  env:
    MESH_NET_KEY: $(MESH_NET_KEY)
    MESH_APP_KEY: $(MESH_APP_KEY)
```
Store in: Pipelines → Library → Variable groups (lock icon for secrets)

## Missing Credentials Behavior

If credentials are not provided:
- App will start but show a warning in debug mode
- Mesh operations will fail gracefully
- Empty credentials will be passed to `meshClient.initialize()`
- Check logs for: `⚠️  WARNING: Mesh credentials not configured!`

## Security Best Practices

1. **Separate test and production credentials**
   - Test credentials (like those in `.env.example`) are safe to share/commit
   - Production credentials must NEVER be committed to git
   - Use different keys for dev/staging/production environments

2. **Use team secret management**
   - Store production keys in 1Password, LastPass, Bitwarden, etc.
   - Share via password manager vaults, not email/chat
   - Revoke access when team members leave

3. **Rotate credentials regularly**
   - Rebuild and redeploy when credentials change
   - No need to modify code
   - Update secrets in CI/CD systems

4. **Use different credentials per environment**
   - Dev: Use test network credentials (can be in `.env.example`)
   - Staging: Use staging network credentials (CI secrets)
   - Production: Use secured production credentials (CI secrets)

5. **Audit access**
   - Know who has production credentials
   - Log when credentials are retrieved
   - Rotate immediately on suspected compromise

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
