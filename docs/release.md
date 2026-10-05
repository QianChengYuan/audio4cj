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

最后一条解释了为什么 `tools/Releases/` 下的二进制从来进不了包（`libs/` 这个 C 产物目录本身已随依赖移除）——
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

> **素材生成脚本不随包**（`scripts/gen_testdata.sh` / `.ps1`）：它们服务于**仓库侧**的
> 全量测试（`testdata/` 已入库，需要重建时才跑）。包内的功能验证走另一条路 ——
> **自足用例**：输入在仓颉里现场构造，不需要素材，也不需要任何外部工具（见「测试素材」一节）。

## 包内容契约

脚本内有两张表（`REQUIRED` / `FORBIDDEN`），任一不满足即判失败并退出码非 0。
它们与 `cjpm.toml` 的 include 白名单**互为验证**：`include` 决定「打什么」，
这两张表断言「打出来的对不对」—— 任何一边被改错，另一边都会报警。

实测通过的包：**96 个条目 / 175.1 KB**（历史对照：未配置打包范围时 736 条目 / 896 KB；
配置打包范围后 118 条目；C 依赖整体移除后 112 条目；**本版把依赖语料的用例、`scripts/`
与两份内部工程文档移出包**后为 96 条目 —— 条目数与体积的每次变化都是"包里有什么"的快照）。

> 体积为什么只给近似值：`docs/` 本身也在包里，**任何文档编辑都会改变包体积**，
> 写精确数字反而追不上自己。条目数是稳定的，体积不是。

### 必须包含

| 条目 | 说明 |
|---|---|
| `cjpm.toml` | 模块定义（含 include 白名单） |
| `src/` | 库源码，**含 `src/test/` 的自足子集** —— 包内用例不依赖任何外部素材（见「测试素材」一节） |
| `docs/`、`README.md`、`LICENSE`、`LICENSES.md`、`NOTICE` | 文档与许可证 |

> **这里曾列出 `build.cj` 与 third-party 下的 6 个 C 文件**（薄封装 + 三个单头文件库
> + LICENSE + README.md）。它们存在的唯一目的是让消费者现场编译 C 库。C 依赖整体移除后，
> 制品里不再有任何 C 代码 —— 这一边少了条目，而"绝不包含"那一边**反过来把
> `third-party/` 与 `libs/` 断言为禁止项**：白名单漏项是安全的，而"把 C 加回来"
> 必须是一次显式动作。

### 绝不包含

| 条目 | 原因 |
|---|---|
| `开发文档/` | 内部设计留痕 |
| `.vscode/` | 本机路径与用户名 |
| `.codebuddy/` | 本机助手工作数据 |
| `.github/`、`tools/`、`m0-poc/`、`musics/`、`sctiptr/` | 消费者不需要 |
| `scripts/` | 开发者脚本（打包 / 素材生成 / 发布）一律不进包 |
| `config/` | cjlint 规则集：只服务于仓库侧 CI，消费者不需要 |
| `testdata/` | **测试素材不随包分发**（`cjpm bundle` 不打包二进制，机制上做不到；详见下节） |
| `docs/release.md`、`docs/codec-expansion-assessment.md` | 内部工程文档（发布流程、编解码扩展评估）：留在仓库，不发往制品页 |
| `src/test/` 下 14 个依赖语料的用例 | 它们需要 `testdata/` 与 ffmpeg 基准，随包只会变成跑不起来的死用例（见下节） |
| `third-party/`、`libs/` | **C 依赖遗留**：前者曾是 dr_libs 与 C 薄封装的所在地，后者曾是各平台的库产物目录。整体移除后不应再出现（防御性断言） |
| `target/` | 构建产物 |

> 历史沿革：`third-party/dr_libs/tests/`（dr_libs 的测试与 fuzzer）也曾被单独剔除 ——
> fuzzer 是"专门让程序崩溃"的代码，放进制品包对审阅者只有负面意义。
>
> **`src/test/` 的取舍走过两次弯路，记在这里**：先是整个 `src/test/` 不随包（"包里连
> 可运行的验证都没有"）；随后改成整包带上测试源码 + 素材生成脚本，但包内没有
> `testdata/`，于是**守卫静默跳过 —— 包内报"206 通过"而其中 42 条一行都没执行**（假绿）。
> 现行做法是第三条路：**包内只带自足用例**（输入现场构造），依赖语料的用例留在仓库。

## 测试素材不随包分发，包内验证靠"自足用例"（随包使用者的必读项）

