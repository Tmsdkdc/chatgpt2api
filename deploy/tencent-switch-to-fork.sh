#!/usr/bin/env bash
# Upload this file to /home/ubuntu; run with a published tag, e.g. v3.2.9-tmsdkdc.1.
set -Eeuo pipefail
umask 077
APP=/home/ubuntu/apps/chatgpt2api
VOLUME=chatgpt2api_runtime
STAMP=$(date +%Y%m%d-%H%M%S)-$$
BACKUP=/home/ubuntu/backups/chatgpt2api-fork-$STAMP
PHASE=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && $1 =~ ^v?[0-9]+\.[0-9]+\.[0-9]+-tmsdkdc\.[1-9][0-9]*$ ]] || die '用法：bash chatgpt2api-switch-to-fork.sh v3.2.9-tmsdkdc.1（须先发布镜像）'
TAG=$1
IMAGE=ghcr.io/tmsdkdc/chatgpt2api:$TAG
[[ $(id -un) == ubuntu ]] || die '请使用 ubuntu 用户运行，脚本会按需使用 sudo -n。'
for tool in python3 curl sudo tar sha256sum; do command -v "$tool" >/dev/null || die "缺少命令：$tool"; done
sudo -n true
[[ -d "$APP" && ! -L "$APP" && $(readlink -f "$APP") == "$APP" ]] || die '应用路径不符合现有部署。'
[[ -d "$APP/data" && ! -L "$APP/data" && -f "$APP/.env" && -f "$APP/config.json" ]] || die '缺少现有数据或配置。'
[[ -f "$APP/verify_api.py" ]] || die '缺少之前安装的 verify_api.py。'
COMPOSE=$APP/compose.yaml
[[ -f "$COMPOSE" && ! -L "$COMPOSE" && ! -L "$APP/.env" && ! -L "$APP/config.json" ]] || die '此脚本只适用于之前创建的 compose.yaml 部署。'
DC=(sudo -n docker compose --project-directory "$APP" -f "$COMPOSE")
[[ $("${DC[@]}" config --services) == app ]] || die 'Compose 服务结构不符合现有部署。'
for unit in caddy cdk-recharge; do sudo -n systemctl is-active --quiet "$unit" || die "$unit 未运行，请先检查。"; done
[[ $(sudo -n docker inspect sub2api --format '{{.State.Running}}') == true ]] || die 'sub2api 未运行。'
curl --fail --silent --max-time 10 http://127.0.0.1:18081/ -o /dev/null || die '原应用首页不可用。'
sudo -n docker inspect chatgpt2api | python3 -c '
import json, sys
c=json.load(sys.stdin)[0]
def require(ok, message):
    if not ok: raise SystemExit(message)
require(c["State"]["Running"], "原容器未运行")
labels=c["Config"].get("Labels") or {}
require(labels.get("com.docker.compose.project")=="chatgpt2api" and labels.get("com.docker.compose.service")=="app", "容器不属于预期 Compose 项目")
mounts={m["Destination"]:m for m in c["Mounts"]}
expected={"/app/data":"/home/ubuntu/apps/chatgpt2api/data", "/app/config.json":"/home/ubuntu/apps/chatgpt2api/config.json"}
for target, source in expected.items():
    require(target in mounts and mounts[target]["Type"]=="bind" and mounts[target]["Source"]==source, "数据或配置挂载不符合预期")
require("/app" in mounts and mounts["/app"]["Type"]=="volume" and mounts["/app"].get("Name")=="chatgpt2api_runtime", "运行卷不符合预期")
require(set(mounts)=={"/app","/app/data","/app/config.json"}, "发现额外挂载，请先人工核对")
env=dict(line.split("=",1) for line in c["Config"]["Env"] if "=" in line)
require(env.get("DATABASE_URL") in {"", "sqlite:////app/data/chatgpt2api.db"}, "此备份流程仅支持现有 SQLite 部署")
ports=c["HostConfig"].get("PortBindings") or {}
require(ports.get("80/tcp")==[{"HostIp":"127.0.0.1","HostPort":"18081"}], "端口映射不符合预期")
require(any("chatgpt2api-web" in (n.get("Aliases") or []) for n in c["NetworkSettings"]["Networks"].values()), "缺少 Sub2API 使用的网络别名")
print("Preflight OK: existing SQLite deployment, mounts, port and network alias verified.")
'

