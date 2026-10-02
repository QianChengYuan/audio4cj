# 依赖许可证台账

> 本文件登记 audio4cj 的全部第三方依赖：来源、许可证、版本锁定方式与审计记录。
>
> **规则（本项目既定政策）**：只接受 OSI 认可的**宽许可**（公共领域 / MIT / MIT-0 / BSD / Apache-2.0），
> 且不引入专利费。GPL 系与专有许可**一律不可用**。
> 许可证结论必须**逐一核对上游仓库的 LICENSE 文件**，不接受二手声明。

## 一、运行时依赖

库被引用时会一并分发的依赖。**当前只有一个**。

### 1.1 dr_libs

| 项 | 内容 |
|---|---|
| 用途 | FLAC / WAV / MP3 的解码内核（经 C 侧薄封装 `third-party/drlibs_wrapper.c`） |
| 来源 | `third-party/dr_libs/`（含 `dr_flac.h`、`dr_wav.h`、`dr_mp3.h`） |
| 许可证 | **双选（任选其一）**：公共领域（Unlicense）**或** MIT No Attribution（MIT-0） |
| 许可证原文 | `third-party/dr_libs/LICENSE`（已核对，首段即写明"available as a choice of the following licenses"） |
| 许可风险 | **无**。两者都是最宽松的许可，且允许闭源分发 |
| 版本锁定 | 锁定 commit `dfe8377631000664666519fdb83da193fd8037f4`（dr_libs 无 Release，只能锁 commit） |
| 版本号（源码宏） | `dr_flac` **0.13.4** / `dr_wav` **0.14.6** / `dr_mp3` **0.7.4** |

**已知 CVE 与修复状态**（本项目的供应链风险清单 R1）：

| CVE | 影响 | 受影响版本上限 | 本项目版本 | 结论 |
|---|---|---|---|---|
| CVE-2025-14369 | `dr_flac` 整数溢出致 DoS | ≤ 0.13.2 | **0.13.4** | ✅ 已修复 |
| CVE-2026-29022 | `dr_wav` 堆缓冲区溢出 | ≤ 0.14.4 | **0.14.6** | ✅ 已修复 |

> 注：本项目的 WAV 解码走**纯仓颉实现**，不经 dr_wav；dr_wav 仍被编译进 `libdrlibs`，
> 因此该 CVE 的修复状态仍需跟踪。相关攻击面回归见 `src/test/cve_regression_test.cj`。

**审计方法（可复现）**：dr_libs 不发布版本标签，因此版本只能从源码宏读取：

```bash
grep -E '^#define DR(FLAC|WAV|MP3)_VERSION_(MAJOR|MINOR|REVISION)' \
    third-party/dr_libs/dr_flac.h third-party/dr_libs/dr_wav.h third-party/dr_libs/dr_mp3.h
```

**审计周期**：每季度一次，或在上游出现新 CVE 时立即执行。

## 二、构建期 / 开发期工具（不随库分发）

这些工具**只在本仓库的构建或开发流程中使用**，不会被 audio4cj 的使用者引入，
因此不受上述"运行时依赖"政策的约束，但**仍需登记**以免日后混淆。

### 2.1 C 编译器（clang / clang-cl / MSVC）

| 项 | 内容 |
|---|---|
| 用途 | 编译 `third-party/drlibs_wrapper.c` 生成动态库（由 `build.cj` 的 `pre-build` 钩子调用） |
| 许可证 | 各自的开源许可（LLVM Apache-2.0 with LLVM exception / MSVC 自带许可） |
| 是否分发 | 否 |

### 2.2 cjbind

| 项 | 内容 |
|---|---|
| 用途 | 曾经尝试用其自动生成 dr_libs 的仓颉绑定 |
| 来源 | `tools/cjbind/`（源码），**其预编译静态二进制已被 `.gitignore` 排除** |
| 许可证 | MIT（待核实原始 LICENSE 文件） |
| 当前状态 | ⚠️ **已不使用**。实测结论：cjbind 0.3.1 的生成物无法编译（13 个错误），因此本项目改为**手写最小绑定**（`src/drlibs/dr_libs_binding.cj`）。保留源码仅为留痕 |
| 是否分发 | 否（`tools/` 不参与 `cjpm` 构建） |

### 2.3 FFmpeg

| 项 | 内容 |
|---|---|
| 用途 | 1) 生成测试素材（`sctiptr/gen_audio_fixtures.py`）；2) 生成 golden PCM 比对基准（`sctiptr/gen_golden.py`） |
| 许可证 | 依构建配置而定（默认 LGPL-2.1+；Gyan 的 full build 启用了 GPL 组件） |
| 是否分发 | **否**。ffmpeg **不是**本库的依赖，不被链接，也不随库分发 |
| 对本项目许可的影响 | **无**。仅在开发机上作为"独立裁判"生成基准文件 |
| 测试是否依赖它 | **否**。golden 基准文件已随仓库入库，`cjpm test` 不需要装 ffmpeg |

## 三、已评估但**未采纳**的依赖

