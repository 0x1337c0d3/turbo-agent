#!/usr/bin/env bash
set -euo pipefail

# Packages and signs TurboFieldfareAgent.app with the Apple Private Cloud Compute (PCC)
# managed provisioning profile and matching keychain identity.

CONFIG="${1:-release}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_PATH="$ROOT_DIR/.build/$CONFIG/TurboFieldfareAgent"
APP_PATH="$ROOT_DIR/.build/$CONFIG/TurboFieldfareAgent.app"
ENTITLEMENTS="$ROOT_DIR/TurboFieldfareAgent.entitlements"

if [ ! -f "$BIN_PATH" ]; then
    echo "Error: Binary not found at $BIN_PATH"
    echo "Build it first: swift build -c $CONFIG"
    exit 1
fi

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "Error: Entitlements not found at $ENTITLEMENTS"
    exit 1
fi

# Find the latest provisioning profile containing the PCC entitlement
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROFILE_PATH=""
if [ -d "$PROFILE_DIR" ]; then
    for p in "$PROFILE_DIR"/*.provisionprofile "$PROFILE_DIR"/*.mobileprovision; do
        if [ -f "$p" ] && security cms -D -i "$p" 2>/dev/null | grep -q "com.apple.developer.private-cloud-compute"; then
            PROFILE_PATH="$p"
            break
        fi
    done
fi

if [ -z "$PROFILE_PATH" ]; then
    echo "Error: No provisioning profile with 'com.apple.developer.private-cloud-compute' found in $PROFILE_DIR"
    exit 1
fi

echo "Using Provisioning Profile: $(basename "$PROFILE_PATH")"

# Automatically find keychain identity that matches the certificates in the provisioning profile
IDENTITY=$(python3 -c '
import plistlib, subprocess, tempfile, sys

profile_path = sys.argv[1]
try:
    profile_data = subprocess.check_output(["security", "cms", "-D", "-i", profile_path])
    plist = plistlib.loads(profile_data)
    keychain_output = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"]).decode()
    matched = None
    for cert_der in plist.get("DeveloperCertificates", []):
        with tempfile.NamedTemporaryFile() as f:
            f.write(cert_der)
            f.flush()
            sha1 = subprocess.check_output(["openssl", "x509", "-inform", "der", "-in", f.name, "-noout", "-fingerprint"]).decode().split("=")[1].replace(":", "").strip()
            for line in keychain_output.splitlines():
                if sha1 in line and "\"" in line:
                    matched = line.split("\"")[1]
                    break
        if matched:
            break
    if matched:
        print(matched)
    else:
        sys.exit(1)
except Exception as e:
    sys.exit(1)
' "$PROFILE_PATH")

if [ -z "$IDENTITY" ]; then
    echo "Error: Could not find matching keychain certificate for the provisioning profile."
    exit 1
fi

echo "Signing with matching identity: $IDENTITY"

# Assemble bundle
mkdir -p "$APP_PATH/Contents/MacOS"
cp -f "$BIN_PATH" "$APP_PATH/Contents/MacOS/TurboFieldfareAgent"
cp -f "$PROFILE_PATH" "$APP_PATH/Contents/embedded.provisionprofile"

cat << 'EOF' > "$APP_PATH/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TurboFieldfareAgent</string>
    <key>CFBundleIdentifier</key>
    <string>com.onereddog.turbofieldfareagent</string>
    <key>CFBundleName</key>
    <string>TurboFieldfareAgent</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF

# Sign binary and bundle
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_PATH/Contents/MacOS/TurboFieldfareAgent"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "Successfully packaged and signed: $APP_PATH"
echo "Run with PCC:"
echo "  $APP_PATH/Contents/MacOS/TurboFieldfareAgent --backend apple --pcc require"
