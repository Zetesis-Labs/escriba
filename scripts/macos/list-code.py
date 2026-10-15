#!/usr/bin/env python3
"""List Mach-O files and nested bundles in inside-out signing order."""
import os
import sys

root = sys.argv[1]
magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
files = []
bundles = []
for directory, dirs, names in os.walk(root, followlinks=False):
    dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(directory, name)) and name != "_CodeSignature"]
    for name in names:
        path = os.path.join(directory, name)
        if os.path.islink(path):
            continue
        with open(path, "rb") as stream:
            if stream.read(4) in magic:
                files.append(path)
    for name in dirs:
        if name.endswith((".framework", ".app", ".xpc", ".appex", ".bundle")):
            bundles.append(os.path.join(directory, name))
for path in sorted(files, key=lambda item: (-item.count(os.sep), item)):
    sys.stdout.buffer.write(path.encode() + b"\0")
for path in sorted(bundles, key=lambda item: (-item.count(os.sep), item)):
    sys.stdout.buffer.write(path.encode() + b"\0")
