#!/usr/bin/env python3
"""从**干净源码导出**生成可分发的 .cjp 包，并校验包内容。

【为什么必须有这一步：不能直接在主工作区执行 cjpm bundle】

    `cjpm bundle` 打包的是**文件系统**，而不是 git 索引 —— 实测它会把
    `.gitignore` 排除掉的目录原样打进包。在主工作区实测的结果是包里出现了：

        开发文档/        2 项   ← 内部设计留痕，明确不对外发布
        tools/         569 项   ← 已声明不再使用的 cjbind 开发工具
        m0-poc/         12 项   ← M0 阶段的历史验证工程（含其 target/ 缓存）
        musics/          3 项   ← 本机测试素材
        target/          3 项   ← 构建中间物

    也就是说：`.gitignore` 对 bundle **完全无效**，而 `cjpm bundle` 本身
    也没有任何 include/exclude 选项（实测仅有 --skip-test / --skip-lint / -V）。

【本脚本的做法】

    git archive HEAD      →  解到临时目录（只含**被跟踪**的文件）
         ↓
    在该目录执行 cjpm bundle（同时会跑 cjpm test，即那 176 个用例）
         ↓
    校验产包条目（必须含的 / 绝不能含的）
         ↓
    把 .cjp 收拢到 target/release-artifacts/

【为什么用 git archive，而不是手工维护一份排除清单】

    排除清单是**另一份真相**：仓库每新增一个目录，就得记得同步更新，
    漏掉一次就等于把它发布出去。`git archive` 的依据是「哪些文件被跟踪」，
    与 `.gitignore` 共用同一份真相，不会漂移 ——
    今后再排除任何东西，只需要在 `.gitignore` 里写一条，发布流程自动跟随。

【用法】

    python scripts/release_bundle.py                 # 要求工作区干净
    python scripts/release_bundle.py --allow-dirty   # 开发期自测用
    python scripts/release_bundle.py --skip-tests    # 转发给 cjpm bundle

    退出码 0 = 产包已生成且内容校验通过；非 0 = 任一步失败或校验不通过。
"""

import argparse
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "target" / "release-artifacts"

# Windows 控制台默认 GBK：本脚本输出的中文与 ⚠/✅ 等符号会直接抛
# UnicodeEncodeError 而中断（实测如此）。强制 UTF-8 并容错替换，
# 使脚本在任何终端下都不会因**输出编码**而失败 —— 发布流程不该被这种事卡住。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):  # 极老的解释器或无 reconfigure 的流
        pass

# ---------------------------------------------------------------------------
# 包内容契约
#
# 这两张表是「发布什么」的**唯一声明**：产包必须同时满足
#   ① 不含任何 FORBIDDEN 条目；
#   ② 每个 REQUIRED 条目都能找到。
# 二者任一不满足即判失败 —— 尤其①，它是隐私边界（内部文档不得外泄），
# 不能靠人工肉眼核对 736 个条目。
# ---------------------------------------------------------------------------

# 消费者构建本库**必须**有的东西。缺任何一个，包都是不可用的。
REQUIRED = [
    "cjpm.toml",  # 模块定义（含 [ffi.c]）
    "build.cj",  # 构建期装配 C 库的钩子 —— 消费者侧就靠它
    "src/",  # 库源码
    "third-party/dr_libs/",  # C 库来源，消费者需用它现场编译
    "config/cjlint_rule_list.json",  # 项目级静态检查配置
    "docs/",  # 面向使用者的公开文档
    "LICENSE",
    "NOTICE",
    "README.md",
]

# 导出后、打包前**主动删除**的目录。
#
# 【为什么删除是安全的】包内容的**隐私边界**由 `git archive` 保证（它只导出
# 被跟踪文件，而 .gitignore 里的东西都没被跟踪），下面这一步纯粹是**减噪**：
# 把消费者用不到的开发期资料去掉。即使这里漏掉了什么，第 3 步的 FORBIDDEN
# 断言仍会把它拦下来 —— 两道防线，各自都能独立成立。
PRUNE = [
    (".github", "CI 配置，消费者不需要"),
    ("sctiptr", "素材生成脚本（依赖 ffmpeg），消费者不需要"),
]

