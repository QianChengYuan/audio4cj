#!/bin/bash
# install.sh — 仓颉 SDK 安装脚本(Linux / macOS)
# 由 .github/actions/setup-cangjie/composite action 调用
# 通过环境变量 INPUT_OS / INPUT_VERSION / INPUT_URL_OVERRIDE / INPUT_SHA_OVERRIDE 传参
#
# 覆盖平台：linux / linux-arm64 / macos（均为 1.2.0）
#
# 注：本文件必须以 **LF** 行尾入库 —— CRLF 的 shell 脚本在 Linux 上会因
#     `\r` 而报 "bad interpreter"。仓库根的 .gitattributes 已用 `eol=lf` 保证。

set -euo pipefail

INPUT_OS="${INPUT_OS:-linux}"
INPUT_VERSION="${INPUT_VERSION:-1.2.0}"
INPUT_URL_OVERRIDE="${INPUT_URL_OVERRIDE:-}"
INPUT_SHA_OVERRIDE="${INPUT_SHA_OVERRIDE:-}"

# 内置下载源表：objectKey 与 SDK 版本一一对应（objectKey 是官方对象存储的文件
# ID，换版本必须换 key），因此按 "${OS}_${VERSION}" 整条列举，而不是用 fileName
# 变量去拼 key。
# SHA-256 同表硬编码（含 macOS，不默认跳过校验）。
# 维护方式：抓 https://cangjie-lang.cn/download/<version> 的前端 JS chunk 搜文件名，
#          可同时得到 objectKey 与 sha；再用 HEAD 请求核对 Content-Length 是否等于
#          官网标称大小。
# 覆盖方式：url-override / sha-override（CI 传 vars.CANGJIE_SDK_URL_* /
#          vars.CANGJIE_SDK_SHA_*）。
# 注：不用关联数组（macOS 自带 bash 3.2 不支持 declare -A），故用扁平 case 列举。
case "${INPUT_OS}_${INPUT_VERSION}" in
  linux_1.2.0)
    DEFAULT_URL="https://cangjie-lang.cn/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-linux-x64-1.2.0.tar.gz&objectKey=6ab1e26eece1f87ff5befa73"
    DEFAULT_SHA="8c5fd944cd9cc51ee63d4a240e3ecc4f540345dae1468e8b47c927ecf2ba998f"
    ;;
  linux-arm64_1.2.0)
    DEFAULT_URL="https://cangjie-lang.cn/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-linux-aarch64-1.2.0.tar.gz&objectKey=6ab1e26eece1f87ff5befa72"
    DEFAULT_SHA="40e3962472d6d1b181e685198b193b904a385ac8dbbdff8aa9c52c4bb6f6e0f1"
    ;;
  macos_1.2.0)
    DEFAULT_URL="https://cangjie-lang.cn/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-mac-aarch64-1.2.0.tar.gz&objectKey=6ab1e6451320215435b23d52"
    DEFAULT_SHA="de88d6ba2185c94979e0ab2fe8ac1d81535dfdff3fcb51fbba71e4b99d851f97"
    ;;
  *)
    DEFAULT_URL=""
    DEFAULT_SHA=""
    ;;
esac

url="${INPUT_URL_OVERRIDE:-$DEFAULT_URL}"
sha="${INPUT_SHA_OVERRIDE:-$DEFAULT_SHA}"

if [ -z "$url" ]; then
  echo "::error::未在内置表中找到 ${INPUT_OS} / ${INPUT_VERSION} 的 SDK 下载地址;请用 url-override 覆盖,或在 install.sh 的内置表中补充该组合"
  exit 1
fi

mkdir -p "$RUNNER_TEMP/cangjie-sdk"
echo "==> 下载仓颉 SDK: $url"
curl -fL --retry 3 -o "$RUNNER_TEMP/cangjie-sdk.tar.gz" "$url"

if [ -n "$sha" ]; then
  echo "==> 校验 SHA-256: $sha"
  # macOS 自带 shasum(无 sha256sum),两者 -c 的输入格式一致
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$sha  $RUNNER_TEMP/cangjie-sdk.tar.gz" | sha256sum -c -
  else
    echo "$sha  $RUNNER_TEMP/cangjie-sdk.tar.gz" | shasum -a 256 -c -
  fi
else
  # bash 3.2(macOS)不支持 ${var^^},用 tr 转大写
  OS_UPPER=$(echo "$INPUT_OS" | tr '[:lower:]' '[:upper:]')
  echo "::warning::平台 ${INPUT_OS} 未配置 SHA-256,跳过校验(建议配 vars.CANGJIE_SDK_SHA_${OS_UPPER})"
fi

echo "==> 解压到: $RUNNER_TEMP/cangjie-sdk"
tar -xzf "$RUNNER_TEMP/cangjie-sdk.tar.gz" -C "$RUNNER_TEMP/cangjie-sdk"

# 探测 envsetup.sh(GNU find 与 BSD find 都支持 -maxdepth,仅 -printf 不通用)
CANGJIE_HOME="$(dirname "$(find "$RUNNER_TEMP/cangjie-sdk" -maxdepth 2 -name envsetup.sh | head -n1)")"
if [ -z "$CANGJIE_HOME" ]; then
  echo "::error::解压后未找到 envsetup.sh"
  exit 1
fi

echo "CANGJIE_HOME=$CANGJIE_HOME"            >> "$GITHUB_ENV"
echo "$CANGJIE_HOME/bin"                      >> "$GITHUB_PATH"
echo "$CANGJIE_HOME/tools/bin"                >> "$GITHUB_PATH"

# 运行时库路径(Linux / macOS 注入方式不同)
case "$INPUT_OS" in
  linux)
    echo "LD_LIBRARY_PATH=$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/tools/lib:${LD_LIBRARY_PATH:-}" >> "$GITHUB_ENV"
    ;;
  linux-arm64)
    echo "LD_LIBRARY_PATH=$CANGJIE_HOME/runtime/lib/linux_aarch64_cjnative:$CANGJIE_HOME/tools/lib:${LD_LIBRARY_PATH:-}" >> "$GITHUB_ENV"
    ;;
  macos)
    # 动态探测 cjnative 子目录(macOS 实测为 darwin_aarch64_cjnative)
    CJ_RUNTIME_LIB="$(find "$CANGJIE_HOME/runtime/lib" -maxdepth 1 -type d -name '*cjnative' | head -n1)"
    if [ -z "$CJ_RUNTIME_LIB" ]; then
      echo "::error::未找到仓颉 runtime lib cjnative 目录($CANGJIE_HOME/runtime/lib 下)"
      ls -la "$CANGJIE_HOME/runtime/lib" || true
      exit 1
    fi
    echo "CJ_RUNTIME_LIB=$CJ_RUNTIME_LIB" >> "$GITHUB_ENV"
    echo "DYLD_LIBRARY_PATH=$CJ_RUNTIME_LIB:$CANGJIE_HOME/tools/lib:${DYLD_LIBRARY_PATH:-}" >> "$GITHUB_ENV"
    ;;
esac

# step output(供 composite 顶层 outputs 引用)
echo "cangjie-home=$CANGJIE_HOME" >> "$GITHUB_OUTPUT"
echo "==> 已安装到: $CANGJIE_HOME"
