#requires -Version 5.1
# Cargado por Actualizador-Proyectos.ps1. PostgreSQL y MySQL 8.4.
# Se conserva el nombre del archivo por compatibilidad. No restaura ni elimina datos.
function Stop-WithDatabaseBackup {
    param($SelectedProject, [string]$EnvironmentPath, [string]$BackupPath, [switch]$BackupOnly)
    Set-OperationStage -Phase 'Preparando' -Step 1 -Steps 6 -Detail 'Comprobando configuracion y contenedores.' -ProjectName $SelectedProject.Name
    $settings = $SelectedProject.Database
    $kind = $settings['bd']
    if (-not $kind -or $kind -eq 'no') {
        if ($BackupOnly) { throw 'Este proyecto no tiene BD=postgres o BD=mysql.' }
        Stop-Environment $SelectedProject $EnvironmentPath
        return
    }
    if ($kind -notin @('postgres', 'mysql')) { throw 'BD debe ser no, postgres o mysql.' }
    foreach ($key in @('bdservicio', 'bdnombre', 'bdusuario')) {
        if ($settings[$key] -cnotmatch '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$') {
            throw "Falta $key o contiene caracteres no admitidos."
        }
    }
    $service = $settings['bdservicio']
    $database = $settings['bdnombre']
    $user = $settings['bdusuario']
    $writers = @(($settings['bddetener'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($writers.Count -eq 0) { throw 'Indica BDDetener con los servicios que escriben en la base de datos.' }
    foreach ($writer in $writers) {
        if ($writer -cnotmatch '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$' -or $writer -eq $service) {
            throw "BDDetener incorrecto: $writer"
        }
    }
    $query = Get-ComposeArguments $SelectedProject $EnvironmentPath @('config', '--services')
    $services = @(& docker @query)
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron consultar los servicios.' }
    foreach ($name in @($service) + $writers) {
        if ($name -cnotin $services) { throw "Servicio no encontrado: $name" }
    }
    $query = Get-ComposeArguments $SelectedProject $EnvironmentPath @('ps', '--quiet', $service)
    $ids = @(& docker @query | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $ids.Count -ne 1) {
        throw 'El servicio de base de datos debe tener exactamente un contenedor arrancado para realizar la copia.'
    }
    $container = $ids[0].Trim()
    if ($kind -eq 'mysql' -and $database -eq 'auto') {
        $names = @(& docker exec $container printenv MYSQL_DATABASE)
        if ($LASTEXITCODE -ne 0 -or $names.Count -ne 1) {
            throw 'No se pudo leer MYSQL_DATABASE del contenedor. Indica BDNombre explicitamente.'
        }
        $database = $names[0].Trim()
        if ($database -cnotmatch '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$') {
            throw 'MYSQL_DATABASE no es un identificador admitido. No se ha detenido la aplicacion.'
        }
    }
    if ($kind -eq 'mysql' -and $user -ne 'root') {
        throw 'Esta integracion MySQL requiere BDUsuario=root y MYSQL_ROOT_PASSWORD dentro del contenedor.'
    }
    # Registrar solo los contenedores de escritura que ya estaban arrancados.
    $query = Get-ComposeArguments $SelectedProject $EnvironmentPath (@('ps', '--quiet') + $writers)
    $runningWriters = @(& docker @query | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { throw 'No se pudieron consultar los contenedores de escritura.' }
    $extension = if ($kind -eq 'mysql') { '.mysql.sql' } else { '.postgres.dump' }
    $destination = "$BackupPath$extension"
    $partial = "$destination.partial"
    if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $partial)) {
        throw "Ya existe una copia con este identificador: $destination"
    }
    $remote = '/tmp/updater-' + [guid]::NewGuid().ToString('N') + $extension
    $stoppingStarted = $false
    try {
        Set-OperationStage -Phase 'Pausando servicios' -Step 2 -Steps 6 -Detail 'Esperando a que terminen los servicios que escriben datos.' -ProjectName $SelectedProject.Name
        if ($runningWriters.Count -gt 0) {
            $stoppingStarted = $true
            Write-DeployLog "Deteniendo escritores antes de copiar $database..."
            & docker stop @runningWriters
            if ($LASTEXITCODE -ne 0) { throw 'No se pudieron detener los escritores.' }
        }
        Write-DeployLog "Creando copia $kind de $database..."
        Set-OperationStage -Phase 'Exportando base de datos' -Step 3 -Steps 6 -Detail "Generando dump de $database. El motor no proporciona un porcentaje fiable." -ProjectName $SelectedProject.Name
        # La contrasena permanece dentro del contenedor; no se imprime ni se copia al TXT.
        # Los identificadores interpolados estan restringidos a caracteres seguros arriba.
        if ($kind -eq 'mysql') {
            $command = "umask 077; MYSQL_PWD=`${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD_no_configurada}; export MYSQL_PWD; exec mysqldump --no-defaults --protocol=socket --user=root --single-transaction --quick --routines --events --triggers --hex-blob --no-tablespaces --set-gtid-purged=OFF --default-character-set=utf8mb4 --comments --dump-date --databases $database --result-file=$remote"
            $validation = 'mysqldump exit 0; completion marker; transfer SHA256; NO restoration test performed'
        }
        else {
            $command = "umask 077; export PGPASSWORD=`$POSTGRES_PASSWORD; exec pg_dump -w -Fc -U $user -d $database -f $remote"
            $validation = 'pg_restore --list; transfer SHA256; NO restoration test performed'
        }
        & docker exec $container sh -c $command
        if ($LASTEXITCODE -ne 0) { throw "El dump $kind fallo. No se cambiaran las carpetas." }
        if ($kind -eq 'postgres') {
            Set-OperationStage -Phase 'Comprobando exportacion' -Step 3 -Steps 6 -Detail 'Leyendo el indice PostgreSQL dentro del contenedor.' -ProjectName $SelectedProject.Name
            & docker exec $container pg_restore --list $remote | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'pg_restore no pudo leer el indice del dump.' }
        }
        Set-OperationStage -Phase 'Calculando huella de origen' -Step 3 -Steps 6 -Detail 'Leyendo el dump dentro del contenedor para calcular SHA256.' -ProjectName $SelectedProject.Name
        $remoteHashLines = @(& docker exec $container sha256sum $remote)
        if ($LASTEXITCODE -ne 0 -or $remoteHashLines.Count -ne 1 -or
            $remoteHashLines[0] -notmatch '^([a-fA-F0-9]{64})\s') {
            throw 'No se pudo calcular SHA256 del dump dentro del contenedor.'
        }
        $remoteHash = $Matches[1]
        # Evitar redireccion binaria por PowerShell 5.1: copiar el archivo directamente.
        Set-OperationStage -Phase 'Copiando a Windows' -Step 4 -Steps 6 -Detail "Guardando el archivo en $partial" -ProjectName $SelectedProject.Name
        & docker cp "${container}:$remote" $partial
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo copiar el dump a Windows.' }
        if (-not (Test-Path -LiteralPath $partial) -or (Get-Item -LiteralPath $partial).Length -lt 5) {
            throw 'El dump copiado esta vacio o incompleto.'
        }
        Set-OperationStage -Phase 'Verificando archivo' -Step 5 -Steps 6 -Detail 'Calculando SHA256 del archivo copiado.' -ProjectName $SelectedProject.Name
        $hash = Get-TrackedFileHash -LiteralPath $partial
        if ($hash -ne $remoteHash) { throw 'El dump copiado no coincide con el original. Se cancela el cambio.' }
        if ($kind -eq 'mysql') {
            $tail = @(Get-Content -LiteralPath $partial -Encoding UTF8 -Tail 8)
            if (-not ($tail -match '^-- Dump completed on ')) {
                throw 'Falta la marca final de mysqldump. Se conserva el archivo parcial para revisar.'
            }
        }
        Set-OperationStage -Phase 'Guardando y reactivando' -Step 6 -Steps 6 -Detail 'Guardando metadatos y completando la operacion.' -ProjectName $SelectedProject.Name
        Move-Item -LiteralPath $partial -Destination $destination
        $metadata = [ordered]@{
            Project = $SelectedProject.ProjectName
            Database = $database
            Engine = $kind
            User = $user
            CreatedAt = (Get-Date).ToString('o')
            SHA256 = $hash
            ArchivePath = $BackupPath
            Validation = $validation
            IncludesUploads = $false
            IncludesGlobalRoles = $false
        }
        $metadata | ConvertTo-Json | Set-Content -LiteralPath "$destination.json" -Encoding UTF8
        Write-DeployLog "Dump guardado: $destination. Transferencia verificada; restauracion real no probada."
        & docker exec $container rm -f $remote
        if ($LASTEXITCODE -ne 0) { Write-DeployLog "No se pudo limpiar el temporal $remote" 'WARN' }
        if ($BackupOnly) {
            if ($runningWriters.Count -gt 0) {
                & docker start @runningWriters
                if ($LASTEXITCODE -ne 0) { throw 'Copia guardada pero fallo la reactivacion de los escritores.' }
            }
        }
        else { Stop-Environment $SelectedProject $EnvironmentPath }
    }
    catch {
        $failure = $_.Exception.Message
        Set-OperationStage -Phase 'Recuperando tras un error' -Detail $failure -ProjectName $SelectedProject.Name
        if ($stoppingStarted -and $runningWriters.Count -gt 0) {
            & docker start @runningWriters
            if ($LASTEXITCODE -ne 0) {
                Write-DeployLog 'No se pudieron reactivar todos los escritores. Revisa Docker antes de continuar.' 'ERROR'
            }
        }
        Write-DeployLog "Copia o parada fallida. Se conservan los archivos disponibles. $failure" 'ERROR'
        throw $failure
    }
}
