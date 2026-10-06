#!/usr/bin/env bash
# ============================================================================
# gen_testdata.sh —— 就地重建测试素材（testdata/），供 `cjpm test` 完整运行
#
# 背景：制品包**不含** testdata/（cjpm bundle 不打包二进制文件，这是平台行为）。
#   仓库内 testdata/ 已入库，故从源码仓库跑测试无需本脚本。
#   但评审方/使用者拿到的是制品包 —— 包里没有素材，`cjpm test` 会成片跳过。
#   本脚本让任何拿到**源码包**的人都能自己把素材生成出来，从而在包内跑通全量测试。
#
# 用法（在包根目录，即与 cjpm.toml 同级处执行）：
#     bash scripts/gen_testdata.sh              # 生成到 ./testdata
#     bash scripts/gen_testdata.sh /tmp/td      # 生成到指定目录
#
# 依赖：ffmpeg / ffprobe（需含 aac / libvorbis / libopus / flac / libmp3lame
#   编码器；libspeex 为可选，缺失时跳过 Speex 样本而不影响其余）。
#
# 授权：本脚本生成的全部素材均由**合成信号**编码而来，不含任何第三方版权内容。
#
# 与仓库内 sctiptr/*.py 的关系：两者产出同一套素材（时长常量、标签字段、
#   封面做法均对齐）。本脚本是**自包含**版本 —— 只依赖 ffmpeg，不依赖 Python，
#   因而适合随包分发、供使用者直接运行。
# ============================================================================
set -euo pipefail

OUT="${1:-testdata}"
# 时长常量与 sctiptr/gen_audio_fixtures.py 严格对齐（改一处必须改另一处）
DUR_REF=3        # 参考信号时长（秒）
DUR_MATRIX=1     # 位深 / 声道 / 采样率矩阵样本时长
DUR_TAGGED=2     # 带标签样本时长（稍长，便于验证时长计算）

command -v ffmpeg  >/dev/null 2>&1 || { echo "错误: 未找到 ffmpeg，请先安装并加入 PATH"; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "错误: 未找到 ffprobe，请先安装并加入 PATH"; exit 1; }

echo ">>> 输出目录: $(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
mkdir -p "$OUT"/{wav,flac,mp3,ogg,aac,mp4}

# 静默执行；失败即中断（-e 生效）
q() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# 可选素材：失败只告警
soft() {
  local what="$1"; shift
  if ! ffmpeg -hide_banner -loglevel error -y "$@" 2>/dev/null; then
    echo "  [warn] 跳过：$what（当前 ffmpeg 缺少相应编码器）"
  fi
}

# ---------------------------------------------------------------- 参考信号
# 所有编码分组的唯一输入源，也是"无损互证"的基准。
echo ">>> 生成参考信号 ..."
REF_SINE="$OUT/ref_440hz_44100_s16_stereo.wav"
REF_MONO="$OUT/ref_1khz_16000_s16_mono.wav"
REF_SILENCE="$OUT/ref_silence_44100_s16_stereo.wav"

q -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=$DUR_REF" -ac 2 -c:a pcm_s16le "$REF_SINE"
q -f lavfi -i "aevalsrc='sin(2*PI*(200*t+390*t*t))':s=44100:d=$DUR_REF:c=stereo" -c:a pcm_s16le "$OUT/ref_sweep_44100_s16_stereo.wav"
q -f lavfi -i "sine=frequency=1000:sample_rate=16000:duration=$DUR_REF" -ac 1 -c:a pcm_s16le "$REF_MONO"
q -f lavfi -i "anullsrc=r=44100:cl=stereo" -t "$DUR_REF" -c:a pcm_s16le "$REF_SILENCE"

