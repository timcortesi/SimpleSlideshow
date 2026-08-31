# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['simpleslideshow.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='SimpleSlideshow',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=True,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='SimpleSlideshow',
)
app = BUNDLE(
    coll,
    name='SimpleSlideshow.app',
    icon=None,
    bundle_identifier='com.simpleslideshow.app',
    info_plist={
        'CFBundleDocumentTypes': [
            {
                'CFBundleTypeExtensions': ['*'],
                'CFBundleTypeRole': 'Viewer',
                'LSHandlerRank': 'Alternate',
            }
        ],
    },
)
