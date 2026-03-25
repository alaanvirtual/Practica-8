# =============================================================================
# SCRIPT 9: Verificacion Completa del Sistema
# Archivo: 09-Verificar-Todo.ps1
# Ejecutar en: Windows Server 2022 (como Administrador)
# =============================================================================

#Requires -RunAsAdministrator
Import-Module ActiveDirectory
Import-Module GroupPolicy
Import-Module FileServerResourceManager -ErrorAction SilentlyContinue

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $color = switch ($Level) {
        "INFO" { "White" }; "OK" { "Green" }; "WARN" { "Yellow" }; "ERROR" { "Red" }
        "HEAD" { "Cyan" }
        default { "White" }
    }
    Write-Host $Message -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

# Preparar reporte
$reportPath = "C:\Scripts\Logs\Verificacion-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
Start-Transcript -Path $reportPath -Append

Write-Section "REPORTE DE VERIFICACION - PRACTICA GPO/FSRM"
Write-Log "Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO"
Write-Log "Servidor: $env:COMPUTERNAME" "INFO"

# ---------------------------------------------------------------------------
# 1. ESTRUCTURA DE AD
# ---------------------------------------------------------------------------
Write-Section "1. ESTRUCTURA DE ACTIVE DIRECTORY"

$domainDN = (Get-ADDomain).DistinguishedName
$domainFQDN = (Get-ADDomain).DNSRoot

# Verificar UOs
$ous = @("OU=Practica,$domainDN", "OU=Cuates,OU=Practica,$domainDN", "OU=NoCuates,OU=Practica,$domainDN")
foreach ($ou in $ous) {
    try {
        $ouObj = Get-ADOrganizationalUnit -Identity $ou
        Write-Log "  [OK] OU existe: $($ouObj.Name)" "OK"
    } catch {
        Write-Log "  [X]  OU NO existe: $ou" "ERROR"
    }
}

# Verificar grupos
foreach ($grupo in @("GRP_Cuates", "GRP_NoCuates")) {
    try {
        $grp = Get-ADGroup -Identity $grupo
        $miembros = (Get-ADGroupMember -Identity $grupo).Count
        Write-Log "  [OK] Grupo: $grupo | Miembros: $miembros" "OK"
    } catch {
        Write-Log "  [X]  Grupo NO existe: $grupo" "ERROR"
    }
}

# Verificar usuarios
Write-Log "" "INFO"
Write-Log "  Usuarios en GRP_Cuates:" "HEAD"
Get-ADGroupMember -Identity "GRP_Cuates" -Recursive | Where-Object { $_.objectClass -eq "user" } | ForEach-Object {
    $usr = Get-ADUser -Identity $_.SamAccountName -Properties Department,LogonHours,HomeDirectory
    $tieneHorario = $null -ne $usr.LogonHours
    Write-Log "    - $($usr.SamAccountName) | Dept: $($usr.Department) | LogonHours: $(if($tieneHorario){'Configurado'}else{'Sin configurar'})" "INFO"
}

Write-Log "" "INFO"
Write-Log "  Usuarios en GRP_NoCuates:" "HEAD"
Get-ADGroupMember -Identity "GRP_NoCuates" -Recursive | Where-Object { $_.objectClass -eq "user" } | ForEach-Object {
    $usr = Get-ADUser -Identity $_.SamAccountName -Properties Department,LogonHours,HomeDirectory
    $tieneHorario = $null -ne $usr.LogonHours
    Write-Log "    - $($usr.SamAccountName) | Dept: $($usr.Department) | LogonHours: $(if($tieneHorario){'Configurado'}else{'Sin configurar'})" "INFO"
}

# ---------------------------------------------------------------------------
# 2. LOGON HOURS
# ---------------------------------------------------------------------------
Write-Section "2. LOGON HOURS (HORARIOS DE ACCESO)"

