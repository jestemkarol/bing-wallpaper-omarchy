"""Every Text in the panel whose content is not a literal must pin textFormat.

Panel.qml cannot be instantiated outside a running Omarchy shell, so the
rendering test next door proves the property on standalone Text elements
instead. This walks the real file and checks the elements that actually carry
feed data, which is the part a future edit is most likely to undo.
"""

import re
import sys

DYNAMIC = re.compile(r"root\.|Model\.|\.length|\bservice\b")


def blocks(source):
    """Yields (line_number, body) for each Text { ... }, matching braces."""
    for match in re.finditer(r"\bText\s*\{", source):
        depth, i = 0, match.end() - 1
        while i < len(source):
            if source[i] == "{":
                depth += 1
            elif source[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        yield source.count("\n", 0, match.start()) + 1, source[match.end():i]


def main(path):
    source = open(path, encoding="utf-8").read()
    offenders = []
    checked = 0
    for line, body in blocks(source):
        # The lookahead has to allow a dotted name, or "font.family: root.x"
        # on the next line is swallowed into the text binding and a literal
        # glyph looks dynamic.
        binding = re.search(r"^\s*text:(.*?)(?=^\s*[\w.]+\s*:|\Z)", body, re.S | re.M)
        if not binding or not DYNAMIC.search(binding.group(1)):
            continue
        checked += 1
        if "textFormat:" not in body:
            offenders.append(line)

    if checked == 0:
        print("no dynamic Text found in %s, the audit is not looking at anything" % path)
        return 1
    for line in offenders:
        print("%s:%d: dynamic text without textFormat" % (path, line))
    print("%d dynamic Text elements, %d unpinned" % (checked, len(offenders)))
    return 1 if offenders else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
