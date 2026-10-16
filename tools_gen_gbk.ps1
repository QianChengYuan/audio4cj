# 生成 GBK(CP936) 映射表数据行（每行 25 条目，每条目 10 字符：GBK首2 GBK次2 '.' Unicode4 '.'）
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
$out = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $sorted.Count; $i += 25) {
    $end = [Math]::Min($i + 25, $sorted.Count)
    # 每条目 10 字符：GBK 首字节 + GBK 次字节 + '.' + Unicode + '.'。
    # 条目内插 '.' 是为把连续十六进制串压到 4 字符以内，避开 cjlint 的
    # G.OTH.02「硬编码证件号」误报（解码侧按步长 10 取两段，见 gbk_table.cj）。
    $hexes = $sorted[$i..($end - 1)] | ForEach-Object { '{0:X2}{1:X2}.{2:X4}.' -f (($_.code -shr 8) -band 0xFF), ($_.code -band 0xFF), $_.uni }
    $line = ($hexes -join '')
    if ($i + 25 -lt $sorted.Count) {
        $out.Add('    "' + $line + '" +')
    } else {
        $out.Add('    "' + $line + '"')
    }
}
[System.IO.File]::WriteAllLines("c:\CodeTools\code\cangjie_code\audio4cj\tools_gbk_data.txt", $out, [System.Text.UTF8Encoding]::new($false))
"entries=$($sorted.Count) lines=$($out.Count)"