# Pull and inspect the image before stopping the live application.
printf '拉取你的镜像：%s\n' "$IMAGE"
sudo -n docker pull "$IMAGE"
NEW_ID=$(sudo -n docker image inspect "$IMAGE" --format '{{.Id}}')
sudo -n docker run --rm --network none --entrypoint python "$NEW_ID" -c '
from pathlib import Path
import ast,sys
root=Path("/opt/chatgpt2api")
assert (root/"VERSION").read_text().strip()==sys.argv[1].removeprefix("v"), "镜像 VERSION 与标签不一致"
tree=ast.parse((root/"services/update_status_service.py").read_text())
values={t.id:n.value.value for n in tree.body if isinstance(n,ast.Assign) for t in n.targets if isinstance(t,ast.Name) and isinstance(n.value,ast.Constant)}
repo="Tmsdkdc/chatgpt2api"
assert values.get("GITHUB_LATEST_RELEASE_URL")==f"https://api.github.com/repos/{repo}/releases/latest", "后台更新源不正确"
assert values.get("GITHUB_RELEASES_URL")==f"https://github.com/{repo}/releases", "Release 地址不正确"
assert values.get("GITHUB_CHANGELOG_URL")==f"https://api.github.com/repos/{repo}/contents/CHANGELOG.md?ref=main", "Changelog 地址不正确"
dist=root/"web_dist"
assert (dist/"index.html").is_file(), "镜像缺少前端"
for p in dist.rglob("*"):
    if p.suffix in {".js",".css",".html"}:
        text=p.read_text()
        assert not any(s in text for s in ("1005859624","qm.qq.com","pay.ldxp.cn","api.klong.lat")), "镜像仍包含推广入口"
print("目标镜像检查通过。")
' "$TAG"
DATA_BYTES=$(sudo -n du -sb "$APP/data" | cut -f1)
python3 - "$APP" "$DATA_BYTES" <<'PY'
import shutil,sys
assert shutil.disk_usage(sys.argv[1]).free > int(sys.argv[2])+1024**3, "可用磁盘不足以保存数据备份，请先检查空间"
PY

mkdir -p /home/ubuntu/backups
mkdir -m 700 "$BACKUP"
OLD_ID=$(sudo -n docker inspect chatgpt2api --format '{{.Image}}')
OLD_TAG=chatgpt2api-fork-rollback:$STAMP
sudo -n docker tag "$OLD_ID" "$OLD_TAG"
printf '%s\n' "$OLD_TAG" > "$BACKUP/old-image.txt"
cp -p "$COMPOSE" "$BACKUP/compose.yaml"
sudo -n cp -p "$APP/.env" "$APP/config.json" "$BACKUP/"

# The standalone rollback remains available after a successful switch.
cat > "$BACKUP/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP=/home/ubuntu/apps/chatgpt2api
B=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ $B == /home/ubuntu/backups/chatgpt2api-fork-* && -f "$B/checksums.txt" ]] || exit 1
[[ $(readlink -f "$APP") == "$APP" && ! -L "$APP/data" ]] || exit 1
cd "$B"
sudo -n sha256sum --check --status checksums.txt
export CHATGPT2API_IMAGE
CHATGPT2API_IMAGE=$(cat old-image.txt)
DC=(sudo -n docker compose --project-directory "$APP" -f "$APP/compose.yaml")
"${DC[@]}" stop app
sudo -n mv "$APP/data" "$B/data.after-switch-$(date +%Y%m%d-%H%M%S)-$$"
sudo -n tar -xzf "$B/data.tar.gz" -C "$APP"
sudo -n docker run --rm --network none --mount type=volume,src=chatgpt2api_runtime,dst=/runtime --entrypoint python "$CHATGPT2API_IMAGE" -c '
import shutil
from pathlib import Path
root=Path("/runtime")
for p in root.iterdir():
    if p.name in {"data","config.json",".venv"}: continue
    if p.is_dir() and not p.is_symlink(): shutil.rmtree(p)
    else: p.unlink()
