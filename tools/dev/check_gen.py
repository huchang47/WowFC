import os, re
f = r'd:\World of Warcraft\_retail_\Interface\AddOns\WowFC\Utils\ROMData_Generated.lua'
print("FileBytes =", os.path.getsize(f))
with open(f, 'r', encoding='utf-8') as fh:
    text = fh.read()
# find all entry headers
for m in re.finditer(r'WOWFC_ROM_DATA\[(".*?")\]\s*=\s*\{', text):
    print("ENTRY:", m.group(1))
# Count bytes per entry by parsing 0x.. tokens between braces is heavy; just report comment sizes
for m in re.finditer(r'-- ROM: (.*?) \((\d+) bytes\)', text):
    print("DECLARED:", m.group(1), m.group(2))