# ---------------------------------------------------------------- WAV 矩阵
echo ">>> 生成 WAV 矩阵 ..."
D="$OUT/wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 1 -c:a pcm_u8      "$D/wav_u8_44100_mono.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 1 -c:a pcm_s16le   "$D/wav_s16_44100_mono.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 2 -c:a pcm_s16le   "$D/wav_s16_44100_stereo.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 1 -c:a pcm_s24le   "$D/wav_s24_44100_mono.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 2 -c:a pcm_s24le   "$D/wav_s24_44100_stereo.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 1 -c:a pcm_s32le   "$D/wav_s32_44100_mono.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 2 -c:a pcm_s32le   "$D/wav_s32_44100_stereo.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ar 22050 -ac 1 -c:a pcm_s16le "$D/wav_s16_22050_mono.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ar 48000 -ac 2 -c:a pcm_s16le "$D/wav_s16_48000_stereo.wav"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ar 96000 -ac 2 -c:a pcm_s16le "$D/wav_s16_96000_stereo.wav"
q -i "$REF_MONO" -t "$DUR_MATRIX" -c:a pcm_s16le "$D/wav_s16_16000_mono.wav"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a pcm_s16le \
  -metadata title="WAV INFO Title" -metadata artist="WAV INFO Artist" \
  -metadata album="WAV INFO Album" -metadata date="2026" \
  -metadata genre="Test" -metadata comment="WAV INFO Comment" -metadata track="3" \
  "$D/wav_info_tagged.wav"

# ---------------------------------------------------------------- FLAC
# 与 wav/ 下的同名样本构成无损互证对：**时长、参数必须完全一致**，
# 否则两者不构成合法的互证对（同一段 PCM 才能要求解码结果相同）。
echo ">>> 生成 FLAC 样本 ..."
D="$OUT/flac"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 1 -c:a flac "$D/flac_s16_44100_mono.flac"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 2 -c:a flac -sample_fmt s16 "$D/flac_s16_44100_stereo.flac"
q -i "$REF_SINE" -t "$DUR_MATRIX" -ac 2 -c:a flac -sample_fmt s32 "$D/flac_s24_44100_stereo.flac"
q -i "$REF_MONO" -t "$DUR_MATRIX" -c:a flac "$D/flac_s16_16000_mono.flac"
# 静音素材不加 -t：直接用参考静音信号的完整时长（3 秒）
q -i "$REF_SILENCE" -c:a flac "$D/flac_silence.flac"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a flac \
  -metadata title="FLAC 测试标题" -metadata artist="元宝" \
  -metadata album="Test Fixtures" -metadata album_artist="Various" \
  -metadata date="2026" -metadata genre="Test" -metadata comment="中文注释" \
  -metadata composer="Composer Name" -metadata track="3/12" \
  -metadata disc="1/2" -metadata ENCODER_CUSTOM="custom-value" \
  "$D/flac_tagged.flac"

# ---------------------------------------------------------------- MP3
# ID3v1 样本只用 ASCII 元数据：ffmpeg 的 -write_id3v1 写 UTF-8，而规范是
# ISO-8859-1，塞中文测出的是"ffmpeg 与规范不一致"而非我们的解析逻辑。
echo ">>> 生成 MP3 样本 ..."
D="$OUT/mp3"
q -i "$REF_SINE" -t "$DUR_MATRIX" -c:a libmp3lame -b:a 128k "$D/mp3_cbr_128k.mp3"
q -i "$REF_SINE" -t "$DUR_MATRIX" -c:a libmp3lame -q:a 4 "$D/mp3_vbr_q4.mp3"
q -i "$REF_MONO" -c:a libmp3lame -b:a 64k "$D/mp3_16000_mono.mp3"
# 高频完整性回归素材：白噪声 + 每 0.25 s 一个瞬变（判据见 src/test/mp3_hf_regression_test.cj）
q -f lavfi -i "anoisesrc=d=2:c=white:a=0.30:r=44100" \
  -f lavfi -i "aevalsrc='0.9*exp(-60*mod(t\,0.25))':s=44100:d=2" \
  -filter_complex "amix=inputs=2:normalize=0" -ac 1 -c:a libmp3lame -b:a 64k \
  "$D/mp3_noise_64k_mono.mp3"
COMMON=( -metadata title="MP3 Title" -metadata artist="MP3 Artist" \
         -metadata album="MP3 Album" -metadata date="2026" \
         -metadata genre="Test" -metadata comment="MP3 Comment" )
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a libmp3lame -b:a 128k -id3v2_version 0 -write_id3v1 1 "${COMMON[@]}" "$D/mp3_id3v1.mp3"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a libmp3lame -b:a 128k -id3v2_version 3 -write_id3v1 0 "${COMMON[@]}" "$D/mp3_id3v23.mp3"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a libmp3lame -b:a 128k -id3v2_version 4 -write_id3v1 0 "${COMMON[@]}" "$D/mp3_id3v24.mp3"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a libmp3lame -b:a 128k -id3v2_version 3 -write_id3v1 1 "${COMMON[@]}" "$D/mp3_id3v23_plus_v1.mp3"

