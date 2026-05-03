param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TextureRoot,

    [string]$OutputRoot = "",
    [string]$NvttExportPath = "nvtt_export",
    [string]$TexdiagPath = "texdiag",
    [switch]$AuditOnly,
    [switch]$Overwrite,
    [switch]$NoSidecar,
    [string[]]$NvttExtraArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-Tool {
    param([string]$Path)

    $cmd = Get-Command $Path -ErrorAction Stop

    if ($null -ne $cmd.Source -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
        return $cmd.Source
    }

    return $cmd.Path
}

function Resolve-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-RelativePathSafe {
    param(
        [string]$BasePath,
        [string]$FilePath
    )

    $base = (Resolve-Path -LiteralPath $BasePath).Path
    $file = (Resolve-Path -LiteralPath $FilePath).Path

    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = [Uri]$base
    $fileUri = [Uri]$file

    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fileUri).ToString()).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
}

function Escape-Argument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '\\(?=")', '\\' -replace '"', '\"') + '"'
}

function Invoke-Native {
    param(
        [string]$Exe,
        [string[]]$NativeArgs
    )

    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()

    try {
        $argumentLine = (($NativeArgs | ForEach-Object { Escape-Argument $_ }) -join " ")

        $process = Start-Process `
            -FilePath $Exe `
            -ArgumentList $argumentLine `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr

        $output = @(
            Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
        ) -join "`n"

        return [PSCustomObject]@{
            ExitCode = [int]$process.ExitCode
            Output = $output.Trim()
        }
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Match-Value {
    param(
        [string]$Text,
        [string]$Name
    )

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*(.+?)\s*$") {
            return $Matches[1].Trim()
        }
    }

    return ""
}

function Get-TexdiagInfo {
    param(
        [string]$TexdiagExe,
        [string]$FilePath
    )

    $result = Invoke-Native -Exe $TexdiagExe -NativeArgs @("info", $FilePath)

    if ($result.ExitCode -ne 0) {
        throw "texdiag failed for '$FilePath':`n$($result.Output)"
    }

    $text = $result.Output

    return [PSCustomObject]@{
        Width = Match-Value $text "width"
        Height = Match-Value $text "height"
        Depth = Match-Value $text "depth"
        MipLevels = Match-Value $text "mipLevels"
        ArraySize = Match-Value $text "arraySize"
        Format = Match-Value $text "format"
        Dimension = Match-Value $text "dimension"
        AlphaMode = Match-Value $text "alpha mode"
        Images = Match-Value $text "images"
        PixelSizeKB = (Match-Value $text "pixel size") -replace "\s*\(KB\)\s*$", ""
        Raw = $text
    }
}

function Get-NvttFormat {
    param([string]$Format)

    switch ($Format) {
        "BC1_UNORM" { return "bc1" }
        "BC2_UNORM" { return "bc2" }
        "BC3_UNORM" { return "bc3" }
        default { return "" }
    }
}

function Get-OutputPath {
    param(
        [string]$OutputRoot,
        [string]$RelativePath
    )

    $dir = [System.IO.Path]::GetDirectoryName($RelativePath)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($RelativePath)

    if ([string]::IsNullOrWhiteSpace($dir)) {
        return Join-Path $OutputRoot ($name + ".ktx2")
    }

    return Join-Path $OutputRoot (Join-Path $dir ($name + ".ktx2"))
}

function Convert-DdsToKtx2 {
    param(
        [string]$NvttExe,
        [string]$InputPath,
        [string]$OutputPath,
        [string]$NvttFormat,
        [string[]]$ExtraArgs
    )

    $outDir = Split-Path -Parent $OutputPath

    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $nativeArgs = @($InputPath, "--format", $NvttFormat, "--export-transfer-function", "linear") + $ExtraArgs + @("--output", $OutputPath)

    return Invoke-Native -Exe $NvttExe -NativeArgs $nativeArgs
}

