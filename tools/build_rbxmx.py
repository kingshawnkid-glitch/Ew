#!/usr/bin/env python3
"""
Packages the Luau source tree into Roblox XML model files (.rbxmx) that can be
inserted into Studio without Rojo (right-click the target service >
"Insert from File...", or drag the file into the Explorer).

Naming rules (same as Rojo):
  *.server.luau -> Script
  *.client.luau -> LocalScript
  *.luau        -> ModuleScript
  directory     -> Folder

Usage:  python3 tools/build_rbxmx.py            (writes build/*.rbxmx)
"""
import os
import sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build")

TARGETS = [
    # (source dir, top-level instance name, output file, destination hint)
    ("src/ReplicatedStorage/EWShared", "EWShared", "EWShared.rbxmx", "ReplicatedStorage"),
    ("src/ServerScriptService/EWServer", "EWServer", "EWServer.rbxmx", "ServerScriptService"),
    ("src/StarterPlayerScripts/EWClient", "EWClient", "EWClient.rbxmx", "StarterPlayer > StarterPlayerScripts"),
    ("src/StarterPlayerScripts/EWInteractionMenu", "EWInteractionMenu", "EWInteractionMenu.rbxmx",
     "StarterPlayer > StarterPlayerScripts"),
]
SINGLE_FILES = []

_ref = 0


def next_ref():
    global _ref
    _ref += 1
    return "RBX%08X" % _ref


def cdata(source):
    # "]]>" cannot appear inside CDATA; split it across two sections.
    return "<![CDATA[" + source.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def script_item(path, indent):
    name = os.path.basename(path)
    if name.endswith(".server.luau"):
        cls, inst = "Script", name[: -len(".server.luau")]
    elif name.endswith(".client.luau"):
        cls, inst = "LocalScript", name[: -len(".client.luau")]
    elif name.endswith(".luau"):
        cls, inst = "ModuleScript", name[: -len(".luau")]
    else:
        return None
    with open(path, "r", encoding="utf-8") as f:
        source = f.read()
    pad = "\t" * indent
    lines = [
        f'{pad}<Item class="{cls}" referent="{next_ref()}">',
        f"{pad}\t<Properties>",
        f'{pad}\t\t<string name="Name">{escape(inst)}</string>',
    ]
    if cls in ("Script", "LocalScript"):
        lines.append(f'{pad}\t\t<bool name="Disabled">false</bool>')
    lines.append(f'{pad}\t\t<ProtectedString name="Source">{cdata(source)}</ProtectedString>')
    lines.append(f"{pad}\t</Properties>")
    lines.append(f"{pad}</Item>")
    return "\n".join(lines)


def folder_item(path, name, indent):
    pad = "\t" * indent
    out = [
        f'{pad}<Item class="Folder" referent="{next_ref()}">',
        f"{pad}\t<Properties>",
        f'{pad}\t\t<string name="Name">{escape(name)}</string>',
        f"{pad}\t</Properties>",
    ]
    for entry in sorted(os.listdir(path)):
        full = os.path.join(path, entry)
        if os.path.isdir(full):
            out.append(folder_item(full, entry, indent + 1))
        else:
            item = script_item(full, indent + 1)
            if item:
                out.append(item)
    out.append(f"{pad}</Item>")
    return "\n".join(out)


HEADER = ('<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
          'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
          'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">')


def write(filename, body):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, filename), "w", encoding="utf-8", newline="\n") as f:
        f.write(HEADER + "\n" + body + "\n</roblox>\n")


def main():
    for src, name, filename, dest in TARGETS:
        write(filename, folder_item(os.path.join(ROOT, src), name, 1))
        print(f"build/{filename:32s} -> insert into {dest}")
    for src, filename, dest in SINGLE_FILES:
        write(filename, script_item(os.path.join(ROOT, src), 1))
        print(f"build/{filename:32s} -> insert into {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
