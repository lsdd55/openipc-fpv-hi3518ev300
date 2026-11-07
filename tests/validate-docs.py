#!/usr/bin/env python3
"""
文档一致性检查。

八轮改动下来文档必然漂移，这个脚本用机械方式守住两件事：

  1. 交叉引用能落地 —— 所有 `docs/X.md` §N 与同文件内的 §N 都必须在目标文档
     里真实存在（`RFC 7748 §5.2` 这类外部引用会被跳过）。
  2. README 自称的断言数自洽 —— §7.1 标题里的数字、正文"这 N 项"的数字、
     以及表格各分项之和，三者必须相等。

不需要任何外部依赖。

用法：
  python3 tests/validate-docs.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = 0


def ok(m):
    print(f"PASS  {m}")


def bad(m):
    global fail
    fail += 1
    print(f"FAIL  {m}")


def numkey(s):
    return [int(x) for x in s.split(".")]


def load_docs():
    docs = {}
    for dirpath, _, files in os.walk(ROOT):
        for f in sorted(files):
            if not f.endswith(".md"):
                continue
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, ROOT).replace("\\", "/")
            txt = open(p, encoding="utf-8").read()
            secs, titles = set(), {}
            for line in txt.split("\n"):
                m = re.match(r"^(#{2,4})\s+(\d+(?:\.\d+)?)\.?\s+(.*)$", line.strip())
                if m:
                    secs.add(m.group(2))
                    titles[m.group(2)] = m.group(3).strip()
            docs[rel] = {"text": txt, "secs": secs, "titles": titles}
    return docs


def is_rfc_ref(text, pos):
    """pos 处的 § 是否属于 `RFC 7748 §5.2` 这类外部引用。

    同一行里该 § 之前出现过 RFC 编号就认作外部引用 —— 一行里同时出现
    RFC 章节号和本文档章节号的情况不存在，所以这个启发式够用。
    """
    line_start = text.rfind("\n", 0, pos) + 1
    return bool(re.search(r"RFC\s*\d+", text[line_start:pos]))


def check_refs(docs):
    print("\n== 交叉引用 ==")
    n_ok = 0
    for rel in sorted(docs):
        d = docs[rel]
        txt = d["text"]

        # 跨文件：`docs/X.md` ... §N
        for m in re.finditer(r"`([^`]*\.md)`[^\n]{0,40}?§(\d+(?:\.\d+)?)", txt):
            target, num = m.group(1), m.group(2)
            line = txt[:m.start()].count("\n") + 1
            tkey = next((k for k in docs if k.endswith(os.path.basename(target))), None)
            if tkey is None:
                bad(f"{rel}:{line} 引用了不存在的文件 {target}")
            elif num not in docs[tkey]["secs"]:
                bad(f"{rel}:{line} {target} 里没有 §{num}")
            else:
                n_ok += 1

        # 同文件：裸 §N
        for m in re.finditer(r"§(\d+(?:\.\d+)?)", txt):
            num = m.group(1)
            if ".md" in txt[max(0, m.start() - 40):m.start()]:
                continue          # 上面已按跨文件处理
            if is_rfc_ref(txt, m.start()):
                continue
            if num not in d["secs"]:
                line = txt[:m.start()].count("\n") + 1
                bad(f"{rel}:{line} 本文件没有 §{num}（裸引用）")
            else:
                n_ok += 1

    if n_ok:
        ok(f"{n_ok} 处交叉引用全部能落地")


def check_counts(docs):
    print("\n== README 断言数自洽 ==")
    d = docs.get("README.md")
    if not d:
        bad("缺 README.md")
        return
    t = d["text"]

    m = re.search(r"^###\s+7\.1\s+[^\n]*?(\d+)\s*项断言", t, re.M)
    if not m:
        bad("README §7.1 标题里找不到「N 项断言」")
        return
    stated = int(m.group(1))

    m = re.search(r"这 (\d+) 项在两种 shell 下都跑过", t)
    if not m:
        bad('找不到「这 N 项在两种 shell 下都跑过」那句话')
        return
    inline = int(m.group(1))

    # 表格各分项（最后一列是数字的行）
    rows = re.findall(r"^\|\s*`[^`]+`\s*\|[^|\n]*\|\s*(\d+)[^|\n]*\|\s*$", t, re.M)
    total = sum(int(x) for x in rows)

    if not rows:
        bad("§7.1 的测试表格里没解析到分项数字")
        return

    ok(f"表格分项 {rows} 相加 = {total}")
    if stated == inline == total:
        ok(f"§7.1 标题({stated}) = 正文({inline}) = 表格合计({total})")
    else:
        bad(f"断言数不一致：标题 {stated} / 正文 {inline} / 表格合计 {total}")


def check_stale(docs):
    print("\n== 已废弃的说法 ==")
    # 断言数只保留当前值
    stale_counts = [r"45 项断言", r"58 项断言", r"61 项断言", r"90 项断言"]
    hit = 0
    for rel, d in docs.items():
        for pat in stale_counts:
            for m in re.finditer(pat, d["text"]):
                line = d["text"][:m.start()].count("\n") + 1
                bad(f"{rel}:{line} 出现过时的断言数「{m.group(0)}」")
                hit += 1

    # fpv/wfbng 只允许出现在"解释这个 bug"的上下文里。
    # 判据：同一行含 斜杠 / 改成 / 弃用 / 不命中 之一。
    exempt = ("斜杠", "改成", "弃用", "不命中", "曾经")
    for rel, d in docs.items():
        for m in re.finditer(r"fpv/wfbng", d["text"]):
            line_start = d["text"].rfind("\n", 0, m.start()) + 1
            line_end = d["text"].find("\n", m.start())
            line = d["text"][line_start:line_end if line_end > 0 else len(d["text"])]
            if any(w in line for w in exempt):
                continue
            n = d["text"][:m.start()].count("\n") + 1
            bad(f"{rel}:{n} 出现 fpv/wfbng 但不是在解释这个 bug"
                f"（可能把旧 VARIANT 值又写回去了）")
            hit += 1

    if not hit:
        ok("没有残留的过时说法（断言数、VARIANT）")


def main():
    docs = load_docs()
    print(f"扫到 {len(docs)} 个 markdown 文件")
    check_refs(docs)
    check_counts(docs)
    check_stale(docs)
    print()
    if fail:
        print(f"失败 {fail} 项")
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