function Write-Sidecar {
    param(
        [object]$Row,
        [object]$Info,
        [string]$Path
    )

    $meta = [ordered]@{
        source = $Row.FullPath
        relativePath = $Row.RelativePath
        output = $Row.OutputKtx2
        convertedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        dds = [ordered]@{
            width = $Info.Width
            height = $Info.Height
            depth = $Info.Depth
            mipLevels = $Info.MipLevels
            arraySize = $Info.ArraySize
            format = $Info.Format
            dimension = $Info.Dimension
            alphaMode = $Info.AlphaMode
            images = $Info.Images
            pixelSizeKB = $Info.PixelSizeKB
            texdiagRaw = $Info.Raw
        }
    }

    $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Ktx2Info {
    param([string]$FilePath)

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)

    if ($bytes.Length -lt 68) {
        throw "KTX2 output too small: '$FilePath'"
    }

    $expectedMagic = [byte[]](0xAB,0x4B,0x54,0x58,0x20,0x32,0x30,0xBB,0x0D,0x0A,0x1A,0x0A)

    for ($i = 0; $i -lt $expectedMagic.Length; $i++) {
        if ($bytes[$i] -ne $expectedMagic[$i]) {
            throw "Output is not a valid KTX2 file: '$FilePath'"
        }
    }

    $dfdOffset = [int][BitConverter]::ToUInt32($bytes, 48)
    $dfdLength = [int][BitConverter]::ToUInt32($bytes, 52)

    if ($dfdOffset -le 0 -or $dfdLength -lt 16 -or ($dfdOffset + $dfdLength) -gt $bytes.Length) {
        throw "Invalid KTX2 DFD range: '$FilePath'"
    }

    return [PSCustomObject]@{
        VkFormat = [BitConverter]::ToUInt32($bytes, 12)
        TypeSize = [BitConverter]::ToUInt32($bytes, 16)
        Width = [BitConverter]::ToUInt32($bytes, 20)
        Height = [BitConverter]::ToUInt32($bytes, 24)
        Depth = [BitConverter]::ToUInt32($bytes, 28)
        LayerCount = [BitConverter]::ToUInt32($bytes, 32)
        FaceCount = [BitConverter]::ToUInt32($bytes, 36)
        LevelCount = [BitConverter]::ToUInt32($bytes, 40)
        SupercompressionScheme = [BitConverter]::ToUInt32($bytes, 44)
        DfdTransfer = $bytes[$dfdOffset + 14]
    }
}

function Get-ExpectedKtx2VkFormats {
    param([string]$DdsFormat)

    switch ($DdsFormat) {
        "BC1_UNORM" { return @(131, 133) }
        "BC2_UNORM" { return @(135) }
        "BC3_UNORM" { return @(137) }
        default { return @() }
    }
}

function Assert-Ktx2Output {
    param(
        [object]$Row,
        [object]$Ktx2
    )

    $expectedVkFormats = @(Get-ExpectedKtx2VkFormats $Row.Format)
    $expectedFaceCount = if ($Row.Dimension -eq "Cube") { 6 } else { 1 }

    if ($expectedVkFormats.Count -eq 0 -or $Ktx2.VkFormat -notin $expectedVkFormats) {
        throw "KTX2 format mismatch for '$($Row.OutputKtx2)': expected VkFormat=$($expectedVkFormats -join ',') from $($Row.Format), got $($Ktx2.VkFormat)"
    }

    if ($Ktx2.DfdTransfer -eq 2) {
        throw "KTX2 DFD transfer is sRGB for '$($Row.OutputKtx2)'"
    }
 	
 	if ($Ktx2.LayerCount -ne 0) {
        throw "KTX2 layer count mismatch for '$($Row.OutputKtx2)': expected 0 for non-array texture, got $($Ktx2.LayerCount)"
    }

    if ($Ktx2.Width -ne [uint32]$Row.Width -or $Ktx2.Height -ne [uint32]$Row.Height) {
        throw "KTX2 size mismatch for '$($Row.OutputKtx2)': expected $($Row.Width)x$($Row.Height), got $($Ktx2.Width)x$($Ktx2.Height)"
    }

    if ($Ktx2.FaceCount -ne $expectedFaceCount) {
        throw "KTX2 face count mismatch for '$($Row.OutputKtx2)': expected $expectedFaceCount, got $($Ktx2.FaceCount)"
    }

    if ($Ktx2.LevelCount -ne [uint32]$Row.MipLevels) {
        throw "KTX2 mip level mismatch for '$($Row.OutputKtx2)': expected $($Row.MipLevels), got $($Ktx2.LevelCount)"
    }
	
	if ($Ktx2.Depth -ne 0) {
        throw "KTX2 depth mismatch for '$($Row.OutputKtx2)': expected 0 for 2D/cubemap KTX2 texture, got $($Ktx2.Depth)"
    }

    if ($Ktx2.TypeSize -ne 1) {
        throw "KTX2 typeSize mismatch for '$($Row.OutputKtx2)': expected 1 for BC block-compressed format, got $($Ktx2.TypeSize)"
    }
}

