# Fork 同步、发布与服务器切换

状态：当前

此 Fork 以 `yukkcat/chatgpt2api` 为上游，使用
`Tmsdkdc/chatgpt2api` 的 Release 和 `ghcr.io/tmsdkdc/chatgpt2api` 镜像。
GitHub 仓库名保留账号大小写，容器镜像路径统一小写。
仓库中的配置与服务器当前使用的镜像是独立状态；修改源码不会自动更新服务器。

## 已定制的行为

- 桌面与手机端移除“交流与服务”入口、购买账号及 API 推广弹窗。
- 登录页、控制台源码链接及后台更新检查指向此 Fork。
- Compose 和安装脚本默认使用此 Fork 的镜像。
- 发布工作流检查源码及编译产物，发现已知推广链接、更新源回退或版本不一致时阻止发布。
- 原作者版权、许可证、NOTICE 和贡献者说明保留。

检查脚本位于 `scripts/check_fork_release.py`。它覆盖已知推广标记，不能识别所有新文案；
合并上游后仍须审查前端差异。同步可能产生冲突，不要使用强制覆盖本地分支的方法解决。

## 同步上游

本地 `origin` 应为自己的 Fork，`upstream` 为原作者仓库。工作区有未提交改动时先处理，
在新的合并分支中更新，测试通过后再合入自己的 `main`：

```bash
git remote -v
# 仅在尚未添加时执行：
git remote add upstream https://github.com/yukkcat/chatgpt2api.git
git fetch --no-tags upstream
git switch main
git pull --ff-only origin main
git switch -c merge-upstream-YYYYMMDD
git merge upstream/main
```

先查看上游 Release，选择需要的稳定基线；也可以显式合并已核对的发布提交 SHA。
不要因为上游出现新提交就直接部署。解决冲突时保留自己的更新地址和去推广改动。

本地验证：

```bash
python scripts/check_fork_release.py
python -m compileall -q api contracts services utils main.py
npm --prefix web-vue ci
# 上游改变图标使用后，按需重新生成并一并保留生成文件：
npm --prefix web-vue run icons:generate
npm --prefix web-vue run build
python scripts/check_fork_release.py --dist web-vue/dist
git diff --check
```

检查桌面和手机端控制台，确认推广入口消失，并验证登录、账号列表与生图。
完整测试源码没有随上游仓库发布；现有 `test:runtime` 命令引用这些本地文件，
不能将缺少测试文件的检出描述为已通过完整回归。

## 版本与发布

自有版本使用 `<上游版本>-tmsdkdc.<修订号>`，例如 `3.2.9-tmsdkdc.1`，
标签为 `v3.2.9-tmsdkdc.1`。同一上游基线继续修改时递增 `.2`、`.3`；
合并新的上游稳定版后，使用新基线，例如 `3.2.10-tmsdkdc.1`。
每次发布必须使用新版本和新标签，不复用旧标签或只覆盖同版本镜像。

发布前将同一版本写入：

1. 根目录 `VERSION`。
2. `web-vue/package.json` 的 `version`。
3. `web-vue/package-lock.json` 顶层和 `packages[""]` 的 `version`。
4. 将本次 `Unreleased` 条目移到 `CHANGELOG.md` 对应的 `## 版本 - 日期` 标题下，注明上游基线。

再次执行验证。仅在确认发布后提交、推送分支并推送对应的单个 `v*` 标签：

```bash
git tag v3.2.9-tmsdkdc.1
git push origin v3.2.9-tmsdkdc.1
```

不要执行 `git push --tags`。发布流水线只由版本标签启动；普通分支推送不会发布镜像。
Fork 的 Actions 页面需要先启用工作流。手动运行 Verify and Publish 可用于仅验证；
发布 Release 和镜像的 job 仍只允许 `v*` 标签。

工作流将自定义标签的 Release 显式标为非预发布并设置为 Latest，
使后台 `releases/latest` 可以读取此 Fork 的定制更新。
确认 Verify、Release 和 Docker job 全部成功。
首个 GHCR 包默认可见性需要人工检查；将包设置为 Public 后，服务器才能匿名拉取。
公开仓库不会自动保证新容器包公开。不向仓库写入服务器密钥、账号凭据或 `.env`。

## 首次切换当前腾讯云服务器

适用范围是此前部署的 Ubuntu 用户、SQLite、
`/home/ubuntu/apps/chatgpt2api/compose.yaml`、
`chatgpt2api_runtime` 运行卷以及本机 `18081` 端口。
脚本会核对挂载、网络别名和现有服务；不同部署应先人工调整，不能直接套用。

等自己的镜像发布完成并可以拉取后，将
`deploy/tencent-switch-to-fork.sh` 上传为
`/home/ubuntu/chatgpt2api-switch-to-fork.sh`，在服务器终端执行：

```bash
bash -n /home/ubuntu/chatgpt2api-switch-to-fork.sh
bash /home/ubuntu/chatgpt2api-switch-to-fork.sh v3.2.9-tmsdkdc.1
```

流程先拉取并检查目标镜像，然后仅暂停 `chatgpt2api`，备份配置、SQLite 数据目录和运行代码，
切换 `.env` 中的镜像并重建应用容器。第一次切换会强制刷新运行代码，
避免“新镜像与已安装版本号相同”时沿用旧文件。
脚本保留原有 Compose、端口、资源限制、数据挂载及 `chatgpt2api-web` 网络别名，
不重建 Sub2API、CDK 或 Caddy。

备份保存在 `/home/ubuntu/backups/chatgpt2api-fork-时间戳/`，
包含敏感配置和账号数据，仅用于本机恢复。不要上传到 GitHub 或发到聊天中。
切换失败会尝试运行该目录内的 `rollback.sh`；成功后也保留手动回滚入口。
回滚会恢复切换时的数据快照；切换后的数据目录会另存到同一个备份目录，
期间新增的调用、设置和账号改动不会自动合并回旧快照。

脚本检查本机首页、实际运行版本、更新源和 `/v1/models`。
完成后使用浏览器 Ctrl+F5，确认登录、推广入口、账号列表和一次真实生图。
镜像构建、在线更新包下载以及此脚本在真实服务器上的结果，需要在实际执行后单独确认。

## 后续更新

后台“版本更新”只显示此 Fork 发布的版本；原作者的新版本不会直接进入服务器。
同步、检查并发布自己的下一版后，再从后台更新或用切换脚本部署该固定版本。
切换脚本始终先备份当前状态；后台在线更新的文件回滚不能代替业务数据备份，
使用后台更新前按 [部署文档](../deployment.md) 保存数据备份。
