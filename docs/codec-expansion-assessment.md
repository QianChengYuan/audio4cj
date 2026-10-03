# OGG / AAC 解码扩展可行性评估

> 评估对象：是否把 **Ogg Vorbis**、**Ogg Opus**、**AAC** 三类解码纳入 audio4cj。
>
> 评估性质：**研究报告，不含实现**。结论用于决定是否立项，以及立项的优先级与范围。

## 一、结论摘要

| 候选 | 建议 | 主要理由 |
|---|---|---|
| **Ogg Vorbis** | ✅ **建议立项（优先级最高）** | 有**单文件、公共领域**的候选（stb_vorbis），构建代价几乎为零，完全符合本项目「1 个 C 运行时依赖」的最小足迹策略；且探测层与标签层已就绪 |
| **Ogg Opus** | ✅ **建议立项（次优先）** | libopus 为 BSD-3-Clause 且**免专利费**；本项目的 Ogg 页重组层可直接复用，只需引入一个**裸 packet 解码器**，无需 opusfile/libogg |
| **AAC** | ❌ **建议不立项** | 无损许可的候选**一个都没有**：FAAD2 是 GPL-2.0-or-later（分发受限），libfdk-aac 是 Fraunhofer 专有许可（非标准开源）。这与本项目"仅收宽许可依赖"的政策直接冲突 |

**发布范围建议**：本次发布（M6）**不含**上述任何解码扩展。理由：新增 C 依赖会让 `LICENSES.md`、依赖台账、CI 矩阵、`[ffi.c]` 与三平台产物目录**整体重做** —— 先发布再扩展等于发布两次。开发文档 §1.2 的原意也是"首期只承诺 WAV / FLAC / MP3"。

**但有一项无需新依赖的收益已落地**：**Ogg 封装的 FLAC 现在可解码**（dr_flac 原生支持，本轮已接入），且 **OGG / MP4 的标签读取**已实现 —— 这两项都**不引入任何新 C 依赖**，因此可以进入本次发布。

## 二、评估前提：本项目的依赖政策

来自开发文档 §1.3 与既有实践：

- 首期只承诺 **WAV / FLAC / MP3**；AAC 与 OGG 解码被**显式剔除**为"待 MVP 验证后再评估"（Vorbis 优先考虑 libvorbis FFI）。
- 现有运行时 C 依赖只有一个：**dr_libs**（Unlicense / MIT-0）。
- **已有纯仓颉解码的先例**：WAV（M2 起）与 **FLAC**（本轮起，含帧解码、CRC-8/CRC-16
  校验与 SEEKTABLE 定位）都是纯仓颉实现，判据是"与 dr_libs 逐位相同"。
  因此下文"新增一个 C 库要付多少代价"的评估，应同时对照另一条路线 ——
  **自己写纯仓颉实现**：两者都要付实现成本，但纯仓颉路线不引入新的供应链、
  许可与扫描面。FLAC 内核的存在证明这条路线在本项目里是走得通的。
- 依赖许可证台账要求**逐一核实仓库 LICENSE 文件**，不接受二手声明。

因此本报告的准入线是：**许可证必须是 OSI 认可的宽许可（MIT / BSD / Apache-2.0 / 公共领域），且不引入专利费**。GPL 系与专有许可**一律不可用**。

## 三、已具备的基础（本轮工作带来的直接收益）

扩展解码不是从零开始，以下部件**已经就位**，可直接复用：

