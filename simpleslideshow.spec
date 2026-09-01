# -*- mode: python ; coding: utf-8 -*-

# List of heavy Qt framework binaries to explicitly purge from the bundle
QT_BINARIES_TO_REMOVE = {
    'Qt3D', 'Qt3DRender', 'Qt3DCore', 'Qt3DExtras', 'Qt3DInput', 'Qt3DLogic',
    'Qt3DAnimation', 'QtQml', 'QtQuick', 'QtQuickWidgets', 'QtWebEngineCore',
    'QtWebEngineWidgets', 'QtWebEngine', 'QtBluetooth', 'QtDesigner',
    'QtHelp', 'QtLocation', 'QtNfc', 'QtPositioning', 'QtQuickTest',
    'QtSensors', 'QtSerialPort', 'QtSql', 'QtSvg', 'QtTest', 'QtVirtualKeyboard',
    'QtWebChannel', 'QtWebSockets', 'QtXml'
}

a = Analysis(
    ['simpleslideshow.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'PyQt6.Qt3D', 'PyQt6.QtQml', 'PyQt6.QtQuick', 'PyQt6.QtWebEngineCore',
        'PyQt6.QtWebEngineWidgets', 'tkinter', 'unittest', 'pydoc', 'doctest'
    ],
    noarchive=False,
    optimize=2,
)

# --- DIRECT BINARY PURGE ---
# Strip out unused native .dylib files that PyInstaller collects by default
filtered_binaries = []
for item in a.binaries:
    name = item[0]
    if not any(qt_mod in name for qt_mod in QT_BINARIES_TO_REMOVE):
        filtered_binaries.append(item)
a.binaries = filtered_binaries

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='SimpleSlideshow',
    debug=False,
    bootloader_ignore_signals=False,
    strip=True,
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
    strip=True,
    upx=True,
    upx_exclude=[],
    name='SimpleSlideshow',
)

app = BUNDLE(
    coll,
    name='SimpleSlideshow.app',
    icon='app_icon.icns',
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