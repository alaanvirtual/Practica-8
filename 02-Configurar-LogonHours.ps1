# =============================================================================
# SCRIPT 2: Control de Acceso Temporal - Logon Hours
# Archivo: 02-Configurar-LogonHours.ps1
# Ejecutar en: Windows Server 2022 (como Administrador)
# =============================================================================
# Cuates:    8:00 AM - 3:00 PM  (lunes a viernes)
# NoCuates:  3:00 PM - 2:00 AM  (lunes a viernes)
# UTC offset: -7 (MST, Los Mochis, Sinaloa — sin cambio de horario de verano)
# =============================================================================

#Requires -RunAsAdministrator
Import-Module ActiveDirectory

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO" { "Cyan" }; "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
    Add-Content -Path "C:\Scripts\Logs\02-LogonHours.log" -Value "[$timestamp][$Level] $Message"
}

# ---------------------------------------------------------------------------
# FUNCION: Convertir horario a byte array de 21 bytes para Set-ADUser
# AD almacena logonHours en UTC. Orden de bits: Dom, Lun, Mar, Mie, Jue, Vie, Sab
# Si HoraFin < HoraInicio el rango cruza la medianoche (ej. NoCuates 15->2)
# ---------------------------------------------------------------------------
function New-LogonHoursByteArray {
    param(
        [int]$HoraInicio,
        [int]$HoraFin,
        [int]$OffsetUTC = -7,   # ✅ CORREGIDO: UTC-7 para Los Mochis (MST permanente)
        [bool[]]$DiasPermitidos = @($false,$true,$true,$true,$true,$true,$false)
    )

    $bits = New-Object bool[] 168

    for ($dia = 0; $dia -lt 7; $dia++) {
        if (-not $DiasPermitidos[$dia]) { continue }

        if ($HoraFin -gt $HoraInicio) {
            $horasLocales = $HoraInicio..($HoraFin - 1)
        } else {
            $horasLocales = @($HoraInicio..23) + @(0..($HoraFin - 1))
        }

        foreach ($horaLocal in $horasLocales) {
            $horaUTC = ($horaLocal - $OffsetUTC) % 24
            if ($horaUTC -lt 0) { $horaUTC += 24 }

            $diaUTC = $dia
            $horaLocalTemp = $horaLocal - $OffsetUTC
            if ($horaLocalTemp -ge 24) { $diaUTC = ($dia + 1) % 7 }
            if ($horaLocalTemp -lt 0)  { $diaUTC = ($dia - 1 + 7) % 7 }

            $bitIndex = ($diaUTC * 24) + $horaUTC
            if ($bitIndex -ge 0 -and $bitIndex -lt 168) {
                $bits[$bitIndex] = $true
            }
        }
    }

    $bytes = New-Object byte[] 21
    for ($i = 0; $i -lt 21; $i++) {
        $byte = 0
        for ($b = 0; $b -lt 8; $b++) {
            if ($bits[$i * 8 + $b]) { $byte = $byte -bor (1 -shl $b) }
        }
        $bytes[$i] = $byte
    }

    return $bytes
}

Write-Log "===== INICIO: Configuracion de Horarios de Acceso =====" "INFO"

$diasSemana = @($false, $true, $true, $true, $true, $true, $false)  # Lun-Vie

# ✅ CORREGIDO: -OffsetUTC -7 en ambas llamadas
Write-Log "Calculando LogonHours para Cuates (8AM-3PM, UTC-7)..." "INFO"
$bytesCuates = New-LogonHoursByteArray -HoraInicio 8 -HoraFin 15 -OffsetUTC -7 -DiasPermitidos $diasSemana
Write-Log "Bytes Cuates: $($bytesCuates -join ',')" "INFO"

Write-Log "Calculando LogonHours para NoCuates (3PM-2AM, UTC-7)..." "INFO"
$bytesNoCuates = New-LogonHoursByteArray -HoraInicio 15 -HoraFin 2 -OffsetUTC -7 -DiasPermitidos $diasSemana
Write-Log "Bytes NoCuates: $($bytesNoCuates -join ',')" "INFO"

# ---------------------------------------------------------------------------
# APLICAR LOGON HOURS — usando Set-ADObject con [byte[]] cast explícito
# Set-ADUser -LogonHours a veces falla con el tipo; Set-ADObject es más confiable
# ---------------------------------------------------------------------------
Write-Log "Aplicando LogonHours a usuarios del grupo GRP_Cuates..." "INFO"

$usuariosCuates = Get-ADGroupMember -Identity "GRP_Cuates" -Recursive |
    Where-Object { $_.objectClass -eq "user" }

