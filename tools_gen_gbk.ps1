# 生成 GBK(CP936) 映射表数据段（每行 25 条目，每条目 10 字符：GBK首2 GBK次2 '.' Unicode4 '.'）
#
# 输出可直接替换 src/meta/gbk_table.cj 中从 `private let GBK_TABLE_HEX_0`
# 到 `protected let GBK_TABLE_HEX` 的整段声明；粘贴后运行
# `cjfmt -d src/meta/` 统一换行与缩进。
# 每 50 行合成一个常量：单条 let 直接拼接近千行字面量会让 cjc 的递归过深，
# 在 macOS / 小栈环境下编译 audio4cj.meta 会崩溃（return code 4）。
$enc = [System.Text.Encoding]::GetEncoding(936)
$entries = New-Object System.Collections.Generic.List[object]
for ($lead = 0x81; $lead -le 0xFE; $lead++) {
    for ($trail = 0x40; $trail -le 0xFE; $trail++) {
        if ($trail -eq 0x7F) { continue }
        $b = [byte[]]@($lead, $trail)
        $chars = $enc.GetChars($b)
        if ($chars.Length -eq 1 -and $chars[0] -ne '?') {
            $rt = $enc.GetBytes($chars)
            if ($rt.Length -eq 2 -and $rt[0] -eq $lead -and $rt[1] -eq $trail) {
                $entries.Add([pscustomobject]@{ code = ($lead * 256 + $trail); uni = [int]$chars[0] })
            }
        }
    }
}
$sorted = $entries | Sort-Object code
$dataLines = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $sorted.Count; $i += 25) {
    $end = [Math]::Min($i + 25, $sorted.Count)
    # 每条目 10 字符：GBK 首字节 + GBK 次字节 + '.' + Unicode + '.'。
    # 条目内插 '.' 是为把连续十六进制串压到 4 字符以内，避开 cjlint 的
    # G.OTH.02「硬编码证件号」误报（解码侧按步长 10 取两段，见 gbk_table.cj）。
    $hexes = $sorted[$i..($end - 1)] | ForEach-Object { '{0:X2}{1:X2}.{2:X4}.' -f (($_.code -shr 8) -band 0xFF), ($_.code -band 0xFF), $_.uni }
    $line = ($hexes -join '')
    $dataLines.Add('"' + $line + '"')
}

$chunkSize = 50
$chunkCount = [int][Math]::Ceiling($dataLines.Count / [double]$chunkSize)
$out = New-Object System.Collections.Generic.List[string]
for ($c = 0; $c -lt $chunkCount; $c++) {
    $start = $c * $chunkSize
    $end = [Math]::Min($start + $chunkSize, $dataLines.Count)
    for ($j = $start; $j -lt $end; $j++) {
        $suffix = if ($j -lt $end - 1) { ' +' } else { '' }
        if ($j -eq $start) {
            $out.Add('private let GBK_TABLE_HEX_' + $c + ': String = ' + $dataLines[$j] + $suffix)
        } else {
            $out.Add('    ' + $dataLines[$j] + $suffix)
        }
    }
}
$out.Add('protected let GBK_TABLE_HEX: String =')
for ($c = 0; $c -lt $chunkCount; $c++) {
    $suffix = if ($c -lt $chunkCount - 1) { ' +' } else { '' }
    $out.Add('    GBK_TABLE_HEX_' + $c + $suffix)
}

$outPath = Join-Path $PSScriptRoot 'target/gbk_data.txt'
$outDir = Split-Path -Parent $outPath
if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}
[System.IO.File]::WriteAllText($outPath, (($out -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
"entries=$($sorted.Count) literals=$($dataLines.Count) chunks=$chunkCount out=$outPath"
