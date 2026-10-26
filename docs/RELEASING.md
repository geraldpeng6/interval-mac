# 发布流程

描述自 `1.0.0-rc.2` 起的发布方式。历史验证记录见 [VALIDATION.md](VALIDATION.md)（保留，不在此重写）。

## 版本元数据（唯一来源）

- `VERSION`：完整 semver 版本（如 `1.0.0-rc.2`），由 `scripts/version.sh` 按 strict semver 校验（允许预发布号与构建元数据，拒绝前导零等非法形式）。
- `BUILD_NUMBER`：单调递增的纯数字构建号，写入 `CFBundleVersion`。禁止 git 提交计数、时间戳等派生自动编号——版本只来自提交的文件和 tag。
- 打包产物的 `CFBundleShortVersionString` 是纯数字 Apple 版本（如 `1.0.0`；Apple 不接受预发布后缀，各分量上限 65535）；完整版本保留在自定义键 `IntervalFullVersion`，供界面展示和未来更新器的预发布比较。
- 每次发布：更新 `VERSION` 与 `BUILD_NUMBER`（构建号必须大于上一次），提交后打对应的 `v` tag。

## 自动发布（推送 tag）

1. `git tag v1.0.0-rc.2 && git push origin v1.0.0-rc.2`。tag 必须等于 `v` + 提交的 `VERSION`，且 `BUILD_NUMBER` 有效，否则工作流直接失败，不产生发布。
2. Release 工作流（`.github/workflows/release.yml`）在 macOS runner 上依次执行：
   - `./scripts/check.sh`：全部 XCTest + 版本元数据边界测试；
   - `./scripts/package.sh`：构建 arm64、校验签名与架构、生成 ZIP / DMG / SHA256SUMS；
   - 以上全部成功后才创建 **draft** release，上传全部资产，最后一步才把 draft 转为正式发布。任一步失败则不发布。
3. 版本带预发布号（如 `1.0.0-rc.2`）→ release 标记为 **prerelease** 渠道；稳定版本为正式渠道。
4. 若该 tag 已存在正式（非 draft）release，工作流失败退出，**不会覆盖**；同名 draft 可重复运行，重跑会覆盖补充资产（幂等）。

## 手动发布（workflow_dispatch）

仅用于重跑或补发某个已评审的版本：在 Actions 页选择 Release 工作流，输入**已存在**的 tag（如 `v1.0.0-rc.2`）。工作流会校验：

- tag 真实存在（`git cat-file -e refs/tags/<tag>^{commit}`）；
- tag 与提交的 `VERSION`、`BUILD_NUMBER` 一致；
- tag 位于 **main 历史**（`git merge-base --is-ancestor`）。

任一校验失败即拒绝发布。不接受任意分支，也不发布未打版本号的 main 构建。

## CI 权限

- 普通测试 CI（`.github/workflows/ci.yml`：main push / PR / tag 触发）保持 `contents: read`，只读。
- Release 工作流整体 `permissions: {}`，仅发布 job 拥有 `contents: write`；使用内置 `GITHUB_TOKEN`（经 `gh` CLI），无需 PAT 或新增 secret。

## 签名与安全边界（如实说明）

- 发布产物默认 **ad-hoc 签名**（`codesign --sign -`），**不是** Developer ID 签名，**未经公证**。README 如实告知用户首次打开的处理方式，不宣称已认证或已公证。
- 应用内安全更新（更新器签名校验等）尚未实现；下载渠道已确定为本仓库公开的 GitHub Releases，不再依赖尚未确定的私有下载策略。
- 源码仓库公开；release 资产直接发布在本仓库 Releases，不引入新的外部仓库或服务。

## 本地打包

```sh
./scripts/package.sh                                          # 产物在 build/
INTERVAL_OUTPUT=/tmp/interval-artifacts ./scripts/package.sh  # 隔离输出，便于测试
```

脚本只在自身的 `mktemp` 临时目录（打包暂存、iconset）内操作并在退出时清理；不会安装应用，不更改系统权限或隔离属性，仅对临时构建的 bundle 执行 `xattr -cr` 与 ad-hoc 签名。同一版本重复运行会先清除旧产物，保证无陈旧资产残留。
