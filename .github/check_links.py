#!/usr/bin/env python3
"""Fail if a relative link in a tracked markdown file points at nothing."""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = ["README.md", "TUTORIAL.md", "TESTPLAN.md"]
LINK = re.compile(r"\]\(([^)\s]+)\)")
SKIP = ("http://", "https://", "mailto:", "#", "/")

bad = []
for doc in DOCS:
    path = os.path.join(ROOT, doc)
    if not os.path.exists(path):
        continue
    text = open(path, encoding="utf-8").read()
    for match in LINK.finditer(text):
        target = match.group(1).split("#", 1)[0]
        if not target or target.startswith(SKIP):
            continue
        if not os.path.exists(os.path.join(ROOT, target)):
            bad.append(f"{doc}: {target}")

if bad:
    print("broken local links:")
    for item in bad:
        print("  " + item)
    sys.exit(1)
print("all local links ok")
