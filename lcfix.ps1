<#
  Normalizes line endings in place, without touching content or encoding.

  Default mode reproduces the committed per-line ending pattern: every line whose
  content is unchanged from the reference commit keeps exactly the ending that
  commit stored for it, and only genuinely edited or inserted lines take a new
  one. Files whose committed blob mixes CRLF and LF therefore stay mixed, so the
  diff shows the real change instead of the whole file.

  The reference is HEAD unless -Ref names another commit. Use the merge base to
  minimize a pull request diff rather than the working-tree diff:
    .\lcfix.ps1 -Ref (git merge-base HEAD origin/main) <path> [<path> ...]

  Files absent from the reference commit are left untouched. Pass -Style to
  convert unconditionally.

  Interactive (run once, keep pasting paths):
    .\lcfix.ps1
    > src\Skublox.Services\ISkubloxClientSettingsStore.cs
    > src\Skublox.Web\Startup.cs src\Skublox.Stripe\StripeGateway.cs
    > q

  One shot:
    .\lcfix.ps1 <path> [<path> ...]
    .\lcfix.ps1 -Style lf <path> [<path> ...]
    .\lcfix.ps1 -Ref <commit> <path> [<path> ...]
#>
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Paths,

    [ValidateSet('lf', 'crlf')]
    [string]$Style,

    [string]$Ref = 'HEAD'
)

$rootCache = @{}

$alignmentLimit = 400

function Get-LineEndingStyle {
    param([byte[]]$Bytes)

    $crlf = 0
    $lf = 0

    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 10) {
            if ($i -gt 0 -and $Bytes[$i - 1] -eq 13) { $crlf++ } else { $lf++ }
        }
    }

    if ($crlf -eq 0 -and $lf -eq 0) { return $null }
    if ($crlf -gt 0 -and $lf -gt 0) { return 'mixed' }
    if ($crlf -gt 0) { return 'crlf' }
    return 'lf'
}

function Test-BinaryBytes {
    param([byte[]]$Bytes)

    $limit = [Math]::Min($Bytes.Length, 8000)
    for ($i = 0; $i -lt $limit; $i++) {
        if ($Bytes[$i] -eq 0) { return $true }
    }

    return $false
}

function Get-RepositoryRoot {
    param([string]$Directory)

    if ($rootCache.ContainsKey($Directory)) {
        return $rootCache[$Directory]
    }

    $root = $null
    $current = $Directory
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            $root = $current
            break
        }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }

    $rootCache[$Directory] = $root
    return $root
}

function Get-RepositoryRelativePath {
    param(
        [string]$File,
        [string]$Root
    )

    if (-not $Root) { return $null }

    $full = [System.IO.Path]::GetFullPath($File)
    return ([System.IO.Path]::GetRelativePath($Root, $full)).Replace('\', '/')
}

function Get-GitBlobBytes {
    param(
        [string]$Root,
        [string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $Root
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { return $null }
        $output = New-Object System.IO.MemoryStream
        $process.StandardOutput.BaseStream.CopyTo($output)
        [void]$process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { return $null }
        return $output.ToArray()
    }
    catch {
        return $null
    }
    finally {
        $process.Dispose()
    }
}

function Get-CommittedBytes {
    param(
        [string]$File,
        [string]$Revision
    )

    $root = Get-RepositoryRoot -Directory ([System.IO.Path]::GetDirectoryName($File))
    if (-not $root) { return $null }

    $relative = Get-RepositoryRelativePath -File $File -Root $root
    if (-not $relative -or $relative.StartsWith('..')) { return $null }

    return Get-GitBlobBytes -Root $root -Arguments @('cat-file', 'blob', "${Revision}:$relative")
}

function Split-ContentLines {
    param([byte[]]$Bytes)

    $lines = New-Object System.Collections.Generic.List[object]
    $start = 0

    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -ne 13 -and $Bytes[$i] -ne 10) { continue }

        $eolStart = $i
        $ending = 'lf'
        if ($Bytes[$i] -eq 13) {
            if (($i + 1) -lt $Bytes.Length -and $Bytes[$i + 1] -eq 10) {
                $ending = 'crlf'
                $i++
            }
            else {
                $ending = 'cr'
            }
        }

        $lines.Add([pscustomobject]@{
                Content = [System.Text.Encoding]::Latin1.GetString($Bytes, $start, $eolStart - $start)
                Ending  = $ending
            })
        $start = $i + 1
    }

    if ($start -lt $Bytes.Length) {
        $lines.Add([pscustomobject]@{
                Content = [System.Text.Encoding]::Latin1.GetString($Bytes, $start, $Bytes.Length - $start)
                Ending  = ''
            })
    }

    return $lines
}

