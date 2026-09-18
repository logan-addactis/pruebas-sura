<#
.SYNOPSIS
    Agrega una columna con el hash de un commit de Git a un archivo de log
    (CSV o delimitado), generando un archivo nuevo listo para subir a Blob Storage.

.PARAMETER InputFile
    Ruta del archivo de log original (tal como lo genera el aplicativo).

.PARAMETER OutputFile
    Ruta del archivo nuevo que se generara, con la columna agregada.

.PARAMETER CommitHash
    Hash del commit de git que se va a asociar a este log.

.PARAMETER Delimiter
    Delimitador usado por el archivo (por defecto coma, para que coincida
    con FIELDTERMINATOR = ',' del BULK INSERT).

.PARAMETER ColumnName
    Nombre de la columna nueva (por defecto "commit_git").

.EXAMPLE
    powershell -File Add-CommitColumn.ps1 -InputFile "log1.csv" -OutputFile "log1_out.csv" -CommitHash "a1b2c3d4"
#>
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$OutputFile,
    [Parameter(Mandatory = $true)][string]$CommitHash,
    [string]$Delimiter = ",",
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

$outputLines = New-Object System.Collections.Generic.List[string]

# Primera linea = encabezado -> se le agrega el nombre de la columna nueva
$outputLines.Add("$($lines[0])$Delimiter$ColumnName")

# Resto de lineas -> se les agrega el hash del commit
for ($i = 1; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line.Trim().Length -eq 0) { continue }  # saltar lineas en blanco
    $outputLines.Add("$line$Delimiter$CommitHash")
}

# UTF8 sin BOM para evitar problemas con BULK INSERT en SQL Server
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($OutputFile, $outputLines, $utf8NoBom)

Write-Host "Archivo generado: $OutputFile ($($outputLines.Count - 1) filas + encabezado)"