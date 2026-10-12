from pathlib import Path
import plistlib, zipfile, shutil
root = Path('work/swift-fixtures').resolve()
app = root / 'Applications 测试/WebStorm 测试.app'
pack = app / 'Contents/plugins/localization-zh'
(pack / 'lib').mkdir(parents=True, exist_ok=True)
(pack / 'resources/empty').mkdir(parents=True, exist_ok=True)
(app / 'Contents/Resources').mkdir(parents=True, exist_ok=True)
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='com.jetbrains.WebStorm',CFBundleName='WebStorm 测试',CFBundleVersion='2025.1'), f)
(app / 'Contents/Resources/build.txt').write_text('WS-251.20.123\n')
xml = b'''<idea-plugin><id>com.intellij.zh</id><name>Chinese</name><version>251.2</version><idea-version since-build='251.10' until-build='251.*'/><depends>com.intellij.modules.platform</depends><extensions defaultExtensionNs='com.intellij'><languageBundle locale='zh-CN' displayName='Chinese'/></extensions></idea-plugin>'''
with zipfile.ZipFile(pack / 'lib/main.jar', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('META-INF/plugin.xml', xml)
    z.writestr('messages/test.properties', b'hello=world' * 10000)
with zipfile.ZipFile(pack / 'lib/extra.jar', 'w', zipfile.ZIP_STORED) as z:
    z.writestr('extra.bin', bytes(range(256)))
(pack / 'LICENSE.txt').write_text('Preserved license')
(pack / '.hidden').write_text('preserved hidden file')
(pack / 'resources/数据.txt').write_text('测试内容')
for name in ['symlink', 'ambiguous', 'corrupt', 'dtd']:
    dst = root / name / app.name
    if dst.exists(): shutil.rmtree(dst)
    shutil.copytree(app, dst)
    p = dst / 'Contents/plugins/localization-zh'
    if name == 'symlink': (p / 'resources/link').symlink_to('/etc/passwd')
    if name == 'ambiguous':
        with zipfile.ZipFile(p / 'lib/other.jar', 'w') as z: z.writestr('META-INF/plugin.xml', xml.replace(b'251.2', b'251.3'))
    if name == 'corrupt': (p / 'lib/main.jar').write_bytes(b'not a ZIP')
    if name == 'dtd':
        with zipfile.ZipFile(p / 'lib/main.jar', 'w') as z:
            z.writestr('META-INF/plugin.xml', ('<!DOCTYPE idea-plugin [<!ENTITY x "abc">]>' + xml.decode()).encode('utf-16'))
(root / 'output').mkdir(exist_ok=True)
# Fixtures to validate reader rejection independently of the scanner.
for name, path in [('traversal','../escape'), ('absolute','/escape'), ('backslash','a\\b')]:
    with zipfile.ZipFile(root / (name + '.zip'), 'w') as z: z.writestr(path, 'bad')
with zipfile.ZipFile(root / 'duplicate.zip', 'w') as z:
    z.writestr('same', 'first'); z.writestr('same', 'second')
with zipfile.ZipFile(root / 'crc.zip', 'w') as z: z.writestr('data', b'ABCDEF')
b = bytearray((root / 'crc.zip').read_bytes()); b[34] ^= 1; (root / 'crc.zip').write_bytes(b)
