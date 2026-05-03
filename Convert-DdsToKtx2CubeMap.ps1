param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TextureRoot,

    [string]$OutputRoot = "",
    [switch]$AuditOnly,
    [switch]$Overwrite,
    [switch]$NoSidecar,

    [ValidateSet("Auto", "Rgb", "Rgba")]
    [string]$Bc1Mode = "Auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Ktx2HeaderSize = 80
$Ktx2LevelIndexEntrySize = 24

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

    return [Uri]::UnescapeDataString(([Uri]$base).MakeRelativeUri([Uri]$file).ToString()).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
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

function Read-UInt16LE {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-UInt32LE {
    param([byte[]]$Bytes, [int]$Offset)
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Read-FourCC {
    param([byte[]]$Bytes, [int]$Offset)
    return [Text.Encoding]::ASCII.GetString($Bytes, $Offset, 4)
}

function Copy-ByteRange {
    param([byte[]]$Bytes, [int]$Offset, [int]$Length)

    $result = New-Object byte[] $Length
    [Buffer]::BlockCopy($Bytes, $Offset, $result, 0, $Length)
    return $result
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

function Get-LevelByteCount {
    param(
        [int]$Width,
        [int]$Height,
        [int]$BlockBytes
    )

    $blocksX = [Math]::Max(1, [int][Math]::Ceiling($Width / 4.0))
    $blocksY = [Math]::Max(1, [int][Math]::Ceiling($Height / 4.0))

    return $blocksX * $blocksY * $BlockBytes
}

function Test-Dxt1HasAlpha {
    param(
        [byte[]]$Bytes,
        [int]$DataOffset,
        [int]$Width,
        [int]$Height,
        [int]$MipCount,
        [int]$FaceCount,
        [string]$Path
    )

    $offset = $DataOffset

    for ($face = 0; $face -lt $FaceCount; $face++) {
        for ($level = 0; $level -lt $MipCount; $level++) {
            $levelWidth = [Math]::Max(1, [int]($Width -shr $level))
            $levelHeight = [Math]::Max(1, [int]($Height -shr $level))
            $levelBytes = Get-LevelByteCount -Width $levelWidth -Height $levelHeight -BlockBytes 8

            if (($offset + $levelBytes) -gt $Bytes.Length) {
                throw "DDS data truncated in '$Path' at face=$face level=$level"
            }

            for ($blockOffset = $offset; $blockOffset -lt ($offset + $levelBytes); $blockOffset += 8) {
                $c0 = Read-UInt16LE $Bytes $blockOffset
                $c1 = Read-UInt16LE $Bytes ($blockOffset + 2)

                if ($c0 -le $c1) {
                    return $true
                }
            }

            $offset += $levelBytes
        }
    }

    return $false
}

function Get-DdsFormatInfo {
    param(
        [string]$FourCC,
        [bool]$HasDx10,
        [uint32]$DxgiFormat,
        [string]$EffectiveBc1Mode
    )

    if ($FourCC -eq "DXT1" -or ($HasDx10 -and $DxgiFormat -eq 71)) {
        $rgba = $EffectiveBc1Mode -eq "Rgba"
        $vkFormat = if ($rgba) { [uint32]133 } else { [uint32]131 }
        $firstChannel = if ($rgba) { 15 } else { 0 }

        return [PSCustomObject]@{
            Format = "BC1_UNORM"
            VkFormat = $vkFormat
            BlockBytes = 8
            DfdModel = 128
            DfdSamples = 1
            DfdFirstChannel = $firstChannel
            DfdSecondChannel = -1
            DfdSecondOffset = 0
            DfdChannelBits = 64
            Bc1Mode = $EffectiveBc1Mode
        }
    }

    if ($FourCC -eq "DXT3" -or ($HasDx10 -and $DxgiFormat -eq 74)) {
        return [PSCustomObject]@{
            Format = "BC2_UNORM"
            VkFormat = [uint32]135
            BlockBytes = 16
            DfdModel = 129
            DfdSamples = 2
            DfdFirstChannel = 15
            DfdSecondChannel = 0
            DfdSecondOffset = 64
            DfdChannelBits = 64
            Bc1Mode = ""
        }
    }

    if ($FourCC -eq "DXT5" -or ($HasDx10 -and $DxgiFormat -eq 77)) {
        return [PSCustomObject]@{
            Format = "BC3_UNORM"
            VkFormat = [uint32]137
            BlockBytes = 16
            DfdModel = 130
            DfdSamples = 2
            DfdFirstChannel = 15
            DfdSecondChannel = 0
            DfdSecondOffset = 64
            DfdChannelBits = 64
            Bc1Mode = ""
        }
    }

    return $null
}

function Read-DdsCube {
    param(
        [string]$Path,
        [string]$Bc1Mode
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -lt 128) {
        throw "DDS too small"
    }

    if ((Read-FourCC $bytes 0) -ne "DDS ") {
        throw "Invalid DDS magic"
    }

    if ((Read-UInt32LE $bytes 4) -ne 124) {
        throw "Invalid DDS header size"
    }

    $height = [int](Read-UInt32LE $bytes 12)
    $width = [int](Read-UInt32LE $bytes 16)
    $depthRaw = [int](Read-UInt32LE $bytes 24)
    $mipRaw = [int](Read-UInt32LE $bytes 28)
    $pfFlags = Read-UInt32LE $bytes 80
    $fourCC = Read-FourCC $bytes 84
    $caps2 = Read-UInt32LE $bytes 112

    $depth = if ($depthRaw -gt 0) { $depthRaw } else { 1 }
    $mipCount = if ($mipRaw -gt 0) { $mipRaw } else { 1 }

    $dataOffset = 128
    $hasDx10 = $false
    $dxgiFormat = [uint32]0
    $resourceDimension = [uint32]0
    $miscFlag = [uint32]0
    $arraySize = 1

    if (($pfFlags -band 0x4) -ne 0 -and $fourCC -eq "DX10") {
        if ($bytes.Length -lt 148) {
            throw "DDS DX10 header missing"
        }

        $hasDx10 = $true
        $dxgiFormat = Read-UInt32LE $bytes 128
        $resourceDimension = Read-UInt32LE $bytes 132
        $miscFlag = Read-UInt32LE $bytes 136
        $arraySize = [int](Read-UInt32LE $bytes 140)
        $dataOffset = 148
    }

    $isLegacyCube = (($caps2 -band 0x200) -ne 0) -and (($caps2 -band 0xFC00) -eq 0xFC00)
    $isDx10Cube = $hasDx10 -and (($miscFlag -band 0x4) -ne 0)

    if (-not ($isLegacyCube -or $isDx10Cube)) {
        return [PSCustomObject]@{
            UnsupportedStatus = "SKIPPED_NOT_CUBEMAP"
        }
    }

    if ($depth -ne 1) {
        return [PSCustomObject]@{
            UnsupportedStatus = "SKIPPED_UNSUPPORTED_DEPTH"
        }
    }

    if ($hasDx10 -and $resourceDimension -ne 3) {
        return [PSCustomObject]@{
            UnsupportedStatus = "SKIPPED_UNSUPPORTED_DIMENSION"
        }
    }

    if ($hasDx10 -and $arraySize -ne 1) {
        return [PSCustomObject]@{
            UnsupportedStatus = "SKIPPED_UNSUPPORTED_ARRAY"
        }
    }

    $isBc1 = $fourCC -eq "DXT1" -or ($hasDx10 -and $dxgiFormat -eq 71)
    $effectiveBc1Mode = $Bc1Mode

    if ($isBc1 -and $Bc1Mode -eq "Auto") {
        $effectiveBc1Mode = if (Test-Dxt1HasAlpha -Bytes $bytes -DataOffset $dataOffset -Width $width -Height $height -MipCount $mipCount -FaceCount 6 -Path $Path) { "Rgba" } else { "Rgb" }
    }

    if ($effectiveBc1Mode -eq "Auto") {
        $effectiveBc1Mode = "Rgb"
    }

    $formatInfo = Get-DdsFormatInfo -FourCC $fourCC -HasDx10 $hasDx10 -DxgiFormat $dxgiFormat -EffectiveBc1Mode $effectiveBc1Mode

    if ($null -eq $formatInfo) {
        $status = if ($hasDx10) { "SKIPPED_UNSUPPORTED_FORMAT_DXGI_$dxgiFormat" } else { "SKIPPED_UNSUPPORTED_FORMAT_$fourCC" }

        return [PSCustomObject]@{
            UnsupportedStatus = $status
        }
    }

    $levelStreams = @()

    for ($i = 0; $i -lt $mipCount; $i++) {
        $levelStreams += (New-Object System.IO.MemoryStream)
    }

    $offset = $dataOffset
    $expectedPayloadBytes = 0

    for ($face = 0; $face -lt 6; $face++) {
        for ($level = 0; $level -lt $mipCount; $level++) {
            $levelWidth = [Math]::Max(1, [int]($width -shr $level))
            $levelHeight = [Math]::Max(1, [int]($height -shr $level))
            $levelBytes = Get-LevelByteCount -Width $levelWidth -Height $levelHeight -BlockBytes $formatInfo.BlockBytes

            if (($offset + $levelBytes) -gt $bytes.Length) {
                throw "DDS data truncated at face=$face level=$level"
            }

            ($levelStreams[$level]).Write($bytes, $offset, $levelBytes)
            $offset += $levelBytes
            $expectedPayloadBytes += $levelBytes
        }
    }

    $levelData = @()

    for ($i = 0; $i -lt $mipCount; $i++) {
        $levelData += ,($levelStreams[$i]).ToArray()
        ($levelStreams[$i]).Dispose()
    }

    $payloadStream = New-Object System.IO.MemoryStream

    try {
        foreach ($levelBytes in $levelData) {
            $payloadStream.Write($levelBytes, 0, $levelBytes.Length)
        }

        $payloadSha256 = Get-Sha256Hex $payloadStream.ToArray()
    } finally {
        $payloadStream.Dispose()
    }

    return [PSCustomObject]@{
        UnsupportedStatus = ""
        Width = $width
        Height = $height
        Depth = 1
        MipLevels = $mipCount
        ArraySize = 6
        Format = $formatInfo.Format
        VkFormat = $formatInfo.VkFormat
        Dimension = "Cube"
        Images = 6 * $mipCount
        FaceCount = 6
        LayerCount = 0
        BlockBytes = $formatInfo.BlockBytes
        FormatInfo = $formatInfo
        LevelData = $levelData
        PayloadSha256 = $payloadSha256
        ExpectedPayloadBytes = $expectedPayloadBytes
        SourceBytes = $bytes.Length
        DataOffset = $dataOffset
        FourCC = $fourCC
        DxgiFormat = if ($hasDx10) { $dxgiFormat } else { "" }
        EffectiveBc1Mode = $formatInfo.Bc1Mode
    }
}

function Write-UInt32 {
    param([System.IO.BinaryWriter]$Writer, [uint32]$Value)
    $Writer.Write($Value)
}

function Write-UInt64 {
    param([System.IO.BinaryWriter]$Writer, [uint64]$Value)
    $Writer.Write($Value)
}

function New-Ktx2Dfd {
    param([object]$FormatInfo)

    $sampleCount = [int]$FormatInfo.DfdSamples
    $wordCount = 1 + 6 + ($sampleCount * 4)
    $blockSize = 4 * (6 + ($sampleCount * 4))
    $words = New-Object uint32[] $wordCount

    $words[0] = [uint32](4 * $wordCount)
    $words[1] = [uint32]0
    $words[2] = [uint32](2 -bor ($blockSize -shl 16))
    $words[3] = [uint32]($FormatInfo.DfdModel -bor (1 -shl 8) -bor (1 -shl 16))
    $words[4] = [uint32](3 -bor (3 -shl 8))
    $words[5] = [uint32]$FormatInfo.BlockBytes
    $words[6] = [uint32]0

    $sampleStart = 7
    $bitLength = [uint32]($FormatInfo.DfdChannelBits - 1)

    $words[$sampleStart] = [uint32]((0) -bor ($bitLength -shl 16) -bor ([uint32]$FormatInfo.DfdFirstChannel -shl 24))
    $words[$sampleStart + 1] = [uint32]0
    $words[$sampleStart + 2] = [uint32]0
    $words[$sampleStart + 3] = [uint32]::MaxValue

    if ($sampleCount -eq 2) {
        $secondStart = $sampleStart + 4
        $words[$secondStart] = [uint32](([uint32]$FormatInfo.DfdSecondOffset) -bor ($bitLength -shl 16) -bor ([uint32]$FormatInfo.DfdSecondChannel -shl 24))
        $words[$secondStart + 1] = [uint32]0
        $words[$secondStart + 2] = [uint32]0
        $words[$secondStart + 3] = [uint32]::MaxValue
    }

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $stream

    try {
        foreach ($word in $words) {
            $writer.Write([uint32]$word)
        }

        return ,$stream.ToArray()
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Get-AlignmentPadding {
    param([uint64]$Offset, [uint32]$Alignment)

    $mod = $Offset % $Alignment

    if ($mod -eq 0) {
        return 0
    }

    return [int]($Alignment - $mod)
}

function Write-Ktx2Cube {
    param(
        [object]$Dds,
        [string]$OutputPath
    )

    $outDir = Split-Path -Parent $OutputPath

    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $dfd = New-Ktx2Dfd -FormatInfo $Dds.FormatInfo
    $levelCount = [int]$Dds.MipLevels
    $levelOffsets = New-Object uint64[] $levelCount
    $levelLengths = New-Object uint64[] $levelCount

    $dfdOffset = [uint32]($Ktx2HeaderSize + ($levelCount * $Ktx2LevelIndexEntrySize))
    $dfdLength = [uint32]$dfd.Length
    $currentOffset = [uint64]($dfdOffset + $dfdLength)
    $alignment = [uint32][Math]::Max(4, $Dds.BlockBytes)

    for ($level = $levelCount - 1; $level -ge 0; $level--) {
        $currentOffset += [uint64](Get-AlignmentPadding -Offset $currentOffset -Alignment $alignment)
        $levelOffsets[$level] = $currentOffset
        $levelLengths[$level] = [uint64]($Dds.LevelData[$level].Length)
        $currentOffset += $levelLengths[$level]
    }

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter $stream

    try {
        $writer.Write([byte[]](0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A))
        Write-UInt32 $writer ([uint32]$Dds.VkFormat)
        Write-UInt32 $writer ([uint32]1)
        Write-UInt32 $writer ([uint32]$Dds.Width)
        Write-UInt32 $writer ([uint32]$Dds.Height)
        Write-UInt32 $writer ([uint32]0)
        Write-UInt32 $writer ([uint32]0)
        Write-UInt32 $writer ([uint32]6)
        Write-UInt32 $writer ([uint32]$levelCount)
        Write-UInt32 $writer ([uint32]0)
        Write-UInt32 $writer $dfdOffset
        Write-UInt32 $writer $dfdLength
        Write-UInt32 $writer ([uint32]0)
        Write-UInt32 $writer ([uint32]0)
        Write-UInt64 $writer ([uint64]0)
        Write-UInt64 $writer ([uint64]0)

        for ($level = 0; $level -lt $levelCount; $level++) {
            Write-UInt64 $writer ([uint64]$levelOffsets[$level])
            Write-UInt64 $writer ([uint64]$levelLengths[$level])
            Write-UInt64 $writer ([uint64]$levelLengths[$level])
        }

        $writer.Write($dfd)

        for ($level = $levelCount - 1; $level -ge 0; $level--) {
            $pad = [int]($levelOffsets[$level] - [uint64]$stream.Position)

            if ($pad -gt 0) {
                $writer.Write((New-Object byte[] $pad))
            }

            $writer.Write([byte[]]$Dds.LevelData[$level])
        }

        [System.IO.File]::WriteAllBytes($OutputPath, $stream.ToArray())
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Get-Ktx2Info {
    param([string]$FilePath)

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)

    if ($bytes.Length -lt $Ktx2HeaderSize) {
        throw "KTX2 output too small"
    }

    $expectedMagic = [byte[]](0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A)

    for ($i = 0; $i -lt $expectedMagic.Length; $i++) {
        if ($bytes[$i] -ne $expectedMagic[$i]) {
            throw "Output is not KTX2"
        }
    }

    $levelCount = [int](Read-UInt32LE $bytes 40)
    $dfdOffset = [int](Read-UInt32LE $bytes 48)
    $dfdLength = [int](Read-UInt32LE $bytes 52)

    if ($dfdOffset -le 0 -or $dfdLength -le 0 -or ($dfdOffset + $dfdLength) -gt $bytes.Length) {
        throw "Invalid KTX2 DFD range"
    }

    $levels = @()

    for ($i = 0; $i -lt $levelCount; $i++) {
        $entryOffset = $Ktx2HeaderSize + ($i * $Ktx2LevelIndexEntrySize)

        $levels += [PSCustomObject]@{
            ByteOffset = [BitConverter]::ToUInt64($bytes, $entryOffset)
            ByteLength = [BitConverter]::ToUInt64($bytes, $entryOffset + 8)
            UncompressedByteLength = [BitConverter]::ToUInt64($bytes, $entryOffset + 16)
        }
    }

    return [PSCustomObject]@{
        Bytes = $bytes
        VkFormat = Read-UInt32LE $bytes 12
        TypeSize = Read-UInt32LE $bytes 16
        Width = Read-UInt32LE $bytes 20
        Height = Read-UInt32LE $bytes 24
        Depth = Read-UInt32LE $bytes 28
        LayerCount = Read-UInt32LE $bytes 32
        FaceCount = Read-UInt32LE $bytes 36
        LevelCount = Read-UInt32LE $bytes 40
        SupercompressionScheme = Read-UInt32LE $bytes 44
        DfdOffset = $dfdOffset
        DfdLength = $dfdLength
        DfdModel = $bytes[$dfdOffset + 12]
        DfdPrimaries = $bytes[$dfdOffset + 13]
        DfdTransfer = $bytes[$dfdOffset + 14]
        DfdFlags = $bytes[$dfdOffset + 15]
        Levels = $levels
    }
}

function Assert-Ktx2Cube {
    param(
        [object]$Dds,
        [object]$Ktx2,
        [string]$OutputPath
    )

    if ($Ktx2.VkFormat -ne $Dds.VkFormat) {
        throw "KTX2 format mismatch: expected $($Dds.VkFormat), got $($Ktx2.VkFormat)"
    }

    if ($Ktx2.TypeSize -ne 1) {
        throw "KTX2 typeSize mismatch: expected 1, got $($Ktx2.TypeSize)"
    }

    if ($Ktx2.Width -ne [uint32]$Dds.Width -or $Ktx2.Height -ne [uint32]$Dds.Height) {
        throw "KTX2 size mismatch: expected $($Dds.Width)x$($Dds.Height), got $($Ktx2.Width)x$($Ktx2.Height)"
    }

    if ($Ktx2.Depth -ne 0) {
        throw "KTX2 depth mismatch: expected 0, got $($Ktx2.Depth)"
    }

    if ($Ktx2.LayerCount -ne 0) {
        throw "KTX2 layer count mismatch: expected 0, got $($Ktx2.LayerCount)"
    }

    if ($Ktx2.FaceCount -ne 6) {
        throw "KTX2 face count mismatch: expected 6, got $($Ktx2.FaceCount)"
    }

    if ($Ktx2.LevelCount -ne [uint32]$Dds.MipLevels) {
        throw "KTX2 mip count mismatch: expected $($Dds.MipLevels), got $($Ktx2.LevelCount)"
    }

    if ($Ktx2.SupercompressionScheme -ne 0) {
        throw "KTX2 supercompression mismatch: expected 0, got $($Ktx2.SupercompressionScheme)"
    }

    if ($Ktx2.DfdTransfer -eq 2) {
        throw "KTX2 DFD transfer is sRGB"
    }

    if ($Ktx2.DfdModel -ne $Dds.FormatInfo.DfdModel) {
        throw "KTX2 DFD model mismatch: expected $($Dds.FormatInfo.DfdModel), got $($Ktx2.DfdModel)"
    }

    for ($level = 0; $level -lt $Dds.MipLevels; $level++) {
        $entry = $Ktx2.Levels[$level]

        if ($entry.ByteLength -ne [uint64]$Dds.LevelData[$level].Length) {
            throw "KTX2 level byte length mismatch level=$level"
        }

        if ($entry.UncompressedByteLength -ne $entry.ByteLength) {
            throw "KTX2 level uncompressed length mismatch level=$level"
        }

        $actual = Copy-ByteRange -Bytes $Ktx2.Bytes -Offset ([int]$entry.ByteOffset) -Length ([int]$entry.ByteLength)
        $expectedHash = Get-Sha256Hex $Dds.LevelData[$level]
        $actualHash = Get-Sha256Hex $actual

        if ($actualHash -ne $expectedHash) {
            throw "KTX2 payload mismatch level=$level"
        }
    }
}

function Write-Sidecar {
    param(
        [object]$Row,
        [object]$Dds,
        [string]$Path
    )

    $meta = [ordered]@{
        source = $Row.FullPath
        relativePath = $Row.RelativePath
        output = $Row.OutputKtx2
        convertedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        preservation = [ordered]@{
            recompressed = $false
            blockBytesCopied = $true
            payloadSha256 = $Dds.PayloadSha256
            vkFormat = $Dds.VkFormat
            bc1Mode = $Dds.EffectiveBc1Mode
        }
        dds = [ordered]@{
            width = $Dds.Width
            height = $Dds.Height
            mipLevels = $Dds.MipLevels
            arraySize = 6
            format = $Dds.Format
            dimension = "Cube"
            images = $Dds.Images
            fourCC = $Dds.FourCC
            dxgiFormat = $Dds.DxgiFormat
            dataOffset = $Dds.DataOffset
        }
    }

    $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $TextureRoot)) {
    throw "TextureRoot does not exist: '$TextureRoot'"
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = $TextureRoot
}

$textureRootFull = (Resolve-Path -LiteralPath $TextureRoot).Path
$outputRootFull = Resolve-Directory $OutputRoot
$ddsFiles = @(Get-ChildItem -LiteralPath $textureRootFull -Recurse -File -Filter "*.dds" | Sort-Object FullName)

if ($ddsFiles.Count -eq 0) {
    throw "No .dds files found under '$textureRootFull'"
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportDir = Join-Path $outputRootFull "_ktx2_cube_reports"
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

$summaryPath = Join-Path $reportDir "dds_cube_summary_$timestamp.txt"
$rows = New-Object System.Collections.Generic.List[object]

foreach ($file in $ddsFiles) {
    $relative = Get-RelativePathSafe -BasePath $textureRootFull -FilePath $file.FullName
    $outputKtx2 = Get-OutputPath -OutputRoot $outputRootFull -RelativePath $relative

    $row = [PSCustomObject]@{
        RelativePath = $relative
        FullPath = $file.FullName
        SourceBytes = $file.Length
        Width = ""
        Height = ""
        MipLevels = ""
        Format = ""
        VkFormat = ""
        Converted = $false
        ConvertStatus = ""
        OutputKtx2 = $outputKtx2
        OutputBytes = ""
        SidecarJson = ""
        PayloadSha256 = ""
        ToolOutput = ""
    }

    try {
        $dds = Read-DdsCube -Path $file.FullName -Bc1Mode $Bc1Mode

        if (-not [string]::IsNullOrWhiteSpace($dds.UnsupportedStatus)) {
            $row.ConvertStatus = $dds.UnsupportedStatus
            $rows.Add($row)
            continue
        }

        $row.Width = $dds.Width
        $row.Height = $dds.Height
        $row.MipLevels = $dds.MipLevels
        $row.Format = $dds.Format
        $row.VkFormat = $dds.VkFormat
        $row.PayloadSha256 = $dds.PayloadSha256

        if ($AuditOnly) {
            $row.ConvertStatus = "AUDIT_ONLY"
            $rows.Add($row)
            continue
        }

        if ((Test-Path -LiteralPath $row.OutputKtx2) -and -not $Overwrite) {
            $row.ConvertStatus = "SKIPPED_EXISTS"
            $row.OutputBytes = (Get-Item -LiteralPath $row.OutputKtx2).Length
            $rows.Add($row)
            continue
        }

        Write-Ktx2Cube -Dds $dds -OutputPath $row.OutputKtx2

        $ktx2 = Get-Ktx2Info -FilePath $row.OutputKtx2
        Assert-Ktx2Cube -Dds $dds -Ktx2 $ktx2 -OutputPath $row.OutputKtx2

        $row.Converted = $true
        $row.ConvertStatus = "OK"
        $row.OutputBytes = (Get-Item -LiteralPath $row.OutputKtx2).Length
        $row.ToolOutput = "KTX2 cube validated: VkFormat=$($ktx2.VkFormat), Size=$($ktx2.Width)x$($ktx2.Height), Faces=$($ktx2.FaceCount), Levels=$($ktx2.LevelCount), PayloadSha256=$($dds.PayloadSha256)"

        if (-not $NoSidecar) {
            $sidecar = $row.OutputKtx2 + ".ddsmeta.json"
            Write-Sidecar -Row $row -Dds $dds -Path $sidecar
            $row.SidecarJson = $sidecar
        }

        $rows.Add($row)
    } catch {
        $row.ConvertStatus = "FAILED_EXCEPTION"
        $row.ToolOutput = $_.Exception.Message
        $rows.Add($row)
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
$summaryLines.Add("Bc1Mode: $Bc1Mode")
$summaryLines.Add("TotalDDS: $($rows.Count)")
$summaryLines.Add("Converted: $convertedCount")
$summaryLines.Add("Failed: $failedCount")
$summaryLines.Add("Skipped: $skippedCount")
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
    $summaryLines.Add("  VkFormat: $($row.VkFormat)")
    $summaryLines.Add("  Size: $($row.Width)x$($row.Height)")
    $summaryLines.Add("  MipLevels: $($row.MipLevels)")

    if (-not [string]::IsNullOrWhiteSpace($row.PayloadSha256)) {
        $summaryLines.Add("  PayloadSha256: $($row.PayloadSha256)")
    }

    if (-not [string]::IsNullOrWhiteSpace($row.SidecarJson)) {
        $summaryLines.Add("  SidecarJson: $($row.SidecarJson)")
    }

    if (-not [string]::IsNullOrWhiteSpace($row.ToolOutput)) {
        $summaryLines.Add("  ToolOutput: $($row.ToolOutput)")
    }

    $summaryLines.Add("")
}

$summaryLines | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "Summary: $summaryPath"
Write-Host "TotalDDS=$($rows.Count) Converted=$convertedCount Failed=$failedCount Skipped=$skippedCount"
