<#
.SYNOPSIS
    Inserta directamente en SQL Server (local, via OLE DB) las filas de
    un log de DataFlow

.PARAMETER LogFile
    Ruta del archivo .log original a insertar.

.PARAMETER CommitHash
    Hash del commit de git asociado a esta carga (va en la columna
    Commit_Git).

.PARAMETER ConnectionStringFile
    Ruta del archivo de texto que contiene la cadena de conexion
    (Provider=SQLOLEDB.1;...). La cadena nunca se escribe en este script,
    se lee de ese archivo en tiempo de ejecucion.

.PARAMETER TableName
    Tabla destino, por defecto dbo.logs.

.PARAMETER InputDelimiter
    Delimitador del archivo de origen (tabulacion por defecto).

.EXAMPLE
    powershell -File Insert-LogToDb.ps1 -LogFile "prueba1-....log" -CommitHash "a1b2c3..." -ConnectionStringFile "Conexion a DB logan.txt"
#>
param(
    [Parameter(Mandatory = $true)][string]$LogFile,
    [Parameter(Mandatory = $true)][string]$CommitHash,
    [Parameter(Mandatory = $true)][string]$ConnectionStringFile,
    [string]$TableName = "dbo.logs",
    [string]$InputDelimiter = "`t"
)

Add-Type -AssemblyName "System.Data"

if (-not (Test-Path -LiteralPath $LogFile)) {
    Write-Error "No se encontro el log: $LogFile"
    exit 1
}
if (-not (Test-Path -LiteralPath $ConnectionStringFile)) {
    Write-Error "No se encontro el archivo de conexion: $ConnectionStringFile"
    exit 1
}

$connString = (Get-Content -LiteralPath $ConnectionStringFile -Raw).Trim()

$lines = Get-Content -LiteralPath $LogFile -Encoding UTF8
if ($lines.Count -lt 2) {
    Write-Error "El log no tiene filas de datos: $LogFile"
    exit 1
}

$splitPattern = [regex]::Escape($InputDelimiter)

# Formato de fecha tal como lo escribe DataFlow (ej: 9/4/2026 9:16:14 AM).
# InvariantCulture + formato explicito para no depender de la configuracion
# regional de la maquina (evita confundir dia/mes segun el locale).
$dateFormat = "M/d/yyyy h:mm:ss tt"
$culture = [System.Globalization.CultureInfo]::InvariantCulture

$connection = New-Object System.Data.OleDb.OleDbConnection($connString)
$insertadas = 0
$omitidas = 0

$sql = "INSERT INTO $TableName ([Date/Time], [Step], [Tool], [Severity], [Message], [Comment], [Commit_Git]) VALUES (?, ?, ?, ?, ?, ?, ?)"

try {
    $connection.Open()

    # Se salta la fila 0 (encabezado: Date/Time, Step, Tool, Severity, Message, Comment)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line.Trim().Length -eq 0) { continue }

        $fields = [regex]::Split($line, $splitPattern)
        if ($fields.Count -lt 6) {
            Write-Warning "Fila $($i + 1) con menos columnas de las esperadas, se omite: $line"
            $omitidas++
            continue
        }

        $rawDate = $fields[0].Trim()
        try {
            $fechaHora = [datetime]::ParseExact($rawDate, $dateFormat, $culture)
        } catch {
            Write-Warning "No se pudo interpretar la fecha '$rawDate' en la fila $($i + 1), se omite."
            $omitidas++
            continue
        }

        $step     = $fields[1].Trim()
        $tool     = $fields[2].Trim()
        $severity = $fields[3].Trim()
        $message  = $fields[4].Trim()
        $comment  = $fields[5].Trim()

        $command = $connection.CreateCommand()
        $command.CommandText = $sql
        [void]$command.Parameters.AddWithValue("?", $fechaHora)
        [void]$command.Parameters.AddWithValue("?", $(if ($step -eq "") { [DBNull]::Value } else { $step }))
        [void]$command.Parameters.AddWithValue("?", $tool)
        [void]$command.Parameters.AddWithValue("?", $severity)
        [void]$command.Parameters.AddWithValue("?", $message)
        [void]$command.Parameters.AddWithValue("?", $(if ($comment -eq "") { [DBNull]::Value } else { $comment }))
        [void]$command.Parameters.AddWithValue("?", $CommitHash)

        try {
            [void]$command.ExecuteNonQuery()
            $insertadas++
        } catch {
            Write-Warning "Fallo al insertar la fila $($i + 1): $($_.Exception.Message)"
            $omitidas++
        } finally {
            $command.Dispose()
        }
    }

    Write-Host "Listo: $insertadas fila(s) insertada(s) en $TableName, $omitidas omitida(s)/con error."
} catch {
    Write-Error "No se pudo conectar o insertar: $($_.Exception.Message)"
    exit 1
} finally {
    if ($connection.State -eq [System.Data.ConnectionState]::Open) {
        $connection.Close()
    }
}