#!/usr/bin/env python3
"""Apply Concept's checked-in patches to pinned build-rule submodules."""

from pathlib import Path
import subprocess


def apply_patches(source_root):
    source_root = Path(source_root)
    target = source_root / 'build-system/bazel-rules/rules_apple'
    patch = source_root / 'build-system/bazel-patches/rules-apple-unsigned-device.patch'
    command = ['git', '-C', str(target), 'apply']
    if subprocess.run(command + ['--reverse', '--check', str(patch)], capture_output=True).returncode == 0:
        return
    subprocess.run(command + ['--check', str(patch)], check=True)
    subprocess.run(command + [str(patch)], check=True)


if __name__ == '__main__':
    apply_patches(Path(__file__).resolve().parents[2])
