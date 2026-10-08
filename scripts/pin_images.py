#!/usr/bin/env python3
"""Container images and CI actions stay pinned to what was reviewed (expert review of October 2026, stage C6).

A tag such as python:3.12-slim or actions/checkout@v5 moves whenever its publisher pushes, and a server would then
build from a base nobody tested. Every image this repository pulls is written name:tag@sha256:<digest> and every
action owner/repo@<commit> # vX.Y.Z, so each build takes the same bytes until someone moves a pin on purpose.

    python3 scripts/pin_images.py            check (CI): exits 1 and names every reference that is not pinned
    python3 scripts/pin_images.py --update   moves each pin to what its tag points to now (images: the same tag;
                                             actions: the newest release of the same major version); review the diff
Images named masslak* are built from this repository and are not pulled.
"""
import glob
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FROM = re.compile(r"^(FROM\s+(?:--platform=\S+\s+)?)(\S+)(.*)$", re.I)
IMAGE = re.compile(r"^(\s*image:\s*)([^\s#]+)(.*)$")
USES = re.compile(r"^(\s*(?:-\s+)?uses:\s*)([^\s#]+)(\s*(?:#\s*(\S+))?.*)$")
PINNED_IMAGE = re.compile(r"^[a-z0-9][\w./-]*:[\w.-]+@sha256:[0-9a-f]{64}$")
PINNED_ACTION = re.compile(r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$")
VERSION = re.compile(r"^v\d+(\.\d+){0,2}$")
ACCEPT = ", ".join(["application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
                    "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"])


def files() -> list[str]:
    found = glob.glob(os.path.join(ROOT, "**", "Dockerfile*"), recursive=True)
    found += glob.glob(os.path.join(ROOT, "docker-compose*.yml")) + glob.glob(os.path.join(ROOT, "deploy", "**", "*.yml"), recursive=True)
    found += glob.glob(os.path.join(ROOT, ".github", "workflows", "*.yml"))
    return sorted(f for f in set(found) if "node_modules" not in f)


def local(ref: str) -> bool:
    return ref.split("/")[-1].startswith("masslak")


def references(path: str):
    """(line number, kind, prefix, reference, rest, version comment) for each image or action the file names."""
    stages = set()
    for n, line in enumerate(open(path, encoding="utf-8").read().splitlines()):
        m = FROM.match(line) if os.path.basename(path).startswith("Dockerfile") else None
        if m:
            ref = m.group(2)
            stage = re.search(r"\bAS\s+(\S+)", m.group(3), re.I)
            if ref.lower() not in stages and ref != "scratch":
                yield n, "image", m.group(1), ref, m.group(3), None
            if stage:
                stages.add(stage.group(1).lower())
            continue
        m = IMAGE.match(line)
        if m and not local(m.group(2)):
            yield n, "image", m.group(1), m.group(2).strip("'\""), m.group(3), None
            continue
        m = USES.match(line)
        if m and not m.group(2).startswith(("./", "docker://")):
            yield n, "action", m.group(1), m.group(2), m.group(3), m.group(4)


def problems() -> list[str]:
    out = []
    for path in files():
        rel = os.path.relpath(path, ROOT)
        for n, kind, _, ref, _, version in references(path):
            if kind == "image" and not PINNED_IMAGE.match(ref):
                out.append(f"{rel}:{n + 1}: image {ref} is not pinned (name:tag@sha256:<digest>)")
            if kind == "action" and not (PINNED_ACTION.match(ref) and version and VERSION.match(version)):
                out.append(f"{rel}:{n + 1}: action {ref} is not pinned (owner/repo@<40-character commit> # vX.Y.Z)")
    return out


# ------------------------------------------------------------------ --update
def _get(url: str, headers: dict, method: str = "GET"):
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers, method=method), timeout=30)  # nosec B310


def image_digest(ref: str) -> str:
    name, tag = ref.split("@")[0].rsplit(":", 1)
    host, _, repo = name.partition("/")
    if "." not in host and ":" not in host:                       # Docker Hub
        host, repo = "registry-1.docker.io", name if "/" in name else f"library/{name}"
    url = f"https://{host}/v2/{repo}/manifests/{tag}"
    headers = {"Accept": ACCEPT}
    try:
        resp = _get(url, headers, "HEAD")
    except urllib.error.HTTPError as e:                            # anonymous token from the registry's challenge
        if e.code != 401:
            raise
        challenge = dict(re.findall(r'(\w+)="([^"]*)"', e.headers.get("WWW-Authenticate", "")))
        token_url = f"{challenge['realm']}?service={challenge.get('service', '')}&scope={challenge.get('scope', f'repository:{repo}:pull')}"
        token = json.load(_get(token_url, {}))
        headers["Authorization"] = f"Bearer {token.get('token') or token.get('access_token')}"
        resp = _get(url, headers, "HEAD")
    digest = resp.headers["Docker-Content-Digest"]
    return f"{name}:{tag}@{digest}"


def action_pin(ref: str, version: str) -> tuple[str, str]:
    repo = ref.split("@")[0]
    major = (version or "v" + ref.split("@")[1].lstrip("v")).split(".")[0]
    out = subprocess.run(["git", "ls-remote", "--tags", f"https://github.com/{'/'.join(repo.split('/')[:2])}"],
                         capture_output=True, text=True, check=True, timeout=60).stdout     # nosec B603 B607
    tags: dict = {}
    for line in out.splitlines():
        sha, name = line.split("\t")
        name = name.removeprefix("refs/tags/")
        peeled = name.endswith("^{}")
        name = name.removesuffix("^{}")
        if re.fullmatch(rf"{major}\.\d+\.\d+", name) and (peeled or name not in tags):
            tags[name] = sha
    best = max(tags, key=lambda t: tuple(int(x) for x in t[1:].split(".")))
    return f"{repo}@{tags[best]}", best


def update() -> None:
    cache: dict = {}
    for path in files():
        lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
        changed = False
        for n, kind, prefix, ref, rest, version in list(references(path)):
            if kind == "image":
                new = cache.setdefault(ref.split("@")[0], None) or image_digest(ref)
                cache[ref.split("@")[0]] = new
                line = f"{prefix}{new}{rest}\n"
            else:
                key = ref.split("@")[0] + "@" + (version or ref.split("@")[1]).split(".")[0]
                new, tag = cache.get(key) or action_pin(ref, version)
                cache[key] = (new, tag)
                line = f"{prefix}{new} # {tag}\n"
            if lines[n] != line:
                lines[n], changed = line, True
                print(f"{os.path.relpath(path, ROOT)}:{n + 1}: {ref} -> {new}")
        if changed:
            open(path, "w", encoding="utf-8").write("".join(lines))


def main() -> int:
    if "--update" in sys.argv[1:]:
        update()
    found = problems()
    for p in found:
        print(p, file=sys.stderr)
    if found:
        print(f"{len(found)} reference(s) not pinned: run python3 scripts/pin_images.py --update and review the diff", file=sys.stderr)
        return 1
    print("OK: every image is pinned by digest and every action by commit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