# ---------------------------------------------------------------- OGG
echo ">>> 生成 OGG 样本 ..."
D="$OUT/ogg"
for qv in 0 4 8; do
  q -i "$REF_SINE" -t "$DUR_MATRIX" -c:a libvorbis -q:a "$qv" "$D/ogg_vorbis_q$qv.ogg"
done
q -i "$REF_MONO" -c:a libvorbis -q:a 4 "$D/ogg_vorbis_q4_mono.ogg"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a libvorbis -q:a 4 \
  -metadata title="OGG Vorbis 标题" -metadata artist="元宝" \
  -metadata album="Test Fixtures" -metadata date="2026" \
  -metadata genre="Test" -metadata track="5" "$D/ogg_vorbis_tagged.ogg"
for br in 32k 96k; do
  q -i "$REF_SINE" -t "$DUR_MATRIX" -c:a libopus -b:a "$br" "$D/ogg_opus_$br.opus"
done
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a libopus -b:a 64k \
  -metadata title="OGG Opus 标题" -metadata artist="元宝" \
  -metadata album="Test Fixtures" "$D/ogg_opus_tagged.opus"
q -i "$REF_SINE" -t "$DUR_MATRIX" -c:a flac -f ogg "$D/ogg_flac.oga"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a flac -f ogg \
  -metadata title="Ogg FLAC 标题" -metadata artist="元宝" \
  -metadata album="Test Fixtures" -metadata track="7" "$D/ogg_flac_tagged.oga"
q -i "$REF_SILENCE" -c:a libvorbis -q:a 4 "$D/ogg_vorbis_silence.ogg"
soft "Ogg/Speex 样本" -i "$REF_MONO" -t "$DUR_MATRIX" -ar 16000 -ac 1 -c:a libspeex "$D/ogg_speex_16000.spx"

# ---------------------------------------------------------------- AAC
echo ">>> 生成 AAC 样本 ..."
D="$OUT/aac"
for br in 64k 128k 256k; do
  q -i "$REF_SINE" -t "$DUR_MATRIX" -c:a aac -b:a "$br" -f adts "$D/aac_adts_$br.aac"
done
q -i "$REF_MONO" -c:a aac -b:a 64k -f adts "$D/aac_adts_64k_mono.aac"

# ---------------------------------------------------------------- MP4
echo ">>> 生成 MP4 样本 ..."
D="$OUT/mp4"
for br in 64k 128k 256k; do
  q -i "$REF_SINE" -t "$DUR_MATRIX" -c:a aac -b:a "$br" "$D/aac_mp4_$br.m4a"
done
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a aac -b:a 128k \
  -metadata title="MP4 测试标题" -metadata artist="元宝" \
  -metadata album="Test Fixtures" -metadata date="2026" "$D/aac_mp4_tagged.m4a"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a aac -b:a 128k \
  -metadata title="MP4 全字段标题" -metadata artist="MP4 艺术家" \
  -metadata album="MP4 专辑" -metadata album_artist="MP4 专辑艺术家" \
  -metadata date="2026" -metadata genre="Test" -metadata comment="MP4 注释" \
  -metadata composer="MP4 作曲" -metadata track="3/12" -metadata disc="1/2" \
  "$D/mp4_tagged_full.m4a"
q -i "$REF_SINE" -t "$DUR_TAGGED" -c:a aac -b:a 128k -movflags +faststart \
  -metadata title="MP4 faststart 标题" -metadata artist="MP4 艺术家" \
  -metadata album="MP4 专辑" "$D/mp4_tagged_faststart.m4a"

# ---------------------------------------------------------------- 封面（现造，零外部素材）
echo ">>> 生成带封面的样本 ..."
COV_DIR="$(mktemp -d)"
trap 'rm -rf "$COV_DIR"' EXIT
COV_PNG="$COV_DIR/cover.png"
q -f lavfi -i "color=c=red:s=16x16"  -frames:v 1 "$COV_PNG"
q -f lavfi -i "color=c=blue:s=16x16" -frames:v 1 "$COV_DIR/cover.jpg"

