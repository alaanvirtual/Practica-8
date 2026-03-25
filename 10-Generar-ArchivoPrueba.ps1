# =============================================================================
# SCRIPT 10: Generar Archivos de Prueba para FSRM
# Archivo: 10-Generar-ArchivoPrueba.ps1
# Ejecutar en: Windows Server 2022 O Cliente Windows (como Administrador)
# =============================================================================
# Genera archivos de diferentes tamanos para probar las cuotas de disco

#Requires -RunAsAdministrator

param(
    [string]$Destino = "C:\Scripts\ArchivosTest",
    [switch]$LimpiarAntes
)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) { "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }; default { "Cyan" } }
    Write-Host "[$(Get-Date -Format HH:mm:ss)][$Level] $Message" -ForegroundColor $color
}

if (-not (Test-Path $Destino)) {
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null
}

if ($LimpiarAntes) {
    Remove-Item "$Destino\*" -Force -ErrorAction SilentlyContinue
    Write-Log "Archivos anteriores eliminados" "INFO"
}

Write-Log "Generando archivos de prueba en: $Destino" "INFO"

# Funcion para crear archivo de tamano exacto
function New-TestFile {
    param([string]$Path, [int]$SizeMB, [string]$Nombre)

    $sizBytes = $SizeMB * 1MB
    $buffer   = New-Object byte[] 1MB

    $fs = [System.IO.File]::OpenWrite($Path)
    try {
        $written = 0
        while ($written -lt $sizBytes) {
            $toWrite = [Math]::Min(1MB, $sizBytes - $written)
            $fs.Write($buffer, 0, $toWrite)
            $written += $toWrite
        }
    } finally {
        $fs.Close()
    }

    $actual = (Get-Item $Path).Length / 1MB
    Write-Log "Creado: $Nombre ($([math]::Round($actual,2)) MB) -> $Path" "OK"
}

# ---------------------------------------------------------------------------
# ARCHIVOS PARA PRUEBA DE CUOTAS
# ---------------------------------------------------------------------------
Write-Log "--- Archivos para prueba de cuotas ---" "INFO"

New-TestFile -Path "$Destino\test-1MB.dat"  -SizeMB 1  -Nombre "test-1MB.dat"
New-TestFile -Path "$Destino\test-4MB.dat"  -SizeMB 4  -Nombre "test-4MB.dat"
New-TestFile -Path "$Destino\test-5MB.dat"  -SizeMB 5  -Nombre "test-5MB.dat"
New-TestFile -Path "$Destino\test-6MB.dat"  -SizeMB 6  -Nombre "test-6MB.dat"
New-TestFile -Path "$Destino\test-9MB.dat"  -SizeMB 9  -Nombre "test-9MB.dat"
New-TestFile -Path "$Destino\test-10MB.dat" -SizeMB 10 -Nombre "test-10MB.dat"
New-TestFile -Path "$Destino\test-11MB.dat" -SizeMB 11 -Nombre "test-11MB.dat"

# ---------------------------------------------------------------------------
# ARCHIVOS PARA PRUEBA DE APANTALLAMIENTO (archivos dummy con extension prohibida)
# ---------------------------------------------------------------------------
Write-Log "" "INFO"
Write-Log "--- Archivos para prueba de apantallamiento ---" "INFO"

# Crear archivos de texto con extensiones prohibidas (son solo texto, no malware real)
$contenidoPrueba = "Este es un archivo de prueba para FSRM - No es un archivo real"

# Archivos multimedia simulados
Set-Content -Path "$Destino\musica-prueba.mp3"  -Value $contenidoPrueba
Set-Content -Path "$Destino\video-prueba.mp4"   -Value $contenidoPrueba
Set-Content -Path "$Destino\video-prueba.avi"   -Value $contenidoPrueba
Write-Log "Archivos multimedia simulados creados (.mp3, .mp4, .avi)" "OK"

# Archivos ejecutables simulados
Set-Content -Path "$Destino\programa-prueba.exe" -Value $contenidoPrueba
Set-Content -Path "$Destino\instalador-prueba.msi" -Value $contenidoPrueba
Write-Log "Archivos ejecutables simulados creados (.exe, .msi)" "OK"

# ---------------------------------------------------------------------------
# INSTRUCCIONES DE USO
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  ARCHIVOS DE PRUEBA GENERADOS" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""
Write-Host "Archivos disponibles en: $Destino" -ForegroundColor White
Write-Host ""
Write-Host "PRUEBA DE CUOTAS:" -ForegroundColor Yellow
Write-Host "  1. Comparte $Destino o copia archivos al servidor" -ForegroundColor White
Write-Host "  2. Como usuario 'sperez' (NoCuates, 5MB):" -ForegroundColor White
Write-Host "     - Copia test-4MB.dat a H:\  -> DEBE FUNCIONAR" -ForegroundColor Green
Write-Host "     - Copia test-6MB.dat a H:\  -> DEBE SER BLOQUEADO" -ForegroundColor Red
Write-Host "  3. Como usuario 'jgarcia' (Cuates, 10MB):" -ForegroundColor White
Write-Host "     - Copia test-9MB.dat a H:\  -> DEBE FUNCIONAR" -ForegroundColor Green
Write-Host "     - Copia test-11MB.dat a H:\ -> DEBE SER BLOQUEADO" -ForegroundColor Red
Write-Host ""
Write-Host "PRUEBA DE APANTALLAMIENTO:" -ForegroundColor Yellow
Write-Host "  Como cualquier usuario, intenta copiar a H:\:" -ForegroundColor White
Write-Host "     - musica-prueba.mp3   -> DEBE SER BLOQUEADO" -ForegroundColor Red
Write-Host "     - video-prueba.mp4    -> DEBE SER BLOQUEADO" -ForegroundColor Red
Write-Host "     - programa-prueba.exe -> DEBE SER BLOQUEADO" -ForegroundColor Red
Write-Host ""
Write-Host "Para ver eventos de bloqueo en el servidor:" -ForegroundColor Yellow
Write-Host "  Get-WinEvent -LogName 'Microsoft-Windows-FSRM*' | Select -First 20 | Format-List" -ForegroundColor White
Write-Host "  O usa el Visor de Eventos: Aplicacion y Servicios > Microsoft > Windows > FSRM" -ForegroundColor White