Write-Log "  Verificando LogonHours de un usuario Cuates..." "HEAD"
$usrCuates = Get-ADGroupMember -Identity "GRP_Cuates" -Recursive | Where-Object { $_.objectClass -eq "user" } | Select-Object -First 1
if ($usrCuates) {
    $u = Get-ADUser -Identity $usrCuates.SamAccountName -Properties LogonHours
    if ($u.LogonHours) {
        Write-Log "  [OK] $($u.SamAccountName) tiene LogonHours configurado (21 bytes)" "OK"
        Write-Log "       Bytes: $($u.LogonHours -join ',')" "INFO"
    } else {
        Write-Log "  [X]  $($u.SamAccountName) NO tiene LogonHours" "ERROR"
    }
}

Write-Log "  Verificando GPO de ForceLogoff..." "HEAD"
$gpoLogoff = Get-GPO -Name "GPO-ForzarCierreSesion" -ErrorAction SilentlyContinue
if ($gpoLogoff) {
    Write-Log "  [OK] GPO 'GPO-ForzarCierreSesion' existe" "OK"
    $links = Get-GPInheritance -Target "OU=Cuates,OU=Practica,$domainDN" -ErrorAction SilentlyContinue
    if ($links) {
        Write-Log "  [OK] GPO vinculada a UOs" "OK"
    }
} else {
    Write-Log "  [X]  GPO 'GPO-ForzarCierreSesion' NO existe" "ERROR"
}

# ---------------------------------------------------------------------------
# 3. FSRM - CUOTAS
# ---------------------------------------------------------------------------
Write-Section "3. FSRM - CUOTAS DE DISCO"

try {
    $cuotas = Get-FsrmQuota -ErrorAction Stop
    Write-Log "  Total de cuotas configuradas: $($cuotas.Count)" "INFO"
    Write-Log "" "INFO"

    foreach ($cuota in $cuotas | Sort-Object Path) {
        $limiteMB = [math]::Round($cuota.Size / 1MB, 0)
        $usoKB    = [math]::Round($cuota.Usage / 1KB, 0)
        $usoPct   = if ($cuota.Size -gt 0) { [math]::Round(($cuota.Usage / $cuota.Size) * 100, 1) } else { 0 }
        $usuario  = Split-Path $cuota.Path -Leaf

        $color = if ($limiteMB -eq 10) { "OK" } elseif ($limiteMB -eq 5) { "WARN" } else { "INFO" }
        Write-Log "  [OK] $usuario -> Limite: ${limiteMB}MB | Uso: ${usoKB}KB (${usoPct}%) | Soft: $($cuota.SoftLimit)" $color
    }
} catch {
    Write-Log "  [X]  Error al obtener cuotas FSRM: $_" "ERROR"
    Write-Log "       Verifica que FSRM este instalado" "WARN"
}

# ---------------------------------------------------------------------------
# 4. FSRM - APANTALLAMIENTO
# ---------------------------------------------------------------------------
Write-Section "4. FSRM - APANTALLAMIENTO DE ARCHIVOS"

try {
    $screens = Get-FsrmFileScreen -ErrorAction Stop
    Write-Log "  Total de apantallamientos: $($screens.Count)" "INFO"
    foreach ($screen in $screens | Sort-Object Path) {
        $usuario = Split-Path $screen.Path -Leaf
        Write-Log "  [OK] $usuario -> Activo: $($screen.Active) | Grupos: $($screen.IncludeGroup -join ', ')" "OK"
    }

    # Verificar grupo de archivos
    $fg = Get-FsrmFileGroup -Name "Archivos-Bloqueados-Practica" -ErrorAction SilentlyContinue
    if ($fg) {
        Write-Log "" "INFO"
        Write-Log "  [OK] Grupo de archivos bloqueados existe" "OK"
        Write-Log "       Extensiones: $($fg.IncludePattern -join ', ')" "INFO"
    } else {
        Write-Log "  [X]  Grupo 'Archivos-Bloqueados-Practica' NO existe" "ERROR"
    }
} catch {
    Write-Log "  [X]  Error al verificar apantallamiento: $_" "ERROR"
}

