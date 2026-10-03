# 发布打包

## 一句话

发布**不要**直接跑 `cjpm bundle`，用 `scripts/release_bundle.py`。

## 为什么

`cjpm bundle` 打包的是**文件系统**，而不是 git 索引 —— `.gitignore` 对它**完全无效**。

实测：在主工作区直接执行 `cjpm bundle`，制品包（`target/audio4cj-0.1.0.cjp`，**736 个条目**）
里出现了这些本不该发布的内容：

| 条目 | 数量 | 问题 |
|---|---|---|
| `开发文档/` | 2 | **内部设计留痕，明确不对外发布** |
| `tools/` | 569 | 已声明不再使用的 cjbind 开发工具 |
| `m0-poc/` | 12 | M0 阶段的历史验证工程（连它的 `target/` 缓存一起） |
| `musics/` | 3 | 本机测试素材 |
| `target/` | 3 | 构建中间物 |

而 `cjpm bundle` **没有任何** include/exclude 选项（实测仅有 `--skip-test` / `--skip-lint` / `-V`）。

## 做法

```
git archive HEAD   →   解到临时目录（只含**被跟踪**的文件）
      ↓
删除消费者用不到的开发期目录（.github/、sctiptr/ —— 纯粹减噪）
      ↓
在该目录执行 cjpm bundle（顺带跑 cjpm test 与 cjlint）
      ↓
校验包内容（必需的必须有、禁止的必须没有）
      ↓
收拢到 target/release-artifacts/
```

**关键点**：包内容的隐私边界由 `git archive` 保证（它只导出被跟踪文件），因此
**`.gitignore` 成为包内容的唯一真相来源** —— 今后要排除任何东西，只需在
`.gitignore` 里加一条，发布包自动跟随，不会再出现「某处清单忘了同步」的漂移。

> 为什么不手工维护一份「打包排除清单」：那是**另一份真相**。仓库每新增一个目录，
> 就得记得同步更新，漏掉一次就等于把它发布出去。而 `git archive` 与 `.gitignore`
> 共用同一份真相，不会漂移。

## 用法

```bash
python scripts/release_bundle.py                 # 发布（要求工作区干净）
python scripts/release_bundle.py --allow-dirty   # 开发期自测：导出 HEAD，不含未提交改动
python scripts/release_bundle.py --skip-tests    # 跳过包内的 cjpm test
python scripts/release_bundle.py --keep-staging  # 保留临时目录以便排查
```

退出码 0 = 产包已生成且内容校验通过；非 0 = 任一步失败或校验不通过。

CI 中由 [`.github/workflows/release.yml`](../.github/workflows/release.yml) 触发
（手动 `workflow_dispatch`，或推 `v*` 标签）。

## 包内容契约

脚本内有两张表（`REQUIRED` / `FORBIDDEN`），任一不满足即判失败并退出码非 0。

实测通过的包：**145 个条目 / 405 KB**（对比直接 bundle 的 736 条目 / 896 KB）。

### 必须包含

| 条目 | 说明 |
|---|---|
| `cjpm.toml`、`build.cj` | 模块定义与**构建期装配 C 库**的钩子 —— 消费者侧就靠它 |
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
| `tools/`、`m0-poc/`、`musics/`、`sctiptr/`、`.github/` | 消费者不需要 |
| `target/`、`libs/`（仅允许 `.gitkeep`） | 构建产物 / 库二进制 |

## 消费者侧的两项要求（已实测）

发布包是**纯源码**。消费者拿到后：

1. **构建期** —— 其 `cjpm` 会执行本库的 `build.cj` 钩子来自动装配 C 库
   （实测：清空 `libs/current/` 后，**只在消费者侧**执行 `cjpm build` 即自动填充完成）。
   由于包内不含库二进制（cjpm 会跳过二进制，且仓库本就不提交平台二进制），
   消费者**需要 C 编译器**。
2. **运行期** —— 产物需能加载平台对应的 C 库。Windows 上实测导入表要求的是
   **`libdrlibs.dll`（带 lib 前缀）**，而非 `drlibs.dll`；同时需要 SDK 运行期库在 PATH 中
   （`cjpm run` 会自动准备，裸跑则需自行配置）。

## 发布到仓颉中心仓

`cjpm publish` 需要先在 SDK 的 `tools/config/cangjie-repo.toml` 配置仓库地址与个人 token。

本流程只负责产出**制品**（`.cjp`）；实际 `publish` 由维护者执行 —— 它是不可逆操作，
故刻意不放进 CI。