| 已有部件 | 位置 | 对扩展的价值 |
|---|---|---|
| **Ogg 页重组**（页头解析、跨页续传、多逻辑流隔离、边界防护） | `src/meta/ogg_page.cj` | **Opus 与 Vorbis 都可以只引入"裸 packet 解码器"**，容器层不再需要额外的库（无需 libogg / opusfile / libvorbisfile） |
| **Ogg 子编码识别**（Vorbis / Opus / FLAC / Speex） | `src/probe/magic.cj` | 探测层已能把"不支持"的信息精确到编码级，扩展后只需翻转 `supported` |
| **Ogg 标签读取**（含 Opus 的 `OpusTags`） | `src/meta/ogg_page.cj` + `vorbis_comment.cj` | 标签能力已完整，扩展解码**不需要**再动标签层 |
| **Decoder 接口**（一编码一实现，注册即用） | `src/codec/decoder.cj` | 新解码器只需实现 3 个方法 |
| **C 侧薄封装 + 不透明句柄**模式 | `third-party/drlibs_wrapper.c` + `src/drlibs/` | 已验证可行的 FFI 接入范式，含句柄生命周期与错误转译 |
| **测试素材**（Vorbis 多质量档/单声道/静音、Opus 双码率/带标签、Speex） | `testdata/ogg/` | 扩展后**素材已就绪**，无需等待 |
| **golden PCM 比对基线**（无损互证 + ffmpeg 逐样本，实测最大差 0） | `src/test/golden_test.cj` | 新解码器可直接接入同一套正确性裁判 |

`Decoder` 接口（`src/codec/decoder.cj`）：

```cangjie
protected interface Decoder {
    func decode(packet: Packet): AudioBuffer
    func codecParams(): CodecParameters
    func reset(): Unit
}
```

## 四、候选库评估

### 4.1 Ogg Vorbis

| 候选 | 许可证 | 形态 | 构建代价 | 说明 |
|---|---|---|---|---|
| **stb_vorbis** | **公共领域 / MIT**（双许可，可自由再许可） | **单文件** `stb_vorbis.c` | **极低**：复制进 `third-party/` 即可，无构建系统、无子依赖 | 覆盖面广（游戏/工具链大量使用）；自带 Ogg 解析与 seek。**首选** |
| **libvorbis**（Xiph 参考实现） | **BSD-3-Clause** | 需 `libogg` + `libvorbis`（`libvorbisfile` 可选） | 中：需构建 2~3 个库 | 正确性与长期维护的"权威一方"。其底层合成 API（`vorbis_synthesis_headerin` / `vorbis_synthesis`）接受**裸 packet**，理论上可省掉 `libvorbisfile` —— 但它依赖 `libogg` 的 `ogg_packet` 结构定义，能否只链 `libvorbis` 需实测 |
| libvorbisidec（Tremor） | BSD-3-Clause | 定点实现 | 中 | 仅在有定点算力约束时才有意义，桌面/服务端无必要 |

**推荐 stb_vorbis 的理由**：它把"引入一个新 C 依赖"的代价压到了本项目从未有过的低点 —— 单文件、零构建脚本、公共领域。这与项目"把不可控部分外包，但只外包最小面"的思路一致。

**代价**：stb_vorbis 自带容器解析，**会绕过我们自己的 `ogg_page.cj`**（标签读取仍用我们的）。等于同一容器有两套解析逻辑。这是可接受的（解码与标签职责分离），但需在文档中写明，避免后续维护者困惑。另外 stb_vorbis 自身的健壮性历史不如 libvorbis 干净（**需做与 dr_libs 同等的审计：锁定 commit + CVE 排查 + fuzz 回归**）。

**能力边界**：Vorbis 无 SBR 类扩展，解码路径相对简单；不涉及专利。素材侧已覆盖多质量档与静音。

### 4.2 Ogg Opus

| 候选 | 许可证 | 形态 | 构建代价 | 说明 |
|---|---|---|---|---|
| **libopus** | **BSD-3-Clause** + **免专利费**（IETF 已收到 Xiph / Microsoft / Broadcom 等的免许可费承诺） | C99 源码，CMake/autoconf | 中：非单文件，需接构建 | **官方参考实现，首选** |
| libopusfile | BSD-3-Clause | 依赖 libopus + libogg | 中 | 提供 Ogg-Opus 封装。**本项目不需要** —— 页重组已自研 |
| 自研 Opus 解码器 | — | — | 不可行 | CELT + SILK 双引擎，属"从零写含 SBR 的解码器"同类问题，明确排除 |

