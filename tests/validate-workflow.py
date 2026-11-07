#!/usr/bin/env python3
"""
校验 .github/workflows/build.yml 的结构与安全约束。

需要 PyYAML：  python3 -c 'import yaml'  ||  pip install --user pyyaml

检查项：
  1. YAML 可解析，触发方式与 job 名符合预期
  2. 步骤顺序正确：构建 → 失败诊断 → 上传
  3. 「失败诊断」带 if: failure()，「上传构建日志」带 if: always()
  4. 产物路径里不含 keys/（私钥绝不能进 artifact）
  5. 文件里不含任何硬编码凭据（PAT、password、token=…）
  6. 构建步骤显式传了 BR2_DL_DIR（下载缓存靠它生效）

用法：
  python3 tests/validate-workflow.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = os.path.join(ROOT, ".github", "workflows", "build.yml")

fail = 0


def ok(msg):
    print(f"PASS  {msg}")


def bad(msg):
    global fail
    fail += 1
    print(f"FAIL  {msg}")


def extract_run_blocks(txt):
    """把每个步骤的 run: | 块抽出来，返回 [(步骤名, shell 文本)]。

    纯文本解析，不依赖 PyYAML —— 这样即使没装 PyYAML，shell 语法检查也照样跑。
    """
    lines = txt.split("\n")
    blocks, cur, i = [], None, 0
    while i < len(lines):
        m = re.match(r"^      - name:\s*(.+)$", lines[i])
        if m:
            cur = m.group(1).strip()
        m = re.match(r"^        run:\s*\|\s*$", lines[i])
        if m and cur:
            body, j = [], i + 1
            while j < len(lines):
                n = lines[j]
                if n.strip() == "":
                    body.append("")
                    j += 1
                    continue
                if len(n) - len(n.lstrip()) >= 10:
                    body.append(n)
                    j += 1
                    continue
                break
            ind = min((len(b) - len(b.lstrip()) for b in body if b.strip()), default=0)
            blocks.append((cur, "\n".join(b[ind:] if b.strip() else "" for b in body)))
            i = j
            continue
        i += 1
    return blocks


def check_run_blocks(txt):
    """每个 run 块的 shell 语法都必须过。

    语法错的步骤在 CI 里会直接让 job 失败，而 YAML 结构校验看不出来。
    GitHub 的 ${{ ... }} 先替换成占位符，避免被 shell 当命令替换。
    """
    import subprocess
    import tempfile

    blocks = extract_run_blocks(txt)
    if not blocks:
        bad("一个 run 块都没抽到")
        return

    tmp = tempfile.mkdtemp()
    p = os.path.join(tmp, "blk.sh")
    broken = []
    for name, text in blocks:
        sub = re.sub(r"\$\{\{[^}]*\}\}", "GH_EXPR", text)
        open(p, "w", encoding="utf-8").write(sub + "\n")
        r = subprocess.run(["bash", "-n", p], capture_output=True, text=True)
        if r.returncode != 0:
            broken.append(f"{name}（bash: {r.stderr.strip().splitlines()[0][:60]}）")

    if broken:
        for b in broken:
            bad(f"run 块语法错: {b}")
    else:
        ok(f"{len(blocks)} 个 run 块的 shell 语法全部通过")


def main():
    if not os.path.isfile(WF):
        print(f"FAIL  找不到 {WF}", file=sys.stderr)
        return 1

    txt = open(WF, encoding="utf-8").read()

    # 这些只依赖文本，先跑（不受 PyYAML 是否安装影响）
    check_run_blocks(txt)

    try:
        import yaml
    except ImportError:
        print("SKIP  未安装 PyYAML，跳过结构检查（pip install --user pyyaml）",
              file=sys.stderr)
        print()
        return 1 if fail else 0

    d = yaml.safe_load(txt)

    # 1. 触发方式（PyYAML 按 YAML 1.1 会把 on: 解析成 True）
    trig = d.get("on", d.get(True))
    if isinstance(trig, dict):
        keys = sorted(trig.keys())
        if "workflow_dispatch" in keys:
            ok(f"触发方式含 workflow_dispatch（共 {len(keys)} 个）")
        else:
            bad("缺 workflow_dispatch，无法手动触发")
    else:
        bad("on: 结构异常")

    jobs = d.get("jobs") or {}
    if "build" in jobs:
        ok(f"存在 build job（共 {len(jobs)} 个 job）")
    else:
        bad(f"没有 build job，实际有 {list(jobs)}")
        return 1

    steps = jobs["build"]["steps"]
    names = [s.get("name", s.get("uses", "?")) for s in steps]
    ok(f"共 {len(steps)} 个步骤")

    # 2. 顺序
    def idx(n):
        return names.index(n) if n in names else -1

    i_build, i_diag = idx("构建"), idx("失败诊断")
    if i_build >= 0 and i_diag == i_build + 1:
        ok("「失败诊断」紧跟「构建」")
    else:
        bad(f"顺序不对：构建@{i_build} 诊断@{i_diag}")

    # 3. if 条件
    if i_diag >= 0 and steps[i_diag].get("if") == "failure()":
        ok("诊断步骤带 if: failure()")
    else:
        bad("诊断步骤缺 if: failure()")

    logstep = next((s for s in steps if "构建日志" in s.get("name", "")), None)
    if logstep is not None:
        if logstep.get("if") == "always()":
            ok("日志上传带 if: always()")
        else:
            bad(f"日志上传的 if 是 {logstep.get('if')!r}，应为 always()")
    else:
        bad("找不到上传构建日志的步骤")

    # 4. 产物不得含私钥
    ups = [s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact")]
    paths = "\n".join(str(s.get("with", {}).get("path", "")) for s in ups)
    if "keys/" not in paths:
        ok(f"artifact 路径不含 keys/（{len(ups)} 个上传步骤）")
    else:
        bad("artifact 路径包含 keys/ —— 私钥会被公开")

    # 4b. 固件产物必须包含 *.tgz —— 上游 REPACK_NOR_SPLIT 打出来的包是
    #     openipc.<soc>-nor-<variant>-split.tgz，后缀 .tgz 而非 .tar。
    #     漏了它，带 md5sum 的安装包不会出现在 artifact 里。
    fw = next((s for s in ups if "固件" in str(s.get("name", ""))), None)
    if fw is None:
        bad("找不到上传固件的步骤")
    else:
        fp = str(fw.get("with", {}).get("path", ""))
        if "*.tgz" in fp:
            ok("固件 artifact 包含 *.tgz（split 安装包）")
        else:
            bad("固件 artifact 没包含 *.tgz —— split 包不会被上传")
        if "*.bin" in fp:
            ok("固件 artifact 包含 *.bin（firmware.bin）")
        else:
            bad("固件 artifact 没包含 *.bin")

    # 4c. 任何步骤都不得去 stat/读取 keys/gs.key
    #     那个文件被 .gitignore 排除、仓库里不存在，配上 set -e 会让 job 必然失败。
    runs_text = "\n".join(str(s.get("run", "")) for s in steps)
    offending = [ln.strip() for ln in runs_text.split("\n")
                 if "gs.key" in ln and ("stat" in ln or "cmp " in ln or "cat " in ln)
                 and not ln.strip().startswith("#")]
    if offending:
        for o in offending:
            bad(f"工作流里去读 keys/gs.key 会必然失败：{o[:70]}")
    else:
        ok("工作流没有去读被忽略的 keys/gs.key")

    # 5. 凭据
    leaks = []
    if re.search(r"ghp_[A-Za-z0-9]{20,}", txt):
        leaks.append("GitHub PAT (ghp_…)")
    if re.search(r"github_pat_", txt):
        leaks.append("fine-grained PAT")
    if re.search(r"(?i)password\s*[:=]\s*\S", txt):
        leaks.append("password 字段")
    if leaks:
        bad("疑似硬编码凭据: " + ", ".join(leaks))
    else:
        ok("无硬编码凭据")

    # 6. BR2_DL_DIR（缓存生效的前提）
    if i_build >= 0 and "BR2_DL_DIR" in str(steps[i_build].get("run", "")):
        ok("构建步骤传了 BR2_DL_DIR（下载缓存可生效）")
    else:
        bad("构建步骤没传 BR2_DL_DIR，actions/cache 会白存")

    cachestep = next((s for s in steps if "缓存" in s.get("name", "")
                      and str(s.get("uses", "")).startswith("actions/cache")), None)
    if cachestep is not None:
        cp = str(cachestep.get("with", {}).get("path", ""))
        if "work/dl" in cp:
            ok(f"缓存路径与 BR2_DL_DIR 一致（{cp}）")
        else:
            bad(f"缓存路径 {cp!r} 与 BR2_DL_DIR 不匹配")
    else:
        bad("没有 actions/cache 步骤")

    print()
    if fail:
        print(f"失败 {fail} 项")
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
