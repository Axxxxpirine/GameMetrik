#!/usr/bin/env python3
"""Package a sandboxed, provisioned app. Never silently fall back to ad-hoc signing.

GAMEMETRIK_DEMO_BUILD=1 is the explicit exception for people without an Apple developer profile:
a separate "GameMetrik Demo.app", ad-hoc signed, without keychain group or URL scheme. It opens the
demonstration data only and cannot store connections."""
import datetime, fnmatch, hashlib, json, os, pathlib, plistlib, re, shutil, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parent.parent
bundle_id = 'ch.gamemetrik.native'
demo = os.environ.get('GAMEMETRIK_DEMO_BUILD') == '1'
# A distinct identifier keeps the demonstration away from the real app's preferences and URL scheme.
if demo: bundle_id += '.demo'
def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout
identities = run('security', 'find-identity', '-v', '-p', 'codesigning').decode()
available = re.findall(r'\d+\) ([A-F0-9]{40}) "([^"]+)"', identities)
requested = os.environ.get('GAMEMETRIK_SIGNING_IDENTITY')
if requested: available = [item for item in available if requested in item]
available.sort(key=lambda item: (not item[1].startswith('Developer ID Application:'), item[1]))
profiles = []
if os.environ.get('GAMEMETRIK_SIGNING_PROFILE'):
    profiles = [pathlib.Path(os.environ['GAMEMETRIK_SIGNING_PROFILE'])]
else:
    for folder in ['Library/Developer/Xcode/UserData/Provisioning Profiles', 'Library/MobileDevice/Provisioning Profiles']:
        profiles.extend((pathlib.Path.home()/folder).glob('*.provisionprofile'))
choice = None
for identity, name in available:
    for path in profiles:
        try: profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(path)))
        except (subprocess.CalledProcessError, plistlib.InvalidFileException): continue
        if profile.get('ExpirationDate', datetime.datetime.min) <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None): continue
        if identity not in [hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])]: continue
        team = profile['TeamIdentifier'][0]
        entitlement = profile.get('Entitlements', {})
        if not fnmatch.fnmatchcase(team+'.'+bundle_id, entitlement.get('com.apple.application-identifier', '')): continue
        if not any(fnmatch.fnmatchcase(team+'.'+bundle_id, group) for group in entitlement.get('keychain-access-groups', [])): continue
        if name.startswith('Developer ID Application:') and not profile.get('ProvisionsAllDevices'): continue
        choice = identity, name, team, path
        break
    if choice: break
if not choice and not demo: raise SystemExit('Aucune identité Apple avec profil macOS valide pour GameMetrik. Configurer GAMEMETRIK_SIGNING_IDENTITY et GAMEMETRIK_SIGNING_PROFILE ; aucune signature ad hoc de secours.')
identity, name, team, profile = ('-', 'Ad hoc', '', None) if demo else choice
binary = pathlib.Path(run('xcrun', 'swift', 'build', '--package-path', str(root), '-c', 'release', '--show-bin-path').decode().strip())/'GameMetrikNative'
dist = root/'dist'; dist.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.stage-', dir=dist) as stage:
    app = pathlib.Path(stage)/('GameMetrik Demo.app' if demo else 'GameMetrik Native.app')
    contents = app/'Contents'; (contents/'MacOS').mkdir(parents=True); (contents/'Resources').mkdir()
    shutil.copy2(binary, contents/'MacOS/GameMetrikNative')
    shutil.copy2(root.parent/'native/GameMetrik.icns', contents/'Resources/GameMetrik.icns')
    shutil.copy2(root/'CONNEXION.md', contents/'Resources/CONNEXION.md')
    if profile: shutil.copy2(profile, contents/'embedded.provisionprofile')
    info = dict(CFBundleName='GameMetrik Native', CFBundleDisplayName='GameMetrik Native', CFBundleIdentifier=bundle_id, CFBundleExecutable='GameMetrikNative', CFBundlePackageType='APPL', CFBundleShortVersionString='0.19.2', CFBundleVersion='35', CFBundleIconFile='GameMetrik', LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True, CFBundleDevelopmentRegion='fr', CFBundleLocalizations=['fr','en'], GMKeychainAccessGroup=team+'.'+bundle_id, NSHumanReadableCopyright='GameMetrik',
        # Synchronization requested by Claude or Codex; refused without the token kept in the AI folder.
        CFBundleURLTypes=[{'CFBundleURLName': bundle_id + '.ia', 'CFBundleURLSchemes': ['gamemetrik-native']}])
    if demo:
        del info['GMKeychainAccessGroup'], info['CFBundleURLTypes']
        info['CFBundleName'] = info['CFBundleDisplayName'] = 'GameMetrik Demo'
    (contents/'Info.plist').write_bytes(plistlib.dumps(info))
    entitlements = {'com.apple.security.app-sandbox':True, 'com.apple.security.network.client':True,
        'com.apple.security.files.user-selected.read-write':True,
        'com.apple.security.files.bookmarks.app-scope':True,
        'com.apple.application-identifier':team+'.'+bundle_id,
        'com.apple.developer.team-identifier':team,
        'keychain-access-groups':[team+'.'+bundle_id]}
    if demo:
        for key in ['com.apple.application-identifier', 'com.apple.developer.team-identifier', 'keychain-access-groups']: del entitlements[key]
    entitlements_file = pathlib.Path(stage)/'entitlements.plist'; entitlements_file.write_bytes(plistlib.dumps(entitlements))
    command = ['codesign','--force','--options','runtime','--sign',identity,'--entitlements',str(entitlements_file)]
    if name.startswith('Developer ID Application:'): command.append('--timestamp')
    run(*command, str(app)); run('codesign','--verify','--deep','--strict',str(app))
    destination = dist/app.name
    if destination.exists():
        previous = dist/'.previous'; previous.mkdir(exist_ok=True)
        destination.rename(previous/(destination.stem+'-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.app'))
    app.rename(destination)
    print(json.dumps({'application':str(destination), 'signature':name.split(':')[0], 'sandbox':True, 'hardenedRuntime':True, 'keychainGroup':None if demo else team+'.'+bundle_id, 'demonstration':demo, 'notarized':False}, ensure_ascii=False))