function Get-DominantEnding {
    param([object[]]$Lines)

    $crlf = 0
    $lf = 0
    foreach ($line in $Lines) {
        if ($line.Ending -eq 'crlf') { $crlf++ }
        elseif ($line.Ending -eq 'lf') { $lf++ }
    }

    if ($crlf -ge $lf -and $crlf -gt 0) { return 'crlf' }
    if ($lf -gt 0) { return 'lf' }
    return $null
}

function Get-LineAlignment {
    param(
        [object[]]$Current,
        [object[]]$Head
    )

    $map = New-Object 'System.Nullable[int][]' $Current.Count

    $prefix = 0
    while ($prefix -lt $Current.Count -and $prefix -lt $Head.Count -and
        $Current[$prefix].Content -eq $Head[$prefix].Content) {
        $map[$prefix] = $prefix
        $prefix++
    }

    $suffix = 0
    while ($suffix -lt ($Current.Count - $prefix) -and $suffix -lt ($Head.Count - $prefix) -and
        $Current[$Current.Count - 1 - $suffix].Content -eq $Head[$Head.Count - 1 - $suffix].Content) {
        $map[$Current.Count - 1 - $suffix] = $Head.Count - 1 - $suffix
        $suffix++
    }

    $currentMid = $Current.Count - $prefix - $suffix
    $headMid = $Head.Count - $prefix - $suffix

    if ($currentMid -le 0 -or $headMid -le 0) { return $map }
    if ($currentMid -gt $alignmentLimit -or $headMid -gt $alignmentLimit) { return $map }

    $dp = [int[, ]]::new(($currentMid + 1), ($headMid + 1))
    for ($a = $currentMid - 1; $a -ge 0; $a--) {
        for ($b = $headMid - 1; $b -ge 0; $b--) {
            if ($Current[$prefix + $a].Content -eq $Head[$prefix + $b].Content) {
                $dp[$a, $b] = $dp[($a + 1), ($b + 1)] + 1
            }
            elseif ($dp[($a + 1), $b] -ge $dp[$a, ($b + 1)]) {
                $dp[$a, $b] = $dp[($a + 1), $b]
            }
            else {
                $dp[$a, $b] = $dp[$a, ($b + 1)]
            }
        }
    }

    $a = 0
    $b = 0
    while ($a -lt $currentMid -and $b -lt $headMid) {
        if ($Current[$prefix + $a].Content -eq $Head[$prefix + $b].Content) {
            $map[$prefix + $a] = $prefix + $b
            $a++
            $b++
        }
        elseif ($dp[($a + 1), $b] -ge $dp[$a, ($b + 1)]) {
            $a++
        }
        else {
            $b++
        }
    }

    return $map
}

function Get-EndingBytes {
    param([string]$Ending)

    switch ($Ending) {
        'crlf' { return [byte[]](13, 10) }
        'cr' { return [byte[]](13) }
        default { return [byte[]](10) }
    }
}

function Convert-ToHeadPattern {
    param(
        [byte[]]$Bytes,
        [byte[]]$HeadBytes
    )

    $current = @(Split-ContentLines -Bytes $Bytes)
    $head = @(Split-ContentLines -Bytes $HeadBytes)

    if ($current.Count -eq 0) { return $Bytes }

    $dominant = Get-DominantEnding -Lines $head
    if (-not $dominant) { $dominant = Get-DominantEnding -Lines $current }
    if (-not $dominant) { $dominant = 'lf' }

    $map = Get-LineAlignment -Current $current -Head $head

    $output = New-Object System.IO.MemoryStream
    $carried = $dominant

    for ($i = 0; $i -lt $current.Count; $i++) {
        $content = [System.Text.Encoding]::Latin1.GetBytes($current[$i].Content)
        $output.Write($content, 0, $content.Length)

        if ($current[$i].Ending -eq '') { continue }

        $ending = $carried
        if ($null -ne $map[$i]) {
            $headEnding = $head[$map[$i]].Ending
            if ($headEnding -ne '') {
                $ending = $headEnding
                $carried = $headEnding
            }
        }

        $endingBytes = Get-EndingBytes -Ending $ending
        $output.Write($endingBytes, 0, $endingBytes.Length)
    }

    return $output.ToArray()
}

