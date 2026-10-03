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
3. 校验产包内容（必需的必须有、禁止的必须没有），任一不满足即退出码非 0；
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

实测通过的包：**142 个条目 / 409 KB**（未配置打包范围时为 736 条目 / 896 KB）。

### 必须包含

| 条目 | 说明 |
|---|---|
| `cjpm.toml`、`build.cj` | 模块定义（含 `[ffi.c]` 与 include 白名单）与**构建期装配 C 库**的钩子 —— 消费者侧就靠它 |
| `src/` | 库源码 |
| `third-party/dr_libs/` | C 库来源（消费者需用它现场编译） |
| `config/cjlint_rule_list.json` | 项目级静态检查配置 |
| `docs/`、`README.md`、`LICENSE`、`NOTICE` | 文档与许可证 |

### 绝不包含

| 条目 | 原因 |
|---|---|
| `开发文档/` | 内部设计留痕 |
| `.vscode/` | 本机路径与用户名 |
| `.codebuddy/` | 本机助手工作数据 |
| `.github/`、`tools/`、`m0-poc/`、`musics/`、`sctiptr/`、`scripts/`、`testdata/` | 消费者不需要 |
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

## 发布到仓颉中心仓

`cjpm publish` 需要先在 SDK 的 `tools/config/cangjie-repo.toml` 配置仓库地址与个人 token。

本流程只负责产出**制品**（`.cjp`）；实际 `publish` 由维护者执行 —— 它是不可逆操作，
故刻意不放进 CI。