foreach ($usr in $usuariosCuates) {
    try {
        $adObj = Get-ADUser -Identity $usr.SamAccountName -Properties DistinguishedName
        Set-ADObject -Identity $adObj.DistinguishedName -Replace @{ logonHours = [byte[]]$bytesCuates }
        Write-Log "  -> $($usr.SamAccountName): LogonHours 8AM-3PM aplicado" "OK"
    }
    catch {
        Write-Log "  -> ERROR en $($usr.SamAccountName): $_" "ERROR"
    }
}

Write-Log "Aplicando LogonHours a usuarios del grupo GRP_NoCuates..." "INFO"

$usuariosNoCuates = Get-ADGroupMember -Identity "GRP_NoCuates" -Recursive |
    Where-Object { $_.objectClass -eq "user" }

foreach ($usr in $usuariosNoCuates) {
    try {
        $adObj = Get-ADUser -Identity $usr.SamAccountName -Properties DistinguishedName
        Set-ADObject -Identity $adObj.DistinguishedName -Replace @{ logonHours = [byte[]]$bytesNoCuates }
        Write-Log "  -> $($usr.SamAccountName): LogonHours 3PM-2AM aplicado" "OK"
    }
    catch {
        Write-Log "  -> ERROR en $($usr.SamAccountName): $_" "ERROR"
    }
}

# ---------------------------------------------------------------------------
# CREAR GPO: Forzar cierre de sesion al vencer el horario
# Equivale a: Computer Config > Windows Settings > Security Settings >
#             Local Policies > Security Options >
#             "Network security: Force logoff when logon hours expire" = Enabled
# ---------------------------------------------------------------------------
Write-Log "Creando GPO para forzar cierre de sesion..." "INFO"

Import-Module GroupPolicy

$GPOName   = "GPO-ForzarCierreSesion"
$domainDN  = (Get-ADDomain).DistinguishedName
$domainFQDN = (Get-ADDomain).DNSRoot

$gpo = Get-GPO -Name $GPOName -ErrorAction SilentlyContinue
if (-not $gpo) {
    $gpo = New-GPO -Name $GPOName -Comment "Fuerza cierre de sesion al vencer LogonHours"
    Write-Log "GPO creada: $GPOName" "OK"
} else {
    Write-Log "GPO ya existe: $GPOName" "WARN"
}

$gpoGuid    = $gpo.Id.ToString()
$gpttmplPath = "\\$domainFQDN\SYSVOL\$domainFQDN\Policies\{$gpoGuid}\Machine\Microsoft\Windows NT\SecEdit"

if (-not (Test-Path $gpttmplPath)) {
    New-Item -ItemType Directory -Path $gpttmplPath -Force | Out-Null
}

$gptContent = @"
[Unicode]
Unicode=yes
[System Access]
ForceLogoffWhenHourExpire = 1
[Version]
signature="`$CHICAGO`$"
Revision=1
"@

$gptFile = Join-Path $gpttmplPath "GptTmpl.inf"
Set-Content -Path $gptFile -Value $gptContent -Encoding Unicode
Write-Log "GptTmpl.inf creado con ForceLogoffWhenHourExpire=1" "OK"

$gptIniPath = "\\$domainFQDN\SYSVOL\$domainFQDN\Policies\{$gpoGuid}\GPT.INI"
if (Test-Path $gptIniPath) {
    $content = Get-Content $gptIniPath
    $content = $content -replace "Version=\d+", "Version=1"
    if ($content -notmatch "gPCMachineExtensionNames") {
        $content += "gPCMachineExtensionNames=[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]"
    }
    Set-Content -Path $gptIniPath -Value $content
}

foreach ($ou in @("OU=Cuates,OU=Practica,$domainDN", "OU=NoCuates,OU=Practica,$domainDN")) {
    try {
        New-GPLink -Name $GPOName -Target $ou -ErrorAction Stop | Out-Null
        Write-Log "GPO vinculada a: $ou" "OK"
    }
    catch {
        if ($_ -match "already linked") {
            Write-Log "GPO ya vinculada a: $ou" "WARN"
        } else {
            Write-Log "Error vinculando GPO a $ou`: $_" "ERROR"
        }
    }
}

Invoke-GPUpdate -Force -RandomDelayInMinutes 0 | Out-Null
Write-Log "Politicas de grupo actualizadas (gpupdate /force)" "OK"

Write-Log "===== FIN: Configuracion de LogonHours completada =====" "OK"
Write-Host ""
Write-Host "SIGUIENTE PASO: Ejecuta 03-Configurar-FSRM.ps1" -ForegroundColor Yellow
Write-Host ""
Write-Host "Para probar LogonHours cambiando la hora del servidor:" -ForegroundColor Magenta
Write-Host "  Set-Date -Date '$(Get-Date -Format yyyy-MM-dd) 15:01:00'  # Cuates fuera de horario" -ForegroundColor White
Write-Host "  Set-Date -Date '$(Get-Date -Format yyyy-MM-dd) 02:01:00'  # NoCuates fuera de horario" -ForegroundColor White