q -i "$REF_SINE" -i "$COV_PNG" -map 0:a -map 1:v \
  -t "$DUR_TAGGED" -c:a flac -metadata title="FLAC 封面标题" \
  -metadata artist="元宝" -metadata album="Test Fixtures" \
  -c:v copy -disposition:v attached_pic "$OUT/flac/flac_cover.flac"

q -i "$REF_SINE" -i "$COV_PNG" -map 0:a -map 1:v \
  -t "$DUR_TAGGED" -c:a libmp3lame -b:a 128k -id3v2_version 3 "${COMMON[@]}" \
  -c:v copy -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
  "$OUT/mp3/mp3_cover.mp3"

q -i "$REF_SINE" -i "$COV_PNG" -map 0:a -map 1:v \
  -t "$DUR_TAGGED" -c:a aac -b:a 128k -metadata title="MP4 Cover" \
  -c:v copy -disposition:v attached_pic "$OUT/mp4/mp4_cover.m4a"

# ---------------------------------------------------------------- golden 基准
# 用 ffmpeg 把可解码素材解成 f32 裸流，作为**独立第三方实现**的比对基准。
# 关键：不加 -ar / -ac，保持素材原采样率与声道数（本库只统一位深与交错布局）。
# 只取第一条音频流（-map a:0 -vn），避免带封面素材里的附加图片流干扰。
echo ">>> 生成 golden 基准 ..."
G="$OUT/golden"
mkdir -p "$G"
gold() { q -i "$1" -map a:0 -vn -f f32le -acodec pcm_f32le "$2"; }

# 基准按「信号」命名而非按素材命名：多个无损素材共用同一份基准，
# 这恰恰说明它们必须解出相同结果（无损互证）。
gold "$OUT/wav/wav_s16_44100_stereo.wav"     "$G/sine_44100_stereo_s16.f32le"
gold "$OUT/flac/flac_s16_44100_stereo.flac"  "$G/sine_44100_stereo_s16.f32le"
gold "$OUT/ogg/ogg_flac.oga"                 "$G/sine_44100_stereo_s16.f32le"
gold "$OUT/wav/wav_s24_44100_stereo.wav"     "$G/sine_44100_stereo_s24.f32le"
gold "$OUT/flac/flac_s24_44100_stereo.flac"  "$G/sine_44100_stereo_s24.f32le"
gold "$OUT/wav/wav_s16_44100_mono.wav"       "$G/sine_44100_mono_s16.f32le"
gold "$OUT/flac/flac_s16_44100_mono.flac"    "$G/sine_44100_mono_s16.f32le"
gold "$OUT/wav/wav_u8_44100_mono.wav"        "$G/sine_44100_mono_u8.f32le"
gold "$OUT/wav/wav_s16_16000_mono.wav"       "$G/tone_16000_mono_s16.f32le"
gold "$OUT/flac/flac_s16_16000_mono.flac"    "$G/tone_16000_mono_s16.f32le"
# 有损格式（MP3）：基准同样是 ffmpeg 的输出，但比对只走 envelope 模式（见 GOLDEN.tsv）
gold "$OUT/mp3/mp3_cbr_128k.mp3"             "$G/mp3_cbr_128k.f32le"
# 高频回归用它做**分频段**基准（envelope 那套对"顶部被抹掉"不敏感）
gold "$OUT/mp3/mp3_noise_64k_mono.mp3"       "$G/mp3_noise_64k_mono.f32le"

