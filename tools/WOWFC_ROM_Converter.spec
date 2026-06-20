# -*- mode: python ; coding: utf-8 -*-

import os
import PyInstaller.config
tools_dir = os.path.abspath('Tools')
repo_dir = os.path.dirname(tools_dir)
addon_dir = os.path.join(repo_dir, 'WowFC')
PyInstaller.config.CONF['distpath'] = addon_dir
PyInstaller.config.CONF['workpath'] = os.path.join(tools_dir, 'build')


a = Analysis(
    [os.path.join(tools_dir, 'convert_roms.py')],
    pathex=[tools_dir],
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
    a.binaries,
    a.datas,
    [],
    name='WowFC_ROM_Converter',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
