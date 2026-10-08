<#
============================================================================
 gen_testdata.ps1 —— 就地重建测试素材（testdata\），供 `cjpm test` 完整运行

 背景：制品包**不含** testdata\（cjpm bundle 不打包二进制文件，这是平台行为）。
   仓库内 testdata\ 已入库，故从源码仓库跑测试无需本脚本。
   但评审方/使用者拿到的是制品包 —— 包里没有素材，`cjpm test` 会明确跳过依赖素材的用例。
   本脚本让任何拿到**制品包**的人都能自己把素材生成出来，从而在包内跑通**全量**测试：
       powershell -ExecutionPolicy Bypass -File scripts\gen_testdata.ps1
       cjpm test                     # 此时应为 206 通过 / 0 失败

 本脚本产出**完整**一套素材，包含三类东西 —— 少任何一类都会让测试失败：
   1. 音频素材（wav/ flac/ mp3/ ogg/ aac/ mp4/ 六个子目录 + 根目录 4 个 ref_*.wav）；
   2. MANIFEST.tsv（探测层识别矩阵的对照基准，`probe_matrix_test` 读它）；
   3. golden/ 下的 *.f32le 与 GOLDEN.tsv（逐样本比对基准，`golden_test` 读它）。
   注意第 2、3 类**不是可选项**：素材在、基准不在 = 真实回归（守卫会硬失败），
   而不是"跳过"。本脚本与 scripts/gen_testdata.sh 产出同一套东西，改一处必须改另一处。

 用法（在包根目录，即与 cjpm.toml 同级处执行）：
     powershell -ExecutionPolicy Bypass -File scripts\gen_testdata.ps1
     powershell -ExecutionPolicy Bypass -File scripts\gen_testdata.ps1 -Out D:\td

 依赖：ffmpeg / ffprobe（需含 aac / libvorbis / libopus / flac / libmp3lame
   编码器；libspeex 为可选，缺失时跳过 Speex 样本而不影响其余）。

 编码：本文件**必须以「带 BOM 的 UTF-8」保存**，不要"顺手清理"掉那个 BOM。
   原因此处踩过实测：脚本含中文，而 Windows PowerShell 5.1 对**无 BOM** 的 UTF-8
   会按 ANSI/GBK 解码，中文字符串解析失败（实测报 4 处 "Unexpected token" 语法错误），
   于是"拿到制品包 → 跑本脚本生成素材 → 跑通全量测试"这条路径直接断掉。
   PowerShell 7（pwsh）无此问题，但不该要求使用者换解释器 —— 保留 BOM 即可两者通吃。

 授权：本脚本生成的全部素材均由**合成信号**编码而来，不含任何第三方版权内容。
============================================================================
#>
[CmdletBinding()]
param(
    [string]$Out = "testdata"
)

$ErrorActionPreference = "Stop"

# 时长常量与 scripts/gen_testdata.sh、sctiptr/gen_audio_fixtures.py 严格对齐
# （sctiptr/ 下的 Python 为**历史实现**，现行来源是这两个脚本；改一处必须改全）。
$DurRef    = 3   # 参考信号时长（秒）
$DurMatrix = 1   # 位深 / 声道 / 采样率矩阵样本时长
$DurTagged = 2   # 带标签样本时长（稍长，便于验证时长计算）

function Test-Tool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "错误: 未找到 $Name，请先安装并加入 PATH" }
}

# 【为什么用 $args 转发，而不是 param + ValueFromRemainingArguments】
#   实测踩过：写成
#       function Invoke-Ffmpeg { param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args); & ffmpeg ... @Args }
#   后，调用 Invoke-Ffmpeg -f lavfi -i ... 会直接报
#       "Parameter cannot be processed because the parameter name 'i' is ambiguous.
#        Possible matches include: -InformationAction -InformationVariable."
#   原因是 ValueFromRemainingArguments 只收集**位置**参数，不收集带横线的参数；
#   于是 -i 被当成公共参数 -InformationAction 的缩写去绑定，整个脚本一跑就断。
#   改用 $args：无 param 块的普通函数会把 -f/-i 等原样收进 $args，再 @args 原样转发
#   给 ffmpeg —— 调用点因此一个都不用改，也不会与公共参数冲突。
function Invoke-Ffmpeg {
    & ffmpeg -hide_banner -loglevel error -y @args
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg 失败（退出码 $LASTEXITCODE）：$($args -join ' ')" }
}

