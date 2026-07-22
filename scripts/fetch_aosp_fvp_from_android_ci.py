#!/usr/bin/env python3
"""Resolve and extract an AOSP FVP product output from Android CI.

The resolver refuses generic GSI/Cuttlefish archives. A candidate is accepted only
when it contains kernel, combined-ramdisk.img, system-qemu.img and userdata.img.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Iterable

REQUIRED = ("kernel", "combined-ramdisk.img", "system-qemu.img", "userdata.img")
DEFAULT_BRANCHES = (
    "aosp-android15-release",
    "aosp-android15-qpr2-release",
    "aosp-android-latest-release",
    "aosp-main",
)
USER_AGENT = "Android-iOSEmulator-FVP-Resolver/1.0"
MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024 * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", choices=("mini", "full"), default="mini")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--diagnostics", required=True, type=Path)
    parser.add_argument("--branch", action="append", dest="branches")
    parser.add_argument("--status-json", type=Path, help="Local status.json for deterministic tests")
    parser.add_argument("--archive-url", help="Try one explicit Android CI artifact URL first")
    parser.add_argument("--max-artifacts", type=int, default=12)
    return parser.parse_args()


def request(url: str, *, timeout: int = 45) -> urllib.response.addinfourl:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
    return urllib.request.urlopen(req, timeout=timeout)


def fetch_json(url: str) -> dict[str, Any]:
    with request(url) as response:
        return json.load(response)


def fetch_text(url: str) -> str:
    with request(url) as response:
        return response.read().decode("utf-8", "replace")


def target_name(entry: dict[str, Any]) -> str:
    value = str(entry.get("name") or entry.get("ID") or entry.get("id") or "")
    if "." in value:
        value = value.rsplit(".", 1)[-1]
    return value


def build_number(value: Any) -> str | None:
    matches = re.findall(r"\d+", str(value or ""))
    return matches[-1] if matches else None


def ranked_targets(status: dict[str, Any], variant: str) -> list[tuple[int, str, str, dict[str, Any]]]:
    exact = (
        ("fvp_mini-userdebug", "fvp_mini-eng")
        if variant == "mini"
        else ("fvp-userdebug", "fvp-eng")
    )
    ranked: list[tuple[int, str, str, dict[str, Any]]] = []
    for entry in status.get("targets", []):
        if not isinstance(entry, dict):
            continue
        name = target_name(entry)
        lower = name.lower()
        if "fvp" not in lower:
            continue
        build = build_number(entry.get("last_known_good_build"))
        if not build:
            continue
        if name == exact[0]:
            score = 0
        elif name == exact[1]:
            score = 1
        elif variant == "mini" and "fvp_mini" in lower:
            score = 10
        elif variant == "full" and "fvp" in lower and "mini" not in lower:
            score = 10
        else:
            score = 50
        if "userdebug" not in lower:
            score += 2
        ranked.append((score, name, build, entry))
    ranked.sort(key=lambda item: (item[0], item[1]))
    return ranked


def candidate_names(target: str, build: str) -> list[str]:
    product = re.sub(r"-(?:userdebug|user|eng)$", "", target)
    names = [
        f"{product}-img-{build}.zip",
        f"{target}-img-{build}.zip",
        f"{product}-images-{build}.zip",
        f"{product}-target_files-{build}.zip",
        f"aosp_{product}-img-{build}.zip",
        f"{product}-img.zip",
    ]
    return list(dict.fromkeys(names))


def page_artifacts(page_url: str, raw_base: str) -> list[str]:
    try:
        body = html.unescape(fetch_text(page_url))
    except Exception:
        return []
    results: list[str] = []
    for match in re.findall(r"(?:href=|src=)?[\"']([^\"']+)[\"']", body):
        decoded = urllib.parse.unquote(match.replace("\\u002F", "/"))
        if "/raw/" in decoded:
            results.append(urllib.parse.urljoin(page_url + "/", decoded))
    filename_pattern = re.compile(
        r"([A-Za-z0-9_./+-]*(?:fvp|img|target_files)[A-Za-z0-9_./+-]*\.(?:zip|tar\.gz|tgz))",
        re.IGNORECASE,
    )
    for filename in filename_pattern.findall(body):
        filename = urllib.parse.unquote(filename).split("/")[-1]
        results.append(f"{raw_base}/{urllib.parse.quote(filename)}")
    return list(dict.fromkeys(results))


def archive_members(path: Path) -> tuple[str, list[str]]:
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            return "zip", archive.namelist()
    try:
        with tarfile.open(path, "r:*") as archive:
            return "tar", [member.name for member in archive.getmembers() if member.isfile()]
    except tarfile.TarError as exc:
        raise ValueError("not a supported zip/tar archive") from exc


def select_members(members: Iterable[str]) -> dict[str, str] | None:
    selected: dict[str, str] = {}
    for required in REQUIRED:
        matches = [name for name in members if Path(name).name == required]
        if not matches:
            return None
        selected[required] = min(matches, key=lambda value: (value.count("/"), len(value)))
    return selected


def extract_selected(path: Path, archive_type: str, selected: dict[str, str], output: Path) -> None:
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    if archive_type == "zip":
        with zipfile.ZipFile(path) as archive:
            for required, member in selected.items():
                with archive.open(member) as source, (output / required).open("wb") as destination:
                    shutil.copyfileobj(source, destination, length=16 * 1024 * 1024)
    else:
        with tarfile.open(path, "r:*") as archive:
            for required, member in selected.items():
                source = archive.extractfile(member)
                if source is None:
                    raise RuntimeError(f"unable to extract {member}")
                with source, (output / required).open("wb") as destination:
                    shutil.copyfileobj(source, destination, length=16 * 1024 * 1024)
    for required in REQUIRED:
        file_path = output / required
        if not file_path.is_file() or file_path.stat().st_size == 0:
            raise RuntimeError(f"extracted file is missing or empty: {required}")


def download(url: str, destination: Path) -> tuple[int, str]:
    error: Exception | None = None
    for attempt in range(1, 4):
        try:
            with request(url, timeout=120) as response:
                content_length = int(response.headers.get("Content-Length") or 0)
                if content_length > MAX_DOWNLOAD_BYTES:
                    raise RuntimeError(f"artifact exceeds {MAX_DOWNLOAD_BYTES} bytes")
                digest = hashlib.sha256()
                size = 0
                with destination.open("wb") as stream:
                    while True:
                        chunk = response.read(16 * 1024 * 1024)
                        if not chunk:
                            break
                        size += len(chunk)
                        if size > MAX_DOWNLOAD_BYTES:
                            raise RuntimeError("artifact exceeded download size limit")
                        digest.update(chunk)
                        stream.write(chunk)
                return size, digest.hexdigest()
        except Exception as exc:
            error = exc
            destination.unlink(missing_ok=True)
            if attempt < 3:
                time.sleep(attempt * 2)
    assert error is not None
    raise error


def write_diagnostics(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    branches = tuple(args.branches or DEFAULT_BRANCHES)
    diagnostics: dict[str, Any] = {
        "verified": False,
        "variant": args.variant,
        "required_files": list(REQUIRED),
        "branches_checked": [],
        "targets_considered": [],
        "artifact_attempts": [],
    }

    candidates: list[tuple[str, str, str]] = []
    if args.archive_url:
        candidates.append(("explicit", "explicit", args.archive_url))

    if args.status_json:
        statuses = [("local", json.loads(args.status_json.read_text(encoding="utf-8")))]
    else:
        statuses = []
        for branch in branches:
            status_url = f"https://ci.android.com/builds/branches/{branch}/status.json"
            branch_record: dict[str, Any] = {"branch": branch, "status_url": status_url}
            try:
                status = fetch_json(status_url)
                branch_record["fetched"] = True
                statuses.append((branch, status))
            except Exception as exc:
                branch_record["fetched"] = False
                branch_record["error"] = f"{type(exc).__name__}: {exc}"
            diagnostics["branches_checked"].append(branch_record)

    for branch, status in statuses:
        ranked = ranked_targets(status, args.variant)
        for score, target, build, entry in ranked:
            diagnostics["targets_considered"].append(
                {"branch": branch, "target": target, "build": build, "score": score}
            )
            base = f"https://ci.android.com/builds/submitted/{build}/{target}/latest"
            raw_base = f"{base}/raw"
            urls = [f"{raw_base}/{urllib.parse.quote(name)}" for name in candidate_names(target, build)]
            urls.extend(page_artifacts(base, raw_base))
            for url in dict.fromkeys(urls):
                candidates.append((branch, target, url))

    candidates = list(dict.fromkeys(candidates))
    candidates.sort(
        key=lambda item: (
            1 if "target_files" in item[2].lower() else 0,
            0 if "-img-" in item[2].lower() else 1,
            item[2],
        )
    )

    with tempfile.TemporaryDirectory(prefix="fvp-ci-") as temp_dir:
        temp_path = Path(temp_dir)
        for branch, target, url in candidates[: max(1, args.max_artifacts)]:
            record: dict[str, Any] = {"branch": branch, "target": target, "url": url}
            archive_path = temp_path / "artifact.download"
            try:
                size, sha256 = download(url, archive_path)
                record.update({"downloaded": True, "size_bytes": size, "sha256": sha256})
                archive_type, members = archive_members(archive_path)
                selected = select_members(members)
                record["archive_type"] = archive_type
                record["member_count"] = len(members)
                record["required_members"] = selected
                if selected is None:
                    record["accepted"] = False
                    record["error"] = "archive does not contain the complete AOSP FVP boot set"
                else:
                    extract_selected(archive_path, archive_type, selected, args.output)
                    record["accepted"] = True
                    diagnostics["artifact_attempts"].append(record)
                    diagnostics.update(
                        {
                            "verified": True,
                            "selected_branch": branch,
                            "selected_target": target,
                            "selected_url": url,
                            "archive_sha256": sha256,
                            "output": str(args.output.resolve()),
                        }
                    )
                    write_diagnostics(args.diagnostics, diagnostics)
                    print(args.output.resolve())
                    return 0
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, ValueError, RuntimeError) as exc:
                record["downloaded"] = False
                record["accepted"] = False
                record["error"] = f"{type(exc).__name__}: {exc}"
            diagnostics["artifact_attempts"].append(record)
            archive_path.unlink(missing_ok=True)

    diagnostics["error"] = (
        "No public Android CI artifact contained kernel, combined-ramdisk.img, "
        "system-qemu.img and userdata.img. Use the pinned AOSP source-build fallback."
    )
    write_diagnostics(args.diagnostics, diagnostics)
    print(diagnostics["error"], file=sys.stderr)
    return 42


if __name__ == "__main__":
    sys.exit(main())
