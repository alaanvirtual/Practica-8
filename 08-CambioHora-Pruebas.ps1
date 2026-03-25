# =============================================================================
# SCRIPT 8: Cambio de Hora para Pruebas de LogonHours
# Archivo: 08-CambioHora-Pruebas.ps1
# Ejecutar en: Windows Server 2022 (como Administrador)
# =============================================================================
# ADVERTENCIA: Cambia el reloj del sistema para pruebas.
# Ejecuta Restaurar-Hora al terminar.
# =============================================================================

#Requires -RunAsAdministrator

param(
    [ValidateSet("CuatesDentroHorario","CuatesFueraHorario","NoCuatesDentroHorario",
                 "NoCuatesFueraHorario","Restaurar")]
    [string]$Modo = "CuatesDentroHorario"
)

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "Cyan" }; "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message" -ForegroundColor $color
}

# Guardar hora original antes de cambiarla
$horaOriginalFile = "C:\Scripts\hora-original.txt"
if (-not (Test-Path $horaOriginalFile)) {
    Get-Date | Out-File $horaOriginalFile
    Write-Log "Hora original guardada: $(Get-Date)" "INFO"
}

$fechaHoy = Get-Date -Format "yyyy-MM-dd"

switch ($Modo) {

    "CuatesDentroHorario" {
        # 10:00 AM - dentro del horario de Cuates (8AM-3PM)
        $nuevaHora = "$fechaHoy 10:00:00"
        Set-Date -Date $nuevaHora
        Write-Log "Hora cambiada a: $(Get-Date) | Cuates DENTRO de horario (8AM-3PM)" "OK"
        Write-Log "Los usuarios Cuates PODRAN iniciar sesion" "OK"
        Write-Log "Los usuarios NoCuates NO podran iniciar sesion" "WARN"
    }

    "CuatesFueraHorario" {
        # 4:00 PM - fuera del horario de Cuates, dentro de NoCuates
        $nuevaHora = "$fechaHoy 16:00:00"
        Set-Date -Date $nuevaHora
        Write-Log "Hora cambiada a: $(Get-Date) | Cuates FUERA de horario" "OK"
        Write-Log "Los usuarios Cuates seran DESCONECTADOS si estan activos" "WARN"
        Write-Log "Los usuarios NoCuates PODRAN iniciar sesion" "OK"
    }

    "NoCuatesDentroHorario" {
        # 8:00 PM - dentro del horario de NoCuates (3PM-2AM)
        $nuevaHora = "$fechaHoy 20:00:00"
        Set-Date -Date $nuevaHora
        Write-Log "Hora cambiada a: $(Get-Date) | NoCuates DENTRO de horario (3PM-2AM)" "OK"
        Write-Log "Los usuarios NoCuates PODRAN iniciar sesion" "OK"
        Write-Log "Los usuarios Cuates NO podran iniciar sesion" "WARN"
    }

    "NoCuatesFueraHorario" {
        # 2:30 AM del dia siguiente - fuera del horario de NoCuates
        $manana = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
        $nuevaHora = "$manana 02:30:00"
        Set-Date -Date $nuevaHora
        Write-Log "Hora cambiada a: $(Get-Date) | NoCuates FUERA de horario" "OK"
        Write-Log "Los usuarios NoCuates seran DESCONECTADOS si estan activos" "WARN"
        Write-Log "Ningun grupo tiene acceso en este horario" "WARN"
    }

    "Restaurar" {
        # Sincronizar con servidor NTP para restaurar hora correcta
        Write-Log "Restaurando hora del sistema via NTP..." "INFO"
        
        # Habilitar el cliente W32tm y sincronizar
        w32tm /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:manual /reliable:YES /update | Out-Null
        net stop w32tm 2>$null | Out-Null
        net start w32tm | Out-Null
        w32tm /resync /force | Out-Null
        
        Write-Log "Hora restaurada: $(Get-Date)" "OK"
        
        # Eliminar archivo de hora guardada
        Remove-Item $horaOriginalFile -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Hora actual del servidor: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Magenta
Write-Host ""
Write-Host "Modos disponibles:" -ForegroundColor Yellow
Write-Host "  .\08-CambioHora-Pruebas.ps1 -Modo CuatesDentroHorario    # 10:00 AM" -ForegroundColor White
Write-Host "  .\08-CambioHora-Pruebas.ps1 -Modo CuatesFueraHorario     # 4:00 PM" -ForegroundColor White
Write-Host "  .\08-CambioHora-Pruebas.ps1 -Modo NoCuatesDentroHorario  # 8:00 PM" -ForegroundColor White
Write-Host "  .\08-CambioHora-Pruebas.ps1 -Modo NoCuatesFueraHorario   # 2:30 AM" -ForegroundColor White
Write-Host "  .\08-CambioHora-Pruebas.ps1 -Modo Restaurar              # NTP sync" -ForegroundColor White
