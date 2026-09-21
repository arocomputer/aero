#!/usr/bin/env python3
"""Refresh the bundled tracker-only list from Peter Lowe, retaining provenance for review."""

import datetime
import pathlib
import re
import urllib.request

SOURCE = "https://pgl.yoyo.org/as/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext&onlytrackers=1"


def main():
    """Reject unexpected input before replacing the reviewed, offline bundle resource."""
    with urllib.request.urlopen(SOURCE, timeout=60) as response:
        text = response.read(2_000_001).decode("utf-8")
    domains = set()
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 2 or fields[0] != "127.0.0.1" or not re.fullmatch(
            r"(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,63}", fields[1]
        ):
            raise ValueError("Unexpected tracker list format")
        domains.add(fields[1])
    if not 500 <= len(domains) <= 20_000:
        raise ValueError("Unexpected tracker list size")
    target = pathlib.Path(__file__).resolve().parents[1] / "Sources/Page/Trackers.txt"
    header = (
        "# Peter Lowe's tracker-only domain list. https://pgl.yoyo.org/as/\n"
        "# Redistribution permission and attribution: TrackerListNotice.txt\n"
        f"# Retrieved {datetime.date.today().isoformat()} from {SOURCE}\n"
    )
    target.write_text(header + "\n".join(sorted(domains)) + "\n", encoding="utf-8")
    print(f"Updated {len(domains)} tracker domains. Review the diff before shipping.")


if __name__ == "__main__":
    main()
