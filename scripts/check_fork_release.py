"""Release policy for this fork; run before publishing and after the console build."""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "Tmsdkdc/chatgpt2api"
PROMOTION_MARKERS = (
    "1005859624",
    "qm.qq.com",
    "pay.ldxp.cn",
    "api.klong.lat",
    "交流与服务",
    "www.ipwo.net",
    "contrib.rocks/image",
    "https://linux.do",
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dist", type=Path, help="Also scan an existing console build")
    args = parser.parse_args()
    errors: list[str] = []
    paths = list((ROOT / "web-vue/src").rglob("*"))
    paths.extend((ROOT / "README.md", ROOT / "README_EN.md"))
    if args.dist:
        dist = args.dist if args.dist.is_absolute() else ROOT / args.dist
        if not (dist / "index.html").is_file():
            errors.append("Console build is missing index.html")
        paths.extend(dist.rglob("*"))
    for path in paths:
        if path.suffix not in {".vue", ".ts", ".js", ".css", ".html", ".json", ".md"}:
            continue
        content = path.read_text(encoding="utf-8")
        for marker in PROMOTION_MARKERS:
            if marker in content:
                errors.append(f"Promotion marker {marker!r} in {path.relative_to(ROOT)}")

    tree = ast.parse((ROOT / "services/update_status_service.py").read_text(encoding="utf-8"))
    constants = {
        target.id: node.value.value
        for node in tree.body if isinstance(node, ast.Assign)
        for target in node.targets if isinstance(target, ast.Name)
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
    }
    expected = {
        "GITHUB_LATEST_RELEASE_URL": f"https://api.github.com/repos/{REPOSITORY}/releases/latest",
        "GITHUB_RELEASES_URL": f"https://github.com/{REPOSITORY}/releases",
        "GITHUB_CHANGELOG_URL": f"https://api.github.com/repos/{REPOSITORY}/contents/CHANGELOG.md?ref=main",
    }
    for name, url in expected.items():
        if constants.get(name) != url:
            errors.append(f"{name} must use this fork")
    for name in ("docker-compose.yml", ".env.example"):
        content = (ROOT / name).read_text(encoding="utf-8")
        if f"ghcr.io/{REPOSITORY.lower()}:" not in content or "ghcr.io/yukkcat/" in content:
            errors.append(f"{name} must use this fork's lowercase GHCR image")
    installer = (ROOT / "deploy/install.sh").read_text(encoding="utf-8")
    if 'REPO_OWNER="${REPO_OWNER:-Tmsdkdc}"' not in installer:
        errors.append("Installer must default to this fork")
    for name in ("web-vue/src/layouts/AppShell.vue", "web-vue/src/views/Login.vue"):
        content = (ROOT / name).read_text(encoding="utf-8")
        if f"https://github.com/{REPOSITORY}" not in content or "github.com/yukkcat/chatgpt2api" in content:
            errors.append(f"{name} must link to this fork")

    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    for name in ("web-vue/package.json", "web-vue/package-lock.json"):
        package = json.loads((ROOT / name).read_text(encoding="utf-8"))
        if package.get("version") != version:
            errors.append(f"{name} version differs from VERSION")
        if name.endswith("package-lock.json") and package.get("packages", {}).get("", {}).get("version") != version:
            errors.append("package-lock.json root package version differs from VERSION")
    if os.environ.get("GITHUB_REF_TYPE") == "tag":
        if not re.fullmatch(r"v\d+\.\d+\.\d+-tmsdkdc\.[1-9]\d*", os.environ.get("GITHUB_REF_NAME", "")):
            errors.append("Fork releases must use v<upstream-version>-tmsdkdc.<revision> tags")
        if os.environ.get("GITHUB_REF_NAME") != f"v{version}":
            errors.append("Release tag must equal v + VERSION")
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        if not any(line.startswith(f"## {version} - ") for line in changelog.splitlines()):
            errors.append("Release requires a dated CHANGELOG section for VERSION")
    if errors:
        raise SystemExit("Fork release blocked:\n- " + "\n- ".join(errors))
    print("Fork release policy passed: promotion links absent; update sources and versions consistent.")


if __name__ == "__main__":
    main()