# ---------------------------------------------------------------------------
# 5. APPLOCKER
# ---------------------------------------------------------------------------
Write-Section "5. APPLOCKER - CONTROL DE EJECUCION"

$gpoCuates   = Get-GPO -Name "GPO-AppLocker-Cuates" -ErrorAction SilentlyContinue
$gpoNoCuates = Get-GPO -Name "GPO-AppLocker-NoCuates" -ErrorAction SilentlyContinue

if ($gpoCuates)   { Write-Log "  [OK] GPO AppLocker Cuates existe" "OK" }
else              { Write-Log "  [X]  GPO AppLocker Cuates NO existe" "ERROR" }

if ($gpoNoCuates) { Write-Log "  [OK] GPO AppLocker NoCuates existe" "OK" }
else              { Write-Log "  [X]  GPO AppLocker NoCuates NO existe" "ERROR" }

# Verificar servicio AppID
$svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
if ($svc) {
    $colorSvc = if ($svc.Status -eq "Running") { "OK" } else { "WARN" }
    Write-Log "  Servicio AppIDSvc: Estado=$($svc.Status) | Inicio=$($svc.StartType)" $colorSvc
} else {
    Write-Log "  [X]  Servicio AppIDSvc no encontrado" "ERROR"
}

# Hash de notepad
if (Test-Path "C:\Scripts\notepad-hash.txt") {
    Write-Log "" "INFO"
    Write-Log "  Hash de notepad.exe (para referencia de bloqueo):" "HEAD"
    Get-Content "C:\Scripts\notepad-hash.txt" | ForEach-Object { Write-Log "    $_" "INFO" }
}

# ---------------------------------------------------------------------------
# 6. RESUMEN
# ---------------------------------------------------------------------------
Write-Section "RESUMEN Y PROXIMOS PASOS"

Write-Log "  Para probar FSRM (cuotas):" "HEAD"
Write-Log "    1. Inicia sesion como jgarcia (Cuates) en cliente Windows" "INFO"
Write-Log "    2. Intenta copiar un archivo de 11MB a H:\ -> Debe ser RECHAZADO" "INFO"
Write-Log "    3. Inicia sesion como sperez (NoCuates)" "INFO"
Write-Log "    4. Intenta copiar un archivo de 6MB a H:\ -> Debe ser RECHAZADO" "INFO"
Write-Log "" "INFO"
Write-Log "  Para probar FSRM (apantallamiento):" "HEAD"
Write-Log "    1. Intenta copiar cancion.mp3 a H:\ -> Debe ser RECHAZADO" "INFO"
Write-Log "    2. Intenta copiar programa.exe a H:\ -> Debe ser RECHAZADO" "INFO"
Write-Log "" "INFO"
Write-Log "  Para probar AppLocker:" "HEAD"
Write-Log "    1. Como jgarcia (Cuates): notepad.exe -> FUNCIONA" "INFO"
Write-Log "    2. Como sperez (NoCuates): notepad.exe -> BLOQUEADO" "INFO"
Write-Log "    3. Como sperez: renombra notepad.exe -> sigue BLOQUEADO" "INFO"
Write-Log "" "INFO"
Write-Log "  Para probar LogonHours:" "HEAD"
Write-Log "    1. .\08-CambioHora-Pruebas.ps1 -Modo CuatesFueraHorario" "INFO"
Write-Log "    2. Espera 1-5 min -> jgarcia debe ser desconectado" "INFO"
Write-Log "    3. .\08-CambioHora-Pruebas.ps1 -Modo Restaurar" "INFO"

Write-Log "" "INFO"
Write-Log "Reporte guardado en: $reportPath" "INFO"

Stop-Transcript