**结论**：制品包内**含 `src/test/` 的自足子集**，**不含 `testdata/`**，也**不含**素材生成脚本。

**成因（平台行为，改不了）**：`cjpm bundle` **不打包二进制文件**。实测把 `/testdata`
加进 `[package].include` 后重新打包：产物几乎不变，包里只多出 `MANIFEST.tsv` 与
`GOLDEN.tsv` 两个**文本**文件，**61 个音频素材一条都没进去**；且 `cjpm bundle --help`
只有 `--skip-test` / `--skip-lint` / `-V`，**没有任何纳入二进制的开关**。

**因此包内的可验证性是这样成立的**：

| 项 | 实情 |
|---|---|
| 包内 `cjpm test` | **143 条全部真实执行**（`PASSED=143, SKIPPED=0, ERROR=0, FAILED=0`），**不需要任何外部工具、不需要素材、不需要联网**。实测：解包到干净目录直接 `cjpm test` |
| 输入从哪来 | 现场构造：WAV（RIFF + PCM）、FLAC（**verbatim 子帧** + 规范 CRC-8/CRC-16）、Ogg 页（映射头 + 跨页续传 + 页 CRC-32）、MP4 box 树、ID3v1/v2 与 Vorbis comment。见 `src/test/selfcontained_test.cj` |
| 判据从哪来 | 由构造式给出：期望 PCM 就是构造时写入的样本（FLAC）；Ogg 封装后的解码结果必须与原生 FLAC **逐位相同** |
| 负向用例 | 两组"改坏一个字节必须报错"：FLAC 帧 CRC-16、Ogg 页 CRC-32。它们与正向用例同等重要 —— 对"损坏被静默接受"是盲的测试等于没有 |
| 未随包的那部分 | 14 个依赖语料的用例留在仓库，由仓库侧 `cjpm test` 全量运行（**222 条**）。仓库侧另有 ffmpeg golden 逐样本比对、素材识别矩阵与基准比对 |
| 重建仓库素材 | `bash scripts/gen_testdata.sh`（或 `.ps1`）用 ffmpeg 就地重建 `testdata/`（61 个文件，全部由合成信号编码而来，不含第三方版权内容）；素材已入库，通常不需要重建 |
| 需要什么前置 | 包内测试：**无**。仓库侧重建素材：ffmpeg / ffprobe（需含 aac / libvorbis / libopus / flac / libmp3lame 编码器；libspeex 可选） |

> **体积与条目对照**：仓库内 `testdata/` 约 5.7 MB（61 文件）；制品包 **96 条目 /
> 175.1 KB** —— **不含**素材与生成脚本，测试源码只带自足子集。
>
> **为什么仍以白名单为主、`exclude` 只做少量精确排除**：两者失效方向不对称 ——
> `exclude` 漏一项 = 多打包 = 危险；`include` 漏一项 = 少打包 = 安全。因此主线仍是
> `include` 白名单（理由见 `scripts/release_bundle.py` 文件头），`exclude` 只用于
> "白名单里某个目录内需要剔除若干具体文件"这一种情形（语料用例、内部文档）。

## 消费者侧的要求（已实测）

发布包是**纯源码，且不含任何 C 代码**。消费者拿到后：

1. **构建期** —— **无额外要求**：只需 SDK 自带的 `cjpm`，**不需要 C 编译器**，
   也不需要预先准备任何库产物。（实测：`cjpm build` / `cjpm check` / `cjpm test`
   全部通过，且构建输出中 C 编译器痕迹为 **0 行**；包内 C 相关条目为 **0 条**。）
2. **运行期** —— **无额外要求**：纯仓颉实现，不加载任何动态库，
   也没有静态链接进去的第三方代码。

> 此前版本在这里列的是两条实打实的要求：消费者**需要该平台的 C 工具链**
> （Linux / macOS 用 clang + ar，Windows 用 MinGW 的 gcc + ar），
> 且**必须先 `build` 再 `check`**。两者都源于 `[ffi.c]` 指向的静态库不在包内这一事实。
> C 依赖移除后，`[ffi.c]`、`build.cj` 与那条约束**一并消失**。
>
> 顺带说明当时的判断为什么是"无法靠配置消除"：二进制进不了包；把库引用改由
> `link-option` 承担**不会传递到消费者的最终链接**（实测消费者链接报 undefined symbol），
> 而 `[ffi.c]` 是唯一能把 C 库依赖传给消费者的机制。这个结论当年成立，
> 也正是它把"去掉 C 依赖"推成了唯一出路。

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