# GOLDEN.tsv：素材 → 基准 + 比对模式（供 src/test/golden_test.cj 读取）
cat > "$G/GOLDEN.tsv" <<'TSV'
# fixture	golden	mode
# 由 scripts/gen_testdata.sh 或 scripts/gen_testdata.ps1 生成，供 src/test/golden_test.cj 读取。
# fixture 为 testdata 下的相对路径；golden 为 testdata/golden 下的文件名。
# mode: samples（逐样本比对，无损格式）/ envelope（长度 + 整体能量，有损格式）。
# 有损格式（MP3）只能走 envelope：两套有损解码器在量化细节与编码器延迟补偿上
# **合法地**存在差异，逐样本相等不是"更高标准"而是错误标准。见 golden_test.cj。
wav/wav_s16_44100_stereo.wav	sine_44100_stereo_s16.f32le	samples
flac/flac_s16_44100_stereo.flac	sine_44100_stereo_s16.f32le	samples
ogg/ogg_flac.oga	sine_44100_stereo_s16.f32le	samples
wav/wav_s24_44100_stereo.wav	sine_44100_stereo_s24.f32le	samples
flac/flac_s24_44100_stereo.flac	sine_44100_stereo_s24.f32le	samples
wav/wav_s16_44100_mono.wav	sine_44100_mono_s16.f32le	samples
flac/flac_s16_44100_mono.flac	sine_44100_mono_s16.f32le	samples
wav/wav_u8_44100_mono.wav	sine_44100_mono_u8.f32le	samples
wav/wav_s16_16000_mono.wav	tone_16000_mono_s16.f32le	samples
flac/flac_s16_16000_mono.flac	tone_16000_mono_s16.f32le	samples
mp3/mp3_cbr_128k.mp3	mp3_cbr_128k.f32le	envelope
mp3/mp3_noise_64k_mono.mp3	mp3_noise_64k_mono.f32le	envelope
TSV

# ---------------------------------------------------------------- MANIFEST.tsv
# 探测层识别矩阵的对照基准。
#
# 【codec 列的语义（实测对齐仓库权威版本）】只有 **Ogg 容器**才带子编码
#   （vorbis / opus / flac / speex）—— 因为 Ogg 是容器，必须再报一层编码。
#   其余格式（wav/flac/mp3/aac/mp4）**codec 列为空**：对它们而言容器即编码，
#   再填一遍等于"期望 flac/flac"，而探测层实际只报 flac/ 。这一列填错会让
#   probe_matrix_test 的 everyFixtureMatchesManifest 全线失败。
echo ">>> 生成 MANIFEST.tsv ..."
{
  printf '# path\tcontainer\tcodec\n'
  printf '# 由 scripts/gen_testdata.sh 或 scripts/gen_testdata.ps1 生成，作为探测层识别矩阵测试的对照基准。\n'
  printf '# container/codec 由本脚本按扩展名与文件名保守识别；权威值与原 sctiptr/gen_audio_fixtures.py 的 sniff() 一致（只有 Ogg 才带子编码）。\n'
  find "$OUT" -type f \( -name '*.wav' -o -name '*.flac' -o -name '*.mp3' \
       -o -name '*.ogg' -o -name '*.oga' -o -name '*.opus' -o -name '*.spx' \
       -o -name '*.aac' -o -name '*.m4a' \) | LC_ALL=C sort | while read -r f; do
    rel="${f#"$OUT"/}"
    case "$rel" in
      wav/*)  c=wav;  codec="" ;;
      flac/*) c=flac; codec="" ;;
      mp3/*)  c=mp3;  codec="" ;;
      mp4/*)  c=mp4;  codec="" ;;
      aac/*)  c=aac;  codec="" ;;
      ogg/*)
        c=ogg
        case "$rel" in
          *vorbis*) codec=vorbis ;;
          *opus*)   codec=opus ;;
          *flac*)   codec=flac ;;
          *speex*)  codec=speex ;;
          *)        codec="" ;;
        esac ;;
      *.wav)  c=wav;  codec="" ;;
      *)      c="";   codec="" ;;
    esac
    printf '%s\t%s\t%s\n' "$rel" "$c" "$codec"
  done
} > "$OUT/MANIFEST.tsv"

# ---------------------------------------------------------------- 汇总
COUNT="$(find "$OUT" -type f \( -name '*.wav' -o -name '*.flac' -o -name '*.mp3' \
        -o -name '*.ogg' -o -name '*.oga' -o -name '*.opus' -o -name '*.spx' \
        -o -name '*.aac' -o -name '*.m4a' \) | wc -l)"
GCOUNT="$(find "$G" -name '*.f32le' | wc -l)"
echo ""
echo "=== 素材生成完成: $OUT ==="
echo "    音频素材 $COUNT 个；golden 基准 $GCOUNT 个"
echo "接下来可运行: cjpm test"
