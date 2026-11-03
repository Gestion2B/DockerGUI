#requires -Version 5.1
# Verificacion local de integridad. Nunca importa datos ni usa la base de produccion.
function Get-DatabaseBackupFiles {
    param([string]$RootPath)
    $old = Join-Path $RootPath 'old'
    if (-not (Test-Path -LiteralPath $old -PathType Container)) { return @() }
    if ((Get-Item -LiteralPath $old).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'La carpeta old no puede ser un enlace para verificar copias.'
    }
    return @(Get-ChildItem -LiteralPath $old -File | Where-Object {
        $_.Name -match '\.(postgres\.dump|mysql\.sql)(\.partial)?$' -and
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | Sort-Object Name -Descending)
}

function Get-DatabaseBackupCatalog {
    param([string]$RootPath, [string]$ProjectId)
    foreach ($file in @(Get-DatabaseBackupFiles $RootPath)) {
        $partial = $file.Name.EndsWith('.partial')
        $status = if ($partial) { 'partial' } else { 'unchecked' }
        $checkedAt = $null
        $message = if ($partial) { 'Copia incompleta; no usar para restaurar.' } else { 'Pendiente de comprobar el archivo actual.' }
        $metaPath = "$($file.FullName).json"
        $reportPath = "$($file.FullName).verify.json"
        if (-not $partial -and -not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
            $status = 'missingMetadata'
            $message = 'No hay metadatos con el hash original.'
        }
        if (-not $partial -and (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
            try {
                $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $metaTicks = if (Test-Path -LiteralPath $metaPath -PathType Leaf) { (Get-Item -LiteralPath $metaPath).LastWriteTimeUtc.Ticks.ToString() } else { '' }
                if ($report.Project -ceq $ProjectId -and $report.File -ceq $file.Name -and
                    [string]$report.Length -eq [string]$file.Length -and
                    $report.LastWriteTicks -eq $file.LastWriteTimeUtc.Ticks.ToString() -and
                    $report.MetadataTicks -eq $metaTicks) {
                    $status = if ($report.Success -eq $true) { 'verified' } else { 'failed' }
                    $checkedAt = $report.CheckedAt
                    $message = $report.Message
                }
                else { $status = 'changed'; $message = 'El archivo o sus metadatos cambiaron. Vuelve a verificar.' }
            }
            catch { $status = 'unchecked'; $message = 'No se pudo leer el resultado anterior.' }
        }
        [pscustomobject]@{
            name = $file.Name
            engine = if ($file.Name -match '\.mysql\.sql') { 'mysql' } else { 'postgres' }
            bytes = $file.Length
            createdAt = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            status = $status
            checkedAt = $checkedAt
            message = $message
            canVerify = -not $partial
            restorationTested = $false
        }
    }
}

function Test-DatabaseBackup {
    param([string]$RootPath, [string]$ProjectId, [string]$BackupName)
    Set-OperationStage -Phase 'Preparando verificacion' -Step 1 -Steps 3 -Detail $BackupName -ProjectName $ProjectId
    $files = @(Get-DatabaseBackupFiles $RootPath | Where-Object { $_.Name -ceq $BackupName })
    if ($files.Count -ne 1 -or $BackupName.EndsWith('.partial')) {
        throw 'No existe una copia terminada con ese nombre dentro de old.'
    }
    $file = $files[0]
    $metaPath = "$($file.FullName).json"
    $reportPath = "$($file.FullName).verify.json"
    foreach ($path in @($metaPath, $reportPath)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Los metadatos y resultados de verificacion no pueden ser enlaces.'
        }
    }
    $length = $file.Length
    $ticks = $file.LastWriteTimeUtc.Ticks.ToString()
    $metaTicks = if (Test-Path -LiteralPath $metaPath -PathType Leaf) { (Get-Item -LiteralPath $metaPath).LastWriteTimeUtc.Ticks.ToString() } else { '' }
    $actualHash = $null
    $success = $false
    $message = ''
    try {
        if ($length -lt 5) { throw 'Archivo vacio o demasiado corto.' }
        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) { throw 'Faltan los metadatos: no se puede comparar con el hash original.' }
        $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($meta.Project -cne $ProjectId) { throw 'La copia pertenece a otro proyecto segun sus metadatos.' }
        if ([string]$meta.SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Los metadatos no contienen un SHA256 valido.' }
        Write-DeployLog "Verificando SHA256: $BackupName ($length bytes)..."
        Set-OperationStage -Phase 'Verificando SHA256' -Step 2 -Steps 3 -Detail $BackupName -ProjectName $ProjectId
        $actualHash = Get-TrackedFileHash -LiteralPath $file.FullName
        if ($actualHash -ne $meta.SHA256) { throw 'SHA256 NO coincide. El archivo ha cambiado o esta danado.' }
        if ($file.Name.EndsWith('.postgres.dump')) {
            $stream = [IO.File]::OpenRead($file.FullName)
            try {
                $header = New-Object byte[] 5
                $read = $stream.Read($header, 0, 5)
                if ($read -ne 5 -or [Text.Encoding]::ASCII.GetString($header) -cne 'PGDMP') {
                    throw 'El archivo no tiene la cabecera PGDMP esperada.'
                }
            }
            finally { $stream.Dispose() }
        }
        else {
            $tail = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Tail 8)
            if (-not ($tail -match '^-- Dump completed on ')) { throw 'Falta el marcador final de mysqldump.' }
        }
        $after = Get-Item -LiteralPath $file.FullName
        if ($after.Length -ne $length -or $after.LastWriteTimeUtc.Ticks.ToString() -ne $ticks -or
            (Get-Item -LiteralPath $metaPath).LastWriteTimeUtc.Ticks.ToString() -ne $metaTicks) {
            throw 'Los archivos cambiaron durante la verificacion. Repite la operacion.'
        }
        $success = $true
        $message = 'SHA256 coincide y formato basico correcto. Restauracion NO probada.'
    }
    catch { $message = $_.Exception.Message }
    Set-OperationStage -Phase 'Guardando resultado' -Step 3 -Steps 3 -Detail $message -ProjectName $ProjectId
    $report = [ordered]@{
        Project = $ProjectId; File = $file.Name; Success = $success
        CheckedAt = (Get-Date).ToString('o'); Length = $length
        LastWriteTicks = $ticks; MetadataTicks = $metaTicks
        SHA256 = $actualHash; Message = $message; RestorationTested = $false
    }
    $temporary = "$reportPath.$([guid]::NewGuid().ToString('N')).tmp"
    $report | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $reportPath -Force
    if (-not $success) { throw "$BackupName : $message" }
    Write-DeployLog "$BackupName : $message"
}
