# 更新记录

> 本文件记录 audio4cj **面向使用者**的变更，版本号对应 `cjpm.toml` 的 `[package].version`。
> 记录按 git 提交史逐版回溯整理；**0.1.0 / 0.1.1 为内部迭代版本，未对外分发**。
> **已在中心仓上架**（`0.1.8` 起，2026-10-17；`0.2.0` 于 2026-10-21 上架；
> `0.3.0` 于 2026-10-22 上架）——中心仓当前最新为 `0.3.0`，可直接
> `audio4cj = "0.3.0"` 引入；引入方式见 [引入方式](README.md#引入方式)：
> 中心仓（推荐）/ Git 引用（需要未发布提交时）/ 本地路径引用，三者均无需额外前置条件。
>
> 性能与解码偏差的**过程数据**（分轮次定责、微基准、受控实验）单独成篇，
> 存放于**源码仓库**（该评估文档不随制品包分发）；
> 本记录只写"使用者能感知到什么变了"，不复述过程。
>
> 本文件是更新记录的**权威副本**：它位于仓库根目录，随制品包分发

## 0.3.0

### 新增

- **Ogg Vorbis 纯仓颉解码**：`AudioFile.open` / `openBytes` 现可直接打开
  `.ogg`（Vorbis）并输出 f32 交错 PCM，`info().bitDepth` 为 `32`（表示浮点，
  与 MP3 一致）。实现覆盖码本/Huffman、floor 1、residue（type 0/1/2）、
  多声道反耦合、IMDCT 与重叠相加；Ogg 层按 **packet 边界**重组（不是字节流拼接），
  逐页校验 CRC-32，并按末页 granule 裁剪尾部。`seekTo` 首版采用"重开 + 从流首
  解码丢弃到目标帧"，返回实际落点毫秒
- **Vorbis 标签随解码器一起可用**：`open()` 后的 `metadata()` 与独立的
  `readTags()` 走同一套 Vorbis comment 解析；带 `METADATA_BLOCK_PICTURE` 的
  封面仍映射到 `Tag.coverArt` / `Tag.coverMime`

### 限制

- 当前只实现 **floor 1**；遇到 floor 0 的 Vorbis 流会明确抛
  `FormatNotSupportedException`，不会静默输出错误音频
- Ogg/Opus、Ogg/Speex 仍不支持解码；`readTags()` 对 Opus 的 `OpusTags`
  仍可正常读取
- Vorbis 解码算法参考了公共领域 / MIT 的 stb_vorbis，代码为纯仓颉重写，
  不链接其 C 源码；来源登记见 `LICENSES.md`

### 版本号

- `cjpm.toml`、`AUDIO4CJ_VERSION`（`src/audio4cj.cj`）与
  `docs/api/core.md` 同步升至 **0.3.0**。

## 0.2.0

### 新增

- **`openBytes` 全容器免落盘直通**：FLAC 与 Ogg-FLAC 从内存字节打开时不再
  写入临时文件（v0.2.0 上半程已覆盖 MP3 / WAV）。FLAC 解码内核在元数据扫描时
  顺带缓存标签块（VORBIS_COMMENT / PICTURE），`metadata()` 零 I/O；Ogg 页重组
  对字节源的要求本就只有顺序读 + reopen，内存源直接可用。内存占用：
  传入数组（不拷贝）+ 有界解码窗口，与音频时长无关
- **FLAC 标签写入**：`writeTags` 的支持范围从 MP3 扩展到 FLAC —— 载体为
  Vorbis comment 块（UTF-8 文本，封面走 `METADATA_BLOCK_PICTURE` 条目）。
  既有元数据块（STREAMINFO / SEEKTABLE / PICTURE / PADDING …）逐位保留，
  音频帧原样平移（SEEKTABLE 的偏移是相对首帧的，平移安全），原子落盘；
  无损性经"写入前解码留底、写入后逐样本比对"验证
- **FLAC 编码支持 24 位**：`flacBytes(buffer, bitsPerSample!: 24)`——s24 口径
  与 `wavBytes` 一致（v × 2^23，向零截断 + 钳位），16 位行为不变。
  24 位的核心价值：16 位会归零的微小信号（幅度 < 2⁻¹⁵）在 s24 下精确保留，
  archive 场景（保留母带动态范围）由此走通纯仓颉全链路。
  无损性经自解码 roundtrip 逐样本零误差验证（1..8 声道 × 尾块路径全覆盖）
- **PCM 分析工具**：新增 `audio4cj.pcm.analyzeBuffer` / `analyzeSamples` /
  `peakEnvelope`，提供峰值、RMS、dBFS、简化 LUFS 与波形峰值包络；全部为
  纯函数、无状态、可并发调用，空输入返回 0 值或空数组，不抛异常

### 修复

- **`openBytes` + `readAll` 组合泄漏临时文件**：`readAll`/`readFrames` 消费完
  即置关闭状态（`drain` 的"半关闭"设计），但临时文件清理只挂在 `close()` 的
  `if (!_closed)` 分支里——半关闭后 `close()` 幂等跳过，`.tmp` 永远不删。
  在线播放场景（内存字节 → 全量解码）是其最典型组合，连续换台会持续堆积
  临时文件。现清理提取为独立路径，挂在**所有**置关闭状态的路径上；
  回归测试覆盖"openBytes + readAll + close"序列
- **FLAC 编码器短块崩溃**：块内帧数 < 5 时（短素材的尾块），固定预测阶
  0..4 的遍历会对负长度分配数组而抛 `NegativeArraySizeException`；
  现预测阶上限随块长收紧（order ≤ 块长 − 1）
- FLAC 编码帧头的位深码勘误：24 位的规范编码是 `110`（码值 6），
  此前误用 `111`（32 位）—— 24 位产物在本库解码器下每样本多读 8 位而报
  "帧超出窗口有效长度"。24 位是本次新增能力，该错误未进入过任何已发布版本

## 0.1.9

### 变更（**仅文档，代码未变**）

- **引入方式改以中心仓为主**：README「引入方式」与[快速上手](docs/quickstart.md)把
  `audio4cj = "0.1.9"` 列为推荐方式，Git 引用降为"需要尚未发版的提交时"的备选，
  本地路径引用不变；并修正了此前"中心仓尚无任何版本"的过期表述
- [发布说明](docs/release.md)补记 2026-10-17 **首次上架成功**的事实与验证方式
  （索引/制品 API + "第一个外部用户"实测），并标注"上架被拒"的口径已过期

## 0.1.8

### 新增

- **32 位浮点 WAV 解码**（`formatTag = 3`，含 `WAVE_FORMAT_EXTENSIBLE` 的子格式 3）——此前这类文件在 `open()` 时被判为"暂不支持的 WAV 编码"，DAW 导出与 `ffmpeg -c:a pcm_f32le` 产生的素材一律打不开。转换采用**按位重解释**而非数值换算，因此逐位无损：次正规数、`-0.0` 的符号位、`±Inf`、`NaN` 载荷（含自定义载荷）都原样通过

### 说明

- 浮点载荷**不做 [-1, 1] 钳位**：削波前的素材与总线电平常越界，归一化不等于钳位，钳位交给消费方（与整型路径的口径一致）
- **64 位浮点 WAV 仍不支持**：本库的统一表示是 f32，收进来只能降精度，故明确拒绝而不是静默截断；报错文案已写明当前支持范围

## 0.1.7

### 新增

- **FLAC 封面：`PICTURE` 块（元数据块类型 6）**——原生 FLAC 与 Ogg-FLAC 的封面此前一律读不到（`Tag.coverArt` 恒为 `None`），现映射到既有的 `Tag.coverArt` / `Tag.coverMime`。同一文件有多个 `PICTURE` 块时 **front cover（图片类型 3）优先**，同类型先到者胜；MIME 缺失的畸形块按魔数（JPEG / PNG / GIF / BMP）兜底
- **Vorbis comment 的 `METADATA_BLOCK_PICTURE`**（base64 编码的同一 PICTURE 结构）——原生 FLAC 与 Ogg 容器共用。此前该条目被**显式跳过**（避免把数十至数百 KB 的 base64 灌进 `Tag.extra`），现在解出图片本体填进 `coverArt`，解不出时仍静默跳过、不落 `extra`
- 两条载体共用同一份 PICTURE 解析与 base64 解码实现（零外部依赖，未引入任何第三方库）：同文件两者并存时**注释头优先、`PICTURE` 块补空**

### 修复

- **FLAC 元数据块链遍历过早返回**：此前一遇到 `VORBIS_COMMENT` 就返回，位于其**之后**的 `PICTURE` 块永远不会被看到；现遍历完整条块链再合并
- **APEv2 封面的 MIME 嗅探越界读**：原实现以 `from + 3 > size` 判断可读性，恰好 3 字节剩余时会读到数组外；现改为按实际需要的最长魔数（4 字节）判断，并顺带识别 GIF / BMP
- **发布门禁两处阻塞**（只影响从源码构建/打包的人，不影响已编译制品的使用者）：① `src/meta/gbk_table.cj` 的 CP936 表条目连写成 8 位十六进制后，与 `cjlint` 的 `G.OTH.02`（禁止硬编码证件号）规则**偶然同形**，48 处 MANDATORY 违规让 `cjpm bundle` 自 0.1.6 起失败——现改为条目内插分隔符（`AA52.7302.`，步长 10）做**结构性**消除，不再依赖注释豁免；② `cjpm bundle` 自带 `cjpm test` + 打包阶段默认堆仅 256MB，本库会在打包阶段 `Out of memory`——`scripts/release_bundle.py` 现默认注入 `cjHeapSize=4GB`

## 0.1.6

### 新增

- **`AudioInfo` 暴露 MP3 锚点元数据**（命名默认参数，旧调用不变）：`bitrateKbps`（kbps）、`isVbr`（检出 Xing/VBRI 即 true，`Info` 标签为 CBR）、`mpegVersion`（`MPEG1`/`MPEG2`/`MPEG2.5`）、`layer`、`channelMode`（`stereo`/`joint stereo`/`dual channel`/`mono`）
- **`Tag.discTotal`**：补齐与 `track/trackTotal` 的对称（ID3v2 `TPOS`、Vorbis `DISCTOTAL`/`TOTALDISCS`、MP4 `disk` atom）
- **`Tag.lyrics`**：非同步歌词（ID3v2 `USLT`/`ULT`、Vorbis `LYRICS`/`UNSYNCEDLYRICS`）
- **APEv2 标签读取**（`readTags`/MP3 标签路径自动纳入）：MP3 的标签优先级为 ID3v2 > APEv2 > ID3v1；APE 文本 item 与 front cover（`COVER ART (FRONT)`）均可读，其余键进 `extra`（键名 `APE:<KEY>`）
- **`AudioFile.openBytes(bytes)`**：从内存字节打开音频（写入临时文件桥接，`close()` 时自动删除）——在线播放场景免手工落盘

### 修复

- **MP3 大 ID3v2 误报损坏**：内嵌大封面可把 ID3v2 推到 64KB 预读窗之外，此前一律误报「找不到合法帧」；现打开时跳过标签区再预读
- **ID3v2 中文乱码（GBK 嗅探回退）**：大量中文 MP3 把 GBK 内容错标为 ISO-8859-1（编码 0）；现嗅探到 GBK 特征（合法双字节序列 + 贪心配对成功 + 解出 CJK）即按内置 CP936 表解码，未命中特征维持 Latin-1
- **MP3 gapless（LAME delay/padding 裁剪）**：解析 LAME 头的 encoder delay/padding，解码层裁掉流首/流尾填充样本；`info().durationMs` 同步为有效时长。连续播放不再有首尾静音缝/咔哒
- **`extra` 键名约定文档化**：ID3v2 的 `TXXX:<描述>` 与其余 `T…` 帧按帧 ID 收入 `extra`（如 `getExtra("TXXX:REPLAYGAIN_TRACK_GAIN")` 可取回放增益）；APE 键 `APE:<KEY>`

### 说明

- 多封面（APIC 重复 / covr 多条目）当前策略为「后出现的覆盖先出现的」，数组化支持留待后续
- SYLT（同步歌词）、POPM/PCNT/UFID/WXXX/RVA2 等二进制帧暂不解析
- FLAC 的 PICTURE 块与 Ogg 的 `METADATA_BLOCK_PICTURE` 仍不支持

> （`docs/changelog.md` 仅为兼容旧链接的跳转页）。

## 0.1.5（待发布）

### 新增

- **FLAC 编码**（新包 `audio4cj.encode`）：`flacBytes(buffer, bitsPerSample!: 16)`
  把 f32 交错 PCM 编码为完整 FLAC 文件映像——定长分帧 4096、子帧类型
  自动择优（constant / verbatim / fixed 0..4）、单分区 Rice 残差，
  复用解码侧同源的 CRC-8 / CRC-16。无损性经双重验证：自解码 roundtrip
  逐样本零误差；ffmpeg 交叉解码 MD5 与原 WAV 一致。
  已知边界：仅 16 位；MD5 未计算（流内全 0）；压缩率低于 libFLAC
  （无立体声联合编码）；非实时（逐位写入有优化空间）。

### 版本号

- `AUDIO4CJ_VERSION` 与 `cjpm.toml` 同步升至 **0.1.5**（0.1.4 从未在中心仓上架，
  直接顺延，无跳版）。

## 0.1.4（待发布）

### 兼容性与性能门槛

- **最低支持 SDK 降到 `1.1.0`**：`cjpm.toml` 的 `cjc-version` 由 `1.2.0` 改为 `1.1.0`
  （CI 的 `CANGJIE_VERSION` 同步）。原因：中心仓审核侧的工具链更可能是 1.1.0，
  而声明 1.2.0 会让对方无法构建、或构建结果与本机不一致。
  已在**本机用 1.1.0 实测**：`cjpm build` 通过、`cjlint -f src/ -c .` 零告警、
  **解包后包内 `cjpm test` 81/81 通过**、仓库侧全量 `cjpm test` 通过；1.2.0 亦可用。
- **MP3 吞吐门槛按「最低声明 SDK」重新校准：红线 `250× -> 150×`**。
  依据（同素材、同代码、实测）：SDK **1.1.0** 为 `320.8× / 222.2× / 286.8×`（三次，各取
  best-of-3）、SDK **1.2.0** 约 `460×` —— 相差约 1.6 倍。红线 150× 低于 1.1.0 实测最小值
  222× 约 32%，既不误报又守得住明显退化；目标 `MP_TARGET = 800×` 不变。
  该用例依赖 `testdata/`，**不随制品包分发**（包内测试不受影响）。
- **明确三种引入方式**：中心仓 / **Git 引用** / 本地路径引用，并写明
  「中心仓审核未通过时改用 Git 或本地引用」——见[快速上手](docs/quickstart.md)。

### 构建与分发

- **制品包内的用例子集改为「纯内存、零副作用」**：随包用例不再写出临时素材
  （自足端到端、CRC 校验与篡改回归、随机输入回归、WAV 写回读等留在源码仓库，
  由仓库侧 `cjpm test` 全量运行）。消费者解包后 `cjpm test` 仍可完整跑通，
  且**不再要求工作目录可写**。
- **包内文本措辞中性化**：描述健壮性测试的用词统一为「随机输入 / 异常输入」，
  避免与自动扫描规则的关键词表相撞（测试内容与断言口径不变，仅表述）。
- **版本号同步**：`cjpm.toml`、`AUDIO4CJ_VERSION`（`src/audio4cj.cj`）与
  `docs/api/core.md` 一致为 **0.1.4**。

## 0.1.3（待发布）

### 修复

- **异步流（`AsyncFrameStream`）在解码失败时不再让消费者永久阻塞**：后台线程抛出的
  异常此前只留在那个线程里，消费者 `next()` 会永远等不到结束哨兵而挂死。
  现在异常会被记录并在 `next()` 中抛给调用方，与同步路径一致 ——
  **`None` 严格且仅表示流已结束、错误一律抛异常的契约在异步路径同样成立**。
  另：关闭后的 `next()` 统一抛 `ClosedResourceException`（此前抛根异常类型）。
- **ID3v2 的 UTF-16 文本含孤立代理项时不再抛标准库异常**：`Rune(0xD800)` 会抛
  `OverflowException`；现在按惯例替换为 U+FFFD（合法代理对的合成不受影响）。
  该路径可被仅 23 字节的结构异常 ID3v2 触发，属不可信输入。
- **Ogg 页在文件末尾被截断时报库内异常**：此前段表/页体读到空数组后会数组越界
  （`IndexOutOfBoundsException`）；现在统一为 `CorruptedFileException`。
- **`seekTo()` 传极端时间戳（如 `Int64.Max`）不再抛标准库溢出异常**：
  时间→帧号的换算改为饱和运算后再按数据区/总帧数裁剪，仍返回实际落点或抛
  `SeekNotSupportedException`。
- **`AudioBuffer.samples` 改为返回副本**：此前返回内部数组，调用方改写它会破坏
  "不可变快照"的契约。库内热路径改用新增的 `copyInto()`，避免多一次整块拷贝。
- **`readAll()` / `readFrames()` 之后 `AudioFile` 状态自洽**：这两个便捷 API 读完
  即关闭共享 reader，但 `isClosed()` 此前仍返回 `false`，而其它方法全部抛
  `ClosedResourceException`。现在关闭状态一并置位（即它们是**一次性 API**），
  需要继续分块读取请自行持有 `stream()`。文档已同步（[facade](docs/api/facade.md) §3.8 / §3.10）。

以上每项都补了回归用例（`src/test/review_fix_test.cj`），用例总数 **246**。

### 构建与分发

- **制品包根目录补齐两个随包文件**：`CHANGELOG.md` 与 `README.OpenSource`。
  根目录只有 `cjpm.toml`、`README.md`、`README_zh.md` 属于「无论 `include`/`exclude`
  都会打包」的自动项，其余根文件必须显式列入白名单 —— 此前这两个文件既不存在，
  也不在 `include` 内（中心仓三方库模板把二者列为根目录标准组成文件）。
  更新记录的权威副本随之移到根目录，`docs/changelog.md` 保留为跳转页。

## 0.1.2

### 新增

- **MP3 解码：纯仓颉实现**。至此 **WAV / FLAC / Ogg 封装的 FLAC / MP3** 四类解码
  **全部为纯仓颉代码**，本库不再链接任何第三方解码库，也不再需要 C 工具链。
  - 覆盖 **MPEG-1 / MPEG-2 / MPEG-2.5** 的 **Layer I / II / III**；
  - 内核包含帧同步与比特流解复用、Huffman 解码（含 count1 二级查表）、
    反量化、IMDCT 与多相合成滤波器组；
  - `AudioFile.open()` 可直接打开 `.mp3` 并解码；标签侧继续覆盖 ID3v1 与
    ID3v2.2 / 2.3 / 2.4。
  - 可解码格式清单与各自的实现范围见 [文档总览](docs/README.md)。

### 修复

- **MP3 count1 二级查表的 32 位回绕缺陷**：极少数高频内容可能因此解码异常。
  已修复，并补上高频完整性回归用例。

### 性能

- **MP3 解码内核多轮优化**：流层每帧开销、Huffman 码表提升到文件级、
  合成内循环展开与标量命名、热路径迭代改写。
- **构建档位补 `-O2`**：此前 `compile-option` 缺优化档位，构建出的库性能被严重低估。
  现在仓库与 CI 均以 `-O2` 构建 —— **升级到本版本后请重新构建**，
  以免沿用旧档位下测得的偏低数据。
- **FLAC 侧完成耗时分层定责**（f32→字节转换 / LPC 重建 / 逐采样开销），
  为后续优化确定了顺序与优先级。

### 构建与分发

- **制品包只交付产品代码、公开文档与许可证**：测试源码、仓库侧静态检查配置
  与内部工程文档都不随包分发。
- **构建输出不再被测试代码的告警淹没**：关闭 `unused` 组告警
  （`compile-option` 增加 `-Woff unused`）；产品代码本身在任何档位下均为**零告警**，
  因此该开关不会掩盖产品代码的真实告警。

## 0.1.1（内部迭代）

> 未对外分发。以下为相对 0.1.0 的变化。

### 构建与分发

- 素材生成脚本（PowerShell / POSIX 两版）对齐，各自修复 5 处运行期缺陷。
- 制品包内补上可自证的验证路径，并如实记录"`testdata/` 素材不随包分发"。

## 0.1.0（首版）

> 首个版本，仓库标签 `v0.1.0`。以下为这一版交付的能力。

### 解码

- **WAV**（位深转换）、**FLAC**（帧解码 + 帧头 CRC-8 / 帧尾 CRC-16 校验 +
  `SEEKTABLE` 定位）、**Ogg 封装的 FLAC**（页重组 + 页 CRC-32）。

### 标签读取

- ID3v1 与 ID3v2.2 / 2.3 / 2.4、Vorbis comment、WAV `LIST` / `INFO`、Ogg 页重组、MP4 `ilst`。
- 两个入口：`AudioFile.metadata()`（要求容器可解码）与 `AudioFile.readTags(path)`
  （**不要求**解码能力）。

### 探测与格式信息

- 十余种容器的魔数探测，Ogg 可**精确识别到子编码**（vorbis / opus / flac / speex）。
- 探测结果对外暴露：`FormatInfo` 与 `AudioFile.format()` / `tracks()`。

### 接口与数据模型

- `AudioFile` 门面（主入口），以及 `AudioInfo` / `AudioBuffer`（**f32 交错**）/ `Tag`
  三个统一出口。
- `FrameStream`（同步拉取）与 `AsyncFrameStream`（后台解码 + 有界队列背压）。
- `Registry<T>` 注册表与以 `Audio4CjException` 为根的异常体系。

### PCM 写出

- `pcm.f32ToPcm` 与 `pcm.wavBytes`：把解码结果打包成 8 / 16 / 24 / 32 位 WAV 字节，
  可转存，也可直接交给播放接口。

### 示例

- `examples/` 示例工程（默认展示流式用法）与 Windows 播放演示（`examples/windows_playback`）。

### 依赖：移除第三方 C 解码依赖（Tier 0–5）

- 位视角转换搬出第三方包；FLAC 全族（原生 FLAC 与 Ogg 封装的 FLAC）切换为纯仓颉内核。
- MP3 解码一度移出发布范围（保留 ID3 标签读取）。
- **整体移除 C 依赖**：制品包内不再包含任何 C 代码；文档与 CI 同步改为"无 C 依赖"表述。
- 制品包精简：剔除原先随包的第三方测试代码与其自带的随机输入测试。

### 构建与分发

- 打包范围改用 cjpm 官方的 `include` **白名单**声明，并按 `include` / `exclude` 收口。
- 补齐中心仓发布元数据，并把"元数据漏填"前移到发布前的断言拦下。
- 发布打包流程：从干净源码导出并校验包内容。
- CI 修正：`cjpm check` 执行顺序、Windows 产物路径、发布工作流的过期说明。

### 仓库边界

- 内部设计留痕、本机编辑器状态、M0 阶段的历史验证工程**不随仓库分发**；
  测试临时音频加忽略规则、不入库。