# 绝不能进入分发包的条目。
#
# 每项是 (路径前缀, 允许的例外后缀集合)；例外用来表达
# 「这个目录可以存在，但里面的内容受限」。
FORBIDDEN = [
    # --- 隐私 / 内部分发边界 ---
    ("开发文档/", set()),  # 内部设计留痕，明确不发布
    (".vscode/", set()),  # 本机编辑器状态（含本机路径与用户名）
    (".codebuddy/", set()),  # 本机助手工作数据
    # --- 纯噪声，消费者不需要 ---
    (".github/", set()),  # 已由 PRUNE 删除；此处断言它真的没了
    ("tools/", set()),  # 已废弃的 cjbind 开发工具
    ("m0-poc/", set()),  # M0 历史验证工程
    ("musics/", set()),  # 本机测试素材
    ("sctiptr/", set()),  # 已由 PRUNE 删除；此处断言它真的没了
    # --- 构建产物 ---
    ("target/", set()),
    # C 库二进制不随包发布：消费者侧的 build.cj 会自己装配（见 README）。
    # 只允许 .gitkeep —— 它让 build.cj 需要的占位目录在包里继续存在。
    ("libs/", {".gitkeep"}),
]


def log(msg: str = "") -> None:
    print(msg, flush=True)


def run(cmd, cwd=None, check=True):
    """执行外部命令；失败即终止（避免在错误状态上继续打包）。"""
    printable = " ".join(str(c) for c in cmd)
    log(f"$ {printable}" + (f"    (cwd={cwd})" if cwd else ""))
    proc = subprocess.run(
        [str(c) for c in cmd], cwd=cwd, capture_output=True, text=True, errors="replace"
    )
    if proc.stdout.strip():
        log(proc.stdout.rstrip())
    if proc.stderr.strip():
        print(proc.stderr.rstrip(), file=sys.stderr, flush=True)
    if check and proc.returncode != 0:
        raise SystemExit(f"命令失败（退出码 {proc.returncode}）：{printable}")
    return proc


def ensure_clean_tree(allow_dirty: bool) -> None:
    """发布必须对应一个确定的提交 —— 工作区脏时导出的内容与你的改动不符。"""
    dirty = run(["git", "status", "--porcelain"], cwd=REPO_ROOT).stdout.strip()
    if not dirty:
        log("工作区干净 ✅")
        return
    if allow_dirty:
        log("⚠ 工作区有未提交改动（--allow-dirty）：导出的是 HEAD，不含这些改动")
        return
    log("工作区有未提交改动，拒绝打包：")
    for line in dirty.splitlines()[:20]:
        log(f"    {line}")
    raise SystemExit("先提交，或显式加 --allow-dirty（发布请勿使用后者）")


def export_sources(staging: Path) -> None:
    """git archive HEAD —— 只导出被跟踪文件，这是包内容的唯一真相来源。"""
    archive = staging / "_export.tar"
    log()
    log("=== 1/4 导出干净源码（git archive HEAD）===")
    run(["git", "archive", "--format=tar", "-o", archive, "HEAD"], cwd=REPO_ROOT)
    with tarfile.open(archive) as tar:
        tar.extractall(staging)
    archive.unlink()
    count = sum(1 for p in staging.rglob("*") if p.is_file())
    log(f"导出完成：{count} 个文件")


def prune_staging(staging: Path) -> None:
    """删掉消费者用不到的开发期目录（减噪；隐私边界已由 git archive 保证）。"""
    log()
    log("=== 1.5/4 减噪：删除消费者不需要的开发期资料 ===")
    for name, why in PRUNE:
        target = staging / name
        if target.exists():
            shutil.rmtree(target)
            log(f"    已删除 {name}/ —— {why}")
        else:
            log(f"    {name}/ 本就不在导出中（未跟踪）")


def bundle_in(staging: Path, skip_tests: bool) -> Path:
    """在导出目录内执行 cjpm bundle（默认同时跑 cjpm test 与 cjlint）。"""
    log()
    log("=== 2/4 在导出目录内执行 cjpm bundle ===")
    log("（cjpm bundle 默认会跑 cjpm test 与 cjlint —— 包内的测试结果顺带被验证）")
    cmd = ["cjpm", "bundle"]
    if skip_tests:
        cmd.append("--skip-test")
    run(cmd, cwd=staging)

    produced = sorted((staging / "target").glob("*.cjp"))
    if not produced:
        raise SystemExit("cjpm bundle 未产出 .cjp 文件（target/ 下找不到）")
    if len(produced) > 1:
        log(f"⚠ target/ 下有多个 .cjp，取第一个：{[p.name for p in produced]}")
    return produced[0]


