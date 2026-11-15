#!/usr/bin/env python3
"""Run the actual keepalive body against host audio/application doubles.

This does not test iOS background execution or battery usage. Imports are the only
platform seam; no production control flow is replaced. The scratch directory is
outside the checkout so app sources remain unchanged during builds.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(scratch):
    sources = scratch / "Sources/ConceptNotifications"
    tests = scratch / "Tests"
    sources.mkdir(parents=True, exist_ok=True)
    tests.mkdir(exist_ok=True)
    for source in (ROOT / "submodules/ConceptNotifications/Sources").glob("*.swift"):
        destination = sources / source.name
        if not destination.exists():
            destination.symlink_to(source)
    for source in (ROOT / "submodules/ConceptNotifications/Tests").glob("*.swift"):
        destination = tests / source.name
        if not destination.exists():
            destination.symlink_to(source)
    body = (ROOT / "submodules/TelegramUI/Sources/ConceptBackgroundKeepAlive.swift").read_text()
    body = "\n".join(line for line in body.splitlines() if not line.startswith("import "))
    body = body.replace("final class ConceptBackgroundKeepAlive:",
                        "private final class ConceptBackgroundKeepAlive:", 1)
    template = (ROOT / "Tests/ConceptKeepAliveHost/KeepAliveLifecycleTests.swift.in").read_text()
    (tests / "KeepAliveLifecycleTests.swift").write_text(
        template.replace("// INSERT_PRODUCTION_KEEPALIVE", body))
    signal_path = json.dumps(str(ROOT / "submodules/SSignalKit"))
    manifest = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ConceptKeepAliveHost", platforms: [.macOS(.v13)],
    dependencies: [.package(path: SIGNAL_PATH)], targets: [
    .target(name: "ConceptNotifications",
        dependencies: [.product(name: "SwiftSignalKit", package: "SSignalKit")],
        path: "Sources/ConceptNotifications"),
    .testTarget(name: "ConceptNotificationsTests",
        dependencies: ["ConceptNotifications", .product(name: "SwiftSignalKit", package: "SSignalKit")],
        path: "Tests")])
'''
    (scratch / "Package.swift").write_text(manifest.replace("SIGNAL_PATH", signal_path))
    environment = os.environ.copy()
    xcode = Path("/Applications/Xcode.app/Contents/Developer")
    if "DEVELOPER_DIR" not in environment and xcode.is_dir():
        environment["DEVELOPER_DIR"] = str(xcode)
    return subprocess.call(["xcrun", "swift", "test", "--package-path", str(scratch)], env=environment)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", type=Path, help="Persistent external scratch directory for incremental runs")
    args = parser.parse_args()
    if args.scratch:
        scratch = args.scratch.resolve()
        if scratch == ROOT or ROOT in scratch.parents:
            parser.error("scratch must be outside the repository")
        raise SystemExit(run(scratch))
    with tempfile.TemporaryDirectory(prefix="concept-keepalive-tests-") as temporary:
        raise SystemExit(run(Path(temporary)))
