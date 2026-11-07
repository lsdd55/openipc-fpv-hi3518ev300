#!/bin/sh
#
# 把本工程安全地发布到 GitHub。
#
#   ./scripts/publish.sh              # 只做本地 git init + commit，并检查密钥安全
#   ./scripts/publish.sh <远程URL>     # 额外添加 remote（仍然不会自动 push）
#
# 设计原则：这个脚本**不会**替你执行 push —— 那需要你的凭据，而且推错仓库
# 的代价（私钥公开）不可撤销。它只负责把本地准备到"一条命令就能推"的状态，
# 并把该看的警告摆在你眼前。
#
set -eu

here=$(cd "$(dirname "$0")" && pwd)
project=$(cd "$here/.." && pwd)
cd "$project"

say() { printf '\033[1m[publish]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[publish] %s\033[0m\n' "$*" >&2; exit 1; }

command -v git >/dev/null || die "没装 git"

# ---- 1. 密钥安全闸门 -------------------------------------------------------
# 这一条是硬性检查，不是提示。gs.key 一旦进仓库，整条链路就等于公开。
if [ -f keys/gs.key ]; then
	if git check-ignore -q keys/gs.key 2>/dev/null || \
	   grep -qxF 'keys/gs.key' .gitignore 2>/dev/null; then
		say "✓ keys/gs.key 不会入库"
	else
		die "keys/gs.key 没有被忽略！先把它加进 .gitignore，否则绝不能提交"
	fi
fi

if [ -f keys/drone.key ]; then
	if git check-ignore -q keys/drone.key 2>/dev/null; then
		die "keys/drone.key 被忽略了 —— 但 CI 需要它来校验镜像里的密钥"
	fi
	say "✓ keys/drone.key 会入库（CI 需要）"
fi

# ---- 2. git init / commit --------------------------------------------------
if [ ! -d .git ]; then
	say "初始化仓库..."
	git init -q
	git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
fi

git add -A

# 二次确认：暂存区里真的没有 gs.key
if git diff --cached --name-only | grep -q '^keys/gs\.key$'; then
	git reset -q keys/gs.key 2>/dev/null || true
	die "gs.key 混进了暂存区，已撤下。请检查 .gitignore 后重试"
fi
say "✓ 暂存区里没有 gs.key"

n=$(git diff --cached --name-only | wc -l | tr -d ' ')
if [ "$n" -gt 0 ]; then
	say "提交 $n 个文件..."
	git -c user.name="${GIT_AUTHOR_NAME:-openipc-fpv}" \
	    -c user.email="${GIT_AUTHOR_EMAIL:-openipc-fpv@localhost}" \
	    commit -q -m "${COMMIT_MSG:-OpenIPC FPV drone/TX firmware for Hi3518EV300 + F23}

SoC Hi3518EV300 / sensor F23 / 16MB SPI NOR.
wfb-ng drone+gs keypair, 5.8GHz 20MHz MCS1 FEC 8:12.
Drivers: RTL8812AU, RTL8733BU.
Video 1920x1080@30 H.264 10Mbps (F23 has no 60fps mode).
Built by GitHub Actions; see README.md." || say "（没有新改动可提交）"
else
	say "没有待提交的改动"
fi

# ---- 3. remote -------------------------------------------------------------
if [ $# -ge 1 ]; then
	url=$1
	if git remote | grep -qx origin; then
		git remote set-url origin "$url"
	else
		git remote add origin "$url"
	fi
	say "已设置 origin = $url"
fi

# ---- 4. 关键警告 -----------------------------------------------------------
cat <<'EOF'

────────────────────────────────────────────────────────────────
推之前请确认仓库是 **私有** 的。

原因：keys/drone.key 的前 32 字节是空中端的私钥，而同一个文件里还带着
GS 公钥。这两样凑在一起，就足以推导出会话密钥 —— 也就是说，谁拿到这个
文件，谁就能解出你的图传、并向链路里注入画面。

镜像本身（firmware.bin）里也烤进了同一份 drone.key，所以固件同样不能
公开发布。若确实需要分享固件，请先用 keys/gen-keys.py 重新生成一套，
再构建；分享用的旧固件对应的密钥就作废了。

创建私有仓库并推送：

    gh repo create <你的用户名>/openipc-fpv-hi3518ev300 --private --source=. --push

或者手动：

    git remote add origin git@github.com:<你>/openipc-fpv-hi3518ev300.git
    git push -u origin main

推完到 Actions 页面点 "Run workflow" 即可，产物在 run 的 Artifacts 里。
────────────────────────────────────────────────────────────────
EOF