'
sudo -n docker run --rm -i --network none --mount type=volume,src=chatgpt2api_runtime,dst=/runtime --entrypoint tar "$CHATGPT2API_IMAGE" -xzf - -C /runtime < "$B/runtime.tar.gz"
sudo -n cp -p "$B/.env" "$B/config.json" "$B/compose.yaml" "$APP/"
"${DC[@]}" up -d --no-deps --force-recreate --pull never app
printf '已恢复备份并启动原镜像，请等待启动后检查首页与生图。备份：%s\n' "$B"
ROLLBACK
chmod 700 "$BACKUP/rollback.sh"

on_error() {
  local code=$?
  trap - ERR
  printf '切换失败；备份及现场：%s\n' "$BACKUP" >&2
  if (( PHASE >= 2 )); then
    bash "$BACKUP/rollback.sh" || printf '自动回滚未完成，请保留备份与终端输出。\n' >&2
  elif (( PHASE == 1 )); then
    "${DC[@]}" up -d --no-deps --pull never app || true
  fi
  exit "$code"
}
trap on_error ERR
printf '将暂停 chatgpt2api，保存一致的数据与运行代码备份：%s\n' "$BACKUP"
PHASE=1
"${DC[@]}" stop app
sudo -n tar -czf "$BACKUP/data.tar.gz" -C "$APP" data
sudo -n docker run --rm --network none --mount type=volume,src="$VOLUME",dst=/runtime,readonly --entrypoint tar "$OLD_ID" --exclude='./data' --exclude='./config.json' --exclude='./.venv' -czf - -C /runtime . > "$BACKUP/runtime.tar.gz"
sudo -n tar -tzf "$BACKUP/data.tar.gz" >/dev/null
tar -tzf "$BACKUP/runtime.tar.gz" >/dev/null
(cd "$BACKUP" && sudo -n sha256sum data.tar.gz runtime.tar.gz .env config.json compose.yaml old-image.txt > checksums.txt)
PHASE=2
python3 - "$APP/.env" "$IMAGE" <<'PY'
from pathlib import Path
import os,sys
p=Path(sys.argv[1])
lines=p.read_text().splitlines()
indexes=[i for i,line in enumerate(lines) if line.startswith("CHATGPT2API_IMAGE=")]
assert len(indexes)==1, "镜像变量缺失或重复，请人工核对 .env"
lines[indexes[0]]="CHATGPT2API_IMAGE="+sys.argv[2]
tmp=p.with_name(".env.fork-pending")
tmp.write_text("\n".join(lines)+"\n")
tmp.chmod(0o600)
os.replace(tmp,p)
PY
export CHATGPT2API_IMAGE=$IMAGE
"${DC[@]}" config --quiet
# Force an initial seed refresh even when the fork has the same VERSION as upstream.
sudo -n docker run --rm --network none --mount type=volume,src="$VOLUME",dst=/runtime --entrypoint sh "$OLD_ID" -c 'rm -f /runtime/.chatgpt2api-image-version'
"${DC[@]}" up -d --no-deps --force-recreate --pull never app
READY=0
for ((second=0; second<300; second+=5)); do
  if curl --fail --silent --max-time 3 http://127.0.0.1:18081/ -o /dev/null; then READY=1; break; fi
  sleep 5
done
(( READY == 1 ))
sudo -n docker exec chatgpt2api python -c 'from pathlib import Path; import sys; assert Path("/app/VERSION").read_text().strip()==sys.argv[1].removeprefix("v"); assert "api.github.com/repos/Tmsdkdc/chatgpt2api/releases/latest" in Path("/app/services/update_status_service.py").read_text()' "$TAG"
python3 "$APP/verify_api.py" models --base-url http://127.0.0.1:18081/v1 --key-env-file "$APP/.env" --output-dir "$BACKUP/api-check"
for unit in caddy cdk-recharge; do sudo -n systemctl is-active --quiet "$unit"; done
[[ $(sudo -n docker inspect sub2api --format '{{.State.Running}}') == true ]]
trap - ERR
"${DC[@]}" ps
printf 'Fork 镜像与 API 检查通过。请在网页 Ctrl+F5 后测试一次生图。\n备份：%s\n回滚：bash %s/rollback.sh\n' "$BACKUP" "$BACKUP"
