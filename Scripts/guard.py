"""Check repository trust boundaries without reading user configuration."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
for path in (root / ".github/workflows").glob("*.yml"):
    for action in re.findall(r"uses:\s*(\S+)", path.read_text(encoding="utf-8")):
        if not re.fullmatch(r"[\w./-]+@[0-9a-f]{40}", action):
            raise SystemExit(f"{path}: action must be pinned by commit: {action}")
# Aero is the system's WebKit plus its own code. A package dependency needs a decision, not a drive-by.
manifest = (root / "Package.swift").read_text(encoding="utf-8")
if re.search(r"\.package\s*\(", manifest):
    raise SystemExit("Package.swift: Aero has no package dependencies; see AGENTS.md before adding one")
print("repository guards passed")
