<#
.SYNOPSIS
    Convierte un log delimitado (por defecto, separado por TABULACIONES,
    como lo genera addactis DataFlow) a un CSV separado por comas, y le
    agrega una columna con el hash de un commit de git.

.PARAMETER InputFile
    Ruta del archivo de log original.

.PARAMETER OutputFile
    Ruta del archivo nuevo que se generara, ya convertido a comas y con
    la columna agregada.

.PARAMETER CommitHash
    Hash del commit de git que se va a asociar a este log.

.PARAMETER InputDelimiter
    Delimitador real del archivo de origen. Por defecto tabulacion (`t),
    que es como vienen los .log de DataFlow. Cambialo si tu archivo usa
    otro caracter.

.PARAMETER OutputDelimiter
    Delimitador de salida, el que espera el BULK INSERT (FIELDTERMINATOR).
    Por defecto coma.

.PARAMETER ColumnName
    Nombre de la columna nueva (por defecto "commit_git").

.EXAMPLE
    powershell -File Add-CommitColumn.ps1 -InputFile "log1.log" -OutputFile "log1_out.txt" -CommitHash "a1b2c3d4"
#>
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [Parameter(Mandatory = $true)][string]$CommitHash,
    [string]$InputDelimiter = "`t",
    [string]$OutputDelimiter = ",",
    [string]$ColumnName = "commit_git"
)

if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Error "No se encontro el archivo de entrada: $InputFile"
    exit 1
}

$lines = Get-Content -LiteralPath $InputFile -Encoding UTF8

if ($lines.Count -eq 0) {
    Write-Error "El archivo esta vacio: $InputFile"
    exit 1
}

function ConvertTo-CsvField {
    param([string]$Value)
    # Escapa comillas dobles duplicandolas y envuelve el campo en comillas.
    # Asi, si el texto original (por ejemplo la columna Message) trae una
    # coma o un salto de linea, no te desalinea las columnas al hacer
    # BULK INSERT con FORMAT = 'CSV' (que interpreta comillas dobles como
    # delimitador de texto por defecto).
    $escaped = $Value -replace '"', '""'
    return '"' + $escaped + '"'
}

$outputLines = New-Object System.Collections.Generic.List[string]
$splitPattern = [regex]::Escape($InputDelimiter)

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line.Trim().Length -eq 0) { continue }  # saltar lineas en blanco

    $fields = [regex]::Split($line, $splitPattern)
    $quotedFields = @($fields | ForEach-Object { ConvertTo-CsvField $_ })

    if ($i -eq 0) {
        # Encabezado: se agrega el nombre de la columna nueva
        $quotedFields += ConvertTo-CsvField $ColumnName
    } else {
        # Filas de datos: se agrega el hash del commit
        $quotedFields += ConvertTo-CsvField $CommitHash
    }

    $outputLines.Add(($quotedFields -join $OutputDelimiter))
}

# UTF8 sin BOM para evitar problemas con BULK INSERT en SQL Server
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($OutputFile, $outputLines, $utf8NoBom)

Write-Host "Archivo generado: $OutputFile ($($outputLines.Count - 1) filas + encabezado, delimitador de salida: '$OutputDelimiter')"