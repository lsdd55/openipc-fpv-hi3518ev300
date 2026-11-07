#!/bin/sh
#
# 发布安全测试：用**真实 git** 验证 .gitignore 与 publish.sh 的闸门。
#
# 这一组测的不是"文件里写了什么"，而是"git 实际会怎么干" —— 因为
# keys/gs.key 一旦被提交，链路密钥就公开了，且 git 历史里删不掉。
#
set -u

here=$(cd "$(dirname "$0")" && pwd)
project=$(cd "$here/.." && pwd)
pass=0; fail=0

ok()  { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }

command -v git >/dev/null || { echo "SKIP 没有 git"; exit 0; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 拷一份干净副本（排除 .git 与构建产物）
mkdir -p "$T/p"
( cd "$project" && tar -cf - \
	--exclude=.git --exclude=work --exclude=output --exclude='*.log' \
	--exclude=__pycache__ . ) | ( cd "$T/p" && tar -xf - )

cd "$T/p" || exit 1
git init -q .
git config user.email t@t
git config user.name t

echo "== gs.key 在任何位置都必须被忽略 =="
# 这一条来自一次真实的失误：gen-keys.py 原先默认写到当前工作目录，
# 从仓库根目录运行时会把 gs.key 生成在根目录，而 .gitignore 只写了
# keys/gs.key —— 那份散落的 gs.key 是「未跟踪、未忽略」状态，
# publish.sh 的 git add -A 会把它一起提交。所以规则必须与路径无关。
for probe in gs.key keys/gs.key overlay/general/package/x/gs.key; do
	mkdir -p "$(dirname "$probe")" 2>/dev/null
	printf 'x' > "$probe"
	done
for probe in gs.key keys/gs.key overlay/general/package/x/gs.key; do
	if git check-ignore -q "$probe" 2>/dev/null; then
		ok "忽略 $probe"
	else
		bad "$probe 没有被忽略 —— git add -A 会把它提交"
	fi
done
rm -rf overlay/general/package/x
# 反向确认：drone.key 不能被忽略，否则 CI 拿不到它做校验
if git check-ignore -q keys/drone.key 2>/dev/null; then
	bad "keys/drone.key 被忽略了 —— CI 需要它来校验镜像里的密钥"
else
	ok "keys/drone.key 未被忽略（CI 需要）"
fi

echo "== .gitignore 实际效果（真实 git add）=="
git add -A >/dev/null 2>&1

if git ls-files --error-unmatch keys/gs.key >/dev/null 2>&1; then
	bad "keys/gs.key 被 git 追踪了 —— 链路密钥会公开"
else
	ok "keys/gs.key 没有被 git 追踪"
fi

if git ls-files --error-unmatch keys/drone.key >/dev/null 2>&1; then
	ok "keys/drone.key 被追踪（CI 校验密钥一致性需要）"
else
	bad "keys/drone.key 没被追踪，CI 的一致性校验会失败"
fi

if git ls-files --error-unmatch \
	overlay/general/package/wifibroadcast-ng/files/drone.key >/dev/null 2>&1; then
	ok "打进镜像的 drone.key 被追踪"
else
	bad "打进镜像的 drone.key 没被追踪，镜像会缺密钥"
fi

n=$(git ls-files | wc -l | tr -d ' ')
if [ "$n" -ge 25 ]; then
	ok "共追踪 $n 个文件"
else
	bad "只追踪了 $n 个文件，可能漏了东西"
fi

# 构建产物不该混进来
if git ls-files | grep -qE '^(work|output)/'; then
	bad "构建产物被追踪了"
else
	ok "没有构建产物混入"
fi

echo
echo "== publish.sh 的闸门确实是硬性的 =="
if sh -n "$project/scripts/publish.sh" 2>/dev/null; then
	ok "publish.sh 语法通过"
else
	bad "publish.sh 语法不过"
fi

# 正向：当前工程状态应该能过闸门（gs.key 已被忽略）
out=$(cd "$T/p" && COMMIT_MSG=t sh "$T/p/scripts/publish.sh" 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
	ok "publish.sh 在正常状态下通过（并完成本地提交）"
else
	bad "publish.sh 在正常状态下失败：$(printf '%s' "$out" | tail -3)"
fi
if git log --oneline 2>/dev/null | grep -q .; then
	ok "确实产生了提交"
else
	bad "没有产生提交"
fi

# 负向：把 .gitignore 里的 gs.key 那行删掉，闸门必须拦住
T2=$(mktemp -d)
( cd "$project" && tar -cf - --exclude=.git --exclude=work --exclude=output \
	--exclude='*.log' --exclude=__pycache__ . ) | ( cd "$T2" && tar -xf - )
cd "$T2" || exit 1
git init -q .
# 必须把「所有」gs.key 规则都拿掉（keys/gs.key、裸 gs.key、**/gs.key），
# 否则兜底规则仍在，闸门根本没被触发，用例会假通过。
grep -vE '^(keys/gs\.key|gs\.key|\*\*/gs\.key)$' .gitignore > .gitignore.tmp \
	&& mv .gitignore.tmp .gitignore
out2=$(cd "$T2" && COMMIT_MSG=t sh "$T2/scripts/publish.sh" 2>&1)
rc2=$?
if [ $rc2 -ne 0 ]; then
	ok "gs.key 未被忽略时 publish.sh 拒绝执行（负向测试）"
else
	bad "gs.key 未被忽略时 publish.sh 竟然通过了 —— 闸门失效"
fi
printf '%s' "$out2" | grep -q 'gs.key' && ok "拒绝时给出了明确原因" || bad "拒绝时没说原因"
cd /
rm -rf "$T2"

echo
echo "----------------------------------------"
echo "通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ] || exit 1