def read_entries(cjp: Path):
    """读取包内条目，剥掉顶层的 `名字-版本/` 前缀。"""
    with tarfile.open(cjp, "r:*") as tar:
        names = tar.getnames()
    if not names:
        raise SystemExit("产包是空的")
    top = names[0].split("/")[0]
    prefix = top + "/"
    return top, [n[len(prefix):] for n in names if n.startswith(prefix)]


def verify_and_report(top: str, entries) -> None:
    log()
    log(f"=== 3/4 校验包内容（顶层目录：{top}）===")
    log(f"条目总数：{len(entries)}")

    # 按第一层目录汇总，便于人眼快速核对
    buckets = {}
    for name in entries:
        parts = [p for p in name.split("/") if p]
        if not parts:
            continue
        key = parts[0] + ("/" if len(parts) > 1 else "")
        buckets[key] = buckets.get(key, 0) + 1
    log("包内第一层项：")
    for key in sorted(buckets, key=lambda k: -buckets[k]):
        log(f"    {key:<32} {buckets[key]}")

    problems = []

    log("— 禁止项检查 —")
    for rule, allowed in FORBIDDEN:
        hits = [
            n
            for n in entries
            if (n == rule.rstrip("/") or n.startswith(rule))
            and not any(n.endswith(suffix) for suffix in allowed)
        ]
        note = f"（允许 {'/'.join(sorted(allowed))}）" if allowed else ""
        if hits:
            problems.append(f"禁止项混入：{rule}（{len(hits)} 项，例如 {hits[:2]}）")
            log(f"    ❌ {rule:<20} 命中 {len(hits)} 项 {note}")
        else:
            log(f"    ✅ {rule:<20} 未包含 {note}")

    log("— 必需项检查 —")
    for rule in REQUIRED:
        hits = [n for n in entries if n == rule.rstrip("/") or n.startswith(rule)]
        if hits:
            log(f"    ✅ {rule:<28} {len(hits)} 项")
        else:
            problems.append(f"必需项缺失：{rule}")
            log(f"    ❌ {rule:<28} 缺失")

    if problems:
        log()
        log("包内容校验**未通过**：")
        for p in problems:
            log(f"    - {p}")
        raise SystemExit(1)

    log()
    log("包内容校验通过 ✅")


def collect(cjp: Path) -> Path:
    log()
    log("=== 4/4 收拢产物 ===")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    dest = OUT_DIR / cjp.name
    shutil.copy2(cjp, dest)
    size_kb = dest.stat().st_size / 1024
    log(f"    {dest}")
    log(f"    大小 {size_kb:.1f} KB")
    return dest


def main() -> int:
    parser = argparse.ArgumentParser(description="从干净源码导出生成可分发的 .cjp 包")
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="工作区有未提交改动时也继续（导出的是 HEAD，仅供开发期自测）",
    )
    parser.add_argument("--skip-tests", action="store_true", help="转发给 cjpm bundle --skip-test")
    parser.add_argument("--keep-staging", action="store_true", help="保留临时目录以便排查")
    args = parser.parse_args()

    log("=== audio4cj 发布打包 ===")
    log(f"仓库：{REPO_ROOT}")

    ensure_clean_tree(args.allow_dirty)

    staging = Path(tempfile.mkdtemp(prefix="audio4cj-release-"))
    log(f"临时目录：{staging}")
    try:
        export_sources(staging)
        prune_staging(staging)
        cjp = bundle_in(staging, args.skip_tests)
        top, entries = read_entries(cjp)
        verify_and_report(top, entries)
        dest = collect(cjp)
    finally:
        if args.keep_staging:
            log(f"（--keep-staging：保留 {staging}）")
        else:
            shutil.rmtree(staging, ignore_errors=True)

    log()
    log(f"完成：{dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
