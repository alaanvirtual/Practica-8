# =============================================================================
# SCRIPT MAESTRO: Ejecutar Todo en Orden
# Archivo: 00-EJECUTAR-TODO.ps1
# Ejecutar en: Windows Server 2022 (como Administrador)
# NOTA: Este script debe ejecutarse DESPUES del primer reinicio del AD
# =============================================================================

#Requires -RunAsAdministrator

param(
    [string]$CSVPath   = "C:\Scripts\usuarios.csv",
    [string]$ServerIP  = "192.168.1.10",   # <-- CAMBIA por la IP del servidor
    [switch]$SoloVerificar
)

function Write-Banner {
    param([string]$Title, [int]$Step = 0)
    Write-Host ""
    Write-Host ("=" * 65) -ForegroundColor Blue
    if ($Step -gt 0) {
        Write-Host ("  PASO $Step: $Title") -ForegroundColor Blue
    } else {
        Write-Host ("  $Title") -ForegroundColor Blue
    }
    Write-Host ("=" * 65) -ForegroundColor Blue
    Write-Host ""
}

Write-Banner "PRACTICA: GPO, FSRM y AppLocker - Windows Server 2022"
Write-Host "Servidor: $env:COMPUTERNAME | Fecha: $(Get-Date)" -ForegroundColor White
Write-Host "CSV de usuarios: $CSVPath" -ForegroundColor White

if ($SoloVerificar) {
    Write-Host "Modo: SOLO VERIFICACION" -ForegroundColor Yellow
    & "C:\Scripts\09-Verificar-Todo.ps1"
    exit
}

# Verificar que los scripts existen
$scripts = @(
    "C:\Scripts\01-Configurar-AD.ps1",
    "C:\Scripts\02-Configurar-LogonHours.ps1",
    "C:\Scripts\03-Configurar-FSRM.ps1",
    "C:\Scripts\04-Configurar-AppLocker.ps1"
)

$faltantes = $scripts | Where-Object { -not (Test-Path $_) }
if ($faltantes) {
    Write-Host "ERROR: Faltan scripts en C:\Scripts\:" -ForegroundColor Red
    $faltantes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "Asegurate de copiar todos los scripts a C:\Scripts\" -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
Write-Banner "Paso 1: Active Directory - UOs y Usuarios" 1
& "C:\Scripts\01-Configurar-AD.ps1" -CSVPath $CSVPath

# ---------------------------------------------------------------------------
Write-Banner "Paso 2: Horarios de Acceso (LogonHours)" 2
& "C:\Scripts\02-Configurar-LogonHours.ps1"

# ---------------------------------------------------------------------------
Write-Banner "Paso 3: FSRM - Cuotas y Apantallamiento" 3
& "C:\Scripts\03-Configurar-FSRM.ps1"

# ---------------------------------------------------------------------------
Write-Banner "Paso 4: AppLocker - Control de Ejecucion" 4
& "C:\Scripts\04-Configurar-AppLocker.ps1"

# ---------------------------------------------------------------------------
Write-Banner "Paso 5: Generar Archivos de Prueba" 5
& "C:\Scripts\10-Generar-ArchivoPrueba.ps1"

# ---------------------------------------------------------------------------
Write-Banner "Paso 6: Verificacion Final" 6
& "C:\Scripts\09-Verificar-Todo.ps1"

# ---------------------------------------------------------------------------
Write-Banner "CONFIGURACION COMPLETADA"
Write-Host "Revisa C:\Scripts\Logs\ para los reportes completos." -ForegroundColor Green
Write-Host ""
Write-Host "Proximos pasos:" -ForegroundColor Yellow
Write-Host "  1. En Cliente Windows 10: copia y ejecuta 05-Union-Windows.ps1" -ForegroundColor White
Write-Host "  2. Tras reinicio del cliente: ejecuta 06-PostUnion-Windows.ps1" -ForegroundColor White
Write-Host "  3. En Linux Mint: ejecuta  sudo bash 07-Union-Linux.sh" -ForegroundColor White
Write-Host "  4. Para pruebas de horario: .\08-CambioHora-Pruebas.ps1 -Modo CuatesFueraHorario" -ForegroundColor White