以下依赖在[解码扩展可行性评估](docs/codec-expansion-assessment.md)中被考虑过，但**均未引入**。
此处登记原因，便于日后复核时不必重新调研：

| 候选 | 许可证 | 未采纳原因 |
|---|---|---|
| FAAD2（AAC 解码） | **GPL-2.0-or-later** | 与本项目的宽许可政策直接冲突（GPL 会传染整个项目） |
| libfdk-aac（AAC 解码） | **Fraunhofer IIS 专有许可**（SPDX `FDK-AAC`） | 非 OSI 认可的标准开源许可，且涉及专利考量 |
| aad4cj（仓颉生态 AAC） | ⚠️ **来源冲突**：README 声明 MIT，GitHub 标注 Apache-2.0 | 许可证来源未澄清即不可用；且其官方明确声明**不支持完整的端到端 AAC 解码**，HE-AACv2 与环绕声不在其支持范围 |
| stb_vorbis（Vorbis 解码） | 公共领域 / MIT（双选） | **许可无问题，属"尚未立项"而非"不可用"** |
| libvorbis（Vorbis 解码） | BSD-3-Clause | 同上 |
| libopus（Opus 解码） | BSD-3-Clause（免专利费） | 同上 |

## 四、本项目自身的许可证

**已确定：Apache License 2.0。**

| 项 | 内容 |
|---|---|
| 许可证 | **Apache-2.0** |
| 许可证原文 | 仓库根 `LICENSE`（取自 apache.org 官方文本，11358 字节，含全部 9 条条款与附录） |
| 版权声明 | 仓库根 `NOTICE`（`Copyright 2026 QianChengYuan`） |
| 生效范围 | 本仓库的全部原创内容：探测层、元数据层、各容器读取器、C 依赖薄封装、PCM 处理、流式层、门面层、测试与脚本 |

### 4.1 与依赖许可证的兼容性

Apache-2.0 是**宽许可**，与本项目当前的全部依赖都可共存：

| 依赖 | 其许可证 | 与 Apache-2.0 的关系 |
|---|---|---|
| dr_libs | 公共领域（Unlicense）或 MIT No Attribution，二选一 | **兼容**。宽许可 → 宽许可，无任何冲突；分发时保留 `third-party/dr_libs/LICENSE` 原文即可 |

### 4.2 关于 NOTICE 的传播义务

Apache-2.0 第 4(d) 条要求：若分发物中包含带 NOTICE 文件的组件，须一并传播该 NOTICE。
本项目的情况：

- dr_libs **未提供 NOTICE 文件**，其许可证也不要求传播 NOTICE；
- 因此 `NOTICE` 只需声明**本项目自身**的版权。其中对被依赖组件的说明是
  **自愿的透明度声明**，不是许可证施加的义务。

### 4.3 对使用者的含义

| 你可以 | 条件 |
|---|---|
| 商用、闭源集成、修改、再分发 | 保留版权与许可证声明；若修改了文件，需标明修改之处 |
| 获得专利授权 | Apache-2.0 第 3 条已包含贡献者的专利授权 —— 这是它相对 MIT 的主要优势 |

| 你需要注意 | 说明 |
|---|---|
| 不得使用本项目商标 | 第 6 条不授予商标权 |
| 不提供担保 | 第 7 条声明按「原样」（AS IS）提供 |

### 4.4 关于 `cjpm.toml` 中没有 license 字段

按 cjpm 的配置规范，`[package]` 节只含 `cjc-version` / `name` / `version` /
`output-type` / `description` / `src-dir` 等项，**没有** license 字段。
因此许可证的声明载体是 `LICENSE` + `NOTICE` + 本文件，而不是 `cjpm.toml`。

## 五、审计流程

新增或更新依赖时，按以下步骤执行并**在本文件中留痕**：

1. **核对许可证原文**：克隆或下载上游，直接读其 `LICENSE` / `COPYING` 文件，
   把关键结论（许可证名 + 文件路径）写进本表。**不得**仅凭 README 或第三方页面的声明。
2. **确认在准入线内**：必须是公共领域 / MIT / MIT-0 / BSD / Apache-2.0 之一，且无专利费。
   否则不予采纳，并在第三节登记原因。
3. **锁定版本**：优先用 `commitId`（无 Release 的项目只能如此）；把锁定值写入本表。
4. **记录版本号**：解析源码中的版本宏，写入本表，便于日后比对。
5. **排查已知 CVE**：检索该版本的公开漏洞，逐条记录"受影响上限 / 本项目版本 / 结论"。
6. **评估攻击面**：本项目会解析**不可信输入**，因此任何解码依赖都要考虑畸形容器样本的回归测试
   （参考 `src/test/fuzz_test.cj` 与 `src/test/cve_regression_test.cj` 的做法）。
7. **更新构建与 CI**：`[ffi.c]`、平台产物目录、CI 矩阵随之调整。

> **审计记录应可复现**：本文件中的所有版本号都给出了可执行的提取命令，
> 所有许可证结论都指出了原文位置，避免"凭印象"的台账。
