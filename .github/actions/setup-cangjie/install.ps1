# install.ps1 — 仓颉 SDK 安装脚本(Windows)
# 由 .github/actions/setup-cangjie/composite action 调用
# 通过环境变量 INPUT_OS / INPUT_VERSION / INPUT_URL_OVERRIDE / INPUT_SHA_OVERRIDE 传参
#
# 覆盖平台：windows（1.2.0）

$ErrorActionPreference = "Stop"

$InputOS        = if ($env:INPUT_OS)        { $env:INPUT_OS }        else { "windows" }
$InputVersion   = if ($env:INPUT_VERSION)   { $env:INPUT_VERSION }   else { "1.2.0" }
$InputURL       = if ($env:INPUT_URL_OVERRIDE) { $env:INPUT_URL_OVERRIDE } else { "" }
$InputSHA       = if ($env:INPUT_SHA_OVERRIDE) { $env:INPUT_SHA_OVERRIDE } else { "" }

# 内置下载源表：objectKey 与 SDK 版本一一对应（objectKey 是官方对象存储的文件 ID，
# 换版本必须换 key），因此按 "${OS}_${VERSION}" 整条列举，而不是用版本变量拼 key。
# 维护方式(与 install.sh 一致)：抓 https://cangjie-lang.cn/download/<version> 的
#          前端 JS chunk 搜文件名，可同时得到 objectKey 与 sha；
#          再用 HEAD 请求核对 Content-Length 是否等于官网标称大小。
# 覆盖方式：url-override / sha-override（CI 传 vars.CANGJIE_SDK_URL_WINDOWS /
#          vars.CANGJIE_SDK_SHA_WINDOWS）。
$defaultURLs = @{
  "windows_1.2.0" = "https://cangjie-lang.cn/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-windows-x64-1.2.0.zip&objectKey=6ab1eafae4bd101f57762f5e"
}
$defaultSHAs = @{
  "windows_1.2.0" = "7BD5088AD56FB03C1214E73EA076DE5AC08580CC419A8CBD46A524EE1CA250BF"
}

$key = "${InputOS}_${InputVersion}"
$url = if ($InputURL) { $InputURL } else { $defaultURLs[$key] }
$sha = if ($InputSHA) { $InputSHA } else { $defaultSHAs[$key] }

if (-not $url) {
  Write-Host "::error::未在内置表中找到 $InputOS / $InputVersion 的 SDK 下载地址;请用 url-override 覆盖,或在 install.ps1 的内置表中补充该组合"
  exit 1
}

New-Item -ItemType Directory -Force -Path "$env:RUNNER_TEMP\cangjie-sdk" | Out-Null
Write-Host "==> 下载仓颉 SDK: $url"
curl.exe -fL --retry 3 -o "$env:RUNNER_TEMP\cangjie-sdk.zip" $url

if ($sha) {
  Write-Host "==> 校验 SHA-256: $sha"
  $actual = (Get-FileHash "$env:RUNNER_TEMP\cangjie-sdk.zip" -Algorithm SHA256).Hash
  if ($actual -ne $sha) {
    Write-Host "::error::SDK SHA-256 校验失败: $actual (期望 $sha)"
    exit 1
  }
} else {
  Write-Host "::warning::平台 $InputOS 未配置 SHA-256,跳过校验"
}

Write-Host "==> 解压到: $env:RUNNER_TEMP\cangjie-sdk"
Expand-Archive -Path "$env:RUNNER_TEMP\cangjie-sdk.zip" -DestinationPath "$env:RUNNER_TEMP\cangjie-sdk" -Force

$envFile = Get-ChildItem "$env:RUNNER_TEMP\cangjie-sdk" -Recurse -Filter envsetup.ps1 | Select-Object -First 1
if (-not $envFile) {
  Write-Host "::error::解压后未找到 envsetup.ps1"
  exit 1
}
$CANGJIE_HOME = $envFile.DirectoryName

"CANGJIE_HOME=$CANGJIE_HOME"                                    | Out-File -FilePath $env:GITHUB_ENV  -Append
"$CANGJIE_HOME\bin"                                              | Out-File -FilePath $env:GITHUB_PATH -Append
"$CANGJIE_HOME\tools\bin"                                        | Out-File -FilePath $env:GITHUB_PATH -Append
# cjlint 依赖 libcjlint.dll(tools\lib)，cjpm/cjc 依赖 libcangjie-runtime.dll(runtime\lib)
"$CANGJIE_HOME\tools\lib"                                        | Out-File -FilePath $env:GITHUB_PATH -Append
"$CANGJIE_HOME\runtime\lib\windows_x86_64_cjnative"              | Out-File -FilePath $env:GITHUB_PATH -Append

# step output(供 composite 顶层 outputs 引用)
"cangjie-home=$CANGJIE_HOME" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
Write-Host "==> 已安装到: $CANGJIE_HOME"
