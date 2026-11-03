#requires -Version 5.1
# Progreso informativo; un fallo al escribirlo nunca cancela la copia.
$script:OperationProgress = $null
function Publish-OperationProgress {
    if (-not $env:DOCKER_UPDATER_PROGRESS_FILE -or -not $script:OperationProgress) { return }
    try {
        $script:OperationProgress.updatedAt = (Get-Date).ToString('o')
        $path = $env:DOCKER_UPDATER_PROGRESS_FILE
        $temporary = "$path.tmp"
        $script:OperationProgress | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    catch { } # El log general conserva el diagnostico aunque la GUI no pueda leer progreso.
}
function Set-OperationStage {
    param([string]$Phase, [int]$Step = 0, [int]$Steps = 0, [string]$Detail, [string]$ProjectName)
    $script:OperationProgress = [ordered]@{
        phase = $Phase; step = $Step; steps = $Steps; detail = $Detail
        project = $ProjectName; phaseStartedAt = (Get-Date).ToString('o')
        updatedAt = (Get-Date).ToString('o'); bytesProcessed = 0; bytesTotal = 0
        lastMessage = $Detail
    }
    Publish-OperationProgress
}
function Get-TrackedFileHash {
    param([Parameter(Mandatory)] [string]$LiteralPath)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($LiteralPath)
        $buffer = New-Object byte[] (4MB)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if ($script:OperationProgress) {
            $script:OperationProgress.bytesTotal = $stream.Length
            $script:OperationProgress.bytesProcessed = 0
            Publish-OperationProgress
        }
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $null = $algorithm.TransformBlock($buffer, 0, $count, $buffer, 0)
            if ($script:OperationProgress -and $clock.ElapsedMilliseconds -ge 750) {
                $script:OperationProgress.bytesProcessed = $stream.Position
                Publish-OperationProgress
                $clock.Restart()
            }
        }
        $null = $algorithm.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        if ($script:OperationProgress) {
            $script:OperationProgress.bytesProcessed = $stream.Position
            Publish-OperationProgress
        }
        return [BitConverter]::ToString($algorithm.Hash).Replace('-', '')
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $algorithm.Dispose()
    }
}
