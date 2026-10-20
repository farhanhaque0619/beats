"""Post-processes the XcodeGen output.

XcodeGen gives the second target that shares a synchronized folder its own copy of the
group with a temporary "TEMP_..." identifier. Point every target at the first group and drop
the copies so Xcode sees one App folder shared by both targets.
"""
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "Ink.xcodeproj/project.pbxproj"
text = open(path).read()

groups = re.findall(r'\n\t\t("?[\w-]+"?) /\* (\S+) \*/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;(.*?)\n\t\t\};', text, re.S)
by_path = {}
for ident, name, body in groups:
    m = re.search(r'path = ([^;]+);', body)
    by_path.setdefault(m.group(1) if m else name, []).append(ident)

for _, idents in by_path.items():
    keep, dupes = idents[0], idents[1:]
    for dupe in dupes:
        # Remove the duplicate object definition.
        text = re.sub(r'\n\t\t' + re.escape(dupe) + r' /\* \S+ \*/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;.*?\n\t\t\};', '', text, count=1, flags=re.S)
        # Re-point references.
        text = text.replace(dupe + ' /*', keep + ' /*')

# A target's list must not mention the same group twice.
def dedupe_lists(m):
    lines = m.group(2).split("\n")
    seen, out = set(), []
    for line in lines:
        key = line.strip()
        if key and key in seen:
            continue
        seen.add(key)
        out.append(line)
    return m.group(1) + "\n".join(out) + m.group(3)

text = re.sub(r'(fileSystemSynchronizedGroups = \()(.*?)(\);)', dedupe_lists, text, flags=re.S)
open(path, "w").write(text)
print("fix-project: synchronized groups:", {k: v[0] for k, v in by_path.items()})
