#!/usr/bin/env python3
"""Embed Sparkle and sign its nested helpers before signing the enclosing application."""

import pathlib
import plistlib
import re
import shutil
import subprocess
import sys


def run(*args):
    """Run packaging tools with argument boundaries intact, including identities containing spaces."""
    subprocess.run(args, check=True)


def main():
    app = pathlib.Path(sys.argv[1])
    identity = sys.argv[2]
    artifacts = pathlib.Path(".build/artifacts/sparkle")
    candidates = list(artifacts.glob("**/macos-*/Sparkle.framework"))
    if len(candidates) != 1:
        raise SystemExit("Expected one resolved macOS Sparkle framework; run swift package resolve")
    target = app / "Contents/Frameworks/Sparkle.framework"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(candidates[0], target, symlinks=True)
    shutil.copyfile(candidates[0].parents[2] / "LICENSE", app / "Contents/Resources/Sparkle-LICENSE.txt")
    options = ["--force", "--options", "runtime", "--sign", identity]
    if identity != "-":
        options.append("--timestamp")
    version = target / "Versions/B"
    for relative in ["XPCServices/Installer.xpc", "XPCServices/Downloader.xpc", "Autoupdate", "Updater.app"]:
        path = version / relative
        if path.exists():
            run("codesign", *options, "--preserve-metadata=entitlements", str(path))
    run("codesign", *options, str(target))

    # Packaged apps must use their embedded framework, not an absolute SwiftPM artifact path.
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    commands = subprocess.check_output(["otool", "-l", str(executable)], text=True)
    for path in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", commands):
        if path.startswith("/") and ".build" in path:
            run("install_name_tool", "-delete_rpath", path, str(executable))


if __name__ == "__main__":
    main()
