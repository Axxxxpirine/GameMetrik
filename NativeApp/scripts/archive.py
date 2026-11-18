#!/usr/bin/env python3
"""Create a local Xcode archive of the already signed native app. No upload."""
import datetime, pathlib, plistlib, subprocess
root = pathlib.Path(__file__).resolve().parent.parent
app = root/'dist/GameMetrik Native.app'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
archive = root/'dist'/('GameMetrik Native-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.xcarchive')
(archive/'Products/Applications').mkdir(parents=True)
subprocess.run(['ditto',str(app),str(archive/'Products/Applications/GameMetrik Native.app')],check=True)
metadata = {'ApplicationProperties':{'ApplicationPath':'Applications/GameMetrik Native.app','Architectures':['arm64'],'CFBundleIdentifier':info['CFBundleIdentifier'],'CFBundleShortVersionString':info['CFBundleShortVersionString'],'CFBundleVersion':info['CFBundleVersion'],'Team':info['GMKeychainAccessGroup'].split('.')[0]},'ArchiveVersion':2,'CreationDate':datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),'Name':'GameMetrik Native','SchemeName':'GameMetrikNative'}
(archive/'Info.plist').write_bytes(plistlib.dumps(metadata))
print(archive)