**关键优势（本项目的独有便利）**：libopus 的解码入口 `opus_decode` / `opus_decode_float` 接受的正是**裸 Opus packet**，而**我们已经能按 packet 切分了**（`oggFirstPackets`）。因此：

- 只需引入 **libopus 一个库**；
- **不需要** opusfile，也**不需要** libogg；
- 容器层与标签层完全复用现有实现。

这是本轮「页重组」工作带来的直接红利，也是 Opus 相对 AAC 在工程上明显更可行的原因之一。

**能力边界与注意点**：
- Opus 内部采样率固定为 48 kHz，输出需按项目的统一约定（f32 交错）处理；`AudioInfo.sampleRate` 应报告 Opus 头部声明的原始采样率（`OpusHead` 中的 input sample rate），并在文档中说明内部会重采样到 48 kHz —— 这是格式事实，不是实现选择。
- 前置跳过（pre-skip）必须正确丢弃，否则时长与时序会偏移（这是 Opus 接入最常见的错误）。
- 素材已覆盖 32k / 96k 双码率与带标签样本。

### 4.3 AAC

**结论：无许可干净的候选，不建议立项。**

| 候选 | 许可证 | 可否采用 | 说明 |
|---|---|---|---|
| **FAAD2** | **GPL-2.0-or-later** | ❌ **不可** | 能力最完整（含 SBR / HE-AAC、MPEG-2/4、LC/MAIN/LTP），但 GPL 会传染整个项目，与本项目的宽许可政策直接冲突 |
| **libfdk-aac** | **Fraunhofer IIS 专有许可**（SPDX: `FDK-AAC`） | ❌ **不可** | 非 OSI 认可的标准开源许可；多方技术资料把它与 GPL 一并归为"分发风险"，并存在专利考量 |
| **FFmpeg 内置 AAC 解码** | LGPL-2.1+ | ⚠️ 技术上可行但**不建议** | 为解码 AAC 引入整个 FFmpeg 作为运行时依赖，与项目"最小依赖足迹"的立身之本相悖；构建与分发代价也是数量级的上升 |
| **aad4cj**（仓颉生态） | ⚠️ **来源冲突**：README 声明 MIT，GitHub 标注 Apache-2.0 | ❌ **不可** | 许可证来源未澄清即不可用（本项目既定台账规则）。且其官方明确声明「**并不直接支持完整的端到端 AAC 解码**，只提供部分关键基础组件」，HE-AACv2 与 MPEG 环绕声不在支持范围 —— 即便许可澄清，也补不齐链路 |
| 自研 AAC 解码器 | — | ❌ | 需含 SBR 的完整解码器，开发文档 §1.3 已明确剔除 |

**技术性补充**：AAC 的专利池（Via LA）历史授权情况复杂，即便找到一个宽许可的实现，商业化分发仍可能触及专利许可问题 —— 这也是 `libfdk-aac` 采用专有许可的原因。这一层风险无法用代码解决，必须在产品层面评估。

> 因此 AAC 的结论不只是"现在不做"，而是"**在当前依赖政策下没有可行的技术路径**"。若未来确需支持，正确的做法是**重新评估依赖政策**（是否接受 LGPL/GPL 依赖）与**专利策略**，而不是找一个"看起来开源"的库塞进来。

## 五、接入点分析（若立项，改动面在哪）

### 5.1 解码器实现

按现有范式新增（以 Vorbis 为例）：

```cangjie
// src/codec/vorbis_decoder.cj（新）
protected class VorbisPcmDecoder <: Decoder {
    // 持有 C 侧不透明句柄，实现 Resource → 构造失败时也必须显式 close()
    public func decode(packet: Packet): AudioBuffer
    public func codecParams(): CodecParameters
    public func reset(): Unit
}
```

**必须继承本项目的两条既有教训**：

