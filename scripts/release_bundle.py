#!/usr/bin/env python3
"""生成可分发的 .cjp 制品包，并校验包内容。

【打包范围由谁决定：cjpm.toml 的 include 字段（cjpm 官方机制）】

    `cjpm.toml` 的 `[package]` 节支持 `include` / `exclude`，两者均为字符串数组，
    匹配规则遵循 gitignore 格式。本项目**只用 include 白名单**，理由：

        黑名单（exclude）漏一项 ⇒ 多打包 ⇒ 危险（可能发布不该发布的内容）
        白名单（include）漏一项 ⇒ 少打包 ⇒ 安全（fail-closed）

    最典型的场景：将来新增一个顶层目录时，白名单不会自动把它发布出去。
    （本项目一度判断"cjpm 不支持该配置"，那是错的 —— 官方文档明确记载了
    `include` / `exclude`，只是一开始查的是 CLI 选项而非 cjpm.toml 字段。）

    官方另有两类"与配置无关"的默认规则：
        默认必打包：根目录的 cjpm.toml、README.md、README_zh.md
        默认不打包：根目录的 cjpm.lock、cangjie-repo.toml、编译产物目录、
                    构建脚本产物目录、**所有二进制文件**
    （最后一条解释了为什么 tools/Releases/ 下的二进制从不进包。）

【本脚本做三件事】

    1. **在仓库内**执行 cjpm bundle —— 刻意不在临时导出目录里打包：
       只有在 开发文档/ 这类目录**确实存在**的地方打包，才能真实检验 include
       白名单是否真的把它们拦住了。换到干净导出目录里打包，等于绕开了待验证的
       机制，只能验证"导出目录很干净"这件理所当然的事。
    2. 校验发布元数据是否漏填（METADATA_REQUIRED）：官方把这些字段**全列为可选项**，
       漏填不会让打包失败 —— 但会造成制品页缺作者、缺标签、检索不到，而这个后果
       要到发布之后才暴露（中心仓不接受同版本重复发布，届时版本号已被占用）。
    3. 校验产包内容（REQUIRED / FORBIDDEN 两张表 + 测试素材依赖断言），
      任一不满足即判失败。

【为什么要求工作区干净】

    include 是按路径生效的：落在 include 范围内的**未跟踪**文件同样会被打包。
    因此打包前必须确认工作区干净。`--allow-dirty` 仅供本机自测，且脚本会明确
    列出"混在打包范围内"的那些改动，避免悄悄把散落文件发出去。

【用法】

    python scripts/release_bundle.py                 # 发布（要求工作区干净）
    python scripts/release_bundle.py --allow-dirty   # 开发期自测
    python scripts/release_bundle.py --skip-tests    # 转发给 cjpm bundle

    退出码 0 = 制品已生成且内容校验通过；非 0 = 任一步失败或校验不通过。
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tomllib
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

# 官方规定：与 include/exclude 配置无关、**始终**打包的根目录文件。
ALWAYS_PACKED = ["cjpm.toml", "README.md", "README_zh.md"]

# ---------------------------------------------------------------------------
# 包内容契约
#
# 这两张表是「发布什么」的**断言**：产包必须同时满足
#   ① 不含任何 FORBIDDEN 条目；
#   ② 每个 REQUIRED 条目都能找到。
# 二者任一不满足即判失败 —— 尤其①，它是隐私边界（内部文档不得外泄），
# 不能靠人工肉眼核对上百个条目。
#
# 注意与 cjpm.toml 的 include 白名单**互为验证**：include 决定"打什么"，
# 这两张表断言"打出来的对不对"。任何一边被改错，另一边都会报警。
# ---------------------------------------------------------------------------

# 消费者构建本库**必须**有的东西。缺任何一个，包都是不可用的。
REQUIRED = [
    "cjpm.toml",  # 模块定义（含 include 白名单）
    "src/",  # 库源码
    "src/test/",  # 测试源码：只随包**自足子集**（依赖语料的文件见 FORBIDDEN）
    "docs/",  # 面向使用者的公开文档
    "LICENSE",
    "LICENSES.md",
    "NOTICE",
    "README.md",
]

# 【刻意不列入 REQUIRED 的一项，理由在此】
#   config/   —— cjlint 规则集只服务于仓库侧 CI，消费者不需要。
#
# 【src/test/ 为什么在 REQUIRED 里】
#   随包的是**纯内存、零副作用**的子集：不需要任何素材，也不写任何临时文件，
#   消费者解包后 `cjpm test` 就能真实跑通 —— 这是制品"可自证"的唯一路径，
#   所以是必需项。依赖语料的、以及需要写盘生成素材的用例，反过来被钉在下方
#   FORBIDDEN 里（前者素材是二进制、进不了包；后者要求可写目录、对消费者无必要）。

# 【曾经还有 build.cj 与 third-party 下的 6 个 C 文件】它们服务于"消费者现场编译
#   C 库"这条链路。C 依赖整体移除后，包内不应再出现任何 C 源码或构建脚本 ——
#   因此这些条目从 REQUIRED 里删除，并在 FORBIDDEN 侧被反过来钉住：
#   "把 C 加回来"必须是一次显式动作，不能悄悄发生。

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
    (".github/", set()),  # CI 配置
    ("tools/", set()),  # 已废弃的 cjbind 开发工具
    ("m0-poc/", set()),  # M0 历史验证工程
    ("musics/", set()),  # 本机测试素材
    ("sctiptr/", set()),  # 历史素材生成脚本（Python）
    ("scripts/", set()),  # 开发者脚本（打包、素材生成、发布）一律不进包
    ("config/", set()),  # cjlint 规则集：只服务于仓库侧 CI，消费者不需要（同类已上架包均无此目录）
    ("examples/", set()),  # 示例工程（独立模块，消费者按需从仓库取）
    ("testdata/", set()),  # 测试素材（二进制本就不会被打包，留下的是空壳）
    ("docs/release.md", set()),  # 发布流程：内部工程文档
    ("docs/codec-expansion-assessment.md", set()),  # 编解码扩展评估：内部工程文档
    # --- 依赖语料的用例：不随包 ---
    #   判据只有一条 —— **要不要素材**：这些文件需要 testdata/ 或 musics/，而素材
    #   是二进制、cjpm 官方规则不打包，留在包里只会变成守卫静默跳过的死用例。
    #   它们仍留在仓库，由仓库侧 `cjpm test` 全量运行（testdata/ 已入库）；
    #   包内的功能验证由自足用例承担（见 REQUIRED 的 src/test/）。
    #   与 cjpm.toml 的 exclude **逐个对应**：任何一边漏改，另一边（以及下方
    #   「测试素材依赖检查」的内容判据）都会报警。
    ("src/test/bench_decode_test.cj", set()),
    ("src/test/diag_dump_test.cj", set()),
    ("src/test/facade_format_test.cj", set()),
    ("src/test/flac_bitstream_test.cj", set()),
    ("src/test/flac_crc_test.cj", set()),
    ("src/test/flac_frame_test.cj", set()),
    ("src/test/flac_meta_test.cj", set()),
    ("src/test/flac_perf_diag_test.cj", set()),
    ("src/test/flac_seektable_test.cj", set()),
    ("src/test/golden_support_test.cj", set()),
    ("src/test/golden_test.cj", set()),
    ("src/test/long_run_test.cj", set()),
    ("src/test/mp3_decode_test.cj", set()),
    ("src/test/mp3_hf_regression_test.cj", set()),
    ("src/test/mp3_throughput_test.cj", set()),
    ("src/test/mp4_tags_test.cj", set()),
    ("src/test/ogg_crc_test.cj", set()),
    ("src/test/ogg_tags_test.cj", set()),
    ("src/test/probe_matrix_test.cj", set()),
    ("src/test/review_fix_test.cj", set()),
    # --- 写盘 / 生成二进制素材的用例：不随包 ---
    #   判据：用例运行时**会写出临时素材**（统一走 src/test/test_scratch.cj 的
    #   testTmpPath，落到 target/test-tmp/），或直接写 target/ 下的产物。
    #   对消费者与制品审阅者都无必要，且隐含"目录可写"这个环境要求 ——
    #   包内只留纯内存、零副作用的用例。
    #   它们仍留在仓库，由仓库侧 `cjpm test` 全量运行（自足端到端、
    #   CRC 校验与损坏样本回归、随机输入回归、WAV 写回读、流式背压等）。
    #   与 cjpm.toml 的 include 白名单**逐个对应**：任何一边漏改，另一边报警。
    ("src/test/async_frame_stream_test.cj", set()),
    ("src/test/flac_decode_test.cj", set()),
    ("src/test/fuzz_test.cj", set()),
    ("src/test/malformed_input_test.cj", set()),
    ("src/test/read_tags_test.cj", set()),
    ("src/test/selfcontained_test.cj", set()),
    ("src/test/test_scratch.cj", set()),
    ("src/test/wav_endtoend_test.cj", set()),
    ("src/test/wav_writer_test.cj", set()),
    # --- 构建产物 ---
    ("target/", set()),
    # --- C 依赖遗留：整体移除后不应再出现（防御性断言，防止将来无意带回）---
    ("third-party/", set()),  # 曾是 dr_libs 与 C 薄封装的所在地
    ("libs/", set()),  # 曾是各平台的 C 库产物目录
]

# 发布元数据中**必须非空**的字段。
#
# 【为什么是"非空断言"，而不是抄一遍官方约束】
#   官方把 authors / tag / category / license / description 全列为**可选项** ——
#   漏填**不会**让 cjpm bundle 失败，所以没有任何一步会替我们报警。
#   但后果要到发布之后才暴露：制品页缺作者、缺标签、检索不到，
#   而中心仓不接受同版本重复发布，那时版本号已被占用。
#   故"非空"是本项目自定的发布策略，只能由本脚本断言。
#
# 【为什么不在这里校验 category 的取值是否在官方枚举内】
#   官方枚举内置在 cjpm 里（二进制可见符号 cjpm.config.CATEGORY_SET），
#   cjpm bundle 已按其校验，取值非法会在打包阶段直接失败。
#   若在本脚本里再抄一份枚举，就会产生**第二份真相** —— 枚举一变即漂移。
#   本表只回答"有没有填"，字段规格与依据见 docs/release.md 的「发布元数据」章节。
METADATA_REQUIRED = [
    "name",
    "version",
    "description",
    "authors",
    "license",
    "tag",
    "category",
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


def read_include_list():
    """读取 cjpm.toml 的 [package].include —— 打包范围的唯一声明处。"""
    config_path = REPO_ROOT / "cjpm.toml"
    with config_path.open("rb") as handle:
        data = tomllib.load(handle)
    include = data.get("package", {}).get("include")
    if not include:
        raise SystemExit(
            "cjpm.toml 的 [package] 缺少 include 字段。\n"
            "  打包范围必须用 include 白名单显式声明（fail-closed）：\n"
            "  黑名单漏一项 = 多打包 = 可能把不该发布的内容发布出去。"
        )
    return [str(rule) for rule in include]


def strip_status(line: str) -> str:
    """从 `git status --porcelain` 的一行里取出路径。"""
    path = line[3:].strip().strip('"')
    if " -> " in path:  # 重命名/复制：取目标路径
        path = path.split(" -> ")[-1].strip().strip('"')
    return path


def in_packaging_scope(path: str, include) -> bool:
    """该路径是否落在打包范围内（include 规则 + 官方始终打包的文件）。"""
    for rule in list(include) + ALWAYS_PACKED:
        rule = rule.rstrip("/")
        if path == rule or path.startswith(rule + "/"):
            return True
    return False


def ensure_clean_tree(include, allow_dirty: bool) -> None:
    """include 按路径生效：范围内的未跟踪文件同样会被打包，故要求工作区干净。"""
    log("=== 1/4 检查工作区 ===")
    proc = run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=REPO_ROOT,
    )
    dirty = [line for line in proc.stdout.splitlines() if line.strip()]
    if not dirty:
        log("工作区干净 ✅")
        return

    risky = [strip_status(line) for line in dirty if in_packaging_scope(strip_status(line), include)]
    log(f"工作区有未提交改动：{len(dirty)} 项")
    if risky:
        log(f"⚠ 其中 {len(risky)} 项**落在打包范围内**，会被打进包：")
        for path in risky[:20]:
            log(f"      {path}")
        if len(risky) > 20:
            log(f"      …… 另有 {len(risky) - 20} 项")
    else:
        log("（没有落在打包范围内的改动）")

    if allow_dirty:
        log("⚠ --allow-dirty：继续，但该制品仅可用于本机自测")
        return
    raise SystemExit("打包前请先提交或清理工作区（发布请勿使用 --allow-dirty）。")


def bundle_in_repo(skip_tests: bool) -> Path:
    """在仓库内执行 cjpm bundle —— 让 include 白名单接受真实目录结构的检验。"""
    log()
    log("=== 2/4 在仓库内执行 cjpm bundle ===")
    log("（刻意不做干净导出：只有在 开发文档/ 等目录确实存在时打包，")
    log("  才能真实检验 include 白名单把它们拦住了。默认还会跑 cjpm test 与 cjlint。）")

    # 先清掉旧制品，避免校验到一个陈旧的包而得出错误结论
    for stale in (REPO_ROOT / "target").glob("*.cjp"):
        stale.unlink()
        log(f"    已删除旧制品 {stale.name}")

    cmd = ["cjpm", "bundle"]
    if skip_tests:
        cmd.append("--skip-test")
    run(cmd, cwd=REPO_ROOT)

    produced = sorted((REPO_ROOT / "target").glob("*.cjp"))
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


_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_LINE_COMMENT = re.compile(r"//[^\n]*")


def strip_comments(text: str) -> str:
    """去掉块注释与行注释，只留代码。

    "依赖素材的测试不进包"这条判据必须落在代码上：注释里出现素材路径往往是在
    **解释规则本身**（如 selfcontained_test.cj 的文件头），不算依赖。
    字符串里带 `//` 的情况在本仓测试代码里不存在，故不做词法级处理。
    """
    return _LINE_COMMENT.sub("", _BLOCK_COMMENT.sub("", text))


def read_test_sources(cjp: Path) -> dict:
    """取出包内 `*_test.cj` 的正文（剥掉顶层 `名字-版本/` 前缀）。

    供"依赖素材的测试不进包"这条断言使用：素材 testdata/、musics/ 都是二进制，
    而 cjpm 从不打包二进制，所以引用它们的用例在制品里必然跑不起来。
    """
    sources = {}
    with tarfile.open(cjp, "r:*") as tar:
        for member in tar.getmembers():
            if not member.isfile() or not member.name.endswith("_test.cj"):
                continue
            handle = tar.extractfile(member)
            if handle is None:
                continue
            rel = member.name.split("/", 1)[1] if "/" in member.name else member.name
            sources[rel] = handle.read().decode("utf-8", errors="replace")
    return sources


def read_metadata():
    """读取 cjpm bundle 生成的 target/meta-data.json —— 随制品上传的元数据。"""
    path = REPO_ROOT / "target" / "meta-data.json"
    if not path.exists():
        raise SystemExit(
            "找不到 target/meta-data.json —— 它由 cjpm bundle 生成，应在打包之后校验。"
        )
    with path.open("rb") as handle:
        return json.load(handle)


def verify_metadata() -> None:
    """断言发布元数据未漏填 —— 官方视这些字段为可选，漏填不会有任何一步报警。"""
    log()
    log("=== 3/4 校验发布元数据 ===")
    data = read_metadata()
    problems = []

    for field in METADATA_REQUIRED:
        if field not in data:
            problems.append(f"字段缺失：{field}")
            log(f"    ❌ {field:<14} meta-data.json 中不存在")
            continue
        value = data[field]
        # 字符串按去空白判空，数组按长度判空 —— 两者都是"填了没"的判据
        filled = bool(value.strip()) if isinstance(value, str) else bool(value)
        shown = value if isinstance(value, str) else "、".join(str(v) for v in value)
        if filled:
            log(f"    ✅ {field:<14} {shown}")
        else:
            problems.append(f"字段为空：{field}")
            log(f"    ❌ {field:<14} 空 —— 发布前必须填写")

    if problems:
        log()
        log("发布元数据校验**未通过**：")
        for item in problems:
            log(f"    - {item}")
        log("    字段规格与取值依据见 docs/release.md 的「发布元数据」章节。")
        raise SystemExit(1)

    log()
    log("发布元数据校验通过 ✅")


def verify_and_report(top: str, entries, test_sources) -> None:
    log()
    log(f"=== 4/4 校验包内容（顶层目录：{top}）===")
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
        prefix = rule.rstrip("/")
        hits = [
            n
            for n in entries
            if (n == prefix or n.startswith(rule))
            # 目录条目本身**不算内容**：例外只约束"目录里的东西"，而被放行的文件
            # 必然伴随它所在的目录条目。旧写法把目录条目也算作混入，于是
            # 「只放行某目录下两个文件」这类规则永远无法通过 —— 白名单首次放行
            # scripts/ 下的两个生成脚本时就撞上了（实测报"禁止项混入：scripts/"）。
            # 注意这不会削弱规则：该目录下的**其他文件**仍会被逐项拦下。
            and n != prefix
            and not any(n.endswith(suffix) for suffix in allowed)
        ]
        note = f"（允许 {'/'.join(sorted(allowed))}）" if allowed else ""
        if hits:
            problems.append(f"禁止项混入：{rule}（{len(hits)} 项，例如 {hits[:2]}）")
            log(f"    ❌ {rule:<20} 命中 {len(hits)} 项 {note}")
        else:
            log(f"    ✅ {rule:<20} 未包含 {note}")

    log("— 测试素材依赖检查 —")
    # 【判据是"有没有引用素材"，不是文件名后缀】
    #   规则：**依赖素材的测试不进包** —— 素材（testdata/、musics/）是二进制，
    #   而 cjpm 从不打包二进制，引用它们的用例对消费者必然跑不起来（报错，或者
    #   永远打印跳过）。所以包内**允许**出现自包含的 `*_test.cj`，只拦真正
    #   引用素材的那些，拦的依据只能是内容。
    # 【判据落在**代码**上，注释不算】
    #   注释里出现素材路径，往往是在**解释这条规则本身**：例如
    #   selfcontained_test.cj 的文件头写着"依赖 testdata/ 的用例在包内没有意义" ——
    #   那是说明，不是依赖。不区分注释就会把本该随包的自足用例一起拦下（实测踩过）。
    #   代价：把素材路径写进注释、代码里靠常量间接引用的情况会漏判；但这类间接引用
    #   通常仍留有代码级线索（下一条的守卫名），且漏网文件会被 FORBIDDEN 的显式
    #   清单拦住 —— 两张表互为验证，正是本脚本的设计。
    # 【除路径外还认"素材守卫"这个标记】
    #   仓库约定：依赖语料的用例在素材缺失时必须**跳过**，统一走
    #   `gsSkipIfNoFixtures(...)`（golden 基准、probe 矩阵等 17 个文件在用）。
    #   守卫名出现在代码里 ⇒ 该文件就是依赖语料的用例，与它用什么姿势拼路径无关。
    # 【为什么只扫 `*_test.cj`，不扫全部 .cj】
    #   产品代码里有**合法**的素材路径引用：src/format/mp3_decode.cj 的
    #   `exists(Path("testdata/diag/phase_timing.on"))`（诊断 sentinel，默认关闭）。
    #   对全部文件按内容判必然误报，故判据只施加在测试源文件上。
    MATERIAL_MARKERS = ("testdata", "musics")
    MATERIAL_GUARD = "SkipIfNoFixtures"
    dependent = []
    for name in sorted(test_sources):
        code = strip_comments(test_sources[name])
        hit = [marker for marker in MATERIAL_MARKERS if marker in code]
        if MATERIAL_GUARD in code:
            hit.append(MATERIAL_GUARD)
        if hit:
            dependent.append((name, hit))
    if dependent:
        shown = "、".join(f"{name}（引用 {'/'.join(hit)}）" for name, hit in dependent[:3])
        more = f"，另有 {len(dependent) - 3} 项" if len(dependent) > 3 else ""
        problems.append(f"依赖素材的测试混入：{shown}{more}")
        for name, hit in dependent[:5]:
            log(f"    ❌ {name:<36} 引用 {'/'.join(hit)}")
    else:
        log(f"    ✅ {'*_test.cj':<20} {len(test_sources)} 项，均未引用素材")

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
        for item in problems:
            log(f"    - {item}")
        raise SystemExit(1)

    log()
    log("包内容校验通过 ✅")


def collect(cjp: Path) -> Path:
    log()
    log("=== 收拢制品 ===")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    dest = OUT_DIR / cjp.name
    shutil.copy2(cjp, dest)
    log(f"    {dest}")
    log(f"    大小 {dest.stat().st_size / 1024:.1f} KB")
    return dest


def main() -> int:
    parser = argparse.ArgumentParser(description="生成可分发的 .cjp 制品包并校验内容")
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="工作区有未提交改动时也继续（仅供本机自测；可能把未跟踪文件打进包）",
    )
    parser.add_argument("--skip-tests", action="store_true", help="转发给 cjpm bundle --skip-test")
    args = parser.parse_args()

    log("=== audio4cj 发布打包 ===")
    log(f"仓库：{REPO_ROOT}")

    include = read_include_list()
    log(f"打包白名单（来自 cjpm.toml [package].include）：{include}")

    ensure_clean_tree(include, args.allow_dirty)
    cjp = bundle_in_repo(args.skip_tests)
    verify_metadata()
    top, entries = read_entries(cjp)
    test_sources = read_test_sources(cjp)
    verify_and_report(top, entries, test_sources)
    dest = collect(cjp)

    log()
    log(f"完成：{dest}")
    log("提示：实际发布由维护者执行 `cjpm publish`（不可逆，故不放进 CI）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
