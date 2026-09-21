"""Check repository trust boundaries without reading user configuration."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
for path in (root / ".github/workflows").glob("*.yml"):
    for action in re.findall(r"uses:\s*(\S+)", path.read_text(encoding="utf-8")):
        if not re.fullmatch(r"[\w./-]+@[0-9a-f]{40}", action):
            raise SystemExit(f"{path}: action must be pinned by commit: {action}")
# Sparkle is the approved exception for authenticated updates. Keep the version and resolved source pinned.
manifest = (root / "Package.swift").read_text(encoding="utf-8")
packages = re.findall(r"\.package\s*\((.*?)\)", manifest, re.S)
allowed = r'\s*url:\s*"https://github.com/sparkle-project/Sparkle"\s*,\s*exact:\s*"2\.10\.0"\s*'
if len(packages) != 1 or not re.fullmatch(allowed, packages[0]):
    raise SystemExit("Package.swift: only the approved, exact Sparkle version is allowed")
resolved = root / "Package.resolved"
if not resolved.exists():
    raise SystemExit("Package.resolved: resolve and commit the approved dependency")
pins = json.loads(resolved.read_text())["pins"]
if len(pins) != 1 or pins[0]["identity"] != "sparkle" or pins[0]["state"] != {
    "revision": "eef1a539a373c1f1a320624b1130fc5de7b2e100", "version": "2.10.0"
}:
    raise SystemExit("Package.resolved: unexpected dependency or Sparkle revision")
print("repository guards passed")