1. **构造失败必须释放句柄**（本项目已发生过真实缺陷：`FlacFormatReader.init` 先打开句柄、后校验参数，校验失败抛异常时句柄无人释放，表现为"文件被其它进程占用"无法删除）。新解码器同样要在抛异常前显式 `close()`。
2. **`decode()` 遇坏帧必须抛 `DecodeException`**，不得返回空 `AudioBuffer` 污染下游（`decoder.cj` 的接口契约）。

### 5.2 容器读取器

| 项 | Vorbis（stb_vorbis） | Opus（libopus） |
|---|---|---|
| 是否需要新 `FormatReader` | 需要（`VorbisFormatReader`），但**容器解析交给 stb_vorbis** | 需要（`OpusFormatReader`），**复用 `ogg_page.cj` 做容器层** |
| seek | stb_vorbis 提供 `stb_vorbis_seek` | 需用 granule position 做二分定位，**工作量明显更大**（Opus 无 SEEKTABLE，只能按页序列二分） |

### 5.3 其余改动点

| 位置 | 改动 |
|---|---|
| `src/probe/magic.cj` | `ogg` 分支的 `supported` 判定增加 `codec == "vorbis"` / `codec == "opus"` |
| `src/facade/audio_file.cj` | `open()` 的 `case "ogg"` 分支按 codec 分派到新读取器；`readTags` 无需改动（已支持） |
| `third-party/` | 新增 C 源码（`stb_vorbis.c` / libopus 源码或构建脚本）；**并同步加进 `cjpm.toml` 的 include 白名单** —— 白名单逐文件列出，漏写会导致消费者现场编译缺文件 |
| `libs/<platform>/` | 新增各平台产物目录（现已改为**静态库** `libdrlibs.a`，不存在 `lib` 前缀双副本问题） |
| `cjpm.toml` | `[ffi.c]` 新增条目 |
| `LICENSES.md` | 新增依赖台账条目与审计记录 |
| 测试 | `testdata/ogg/` 素材已就绪；新增解码测试 + **纳入 golden 基线的对照**（Vorbis/Opus 为有损，只能做帧数与能量松比对，与 MP3 同等对待） |

## 六、构建与分发代价

这是本次评估中**最容易被低估**的部分。新增一个 C 库意味着：

| 项 | 现状 | 新增一个 C 库之后 |
|---|---|---|
| 运行时 C 依赖数 | 1（dr_libs） | 2（Vorbis）或 3（Vorbis + Opus） |
| `[ffi.c]` 条目 | 每个平台一条（`[target.<三元组>.ffi.c]`，共 4 个平台），库为**静态库** `libdrlibs.a` | 每条依赖 × 每个平台一条 |
| 平台产物目录 | 4 个（`windows_x86_64` / `linux_x86_64` / `macos_aarch64` / `macos_x86_64`），其中仅 Windows **预置（提交）**了产物 | 每个依赖 × 每个平台一套 |
| CI 矩阵 | Linux / Windows / macOS **三平台** | 依赖数 × 平台数，且每个平台都要能编译该 C 库 |
| `LICENSES.md` | dr_libs 一条 | 每条依赖的来源、版本锁定方式、审计记录 |
| 供应链审计 | dr_libs 的 CVE 排查流程已建立 | 每个新库都要走同样的流程（锁 commit、查 CVE、fuzz 回归） |

**这正是"先发布再扩展 = 发布两次"的由来**：上述每一项都会让发布物整体重做。

## 七、工作量与建议

### 7.1 相对量级（粗估）

| 阶段 | 相对量级 | 主要构成 |
|---|---|---|
| Ogg **Vorbis**（stb_vorbis） | **小** | 单文件接入 + `VorbisFormatReader` + seek + 测试。构建代价几乎为零是它最大的优势 |
| Ogg **Opus**（libopus） | **中** | libopus 构建接入 + 复用页重组 + **pre-skip 处理** + **granule-based seek**（最费工的一块） |
| **AAC** | **不可行** | 许可无解，工作量估算无意义 |