function Convert-LineEndings {
    param(
        [byte[]]$Bytes,
        [string]$TargetStyle
    )

    $newline = Get-EndingBytes -Ending $TargetStyle
    $output = New-Object System.IO.MemoryStream

    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if ($Bytes[$i] -eq 13 -or $Bytes[$i] -eq 10) {
            if ($Bytes[$i] -eq 13 -and ($i + 1) -lt $Bytes.Length -and $Bytes[$i + 1] -eq 10) {
                $i++
            }
            $output.Write($newline, 0, $newline.Length)
        }
        else {
            $output.WriteByte($Bytes[$i])
        }
    }

    return $output.ToArray()
}

function Test-ByteArrayEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($Left.Length -ne $Right.Length) { return $false }

    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }

    return $true
}

function Invoke-LcFix {
    param([string[]]$Targets)

    $changed = 0
    $skipped = 0
    $left = 0
    $binary = 0
    $missing = 0

    foreach ($target in $Targets) {
        if ([string]::IsNullOrWhiteSpace($target)) {
            continue
        }

        $clean = $target.Trim().Trim('"').Trim("'")
        $resolved = @(Resolve-Path -Path $clean -ErrorAction SilentlyContinue)

        if ($resolved.Count -eq 0) {
            Write-Host "not found : $clean" -ForegroundColor DarkYellow
            $missing++
            continue
        }

        foreach ($item in $resolved) {
            $file = $item.Path

            if (Test-Path -Path $file -PathType Container) {
                continue
            }

            $bytes = [System.IO.File]::ReadAllBytes($file)

            if (Test-BinaryBytes -Bytes $bytes) {
                Write-Host "binary : $file" -ForegroundColor DarkYellow
                $binary++
                continue
            }

            $mode = $null
            $normalized = $null

            if ($Style) {
                $mode = $Style
                $normalized = Convert-LineEndings -Bytes $bytes -TargetStyle $Style
            }
            else {
                $committedBytes = Get-CommittedBytes -File $file -Revision $Ref
                if ($committedBytes) {
                    $mode = $Ref
                    $normalized = Convert-ToHeadPattern -Bytes $bytes -HeadBytes $committedBytes
                }
                else {
                    Write-Host "not in $Ref (pass -Style to force) : $file" -ForegroundColor DarkGray
                    $left++
                    continue
                }
            }

            if (Test-ByteArrayEqual -Left $normalized -Right $bytes) {
                Write-Host "already matches $mode : $file" -ForegroundColor DarkGray
                $skipped++
                continue
            }

            [System.IO.File]::WriteAllBytes($file, $normalized)
            Write-Host "fixed ($mode): $file" -ForegroundColor Green
            $changed++
        }
    }

    Write-Host "$changed fixed, $skipped already correct, $left left alone, $binary binary, $missing not found" -ForegroundColor Cyan
}

function Split-PathArguments {
    param([string]$Line)

    $tokens = [regex]::Matches($Line, '"([^"]+)"|''([^'']+)''|(\S+)')
    return $tokens | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value }
        elseif ($_.Groups[2].Success) { $_.Groups[2].Value }
        else { $_.Groups[3].Value }
    }
}

if ($Paths -and $Paths.Count -gt 0) {
    Invoke-LcFix -Targets $Paths
    return
}

Write-Host "line encoding fixer ready. paste 2 same paths. blank line or 'q' to quit." -ForegroundColor Cyan

while ($true) {
    Write-Host "> " -NoNewline
    $line = [Console]::ReadLine()

    if ($null -eq $line) {
        break
    }

    $line = $line.Trim()

    if ($line -eq '' -or $line -eq 'q' -or $line -eq 'quit' -or $line -eq 'exit') {
        break
    }

    Invoke-LcFix -Targets (Split-PathArguments -Line $line)
}
