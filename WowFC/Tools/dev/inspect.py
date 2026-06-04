import os
roms = r'd:\World of Warcraft\_retail_\Interface\AddOns\WowFC\ROMs'
targets = ['1943.nes', '街头霸王II.nes', '街头霸王III.nes', 'Tetris (USA) (Tengen) (Unl).nes']
for name in targets:
    p = os.path.join(roms, name)
    if not os.path.exists(p):
        print(f"{name}: MISSING ON DISK")
        continue
    with open(p, 'rb') as f:
        d = f.read(16)
    size = os.path.getsize(p)
    print(f"{name}: first16={d.hex()} size={size}")
    if d[0:4] == b'NES\x1a':
        prg, chr_, c1, c2 = d[4], d[5], d[6], d[7]
        mapper = (c1 >> 4) | (c2 & 0xF0)
        print(f"   PRG16k={prg} CHR8k={chr_} ctrl1={c1:02X} ctrl2={c2:02X} mapper={mapper}")
    else:
        print(f"   NOT standard iNES magic at offset 0")
