# 发布打包

## 一句话

打包范围由 `cjpm.toml` 的 `[package].include` 白名单声明；
执行 `python scripts/release_bundle.py` 产出**并校验**制品。

## 打包范围：cjpm.toml 的 include 白名单

cjpm 官方支持在 `[package]` 下配置 `include`（指定打包范围）与 `exclude`（指定打包排除范围）。
两者均为字符串数组，**匹配规则遵循 gitignore 格式**
（见 [制品包发布 · 仓颉中心仓](https://pkgdocs.cangjie-lang.cn/docs/zh/1.0.0/central-repo/source_zh_cn/client/upload.html)）。

本项目**只用 `include` 白名单**，理由是两个方向的失效后果不对称：

| 用错方向 | 后果 |
|---|---|
| `exclude`（黑名单）漏一项 | **多打包** ⇒ 危险（可能把不该发布的内容发布出去） |
| `include`（白名单）漏一项 | 少打包 ⇒ 安全（fail-closed） |

最典型的场景：将来新增一个顶层目录时，白名单不会自动把它发布出去。

### 实测踩到的两个坑

**一、规则必须用前导斜杠锚定到仓库根目录。**

规则遵循 gitignore 语义，而 gitignore 中**不带斜杠**的规则会在**任意层级**生效。
实测：规则写成 `"src"` 时，`tools/cjbind/cjbind/cjbind/src/` 与 `m0-poc/src/`
被一并捞进了制品包（共 112 项）—— 只因它们的目录名也叫 `src`。
写成 `"/src"` 即只匹配根下的 `src`。

**二、官方另有两类与配置无关的默认规则。**

- 默认**必打包**：根目录的 `cjpm.toml`、`README.md`、`README_zh.md`
- 默认**不打包**：根目录的 `cjpm.lock`、`cangjie-repo.toml`、编译产物目录、
  构建脚本产物目录、**所有二进制文件**

最后一条解释了为什么 `libs/` 与 `tools/Releases/` 下的二进制从来进不了包 ——
这不是本项目的配置所致，而是 cjpm 的固有行为。

## 为什么还需要一个脚本

`.gitignore` 管不住 `cjpm bundle`（它打包文件系统而非 git 索引），因此打包范围
必须在 `cjpm.toml` 里**显式声明一次**；而 `scripts/release_bundle.py` 负责
**断言这次声明真的生效了**：

1. 检查工作区干净 —— `include` 按路径生效，范围内的**未跟踪**文件同样会被打包，
   所以脚本会明确指出「有哪些改动落在打包范围内」；
2. **在仓库内**执行 `cjpm bundle`（默认还会跑 `cjpm test` 与 `cjlint`）；
3. 校验产包内容（必需的必须有、禁止的必须没有）与**元数据完整性**
   （`authors` / `tag` / `category` 等不得漏填，见下节），任一不满足即退出码非 0；
4. 收拢制品到 `target/release-artifacts/`。

> **为什么刻意不做「干净导出」**：本项目一度用 `git archive` 导出到临时目录再打包，
> 但那会**绕开待验证的机制** —— 临时目录里 `开发文档/`、`tools/` 本来就不存在，
> 等于只验证了「导出目录很干净」这件理所当然的事。改在仓库内打包后，
> 每次发布都在真实目录结构上检验 include 白名单 —— 上面那个
> 「不带斜杠的规则在任意层级生效」的坑正是这样才被发现的。

## 用法

```bash
python scripts/release_bundle.py                 # 发布（要求工作区干净）
python scripts/release_bundle.py --allow-dirty   # 开发期自测（会列出范围内的未跟踪文件）
python scripts/release_bundle.py --skip-tests    # 跳过包内的 cjpm test
```

退出码 0 = 制品已生成且内容校验通过；非 0 = 任一步失败或校验不通过。

CI 中由 [`.github/workflows/release.yml`](../.github/workflows/release.yml) 触发
（手动 `workflow_dispatch`，或推 `v*` 标签）。

## 包内容契约

脚本内有两张表（`REQUIRED` / `FORBIDDEN`），任一不满足即判失败并退出码非 0。
它们与 `cjpm.toml` 的 include 白名单**互为验证**：`include` 决定「打什么」，
这两张表断言「打出来的对不对」—— 任何一边被改错，另一边都会报警。

实测通过的包：**118 个条目 / 397.9 KB**（未配置打包范围时为 736 条目 / 896 KB；
0.1.0 首次提交上架审核被退回时是 145 条目 / 422.8 KB —— 差额正是下表剔掉的那些）。

### 必须包含

| 条目 | 说明 |
|---|---|
| `cjpm.toml`、`build.cj` | 模块定义（含 `[ffi.c]` 与 include 白名单）与**构建期装配 C 库**的钩子 —— 消费者侧就靠它 |
| `src/` | 库源码 |
| `third-party/drlibs_wrapper.c` | 薄封装 C 源文件（`build.cj` 编译的就是它） |
| `third-party/dr_libs/` 下的 `dr_flac.h`、`dr_mp3.h`、`dr_wav.h` | 三个**单头文件**库 —— wrapper 只 include 这三个 |
| `third-party/dr_libs/LICENSE`、`README.md` | 第三方许可原文与出处说明（许可义务要求保留 LICENSE） |
| `config/cjlint_rule_list.json` | 项目级静态检查配置 |
| `docs/`、`README.md`、`LICENSE`、`NOTICE` | 文档与许可证 |

> **为什么 `third-party` 逐文件列出，而不是整目录**：dr_libs 原仓库还带 `tests/`
> 与 fuzzer（`*.c` / `*.cpp` / `*_fuzzer.cc`）以及 `CMakeLists.txt`，构建完全用不到，
> 而 fuzzer 是"专门让程序崩溃"的代码 —— 放进制品包对审阅者只有负面意义。
> 0.1.0 首次提交上架审核被退回后先把这类内容清出去；**退回原因未获官方说明**，
> 这是按官方安全策略里「三方库目录、内容审核」一条做的预防性收紧，不是已证实的成因。

### 绝不包含

| 条目 | 原因 |
|---|---|
| `开发文档/` | 内部设计留痕 |
| `.vscode/` | 本机路径与用户名 |
| `.codebuddy/` | 本机助手工作数据 |
| `.github/`、`tools/`、`m0-poc/`、`musics/`、`sctiptr/`、`scripts/`、`testdata/` | 消费者不需要 |
| `third-party/dr_libs/tests/` | dr_libs 的测试与 fuzzer，构建用不到（见上方说明） |
| `target/`、`libs/` | 构建产物 / 库二进制 |

## 消费者侧的要求（已实测）

发布包是**纯源码**。消费者拿到后：

1. **构建期** —— 其 `cjpm` 会执行本库的 `build.cj` 钩子来准备 C 库
   （实测：删掉 `libs/` 下的产物后，**只在消费者侧**执行 `cjpm build` 即重新编译完成）。
   C 库是**静态库**，编译需要该平台的 C 工具链（Linux / macOS 用 clang + ar，
   Windows 用 MinGW 的 gcc + ar）。由于包内不含库二进制（cjpm 一律不打包二进制），
   消费者**需要 C 编译器**。
2. **运行期** —— **无额外要求**。C 库是**静态链接**的，直接进可执行文件，
   不需要分发或加载任何动态库。
   实测：消费者产物目录中没有任何 DLL，仅把 SDK 运行期库加入 PATH 即可正常运行。

### ⚠ 一个已知的顺序约束：先 `build`，再 `check`

包内没有任何 `libs/` 目录（cjpm 从不打包二进制），而 `cjpm check` 在配置解析阶段
就校验 `[ffi.c]` 指向的库是否存在、且**不触发构建脚本**。因此消费者侧的正确顺序是：

```bash
cjpm build     # 先由 build.cj 编出 libs/<平台>/libdrlibs.a
cjpm check     # 此时才能通过
```

反过来会报 `can not find the library 'drlibs' which is listed in
'target.<三元组>.ffi.c' field`。`cjpm build` 与 `cjpm test` 不受影响 —— 它们都会先跑
各自的钩子。**注意：仓库内 `check` 通过 ≠ 包内 `check` 通过** —— 本仓库的
`libs/windows_x86_64/` 预置了产物（二进制入库），而制品包里没有。

**这条约束无法靠配置消除**（两条路都已实测否掉）：二进制进不了包；把库引用改由
`link-option` 承担则**不会传递到消费者的最终链接**（消费者链接报 undefined symbol），
而 `[ffi.c]` 恰是唯一能把 C 库依赖传给消费者的机制。成因详见 `build.cj` 文件头。

## 发布元数据（仓颉中心仓）

`[package]` 下与发布相关的元数据，本项目的取值与依据：

| 字段 | 本项目取值 | 必填 | 说明 |
|---|---|---|---|
| `authors` | `["yuan_1992"]` | 否 | 制品页展示的作者 ID 列表 |
| `license` | `["Apache-2.0"]` | 否 | 官方要求取值遵循 [SPDX Identifier](https://spdx.org/licenses/) 规范 |
| `repository` | GitCode 仓库 url | 否 | 制品代码仓。以 GitCode 为对外主仓；CI 仍跑在 GitHub，**本字段不参与构建** |
| `homepage` | 同 `repository` | 否 | 制品主页 |
| `documentation` | `.../blob/main/README.md` | 否 | 制品文档页。用**网页视图** `/blob/` 而非纯文本 `/raw/`（两者均实测返回 200） |
| `tag` | `["audio", "flac", "mp3", "wav", "decoder"]` | 否 | 制品标签，**上限 5 项**（见下） |
| `category` | `["Audio and Video"]` | 否 | 必须取自官方枚举，此处为规范写法（见下） |

`organization` 留空即「无组织模块」（官方语义），本项目即如此。
`name` / `version` / `cjc-version` / `output-type` / `description` 为必填项，见官方字段表。

### 官方约束（来源说明）

官方文档给出了字段清单与必填性，但**未给出** `tag` / `category` 的取值约束 ——
[制品包发布](https://pkgdocs.cangjie-lang.cn/docs/zh/1.0.0/central-repo/source_zh_cn/client/upload.html)
与[中心仓元数据规格](https://pkgdocs.cangjie-lang.cn/docs/zh/1.0.0/central-repo/source_zh_cn/appendix/meta_data.html)
两页均未提及数量上限、字符长度或枚举白名单。以下三条因此来自 **cjpm 自身**：

1. **`tag` 上限 5 项** —— cjpm 内含校验文案 `Error: size of field 'tag' cannot be over ...`；
   相邻工程 `winsound4cj` 实测报错为 `...cannot be over 5`。
   本项目列表**恰好 5 项，不可再增**。
2. **`category` 必须取自官方枚举** —— cjpm 内置该枚举（二进制中可见符号
   `cjpm.config.CATEGORY_SET`），并同样有长度校验
   （`Error: size of field 'category' cannot be over ...`）。
3. **`category` 会被归一化** —— 实测写入小写 `audio and video` 被接受，但生成的
   `target/meta-data.json` 中为规范写法 `Audio and Video`；故 `cjpm.toml` 直接写规范形式。

> **枚举提取方法的局限（务必知悉）**：`Audio and Video` 是从 `cjpm.exe` 的字符串池里
> 提取出的候选，与 `video`、`algorithm`、`animation`、`character encoding`、
> `image processing`、`database framework`、`database driver`、`network`、`security`、
> `logging`、`developer tools`、`scientific computing` 等约二十余项同处一个聚集区。
> 该字符串池中**同时混有 cjpm 的选项名与字段名**，因此不能据此宣称拿到了完整枚举。
>
> 可靠兜底是 `cjpm bundle` —— 它按官方枚举校验，取值非法会在**打包阶段**直接失败
> （fail-fast），而不是等到上传。所以本项目**不把枚举抄进脚本**：
> 那会制造第二份真相，枚举一变就漂移。

### 元数据在何时被校验

| 时机 | 校验者 | 内容 |
|---|---|---|
| 打包 | `cjpm bundle` | 官方规则：字段长度上限、`category` 枚举合法性 |
| 打包后 | `scripts/release_bundle.py` | 项目策略：**是否漏填**（非空断言），**不**重复官方枚举 |

生成物是 `target/meta-data.json`，随制品上传、供仓库端入库检查。

### 为什么"漏填"必须由脚本拦下

`authors` / `tag` / `category` / `license` / `description` 在 cjpm 里**全是可选项** ——
漏填**不会**导致打包失败。但后果是制品页缺作者、缺标签、检索不到，
而且这个后果**要到发布之后才会被发现**，那时版本号已被占用
（中心仓不接受同版本重复发布）。

因此发布脚本对这几项做非空断言：让"忘了填"在本地就被拦下，而不是在发布之后。

## 发布到仓颉中心仓

`cjpm publish` 需要先在 SDK 的 `tools/config/cangjie-repo.toml` 配置仓库地址与个人 token。

本流程只负责产出**制品**（`.cjp`）；实际 `publish` 由维护者执行 —— 它是不可逆操作，
故刻意不放进 CI。
