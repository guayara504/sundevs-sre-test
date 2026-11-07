#!/usr/bin/env python3
"""Empaqueta las Lambdas en build/<nombre>.zip de forma reproducible.

- Dependencias para Lambda arm64 / Python 3.12 (wheels manylinux aarch64),
  independiente del SO donde se construya (Windows, macOS o el runner).
- Zip determinista (orden y timestamps fijos): mismo codigo -> mismo hash,
  asi Terraform no redespliega si nada cambio.

Uso: python scripts/build_lambda.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
BUILD = ROOT / "build"
FIXED_DATE = (2020, 1, 1, 0, 0, 0)
FUNCTIONS = ["processor", "health_canary", "dr_orchestrator"]
EXCLUDE_DIRS = {"__pycache__", ".pytest_cache"}
EXCLUDE_SUFFIXES = {".pyc", ".pyo"}


def install_requirements(requirements: Path, target: Path) -> None:
    subprocess.run(
        [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--quiet",
            "--disable-pip-version-check",
            "--no-compile",
            "--requirement",
            str(requirements),
            "--target",
            str(target),
            "--platform",
            "manylinux2014_aarch64",
            "--implementation",
            "cp",
            "--python-version",
            "3.12",
            "--only-binary=:all:",
            "--upgrade",
        ],
        check=True,
    )


def deterministic_zip(source: Path, destination: Path) -> None:
    files = sorted(
        p
        for p in source.rglob("*")
        if p.is_file() and not (set(p.relative_to(source).parts) & EXCLUDE_DIRS) and p.suffix not in EXCLUDE_SUFFIXES
    )
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in files:
            info = zipfile.ZipInfo(path.relative_to(source).as_posix(), date_time=FIXED_DATE)
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, path.read_bytes())


def build(name: str) -> Path:
    source = SRC / name
    staging = BUILD / "staging" / name
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    for item in source.iterdir():
        if item.name in EXCLUDE_DIRS or item.name == "requirements.txt":
            continue
        if item.is_dir():
            shutil.copytree(item, staging / item.name)
        else:
            shutil.copy2(item, staging / item.name)

    requirements = source / "requirements.txt"
    if requirements.exists():
        install_requirements(requirements, staging)

    artifact = BUILD / f"{name}.zip"
    deterministic_zip(staging, artifact)
    return artifact


def main() -> None:
    BUILD.mkdir(exist_ok=True)
    for name in FUNCTIONS:
        artifact = build(name)
        print(f"built {artifact.relative_to(ROOT)} ({artifact.stat().st_size // 1024} KiB)")


if __name__ == "__main__":
    main()