# 可选素材：失败只告警。
# 约定：第一个参数是"这是什么素材"（只用于告警文案），其余原样传给 ffmpeg。
function Invoke-FfmpegSoft {
    $what = $args[0]
    $rest = @($args | Select-Object -Skip 1)
    & ffmpeg -hide_banner -loglevel error -y @rest 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "  [warn] 跳过：$what（当前 ffmpeg 缺少相应编码器）" }
}

Test-Tool "ffmpeg"
Test-Tool "ffprobe"

Write-Host ">>> 输出目录: $Out"
foreach ($d in "wav", "flac", "mp3", "ogg", "aac", "mp4") {
    New-Item -ItemType Directory -Force -Path (Join-Path $Out $d) | Out-Null
}

# ---------------------------------------------------------------- 参考信号
Write-Host ">>> 生成参考信号 ..."
$refSine    = Join-Path $Out "ref_440hz_44100_s16_stereo.wav"
$refMono    = Join-Path $Out "ref_1khz_16000_s16_mono.wav"
$refSilence = Join-Path $Out "ref_silence_44100_s16_stereo.wav"

Invoke-Ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=$DurRef" -ac 2 "-c:a" pcm_s16le $refSine
Invoke-Ffmpeg -f lavfi -i "aevalsrc='sin(2*PI*(200*t+390*t*t))':s=44100:d=${DurRef}:c=stereo" "-c:a" pcm_s16le (Join-Path $Out "ref_sweep_44100_s16_stereo.wav")
Invoke-Ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=16000:duration=$DurRef" -ac 1 "-c:a" pcm_s16le $refMono
Invoke-Ffmpeg -f lavfi -i "anullsrc=r=44100:cl=stereo" -t $DurRef "-c:a" pcm_s16le $refSilence

