#!/usr/bin/env bash
set -euo pipefail
: "${IOS_CERTIFICATE_P12_BASE64:?Add the certificate secret}"
: "${IOS_CERTIFICATE_PASSWORD:?Add the certificate password secret}"
: "${IOS_PROVISION_PROFILE_BASE64:?Add the provisioning profile secret}"
: "${APPLE_TEAM_ID:?Add your Apple Developer team ID}"
: "${RUNNER_TEMP:?Run in GitHub Actions or set RUNNER_TEMP}"
: "${GITHUB_ENV:?Run in GitHub Actions or set GITHUB_ENV to an environment output file}"
KEYCHAIN_PATH="$RUNNER_TEMP/roxy-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP'])
for key, name in [('IOS_CERTIFICATE_P12_BASE64', 'roxy-certificate.p12'), ('IOS_PROVISION_PROFILE_BASE64', 'roxy.mobileprovision')]:
    (root / name).write_bytes(base64.b64decode(os.environ[key], validate=True))
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$RUNNER_TEMP/roxy-certificate.p12" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
security cms -D -i "$RUNNER_TEMP/roxy.mobileprovision" > "$RUNNER_TEMP/roxy-profile.plist"
python3 - <<'PY'
from datetime import datetime
from pathlib import Path
import os, plistlib, re, shutil, subprocess
root = Path(os.environ['RUNNER_TEMP'])
profile = plistlib.loads((root / 'roxy-profile.plist').read_bytes())
bundle = os.environ.get('ROXY_BUNDLE_ID', 'com.roxy.player')
team = os.environ['APPLE_TEAM_ID']
group = os.environ.get('ROXY_APP_GROUP', 'group.' + bundle)
if profile['ExpirationDate'] <= datetime.utcnow(): raise SystemExit('Provisioning profile has expired')
if team not in profile['TeamIdentifier']: raise SystemExit('APPLE_TEAM_ID does not match provisioning profile')
entitlements = profile['Entitlements']
prefix = profile.get('ApplicationIdentifierPrefix', [team])[0]
if entitlements.get('application-identifier') != prefix + '.' + bundle:
    raise SystemExit('Profile must explicitly match ROXY_BUNDLE_ID: ' + bundle)
if group not in entitlements.get('com.apple.security.application-groups', []):
    raise SystemExit('Enable the app group in the provisioning profile: ' + group)
method = os.environ.get('ROXY_EXPORT_METHOD', 'release-testing')
if method == 'debugging' and not entitlements.get('get-task-allow'):
    raise SystemExit('Debugging export needs a development provisioning profile')
if method == 'release-testing' and (not profile.get('ProvisionedDevices') or entitlements.get('get-task-allow')):
    raise SystemExit('Release-testing export needs an Ad Hoc distribution profile with registered devices')
if method == 'app-store-connect' and (profile.get('ProvisionedDevices') or entitlements.get('get-task-allow')):
    raise SystemExit('App Store export needs an App Store distribution profile')
profiles = Path.home() / 'Library/MobileDevice/Provisioning Profiles'
profiles.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'roxy.mobileprovision', profiles / (profile['UUID'] + '.mobileprovision'))
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning', str(root / 'roxy-signing.keychain-db')], text=True)
identity = re.search(r'\b([A-F0-9]{40})\b', identities)
if not identity: raise SystemExit('No valid code signing identity in certificate')
with open(os.environ['GITHUB_ENV'], 'a') as file:
    file.write('ROXY_SIGNING_IDENTITY=' + identity[1] + '\n')
    file.write('ROXY_PROFILE_NAME=' + profile['UUID'] + '\n')
    file.write('ROXY_PROFILE_UUID=' + profile['UUID'] + '\n')
PY