if (-not (Test-Path -LiteralPath $TextureRoot)) {
    throw "TextureRoot does not exist: '$TextureRoot'"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = $TextureRoot
}

$texdiagExe = Resolve-Tool $TexdiagPath
$nvttExe = $null

if (-not $AuditOnly) {
    $nvttExe = Resolve-Tool $NvttExportPath
}

$textureRootFull = (Resolve-Path -LiteralPath $TextureRoot).Path
$outputRootFull = Resolve-Directory $OutputRoot

$ddsFiles = @(Get-ChildItem -LiteralPath $textureRootFull -Recurse -File -Filter "*.dds" | Sort-Object FullName)

if ($ddsFiles.Count -eq 0) {
    throw "No .dds files found under '$textureRootFull'"
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportDir = Join-Path $outputRootFull "_ktx2_reports"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

$summaryPath = Join-Path $reportDir "dds_summary_$timestamp.txt"

$rows = New-Object System.Collections.Generic.List[object]
$infoByPath = @{}

foreach ($file in $ddsFiles) {
    $info = Get-TexdiagInfo -TexdiagExe $texdiagExe -FilePath $file.FullName
    $relative = Get-RelativePathSafe -BasePath $textureRootFull -FilePath $file.FullName
    $outputKtx2 = Get-OutputPath -OutputRoot $outputRootFull -RelativePath $relative

    $row = [PSCustomObject]@{
        RelativePath = $relative
        FullPath = $file.FullName
        SourceBytes = $file.Length
        Width = $info.Width
        Height = $info.Height
        Depth = $info.Depth
        MipLevels = $info.MipLevels
        ArraySize = $info.ArraySize
        Format = $info.Format
        Dimension = $info.Dimension
        AlphaMode = $info.AlphaMode
        Images = $info.Images
        PixelSizeKB = $info.PixelSizeKB
        Converted = $false
        ConvertStatus = ""
        OutputKtx2 = $outputKtx2
        OutputBytes = ""
        SidecarJson = ""
        ToolOutput = ""
    }

    $rows.Add($row)
    $infoByPath[$file.FullName] = $info
}

if ($AuditOnly) {
    foreach ($row in $rows) {
        $row.ConvertStatus = "AUDIT_ONLY"
    }
} else {
    foreach ($row in $rows) {
        $nvttFormat = Get-NvttFormat $row.Format

        if ([string]::IsNullOrWhiteSpace($nvttFormat)) {
            $row.ConvertStatus = "SKIPPED_UNSUPPORTED_FORMAT"
            continue
        }

        if ($row.Depth -ne "1") {
            $row.ConvertStatus = "SKIPPED_UNSUPPORTED_DEPTH"
            continue
        }

        $is2D = $row.Dimension -eq "2D" -and $row.ArraySize -eq "1"

        if (-not $is2D) {
            $row.ConvertStatus = "SKIPPED_UNSUPPORTED_DIMENSION"
            continue
        }

        if ((Test-Path -LiteralPath $row.OutputKtx2) -and -not $Overwrite) {
            $row.ConvertStatus = "SKIPPED_EXISTS"
            $row.OutputBytes = (Get-Item -LiteralPath $row.OutputKtx2).Length
            continue
        }

        $result = Convert-DdsToKtx2 -NvttExe $nvttExe -InputPath $row.FullPath -OutputPath $row.OutputKtx2 -NvttFormat $nvttFormat -ExtraArgs $NvttExtraArgs
        $row.ToolOutput = $result.Output

        if ($result.ExitCode -ne 0) {
            $row.ConvertStatus = "FAILED_EXIT_$($result.ExitCode)"
            continue
        }

        if (-not (Test-Path -LiteralPath $row.OutputKtx2)) {
            $row.ConvertStatus = "FAILED_OUTPUT_MISSING"
            continue
        }
		
		try {
            $ktx2Info = Get-Ktx2Info -FilePath $row.OutputKtx2
            Assert-Ktx2Output -Row $row -Ktx2 $ktx2Info
            $row.ToolOutput = (($row.ToolOutput, "KTX2 validated: VkFormat=$($ktx2Info.VkFormat), Size=$($ktx2Info.Width)x$($ktx2Info.Height), Faces=$($ktx2Info.FaceCount), Levels=$($ktx2Info.LevelCount)") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
        } catch {
            $row.ConvertStatus = "FAILED_KTX2_VALIDATION"
            $row.ToolOutput = (($row.ToolOutput, $_.Exception.Message) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
            continue
        }

        $row.Converted = $true
        $row.ConvertStatus = "OK"
        $row.OutputBytes = (Get-Item -LiteralPath $row.OutputKtx2).Length

        if (-not $NoSidecar) {
            $sidecar = $row.OutputKtx2 + ".ddsmeta.json"
            Write-Sidecar -Row $row -Info $infoByPath[$row.FullPath] -Path $sidecar
            $row.SidecarJson = $sidecar
        }
    }
}

$convertedCount = @($rows | Where-Object { $_.Converted }).Count
$failedCount = @($rows | Where-Object { $_.ConvertStatus -like "FAILED_*" }).Count
$skippedCount = @($rows | Where-Object { $_.ConvertStatus -like "SKIPPED_*" }).Count

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add("TextureRoot: $textureRootFull")
$summaryLines.Add("OutputRoot: $outputRootFull")
$summaryLines.Add("AuditOnly: $AuditOnly")
$summaryLines.Add("Overwrite: $Overwrite")
$summaryLines.Add("TotalDDS: $($rows.Count)")
$summaryLines.Add("Converted: $convertedCount")
$summaryLines.Add("Failed: $failedCount")
$summaryLines.Add("Skipped: $skippedCount")
$summaryLines.Add("")
$summaryLines.Add("FormatCounts:")

foreach ($g in @($rows | Group-Object Format | Sort-Object Name)) {
    $summaryLines.Add("  $($g.Name): $($g.Count)")
}

$summaryLines.Add("")
$summaryLines.Add("StatusCounts:")

foreach ($g in @($rows | Group-Object ConvertStatus | Sort-Object Name)) {
    $summaryLines.Add("  $($g.Name): $($g.Count)")
}

$summaryLines.Add("")
$summaryLines.Add("Files:")

foreach ($row in @($rows | Sort-Object RelativePath)) {
    $summaryLines.Add("[$($row.ConvertStatus)] $($row.RelativePath)")
    $summaryLines.Add("  Source: $($row.FullPath)")
    $summaryLines.Add("  Output: $($row.OutputKtx2)")
    $summaryLines.Add("  Format: $($row.Format)")
    $summaryLines.Add("  Size: $($row.Width)x$($row.Height)")
    $summaryLines.Add("  Depth: $($row.Depth)")
    $summaryLines.Add("  MipLevels: $($row.MipLevels)")
    $summaryLines.Add("  ArraySize: $($row.ArraySize)")
    $summaryLines.Add("  Dimension: $($row.Dimension)")
    $summaryLines.Add("  AlphaMode: $($row.AlphaMode)")
    $summaryLines.Add("  Images: $($row.Images)")
    $summaryLines.Add("  PixelSizeKB: $($row.PixelSizeKB)")

    if (-not [string]::IsNullOrWhiteSpace($row.SidecarJson)) {
        $summaryLines.Add("  SidecarJson: $($row.SidecarJson)")
    }

    if (($row.ConvertStatus -like "FAILED_*") -and -not [string]::IsNullOrWhiteSpace($row.ToolOutput)) {
        $summaryLines.Add("  ToolOutput: $($row.ToolOutput)")
    }

    $summaryLines.Add("")
}

$summaryLines | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "Summary: $summaryPath"
Write-Host "TotalDDS=$($rows.Count) Converted=$convertedCount Failed=$failedCount Skipped=$skippedCount"