# ---------------------------------------------------------------- WAV 矩阵
Write-Host ">>> 生成 WAV 矩阵 ..."
$D = Join-Path $Out "wav"
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 1 "-c:a" pcm_u8    (Join-Path $D "wav_u8_44100_mono.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 1 "-c:a" pcm_s16le (Join-Path $D "wav_s16_44100_mono.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 2 "-c:a" pcm_s16le (Join-Path $D "wav_s16_44100_stereo.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 1 "-c:a" pcm_s24le (Join-Path $D "wav_s24_44100_mono.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 2 "-c:a" pcm_s24le (Join-Path $D "wav_s24_44100_stereo.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 1 "-c:a" pcm_s32le (Join-Path $D "wav_s32_44100_mono.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 2 "-c:a" pcm_s32le (Join-Path $D "wav_s32_44100_stereo.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ar 22050 -ac 1 "-c:a" pcm_s16le (Join-Path $D "wav_s16_22050_mono.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ar 48000 -ac 2 "-c:a" pcm_s16le (Join-Path $D "wav_s16_48000_stereo.wav")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ar 96000 -ac 2 "-c:a" pcm_s16le (Join-Path $D "wav_s16_96000_stereo.wav")
Invoke-Ffmpeg -i $refMono -t $DurMatrix "-c:a" pcm_s16le (Join-Path $D "wav_s16_16000_mono.wav")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" pcm_s16le `
    -metadata "title=WAV INFO Title" -metadata "artist=WAV INFO Artist" `
    -metadata "album=WAV INFO Album" -metadata "date=2026" `
    -metadata "genre=Test" -metadata "comment=WAV INFO Comment" -metadata "track=3" `
    (Join-Path $D "wav_info_tagged.wav")

# ---------------------------------------------------------------- FLAC
Write-Host ">>> 生成 FLAC 样本 ..."
$D = Join-Path $Out "flac"
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 1 "-c:a" flac (Join-Path $D "flac_s16_44100_mono.flac")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 2 "-c:a" flac -sample_fmt s16 (Join-Path $D "flac_s16_44100_stereo.flac")
Invoke-Ffmpeg -i $refSine -t $DurMatrix -ac 2 "-c:a" flac -sample_fmt s32 (Join-Path $D "flac_s24_44100_stereo.flac")
Invoke-Ffmpeg -i $refMono -t $DurMatrix "-c:a" flac (Join-Path $D "flac_s16_16000_mono.flac")
Invoke-Ffmpeg -i $refSilence "-c:a" flac (Join-Path $D "flac_silence.flac")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" flac `
    -metadata "title=FLAC 测试标题" -metadata "artist=元宝" `
    -metadata "album=Test Fixtures" -metadata "album_artist=Various" `
    -metadata "date=2026" -metadata "genre=Test" -metadata "comment=中文注释" `
    -metadata "composer=Composer Name" -metadata "track=3/12" `
    -metadata "disc=1/2" -metadata "ENCODER_CUSTOM=custom-value" `
    (Join-Path $D "flac_tagged.flac")

# ---------------------------------------------------------------- MP3
Write-Host ">>> 生成 MP3 样本 ..."
$D = Join-Path $Out "mp3"
Invoke-Ffmpeg -i $refSine -t $DurMatrix "-c:a" libmp3lame "-b:a" 128k (Join-Path $D "mp3_cbr_128k.mp3")
Invoke-Ffmpeg -i $refSine -t $DurMatrix "-c:a" libmp3lame "-q:a" 4 (Join-Path $D "mp3_vbr_q4.mp3")
Invoke-Ffmpeg -i $refMono "-c:a" libmp3lame "-b:a" 64k (Join-Path $D "mp3_16000_mono.mp3")
# 高频完整性回归素材：白噪声 + 每 0.25 s 一个瞬变。低码率 + 噪声/瞬变正是
# count1 区（频谱顶部）占比最大、最能暴露"顶部被整段写零"这一类缺陷的内容。
# 判据见 src/test/mp3_hf_regression_test.cj。
Invoke-Ffmpeg -f lavfi -i "anoisesrc=d=2:c=white:a=0.30:r=44100" `
    -f lavfi -i "aevalsrc='0.9*exp(-60*mod(t\,0.25))':s=44100:d=2" `
    -filter_complex "amix=inputs=2:normalize=0" -ac 1 "-c:a" libmp3lame "-b:a" 64k `
    (Join-Path $D "mp3_noise_64k_mono.mp3")
# 吞吐门禁用素材：20 秒合成混合内容（粉噪声 + 每 0.4 秒一个瞬变 + 多音，128k 立体声）。
# 噪声是最坏情形（count1 区被填满），门槛因此挂在这条上，
# 且 20 秒能把"每文件固定开销"摊薄。见 src/test/mp3_throughput_test.cj。
Invoke-Ffmpeg -f lavfi -i "anoisesrc=d=20:c=pink:a=0.22:r=44100" `
    -f lavfi -i "aevalsrc='0.7*exp(-50*mod(t\,0.4))*sin(2*PI*1800*t)':s=44100:d=20" `
    -f lavfi -i "aevalsrc='0.25*sin(2*PI*220*t)+0.18*sin(2*PI*880*t)+0.12*sin(2*PI*3500*t)':s=44100:d=20" `
    -filter_complex "amix=inputs=3:normalize=0,volume=0.8" -ac 2 "-c:a" libmp3lame "-b:a" 128k `
    (Join-Path $D "mp3_mix_128k_20s.mp3")
$common = @(
    "-metadata", "title=MP3 Title", "-metadata", "artist=MP3 Artist",
    "-metadata", "album=MP3 Album", "-metadata", "date=2026",
    "-metadata", "genre=Test", "-metadata", "comment=MP3 Comment"
)
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" libmp3lame "-b:a" 128k -id3v2_version 0 -write_id3v1 1 @common (Join-Path $D "mp3_id3v1.mp3")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" libmp3lame "-b:a" 128k -id3v2_version 3 -write_id3v1 0 @common (Join-Path $D "mp3_id3v23.mp3")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" libmp3lame "-b:a" 128k -id3v2_version 4 -write_id3v1 0 @common (Join-Path $D "mp3_id3v24.mp3")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" libmp3lame "-b:a" 128k -id3v2_version 3 -write_id3v1 1 @common (Join-Path $D "mp3_id3v23_plus_v1.mp3")

# ---------------------------------------------------------------- OGG
Write-Host ">>> 生成 OGG 样本 ..."
$D = Join-Path $Out "ogg"
foreach ($qv in "0", "4", "8") {
    Invoke-Ffmpeg -i $refSine -t $DurMatrix "-c:a" libvorbis "-q:a" $qv (Join-Path $D "ogg_vorbis_q$qv.ogg")
}
Invoke-Ffmpeg -i $refMono "-c:a" libvorbis "-q:a" 4 (Join-Path $D "ogg_vorbis_q4_mono.ogg")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" libvorbis "-q:a" 4 `
    -metadata "title=OGG Vorbis 标题" -metadata "artist=元宝" `
    -metadata "album=Test Fixtures" -metadata "date=2026" `
    -metadata "genre=Test" -metadata "track=5" (Join-Path $D "ogg_vorbis_tagged.ogg")
foreach ($br in "32k", "96k") {
    Invoke-Ffmpeg -i $refSine -t $DurMatrix "-c:a" libopus "-b:a" $br (Join-Path $D "ogg_opus_$br.opus")
}
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" libopus "-b:a" 64k `
    -metadata "title=OGG Opus 标题" -metadata "artist=元宝" `
    -metadata "album=Test Fixtures" (Join-Path $D "ogg_opus_tagged.opus")
Invoke-Ffmpeg -i $refSine -t $DurMatrix "-c:a" flac -f ogg (Join-Path $D "ogg_flac.oga")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" flac -f ogg `
    -metadata "title=Ogg FLAC 标题" -metadata "artist=元宝" `
    -metadata "album=Test Fixtures" -metadata "track=7" (Join-Path $D "ogg_flac_tagged.oga")
Invoke-Ffmpeg -i $refSilence "-c:a" libvorbis "-q:a" 4 (Join-Path $D "ogg_vorbis_silence.ogg")
Invoke-FfmpegSoft "Ogg/Speex 样本" -i $refMono -t $DurMatrix -ar 16000 -ac 1 "-c:a" libspeex (Join-Path $D "ogg_speex_16000.spx")

# ---------------------------------------------------------------- AAC
Write-Host ">>> 生成 AAC 样本 ..."
$D = Join-Path $Out "aac"
foreach ($br in "64k", "128k", "256k") {
    Invoke-Ffmpeg -i $refSine -t $DurMatrix "-c:a" aac "-b:a" $br -f adts (Join-Path $D "aac_adts_$br.aac")
}
Invoke-Ffmpeg -i $refMono "-c:a" aac "-b:a" 64k -f adts (Join-Path $D "aac_adts_64k_mono.aac")

# ---------------------------------------------------------------- MP4
Write-Host ">>> 生成 MP4 样本 ..."
$D = Join-Path $Out "mp4"
foreach ($br in "64k", "128k", "256k") {
    Invoke-Ffmpeg -i $refSine -t $DurMatrix "-c:a" aac "-b:a" $br (Join-Path $D "aac_mp4_$br.m4a")
}
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" aac "-b:a" 128k `
    -metadata "title=MP4 测试标题" -metadata "artist=元宝" `
    -metadata "album=Test Fixtures" -metadata "date=2026" (Join-Path $D "aac_mp4_tagged.m4a")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" aac "-b:a" 128k `
    -metadata "title=MP4 全字段标题" -metadata "artist=MP4 艺术家" `
    -metadata "album=MP4 专辑" -metadata "album_artist=MP4 专辑艺术家" `
    -metadata "date=2026" -metadata "genre=Test" -metadata "comment=MP4 注释" `
    -metadata "composer=MP4 作曲" -metadata "track=3/12" -metadata "disc=1/2" `
    (Join-Path $D "mp4_tagged_full.m4a")
Invoke-Ffmpeg -i $refSine -t $DurTagged "-c:a" aac "-b:a" 128k -movflags +faststart `
    -metadata "title=MP4 faststart 标题" -metadata "artist=MP4 艺术家" `
    -metadata "album=MP4 专辑" (Join-Path $D "mp4_tagged_faststart.m4a")

# ---------------------------------------------------------------- 封面（现造，零外部素材）
Write-Host ">>> 生成带封面的样本 ..."
$covDir = Join-Path ([System.IO.Path]::GetTempPath()) ("a4cj_covers_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $covDir | Out-Null
try {
    $covPng = Join-Path $covDir "cover.png"
    Invoke-Ffmpeg -f lavfi -i "color=c=red:s=16x16"  "-frames:v" 1 $covPng
    Invoke-Ffmpeg -f lavfi -i "color=c=blue:s=16x16" "-frames:v" 1 (Join-Path $covDir "cover.jpg")

    Invoke-Ffmpeg -i $refSine -i $covPng -map 0:a -map 1:v `
        -t $DurTagged "-c:a" flac -metadata "title=FLAC 封面标题" `
        -metadata "artist=元宝" -metadata "album=Test Fixtures" `
        "-c:v" copy "-disposition:v" attached_pic (Join-Path $Out "flac\flac_cover.flac")

    Invoke-Ffmpeg -i $refSine -i $covPng -map 0:a -map 1:v `
        -t $DurTagged "-c:a" libmp3lame "-b:a" 128k -id3v2_version 3 @common `
        "-c:v" copy "-metadata:s:v" "title=Album cover" "-metadata:s:v" "comment=Cover (front)" `
        (Join-Path $Out "mp3\mp3_cover.mp3")

    Invoke-Ffmpeg -i $refSine -i $covPng -map 0:a -map 1:v `
        -t $DurTagged "-c:a" aac "-b:a" 128k -metadata "title=MP4 Cover" `
        "-c:v" copy "-disposition:v" attached_pic (Join-Path $Out "mp4\mp4_cover.m4a")
}
finally {
    Remove-Item -Recurse -Force $covDir -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- golden 基准
# 用 ffmpeg 把可解码素材解成 f32 裸流，作为**独立第三方实现**的比对基准。
# 关键：不加 -ar / -ac，保持素材原采样率与声道数（本库只统一位深与交错布局）。
# 只取第一条音频流（-map a:0 -vn），避免带封面素材里的附加图片流干扰。
Write-Host ">>> 生成 golden 基准 ..."
$G = Join-Path $Out "golden"
New-Item -ItemType Directory -Force -Path $G | Out-Null

function Invoke-Gold([string]$Src, [string]$Dst) {
    & ffmpeg -hide_banner -loglevel error -y -i $Src -map a:0 -vn -f f32le -acodec pcm_f32le $Dst
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg 生成 golden 失败（退出码 $LASTEXITCODE）：$Src" }
}

# 基准按「信号」命名而非按素材命名：多个无损素材共用同一份基准，
# 这恰恰说明它们必须解出相同结果（无损互证）。
Invoke-Gold (Join-Path $Out "wav\wav_s16_44100_stereo.wav")    (Join-Path $G "sine_44100_stereo_s16.f32le")
Invoke-Gold (Join-Path $Out "flac\flac_s16_44100_stereo.flac") (Join-Path $G "sine_44100_stereo_s16.f32le")
Invoke-Gold (Join-Path $Out "ogg\ogg_flac.oga")                (Join-Path $G "sine_44100_stereo_s16.f32le")
Invoke-Gold (Join-Path $Out "wav\wav_s24_44100_stereo.wav")    (Join-Path $G "sine_44100_stereo_s24.f32le")
Invoke-Gold (Join-Path $Out "flac\flac_s24_44100_stereo.flac") (Join-Path $G "sine_44100_stereo_s24.f32le")
Invoke-Gold (Join-Path $Out "wav\wav_s16_44100_mono.wav")      (Join-Path $G "sine_44100_mono_s16.f32le")
Invoke-Gold (Join-Path $Out "flac\flac_s16_44100_mono.flac")   (Join-Path $G "sine_44100_mono_s16.f32le")
Invoke-Gold (Join-Path $Out "wav\wav_u8_44100_mono.wav")       (Join-Path $G "sine_44100_mono_u8.f32le")
Invoke-Gold (Join-Path $Out "wav\wav_s16_16000_mono.wav")      (Join-Path $G "tone_16000_mono_s16.f32le")
Invoke-Gold (Join-Path $Out "flac\flac_s16_16000_mono.flac")   (Join-Path $G "tone_16000_mono_s16.f32le")
# 有损格式（MP3）：基准同样是 ffmpeg 的输出，但比对只走 envelope 模式（见 GOLDEN.tsv）
Invoke-Gold (Join-Path $Out "mp3\mp3_cbr_128k.mp3")            (Join-Path $G "mp3_cbr_128k.f32le")
# 高频回归用它做**分频段**基准（envelope 那套对"顶部被抹掉"不敏感，见 mp3_hf_regression_test.cj）
Invoke-Gold (Join-Path $Out "mp3\mp3_noise_64k_mono.mp3")      (Join-Path $G "mp3_noise_64k_mono.f32le")

# GOLDEN.tsv：素材 → 基准 + 比对模式（供 src/test/golden_test.cj 读取）
# 【与 gen_testdata.sh 必须逐字节一致】含行尾：这里显式用 LF 与无 BOM 的 UTF-8，
#   否则 Windows 默认的 CRLF + BOM 会让"两脚本产出一致"这条验收出现假差异。
$goldenTsv = @(
    "# fixture`tgolden`tmode"
    "# 由 scripts/gen_testdata.sh 或 scripts/gen_testdata.ps1 生成，供 src/test/golden_test.cj 读取。"
    "# fixture 为 testdata 下的相对路径；golden 为 testdata/golden 下的文件名。"
    "# mode: samples（逐样本比对，无损格式）/ envelope（长度 + 整体能量，有损格式）。"
    "# 有损格式（MP3）只能走 envelope：两套有损解码器在量化细节与编码器延迟补偿上"
    "# **合法地**存在差异，逐样本相等不是'更高标准'而是错误标准。见 golden_test.cj。"
    "wav/wav_s16_44100_stereo.wav`tsine_44100_stereo_s16.f32le`tsamples"
    "flac/flac_s16_44100_stereo.flac`tsine_44100_stereo_s16.f32le`tsamples"
    "ogg/ogg_flac.oga`tsine_44100_stereo_s16.f32le`tsamples"
    "wav/wav_s24_44100_stereo.wav`tsine_44100_stereo_s24.f32le`tsamples"
    "flac/flac_s24_44100_stereo.flac`tsine_44100_stereo_s24.f32le`tsamples"
    "wav/wav_s16_44100_mono.wav`tsine_44100_mono_s16.f32le`tsamples"
    "flac/flac_s16_44100_mono.flac`tsine_44100_mono_s16.f32le`tsamples"
    "wav/wav_u8_44100_mono.wav`tsine_44100_mono_u8.f32le`tsamples"
    "wav/wav_s16_16000_mono.wav`ttone_16000_mono_s16.f32le`tsamples"
    "flac/flac_s16_16000_mono.flac`ttone_16000_mono_s16.f32le`tsamples"
    "mp3/mp3_cbr_128k.mp3`tmp3_cbr_128k.f32le`tenvelope"
    "mp3/mp3_noise_64k_mono.mp3`tmp3_noise_64k_mono.f32le`tenvelope"
)
[System.IO.File]::WriteAllText((Join-Path $G "GOLDEN.tsv"), (($goldenTsv -join "`n") + "`n"),
    (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- MANIFEST.tsv
# 探测层识别矩阵的对照基准。
#
# 【codec 列的语义（实测对齐仓库权威版本）】只有 **Ogg 容器**才带子编码
#   （vorbis / opus / flac / speex）—— 因为 Ogg 是容器，必须再报一层编码。
#   其余格式（wav/flac/mp3/aac/mp4）**codec 列为空**：对它们而言容器即编码，
#   再填一遍等于"期望 flac/flac"，而探测层实际只报 flac/ 。这一列填错会让
#   probe_matrix_test 的 everyFixtureMatchesManifest 全线失败。
Write-Host ">>> 生成 MANIFEST.tsv ..."
$OutAbs = (Resolve-Path $Out).Path
$relFiles = Get-ChildItem -Path $OutAbs -Recurse -File |
    Where-Object { $_.Extension.ToLower() -in @(".wav", ".flac", ".mp3", ".ogg", ".oga", ".opus", ".spx", ".aac", ".m4a") } |
    ForEach-Object { $_.FullName.Substring($OutAbs.Length).TrimStart('\', '/').Replace('\', '/') }

# 【排序必须用序数比较】等价于 shell 的 LC_ALL=C sort。PowerShell 默认的 Sort-Object
#   按区域文化排序，'_' 与字母的先后可能与仓库内权威文件不同 —— 那是排序口径不同，
#   不是素材差异，但会让"与仓库逐行比对"这条验收报出假失败。
$sorted = [string[]]$relFiles
[Array]::Sort($sorted, [System.StringComparer]::Ordinal)

$manifest = New-Object System.Collections.Generic.List[string]
$manifest.Add("# path`tcontainer`tcodec")
$manifest.Add("# 由 scripts/gen_testdata.sh 或 scripts/gen_testdata.ps1 生成，作为探测层识别矩阵测试的对照基准。")
$manifest.Add("# container/codec 由本脚本按扩展名与文件名保守识别；权威值与原 sctiptr/gen_audio_fixtures.py 的 sniff() 一致（只有 Ogg 才带子编码）。")
foreach ($rel in $sorted) {
    $c = ""
    $codec = ""
    if ($rel -like 'wav/*') {
        $c = "wav"
    }
    elseif ($rel -like 'flac/*') {
        $c = "flac"
    }
    elseif ($rel -like 'mp3/*') {
        $c = "mp3"
    }
    elseif ($rel -like 'mp4/*') {
        $c = "mp4"
    }
    elseif ($rel -like 'aac/*') {
        $c = "aac"
    }
    elseif ($rel -like 'ogg/*') {
        $c = "ogg"
        if ($rel -like '*vorbis*') { $codec = "vorbis" }
        elseif ($rel -like '*opus*') { $codec = "opus" }
        elseif ($rel -like '*flac*') { $codec = "flac" }
        elseif ($rel -like '*speex*') { $codec = "speex" }
    }
    elseif ($rel -like '*.wav') {
        $c = "wav"
    }
    $manifest.Add("$rel`t$c`t$codec")
}
# 同样显式用 LF + 无 BOM（理由见上）
[System.IO.File]::WriteAllText((Join-Path $Out "MANIFEST.tsv"), (($manifest -join "`n") + "`n"),
    (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- 汇总
$exts = @("*.wav", "*.flac", "*.mp3", "*.ogg", "*.oga", "*.opus", "*.spx", "*.aac", "*.m4a")
$count  = (Get-ChildItem -Path $Out -Recurse -File -Include $exts).Count
$gcount = (Get-ChildItem -Path $G -File -Filter *.f32le).Count
Write-Host ""
Write-Host "=== 素材生成完成: $Out ==="
Write-Host "    音频素材 $count 个；golden 基准 $gcount 个；MANIFEST.tsv 与 GOLDEN.tsv 已生成"
Write-Host "接下来可运行: cjpm test（应为 206 通过 / 0 失败）"