> 上述为**相对量级**而非精确人日承诺：实际取决于 libopus 在三平台的构建打通所需时间，那部分不确定性最大。

### 7.2 建议的推进方式

1. **本次发布（M6）不含解码扩展**。发布范围锁定为：
   - 解码：WAV / FLAC / MP3 / **Ogg 封装的 FLAC**（本轮新增，无新依赖）
   - 标签：WAV / FLAC / MP3 / **OGG（Vorbis / Opus / FLAC-in-Ogg）** / **MP4（ilst）**（本轮新增，无新依赖）
   - 探测：完整识别并区分 Ogg 子编码
2. **发布后单独立项 Vorbis**（先做，因为它能验证"新增 C 依赖"这条流水线：`[ffi.c]`、多平台产物、许可证台账、CI 矩阵、审计流程 —— 把这套走通一次，再做 Opus 就是复用）。
3. **Vorbis 完成后再评估 Opus**，届时"新增依赖的边际成本"已有实测数据。
4. **AAC 不立项**；若产品确有需求，先做**依赖政策评估**（是否接受 LGPL/GPL）与**专利策略评估**，再谈技术选型。

### 7.3 决策门（立项前必须回答）

- [ ] stb_vorbis 的当前 commit 是否已修复全部已知 CVE？（需逐条排查，流程同 dr_libs）
- [ ] libvorbis 的底层合成 API 能否只链 `libvorbis`、免除 `libogg`？（需实测）
- [ ] libopus 在 Windows / Linux / macOS 三平台的构建能否脚本化到 `build.cj` 的 pre-build 钩子里？
- [x] `[ffi.c]` 能否按目标平台切换产物路径？—— **已证实可以**：`[target.<三元组>.ffi.c]`（2026-10-03 实测，见 `cjpm.toml` 与 `build.cj` 文件头）。原先的备选方案「由 `build.cj` 把产物拷贝到固定路径」（`libs/current/` 中间层）**已废弃**。
- [ ] Windows 的 `lib` 前缀双副本方案能否平滑扩展到多个 C 库？
- [ ] 新增依赖后，项目的"最小依赖足迹"叙事是否还成立？（这是本项目的差异化卖点之一，需权衡）

## 八、未核实项（诚实标注）

以下内容**未在本机实测**，报告中按"需核实"处理，不应作为决策的唯一依据：

1. **libopus 的许可证原文**：本报告依据公开资料认定其为 BSD-3-Clause 且免专利费，但**未逐字核对仓库 `COPYING` 文件**。立项时必须完成该核对（本项目既定台账规则）。
2. **libfdk-aac 的许可细节**：依据公开资料认定其为 Fraunhofer 专有许可（SPDX `FDK-AAC`），未核对原始许可文本。
3. **FAAD2 的许可证**：已通过多个独立来源交叉确认其为 **GPL-2.0-or-later**，此条置信度较高。
4. **stb_vorbis 是否可只链 `libvorbis`**：属推测，需实测。
5. **各候选库的 CVE 现状**：均未排查，属立项前的必做项。
6. **三平台的构建可行性**：**已在三平台 CI 上实测通过**（Linux / Windows / macOS 各处都会执行 `cjpm build` 走 `build.cj`）。仓库仍只**提交**了 Windows 产物 —— 其余平台本机无法交叉编译，产物在 CI 上现场生成。

## 九、一句话结论

> **Vorbis 值得做且现在就能低成本做（单文件、公共领域）；Opus 值得做且比想象中容易（页重组已自研，只需一个裸 packet 解码器）；AAC 在当前依赖政策下没有可行路径 —— 它的障碍不是技术，而是许可与专利。**
>
> 但三件事都**不该塞进本次发布**：本次发布的价值恰恰来自"零新增 C 依赖"这一条 —— 解码扩了 Ogg-FLAC，标签扩了 OGG 与 MP4，探测精确到了编码级。
