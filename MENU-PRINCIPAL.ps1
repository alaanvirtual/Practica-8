# =============================================================================
# MENU PRINCIPAL - Practica GPO/FSRM/AppLocker
# Archivo: MENU-Principal.ps1
# Ejecutar en: Windows Server 2022 (como Administrador)
# =============================================================================
# Contiene TODOS los scripts embebidos. Solo necesitas este archivo.
# =============================================================================

#Requires -RunAsAdministrator

# ---------------------------------------------------------------------------
# VARIABLES GLOBALES - MODIFICA SEGUN TU ENTORNO
# ---------------------------------------------------------------------------
$global:DomainName    = "practica.local"
$global:DomainNetBIOS = "PRACTICA"
$global:SafePassword  = "Admin@12345"
$global:CSVPath       = "C:\Scripts\usuarios.csv"
$global:LogDir        = "C:\Scripts\Logs"
$global:UsuariosDir   = "C:\Usuarios"

# ---------------------------------------------------------------------------
# FUNCION DE LOG COMPARTIDA
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO", [string]$LogFile = "menu.log")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Cyan" }
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "HEAD"  { "Magenta" }
        default { "White" }
    }
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
    if (-not (Test-Path $global:LogDir)) { New-Item -ItemType Directory -Path $global:LogDir -Force | Out-Null }
    Add-Content -Path "$global:LogDir\$LogFile" -Value "[$timestamp][$Level] $Message"
}

function Write-Banner {
    param([string]$Titulo, [string]$Color = "Cyan")
    $linea = "=" * 65
    Write-Host ""
    Write-Host $linea -ForegroundColor $Color
    Write-Host "  $Titulo" -ForegroundColor $Color
    Write-Host $linea -ForegroundColor $Color
    Write-Host ""
}

function Pause-Menu {
    Write-Host ""
    Write-Host "Presiona ENTER para volver al menu..." -ForegroundColor Gray
    Read-Host | Out-Null
}

# ===========================================================================
# FUNCION 1: CONFIGURAR ACTIVE DIRECTORY
# ===========================================================================
function Invoke-ConfigurarAD {
    Write-Banner "PASO 1: Configurar Active Directory" "Blue"
    Write-Log "===== INICIO: Configuracion de Active Directory =====" "INFO" "01-AD.log"

    if (-not (Test-Path $global:LogDir)) { New-Item -ItemType Directory -Path $global:LogDir -Force | Out-Null }
    if (-not (Test-Path $global:UsuariosDir)) { New-Item -ItemType Directory -Path $global:UsuariosDir -Force | Out-Null }

    # Verificar e instalar AD DS
    if (-not (Get-WindowsFeature -Name AD-Domain-Services).Installed) {
        Write-Log "Instalando Active Directory Domain Services..." "INFO" "01-AD.log"
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
        Write-Log "AD DS instalado." "OK" "01-AD.log"
    }

    # Verificar si el dominio ya existe
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        Write-Log "El dominio $($domain.DNSRoot) ya existe. Saltando promocion." "WARN" "01-AD.log"
    }
    catch {
        Write-Log "Promoviendo servidor como Controlador de Dominio: $global:DomainName" "INFO" "01-AD.log"
        $securePass = ConvertTo-SecureString $global:SafePassword -AsPlainText -Force
        Install-ADDSForest `
            -DomainName                    $global:DomainName `
            -DomainNetbiosName             $global:DomainNetBIOS `
            -SafeModeAdministratorPassword $securePass `
            -InstallDns `
            -Force `
            -NoRebootOnCompletion
        Write-Log "Dominio creado. El servidor se reiniciara." "OK" "01-AD.log"
        Write-Log "Vuelve a ejecutar el menu despues del reinicio." "WARN" "01-AD.log"
        Start-Sleep -Seconds 5
        Restart-Computer -Force
        exit
    }

    Import-Module ActiveDirectory

    # --- UOs ---
    Write-Log "Creando Unidades Organizativas..." "INFO" "01-AD.log"
    $domainDN = (Get-ADDomain).DistinguishedName
    $UOs = @(
        @{ Name = "Practica"; Path = $domainDN },
        @{ Name = "Cuates";   Path = "OU=Practica,$domainDN" },
        @{ Name = "NoCuates"; Path = "OU=Practica,$domainDN" },
        @{ Name = "Equipos";  Path = "OU=Practica,$domainDN" }
    )
    foreach ($ou in $UOs) {
        $ouDN = "OU=$($ou.Name),$($ou.Path)"
        try {
            Get-ADOrganizationalUnit -Identity $ouDN -ErrorAction Stop | Out-Null
            Write-Log "OU ya existe: $($ou.Name)" "WARN" "01-AD.log"
        } catch {
            New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path -ProtectedFromAccidentalDeletion $false
            Write-Log "OU creada: $($ou.Name)" "OK" "01-AD.log"
        }
    }

    # --- Grupos ---
    Write-Log "Creando grupos de seguridad..." "INFO" "01-AD.log"
    $grupos = @(
        @{ Name = "GRP_Cuates";   OU = "OU=Cuates,OU=Practica,$domainDN";   Desc = "Grupo Cuates - Acceso 8AM a 3PM" },
        @{ Name = "GRP_NoCuates"; OU = "OU=NoCuates,OU=Practica,$domainDN"; Desc = "Grupo NoCuates - Acceso 3PM a 2AM" }
    )
    foreach ($grp in $grupos) {
        try {
            Get-ADGroup -Identity $grp.Name -ErrorAction Stop | Out-Null
            Write-Log "Grupo ya existe: $($grp.Name)" "WARN" "01-AD.log"
        } catch {
            New-ADGroup -Name $grp.Name -GroupScope Global -GroupCategory Security `
                        -Path $grp.OU -Description $grp.Desc
            Write-Log "Grupo creado: $($grp.Name)" "OK" "01-AD.log"
        }
    }

    # --- Usuarios desde CSV ---
    Write-Log "Leyendo CSV: $global:CSVPath" "INFO" "01-AD.log"
    if (-not (Test-Path $global:CSVPath)) {
        Write-Log "ERROR: No se encontro el CSV en $global:CSVPath" "ERROR" "01-AD.log"
        Pause-Menu; return
    }

    $usuarios = Import-Csv -Path $global:CSVPath
    foreach ($u in $usuarios) {
        $dept   = $u.Departamento.Trim()
        $ouPath = if ($dept -eq "Cuates") { "OU=Cuates,OU=Practica,$domainDN" } else { "OU=NoCuates,OU=Practica,$domainDN" }
        $secPass = ConvertTo-SecureString $u.Contrasena -AsPlainText -Force
        $upn     = "$($u.Usuario)@$global:DomainName"

        try {
            Get-ADUser -Identity $u.Usuario -ErrorAction Stop | Out-Null
            Write-Log "Usuario ya existe: $($u.Usuario)" "WARN" "01-AD.log"
        } catch {
            New-ADUser `
                -Name              "$($u.Nombre) $($u.Apellido)" `
                -GivenName         $u.Nombre `
                -Surname           $u.Apellido `
                -SamAccountName    $u.Usuario `
                -UserPrincipalName $upn `
                -EmailAddress      $u.Email `
                -Department        $dept `
                -Path              $ouPath `
                -AccountPassword   $secPass `
                -Enabled           $true `
                -PasswordNeverExpires $true `
                -ChangePasswordAtLogon $false
            Write-Log "Usuario creado: $($u.Usuario) -> OU: $dept" "OK" "01-AD.log"
        }

        $grupo = if ($dept -eq "Cuates") { "GRP_Cuates" } else { "GRP_NoCuates" }
        try {
            Add-ADGroupMember -Identity $grupo -Members $u.Usuario -ErrorAction Stop
            Write-Log "  -> Agregado a $grupo" "OK" "01-AD.log"
        } catch {
            Write-Log "  -> Ya pertenece a $grupo o error: $_" "WARN" "01-AD.log"
        }

        # Carpeta personal
        $homePath = "$global:UsuariosDir\$($u.Usuario)"
        if (-not (Test-Path $homePath)) {
            New-Item -ItemType Directory -Path $homePath -Force | Out-Null
            $acl = Get-Acl $homePath
            $acl.SetAccessRuleProtection($true, $false)
            $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow")
            $userRule  = New-Object System.Security.AccessControl.FileSystemAccessRule("$global:DomainNetBIOS\$($u.Usuario)","Modify","ContainerInherit,ObjectInherit","None","Allow")
            $acl.AddAccessRule($adminRule)
            $acl.AddAccessRule($userRule)
            Set-Acl -Path $homePath -AclObject $acl
            Write-Log "  -> Carpeta creada: $homePath" "OK" "01-AD.log"
        }

        Set-ADUser -Identity $u.Usuario `
            -HomeDirectory "\\$env:COMPUTERNAME\Usuarios\$($u.Usuario)" `
            -HomeDrive "H:"
    }

    # Recurso compartido
    if (-not (Get-SmbShare -Name "Usuarios" -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name "Usuarios" -Path $global:UsuariosDir `
                     -FullAccess "Administrators" -ReadAccess "Everyone" | Out-Null
        Write-Log "Recurso compartido 'Usuarios' creado." "OK" "01-AD.log"
    }

    Write-Log "===== FIN: Configuracion de AD completada =====" "OK" "01-AD.log"
    Pause-Menu
}

# ===========================================================================
# FUNCION 2: CONFIGURAR LOGON HOURS
# ===========================================================================
function New-LogonHoursByteArray {
    param(
        [int]$HoraInicio,
        [int]$HoraFin,
        [int]$OffsetUTC = -6,
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
            $horaUTC      = ($horaLocal - $OffsetUTC) % 24
            if ($horaUTC -lt 0) { $horaUTC += 24 }
            $diaUTC       = $dia
            $horaLocalTemp = $horaLocal - $OffsetUTC
            if ($horaLocalTemp -ge 24) { $diaUTC = ($dia + 1) % 7 }
            if ($horaLocalTemp -lt 0)  { $diaUTC = ($dia - 1 + 7) % 7 }
            $bitIndex = ($diaUTC * 24) + $horaUTC
            if ($bitIndex -ge 0 -and $bitIndex -lt 168) { $bits[$bitIndex] = $true }
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

function Invoke-ConfigurarLogonHours {
    Write-Banner "PASO 2: Configurar Horarios de Acceso (LogonHours)" "Blue"
    Write-Log "===== INICIO: Configuracion de Horarios de Acceso =====" "INFO" "02-LogonHours.log"

    Import-Module ActiveDirectory
    Import-Module GroupPolicy

    $diasSemana = @($false, $true, $true, $true, $true, $true, $false)

    Write-Log "Calculando LogonHours para Cuates (8AM-3PM Local)..." "INFO" "02-LogonHours.log"
    $bytesCuates = New-LogonHoursByteArray -HoraInicio 8 -HoraFin 15 -OffsetUTC -7 -DiasPermitidos $diasSemana
    Write-Log "Bytes Cuates: $($bytesCuates -join ',')" "INFO" "02-LogonHours.log"

    Write-Log "Calculando LogonHours para NoCuates (3PM-2AM Local)..." "INFO" "02-LogonHours.log"
    $bytesNoCuates = New-LogonHoursByteArray -HoraInicio 15 -HoraFin 2 -OffsetUTC -7 -DiasPermitidos $diasSemana
    Write-Log "Bytes NoCuates: $($bytesNoCuates -join ',')" "INFO" "02-LogonHours.log"

    # --- Cuates ---
    Write-Log "Aplicando LogonHours a usuarios del grupo Cuates..." "INFO" "02-LogonHours.log"
    $usuariosCuates = Get-ADGroupMember -Identity "GRP_Cuates" -Recursive |
        Where-Object { $_.objectClass -eq "user" }

    foreach ($usr in $usuariosCuates) {
        try {
            $adObj = Get-ADUser -Identity $usr.SamAccountName -Properties DistinguishedName
            Set-ADObject -Identity $adObj.DistinguishedName -Replace @{logonHours = [byte[]]$bytesCuates}
            Write-Log "  -> $($usr.SamAccountName): LogonHours 8AM-3PM aplicado" "OK" "02-LogonHours.log"
        } catch {
            Write-Log "  -> ERROR en $($usr.SamAccountName): $_" "ERROR" "02-LogonHours.log"
        }
    }

    # --- NoCuates ---
    Write-Log "Aplicando LogonHours a usuarios del grupo NoCuates..." "INFO" "02-LogonHours.log"
    $usuariosNoCuates = Get-ADGroupMember -Identity "GRP_NoCuates" -Recursive |
        Where-Object { $_.objectClass -eq "user" }

    foreach ($usr in $usuariosNoCuates) {
        try {
            $adObj = Get-ADUser -Identity $usr.SamAccountName -Properties DistinguishedName
            Set-ADObject -Identity $adObj.DistinguishedName -Replace @{logonHours = [byte[]]$bytesNoCuates}
            Write-Log "  -> $($usr.SamAccountName): LogonHours 3PM-2AM aplicado" "OK" "02-LogonHours.log"
        } catch {
            Write-Log "  -> ERROR en $($usr.SamAccountName): $_" "ERROR" "02-LogonHours.log"
        }
    }

    # --- GPO ForceLogoff ---
    Write-Log "Creando GPO para forzar cierre de sesion..." "INFO" "02-LogonHours.log"
    $GPOName    = "GPO-ForzarCierreSesion"
    $domainDN   = (Get-ADDomain).DistinguishedName
    $domainFQDN = (Get-ADDomain).DNSRoot

    $gpo = Get-GPO -Name $GPOName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $GPOName -Comment "Fuerza cierre de sesion al vencer LogonHours"
        Write-Log "GPO creada: $GPOName" "OK" "02-LogonHours.log"
    } else {
        Write-Log "GPO ya existe: $GPOName" "WARN" "02-LogonHours.log"
    }

    $gpoGuid     = $gpo.Id.ToString()
    $gpttmplPath = "\\$domainFQDN\SYSVOL\$domainFQDN\Policies\{$gpoGuid}\Machine\Microsoft\Windows NT\SecEdit"
    if (-not (Test-Path $gpttmplPath)) { New-Item -ItemType Directory -Path $gpttmplPath -Force | Out-Null }

    $gptContent = @"
[Unicode]
Unicode=yes
[System Access]
ForceLogoffWhenHourExpire = 1
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
    Set-Content -Path "$gpttmplPath\GptTmpl.inf" -Value $gptContent -Encoding Unicode
    Write-Log "GptTmpl.inf creado con ForceLogoffWhenHourExpire=1" "OK" "02-LogonHours.log"

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
            Write-Log "GPO vinculada a: $ou" "OK" "02-LogonHours.log"
        } catch {
            if ($_ -match "already linked") {
                Write-Log "GPO ya vinculada a: $ou" "WARN" "02-LogonHours.log"
            } else {
                Write-Log "Error vinculando GPO a $ou`: $_" "ERROR" "02-LogonHours.log"
            }
        }
    }

    Invoke-GPUpdate -Force -RandomDelayInMinutes 0 | Out-Null
    Write-Log "Politicas actualizadas (gpupdate /force)" "OK" "02-LogonHours.log"
    Write-Log "===== FIN: Configuracion de LogonHours completada =====" "OK" "02-LogonHours.log"
    Pause-Menu
}

# ===========================================================================
# FUNCION 3: CONFIGURAR FSRM
# ===========================================================================
function Invoke-ConfigurarFSRM {
    Write-Banner "PASO 3: Configurar FSRM - Cuotas y Apantallamiento" "Blue"
    Write-Log "===== INICIO: Configuracion FSRM =====" "INFO" "03-FSRM.log"

    # Instalar FSRM
    if (-not (Get-WindowsFeature -Name FS-Resource-Manager).Installed) {
        Write-Log "Instalando FSRM..." "INFO" "03-FSRM.log"
        Install-WindowsFeature -Name FS-Resource-Manager -IncludeManagementTools | Out-Null
        Write-Log "FSRM instalado." "OK" "03-FSRM.log"
    } else {
        Write-Log "FSRM ya esta instalado." "WARN" "03-FSRM.log"
    }

    Import-Module FileServerResourceManager
    Import-Module ActiveDirectory

    # --- Acciones y umbrales ---
    $accionEvento80  = New-FsrmAction -Type Event -EventType Warning `
        -Body "El usuario [Source Io Owner] ha alcanzado el 80% de su cuota en [Quota Path]."
    $accionEvento100 = New-FsrmAction -Type Event -EventType Error `
        -Body "LIMITE ALCANZADO: [Source Io Owner] supero la cuota en [Quota Path]."
    $umbral80  = New-FsrmQuotaThreshold -Percentage 80  -Action $accionEvento80
    $umbral100 = New-FsrmQuotaThreshold -Percentage 100 -Action $accionEvento100

    # --- Plantillas de cuota ---
    # Plantilla 10MB - Cuates (Hard Limit)
    try {
        Get-FsrmQuotaTemplate -Name "Cuota-10MB-Cuates" -ErrorAction Stop | Out-Null
        Set-FsrmQuotaTemplate -Name "Cuota-10MB-Cuates" -Size 10MB -Threshold @($umbral80, $umbral100)
        Write-Log "Plantilla actualizada: Cuota-10MB-Cuates" "WARN" "03-FSRM.log"
    } catch {
        New-FsrmQuotaTemplate -Name "Cuota-10MB-Cuates" -Size 10MB -Threshold @($umbral80, $umbral100) | Out-Null
        Write-Log "Plantilla creada: Cuota-10MB-Cuates (10MB Hard Limit)" "OK" "03-FSRM.log"
    }

    # Plantilla 5MB - NoCuates (Hard Limit)
    try {
        Get-FsrmQuotaTemplate -Name "Cuota-5MB-NoCuates" -ErrorAction Stop | Out-Null
        Set-FsrmQuotaTemplate -Name "Cuota-5MB-NoCuates" -Size 5MB -Threshold @($umbral80, $umbral100)
        Write-Log "Plantilla actualizada: Cuota-5MB-NoCuates" "WARN" "03-FSRM.log"
    } catch {
        New-FsrmQuotaTemplate -Name "Cuota-5MB-NoCuates" -Size 5MB -Threshold @($umbral80, $umbral100) | Out-Null
        Write-Log "Plantilla creada: Cuota-5MB-NoCuates (5MB Hard Limit)" "OK" "03-FSRM.log"
    }

    # --- Asignar cuotas ---
    $domainDN = (Get-ADDomain).DistinguishedName

    foreach ($entry in @(
        @{ Grupo = "GRP_Cuates";   Template = "Cuota-10MB-Cuates"  },
        @{ Grupo = "GRP_NoCuates"; Template = "Cuota-5MB-NoCuates" }
    )) {
        $miembros = Get-ADGroupMember -Identity $entry.Grupo -Recursive | Where-Object { $_.objectClass -eq "user" }
        foreach ($usr in $miembros) {
            $carpeta = "$global:UsuariosDir\$($usr.SamAccountName)"
            if (-not (Test-Path $carpeta)) { New-Item -ItemType Directory -Path $carpeta -Force | Out-Null }
            try {
                Get-FsrmQuota -Path $carpeta -ErrorAction Stop | Out-Null
                Set-FsrmQuota -Path $carpeta -Template $entry.Template
                Write-Log "  Cuota actualizada ($($entry.Template)): $($usr.SamAccountName)" "OK" "03-FSRM.log"
            } catch {
                New-FsrmQuota -Path $carpeta -Template $entry.Template | Out-Null
                Write-Log "  Cuota asignada ($($entry.Template)): $($usr.SamAccountName)" "OK" "03-FSRM.log"
            }
        }
    }

    # --- Grupo de archivos bloqueados ---
    $fileGroupName = "Archivos-Bloqueados-Practica"
    $extensiones   = @("*.mp3","*.mp4","*.avi","*.mkv","*.mov","*.wmv","*.flac","*.wav","*.exe","*.msi","*.bat","*.cmd","*.com","*.scr","*.pif")
    try {
        Get-FsrmFileGroup -Name $fileGroupName -ErrorAction Stop | Out-Null
        Set-FsrmFileGroup -Name $fileGroupName -IncludePattern $extensiones
        Write-Log "Grupo de archivos actualizado: $fileGroupName" "WARN" "03-FSRM.log"
    } catch {
        New-FsrmFileGroup -Name $fileGroupName -IncludePattern $extensiones | Out-Null
        Write-Log "Grupo de archivos creado: $fileGroupName" "OK" "03-FSRM.log"
    }

    # --- Plantilla de apantallamiento ---
    $screenTpl    = "Pantalla-Multimedia-Ejecutables"
    $accionBloqueo = New-FsrmAction -Type Event -EventType Warning `
        -Body "ARCHIVO BLOQUEADO: [Source Io Owner] intento guardar '[Source File Path]' en [File Screen Path]."
    try {
        Get-FsrmFileScreenTemplate -Name $screenTpl -ErrorAction Stop | Out-Null
        Set-FsrmFileScreenTemplate -Name $screenTpl -Active -IncludeGroup @($fileGroupName) -Notification @($accionBloqueo)
        Write-Log "Plantilla apantallamiento actualizada: $screenTpl" "WARN" "03-FSRM.log"
    } catch {
        New-FsrmFileScreenTemplate -Name $screenTpl -Active -IncludeGroup @($fileGroupName) -Notification @($accionBloqueo) | Out-Null
        Write-Log "Plantilla apantallamiento creada: $screenTpl" "OK" "03-FSRM.log"
    }

    # --- Aplicar apantallamiento a todas las carpetas ---
    $todos = @()
    $todos += Get-ADGroupMember -Identity "GRP_Cuates"   -Recursive | Where-Object { $_.objectClass -eq "user" }
    $todos += Get-ADGroupMember -Identity "GRP_NoCuates" -Recursive | Where-Object { $_.objectClass -eq "user" }

    foreach ($usr in $todos) {
        $carpeta = "$global:UsuariosDir\$($usr.SamAccountName)"
        if (Test-Path $carpeta) {
            try {
                Get-FsrmFileScreen -Path $carpeta -ErrorAction Stop | Out-Null
                Set-FsrmFileScreen -Path $carpeta -Template $screenTpl -Active
                Write-Log "  Apantallamiento actualizado: $($usr.SamAccountName)" "OK" "03-FSRM.log"
            } catch {
                New-FsrmFileScreen -Path $carpeta -Template $screenTpl -Active | Out-Null
                Write-Log "  Apantallamiento aplicado: $($usr.SamAccountName)" "OK" "03-FSRM.log"
            }
        }
    }

    # Verificacion rapida
    Write-Log "" "INFO" "03-FSRM.log"
    Write-Log "Cuotas configuradas:" "HEAD" "03-FSRM.log"
    Get-FsrmQuota | ForEach-Object {
        Write-Log "  $($_.Path) -> $([math]::Round($_.Size/1MB,0)) MB" "INFO" "03-FSRM.log"
    }

    Write-Log "===== FIN: FSRM configurado correctamente =====" "OK" "03-FSRM.log"
    Pause-Menu
}

# ===========================================================================
# FUNCION 4: CONFIGURAR APPLOCKER
# ===========================================================================
function Invoke-ConfigurarAppLocker {
    Write-Banner "PASO 4: Configurar AppLocker" "Blue"
    Write-Log "===== INICIO: Configuracion AppLocker =====" "INFO" "04-AppLocker.log"

    Import-Module GroupPolicy
    Import-Module ActiveDirectory

    $notepadPath = "$env:SystemRoot\System32\notepad.exe"
    if (-not (Test-Path $notepadPath)) {
        Write-Log "ERROR: notepad.exe no encontrado." "ERROR" "04-AppLocker.log"
        Pause-Menu; return
    }

    $hashSHA256  = (Get-FileHash -Path $notepadPath -Algorithm SHA256).Hash
    $notepadSize = (Get-Item $notepadPath).Length
    Write-Log "Hash SHA256 de notepad.exe: $hashSHA256" "INFO" "04-AppLocker.log"
    Set-Content -Path "C:\Scripts\notepad-hash.txt" -Value "Archivo: $notepadPath`nHash SHA256: $hashSHA256`nFecha: $(Get-Date)`nVersion: $((Get-Item $notepadPath).VersionInfo.FileVersion)"

    $domainFQDN = (Get-ADDomain).DNSRoot
    $domainDN   = (Get-ADDomain).DistinguishedName

    # XML Cuates - Notepad PERMITIDO
    $xmlCuates = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePublisherRule Id="a9e18c21-ff8f-43cf-b9fc-db40eed693ba"
                       Name="Permitir ejecutables Microsoft (Administradores)"
                       Description="Regla base para administradores"
                       UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
                                ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FileHashRule Id="b5dd97a5-3e2f-4f68-a20a-4a48c41e84e7"
                  Name="Permitir Bloc de Notas - Cuates (Hash)"
                  Description="Cuates pueden usar notepad.exe"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256" Data="0x$hashSHA256" SourceFileName="notepad.exe" SourceFileLength="$notepadSize" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20"
                  Name="Permitir Windows System" Description="Ejecutables del sistema"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51"
                  Name="Permitir Program Files" Description="Ejecutables de Program Files"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Script"  EnforcementMode="NotConfigured" />
  <RuleCollection Type="Msi"     EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll"     EnforcementMode="NotConfigured" />
  <RuleCollection Type="Appx"    EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

    # XML NoCuates - Notepad BLOQUEADO por hash
    $xmlNoCuates = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePublisherRule Id="a9e18c21-ff8f-43cf-b9fc-db40eed693ba"
                       Name="Permitir ejecutables Microsoft (Administradores)"
                       Description="Regla base para administradores"
                       UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
                                ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FileHashRule Id="c7dd97b6-4e3f-5f79-b31b-5b59d52f95f8"
                  Name="BLOQUEAR Bloc de Notas - NoCuates (Hash)"
                  Description="NoCuates NO pueden usar notepad.exe - bloqueado por hash aunque se renombre"
                  UserOrGroupSid="S-1-1-0" Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256" Data="0x$hashSHA256" SourceFileName="notepad.exe" SourceFileLength="$notepadSize" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20"
                  Name="Permitir Windows System" Description="Ejecutables del sistema (excepto bloqueados)"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51"
                  Name="Permitir Program Files" Description="Ejecutables de Program Files"
                  UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Script"  EnforcementMode="NotConfigured" />
  <RuleCollection Type="Msi"     EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll"     EnforcementMode="NotConfigured" />
  <RuleCollection Type="Appx"    EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

    $xmlCuatesPath   = "C:\Scripts\AppLocker-Cuates.xml"
    $xmlNoCuatesPath = "C:\Scripts\AppLocker-NoCuates.xml"
    Set-Content -Path $xmlCuatesPath   -Value $xmlCuates   -Encoding UTF8
    Set-Content -Path $xmlNoCuatesPath -Value $xmlNoCuates -Encoding UTF8
    Write-Log "XMLs de AppLocker generados." "OK" "04-AppLocker.log"

    # Crear GPOs y aplicar XML
    foreach ($cfg in @(
        @{ Nombre = "GPO-AppLocker-Cuates";   XML = $xmlCuatesPath;   OU = "OU=Cuates,OU=Practica,$domainDN" },
        @{ Nombre = "GPO-AppLocker-NoCuates"; XML = $xmlNoCuatesPath; OU = "OU=NoCuates,OU=Practica,$domainDN" }
    )) {
        $gpo = Get-GPO -Name $cfg.Nombre -ErrorAction SilentlyContinue
        if (-not $gpo) {
            $gpo = New-GPO -Name $cfg.Nombre
            Write-Log "GPO creada: $($cfg.Nombre)" "OK" "04-AppLocker.log"
        } else {
            Write-Log "GPO ya existe: $($cfg.Nombre)" "WARN" "04-AppLocker.log"
        }

        $gpoGuid      = $gpo.Id.ToString()
        $applockerDir = "\\$domainFQDN\SYSVOL\$domainFQDN\Policies\{$gpoGuid}\Machine\Microsoft\Windows NT\AppLocker"
        if (-not (Test-Path $applockerDir)) { New-Item -ItemType Directory -Path $applockerDir -Force | Out-Null }
        Copy-Item -Path $cfg.XML -Destination "$applockerDir\AppLocker.xml" -Force
        Write-Log "  XML copiado a SYSVOL para $($cfg.Nombre)" "OK" "04-AppLocker.log"

        Set-GPRegistryValue -Name $cfg.Nombre `
            -Key "HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc" `
            -ValueName "Start" -Type DWord -Value 2 | Out-Null

        try {
            New-GPLink -Name $cfg.Nombre -Target $cfg.OU -ErrorAction Stop | Out-Null
            Write-Log "  GPO vinculada a: $($cfg.OU)" "OK" "04-AppLocker.log"
        } catch {
            if ($_ -match "already linked") {
                Write-Log "  GPO ya vinculada a: $($cfg.OU)" "WARN" "04-AppLocker.log"
            } else {
                Write-Log "  Error vinculando: $_" "ERROR" "04-AppLocker.log"
            }
        }
    }

    # Habilitar servicio AppIDSvc
    Set-Service -Name AppIDSvc -StartupType Automatic
    Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    $svc = Get-Service -Name AppIDSvc
    Write-Log "AppIDSvc: Estado=$($svc.Status), Inicio=$($svc.StartType)" "OK" "04-AppLocker.log"

    Invoke-GPUpdate -Force -RandomDelayInMinutes 0 | Out-Null
    Write-Log "Politicas actualizadas (gpupdate /force)" "OK" "04-AppLocker.log"
    Write-Log "===== FIN: AppLocker configurado correctamente =====" "OK" "04-AppLocker.log"
    Pause-Menu
}

# ===========================================================================
# FUNCION 5: GENERAR ARCHIVOS DE PRUEBA
# ===========================================================================
function Invoke-GenerarArchivosPrueba {
    Write-Banner "Generar Archivos de Prueba para FSRM" "Blue"

    $destino = "C:\Scripts\ArchivosTest"
    if (-not (Test-Path $destino)) { New-Item -ItemType Directory -Path $destino -Force | Out-Null }

    function New-TestFile {
        param([string]$Path, [int]$SizeMB)
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
        } finally { $fs.Close() }
        Write-Log "Creado: $(Split-Path $Path -Leaf) ($SizeMB MB)" "OK" "10-ArchivosTest.log"
    }

    Write-Log "Generando archivos de prueba de cuotas..." "INFO" "10-ArchivosTest.log"
    foreach ($mb in @(1,4,5,6,9,10,11)) {
        New-TestFile -Path "$destino\test-${mb}MB.dat" -SizeMB $mb
    }

    Write-Log "Generando archivos de apantallamiento simulados..." "INFO" "10-ArchivosTest.log"
    $txt = "Archivo de prueba FSRM - No es un archivo real"
    foreach ($ext in @("mp3","mp4","avi","exe","msi")) {
        Set-Content -Path "$destino\prueba.$ext" -Value $txt
        Write-Log "Creado: prueba.$ext" "OK" "10-ArchivosTest.log"
    }

    Write-Log "Archivos de prueba listos en: $destino" "OK" "10-ArchivosTest.log"
    Pause-Menu
}

# ===========================================================================
# FUNCION 6: CAMBIO DE HORA PARA PRUEBAS
# ===========================================================================
function Invoke-CambioHora {
    Write-Banner "Cambio de Hora para Pruebas de LogonHours" "Yellow"
    Write-Host "  [1] Cuates DENTRO de horario    (10:00 AM - pueden entrar)" -ForegroundColor Green
    Write-Host "  [2] Cuates FUERA de horario     (4:00 PM  - seran desconectados)" -ForegroundColor Red
    Write-Host "  [3] NoCuates DENTRO de horario  (8:00 PM  - pueden entrar)" -ForegroundColor Green
    Write-Host "  [4] NoCuates FUERA de horario   (2:30 AM  - seran desconectados)" -ForegroundColor Red
    Write-Host "  [5] RESTAURAR hora real (NTP)" -ForegroundColor Cyan
    Write-Host "  [0] Volver al menu" -ForegroundColor Gray
    Write-Host ""

    $horaOriginalFile = "C:\Scripts\hora-original.txt"
    if (-not (Test-Path $horaOriginalFile)) { Get-Date | Out-File $horaOriginalFile }

    $opcion = Read-Host "Selecciona una opcion"
    $fechaHoy = Get-Date -Format "yyyy-MM-dd"

    switch ($opcion) {
        "1" {
            Set-Date -Date "$fechaHoy 10:00:00"
            Write-Log "Hora -> 10:00 AM | Cuates DENTRO de horario" "OK" "08-CambioHora.log"
        }
        "2" {
            Set-Date -Date "$fechaHoy 16:00:00"
            Write-Log "Hora -> 4:00 PM | Cuates FUERA de horario - sesiones activas seran cerradas" "WARN" "08-CambioHora.log"
        }
        "3" {
            Set-Date -Date "$fechaHoy 20:00:00"
            Write-Log "Hora -> 8:00 PM | NoCuates DENTRO de horario" "OK" "08-CambioHora.log"
        }
        "4" {
            $manana = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")
            Set-Date -Date "$manana 02:30:00"
            Write-Log "Hora -> 2:30 AM | NoCuates FUERA de horario" "WARN" "08-CambioHora.log"
        }
        "5" {
            Write-Log "Restaurando hora via NTP..." "INFO" "08-CambioHora.log"
            w32tm /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:manual /reliable:YES /update | Out-Null
            net stop w32tm 2>$null | Out-Null
            net start w32tm | Out-Null
            w32tm /resync /force | Out-Null
            Remove-Item $horaOriginalFile -ErrorAction SilentlyContinue
            Write-Log "Hora restaurada: $(Get-Date)" "OK" "08-CambioHora.log"
        }
        "0" { return }
        default { Write-Host "Opcion invalida." -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "Hora actual del servidor: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Magenta
    Pause-Menu
}

# ===========================================================================
# FUNCION 7: VERIFICAR TODO
# ===========================================================================
function Invoke-VerificarTodo {
    Write-Banner "Verificacion Completa del Sistema" "Cyan"

    Import-Module ActiveDirectory
    Import-Module GroupPolicy
    Import-Module FileServerResourceManager -ErrorAction SilentlyContinue

    $reportPath = "$global:LogDir\Verificacion-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    Start-Transcript -Path $reportPath -Append | Out-Null

    $domainDN   = (Get-ADDomain).DistinguishedName
    $domainFQDN = (Get-ADDomain).DNSRoot

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  1. ESTRUCTURA DE ACTIVE DIRECTORY" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan

    foreach ($ou in @("OU=Practica,$domainDN","OU=Cuates,OU=Practica,$domainDN","OU=NoCuates,OU=Practica,$domainDN")) {
        try { Get-ADOrganizationalUnit -Identity $ou | Out-Null; Write-Host "  [OK] OU: $(($ou -split ',')[0])" -ForegroundColor Green }
        catch { Write-Host "  [X]  OU no existe: $ou" -ForegroundColor Red }
    }
    foreach ($g in @("GRP_Cuates","GRP_NoCuates")) {
        try {
            $miembros = (Get-ADGroupMember -Identity $g).Count
            Write-Host "  [OK] Grupo: $g | Miembros: $miembros" -ForegroundColor Green
        } catch { Write-Host "  [X]  Grupo no existe: $g" -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  2. LOGON HOURS" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan

    foreach ($g in @("GRP_Cuates","GRP_NoCuates")) {
        $primer = Get-ADGroupMember -Identity $g -Recursive | Where-Object { $_.objectClass -eq "user" } | Select-Object -First 1
        if ($primer) {
            $u = Get-ADUser -Identity $primer.SamAccountName -Properties LogonHours
            if ($u.LogonHours) {
                Write-Host "  [OK] $($u.SamAccountName) tiene LogonHours (21 bytes)" -ForegroundColor Green
            } else {
                Write-Host "  [X]  $($u.SamAccountName) NO tiene LogonHours" -ForegroundColor Red
            }
        }
    }
    $gpoLogoff = Get-GPO -Name "GPO-ForzarCierreSesion" -ErrorAction SilentlyContinue
    if ($gpoLogoff) { Write-Host "  [OK] GPO ForceLogoff existe" -ForegroundColor Green }
    else            { Write-Host "  [X]  GPO ForceLogoff NO existe" -ForegroundColor Red }

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  3. FSRM - CUOTAS" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan

    try {
        $cuotas = Get-FsrmQuota -ErrorAction Stop
        Write-Host "  Total cuotas: $($cuotas.Count)" -ForegroundColor White
        foreach ($c in $cuotas | Sort-Object Path) {
            $mb  = [math]::Round($c.Size/1MB,0)
            $usr = Split-Path $c.Path -Leaf
            $col = if ($mb -eq 10) { "Green" } else { "Yellow" }
            Write-Host "  [OK] $usr -> ${mb}MB" -ForegroundColor $col
        }
    } catch { Write-Host "  [X]  Error FSRM: $_" -ForegroundColor Red }

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  4. FSRM - APANTALLAMIENTO" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan

    try {
        $screens = Get-FsrmFileScreen -ErrorAction Stop
        Write-Host "  Total apantallamientos: $($screens.Count)" -ForegroundColor White
        foreach ($s in $screens | Sort-Object Path) {
            Write-Host "  [OK] $(Split-Path $s.Path -Leaf) -> Activo: $($s.Active)" -ForegroundColor Green
        }
        $fg = Get-FsrmFileGroup -Name "Archivos-Bloqueados-Practica" -ErrorAction SilentlyContinue
        if ($fg) { Write-Host "  [OK] Grupo archivos bloqueados: $($fg.IncludePattern -join ', ')" -ForegroundColor Green }
        else      { Write-Host "  [X]  Grupo archivos bloqueados NO existe" -ForegroundColor Red }
    } catch { Write-Host "  [X]  Error apantallamiento: $_" -ForegroundColor Red }

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  5. APPLOCKER" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan

    foreach ($gpoName in @("GPO-AppLocker-Cuates","GPO-AppLocker-NoCuates")) {
        $g = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
        if ($g) { Write-Host "  [OK] $gpoName existe" -ForegroundColor Green }
        else     { Write-Host "  [X]  $gpoName NO existe" -ForegroundColor Red }
    }
    $svc = Get-Service -Name AppIDSvc -ErrorAction SilentlyContinue
    if ($svc) {
        $col = if ($svc.Status -eq "Running") { "Green" } else { "Yellow" }
        Write-Host "  AppIDSvc: $($svc.Status)" -ForegroundColor $col
    }

    Write-Host ""
    Write-Host "Reporte guardado en: $reportPath" -ForegroundColor Gray
    Stop-Transcript | Out-Null

    Pause-Menu
}

# ===========================================================================
# FUNCION 8: EJECUTAR TODO EN ORDEN
# ===========================================================================
function Invoke-EjecutarTodo {
    Write-Banner "EJECUTAR TODO EN ORDEN (1 -> 4)" "Green"
    Write-Host "  Esto ejecutara los pasos 1, 2, 3 y 4 en secuencia." -ForegroundColor White
    Write-Host "  Asegurate de que el CSV este en: $global:CSVPath" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Continuar? (S/N)"
    if ($confirm -ne "S" -and $confirm -ne "s") { return }

    Invoke-ConfigurarAD
    Invoke-ConfigurarLogonHours
    Invoke-ConfigurarFSRM
    Invoke-ConfigurarAppLocker
    Invoke-GenerarArchivosPrueba
    Invoke-VerificarTodo
}

# ===========================================================================
# MENU PRINCIPAL
# ===========================================================================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "    PRACTICA: GPO / FSRM / AppLocker" -ForegroundColor Cyan
    Write-Host "    Windows Server 2022  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  CONFIGURACION DEL SERVIDOR" -ForegroundColor Cyan
    Write-Host "  [1] Configurar Active Directory (UOs, Grupos, Usuarios)" -ForegroundColor White
    Write-Host "  [2] Configurar Horarios de Acceso (LogonHours + GPO)" -ForegroundColor White
    Write-Host "  [3] Configurar FSRM (Cuotas + Apantallamiento)" -ForegroundColor White
    Write-Host "  [4] Configurar AppLocker (Notepad por Hash)" -ForegroundColor White
    Write-Host ""
    Write-Host "  HERRAMIENTAS DE PRUEBA" -ForegroundColor Cyan
    Write-Host "  [5] Generar Archivos de Prueba (FSRM)" -ForegroundColor White
    Write-Host "  [6] Cambiar Hora del Sistema (LogonHours)" -ForegroundColor White
    Write-Host "  [7] Verificar Todo y Generar Reporte" -ForegroundColor White
    Write-Host ""
    Write-Host "  [8] EJECUTAR TODO EN ORDEN (1 al 4 + verificacion)" -ForegroundColor Green
    Write-Host "  [0] Salir" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  Dominio: $global:DomainName  |  CSV: $global:CSVPath" -ForegroundColor DarkGray
    Write-Host ""
}

# ===========================================================================
# LOOP PRINCIPAL
# ===========================================================================
do {
    Show-Menu
    $opcion = Read-Host "  Selecciona una opcion"

    switch ($opcion) {
        "1" { Invoke-ConfigurarAD }
        "2" { Invoke-ConfigurarLogonHours }
        "3" { Invoke-ConfigurarFSRM }
        "4" { Invoke-ConfigurarAppLocker }
        "5" { Invoke-GenerarArchivosPrueba }
        "6" { Invoke-CambioHora }
        "7" { Invoke-VerificarTodo }
        "8" { Invoke-EjecutarTodo }
        "0" { Write-Host "Saliendo..." -ForegroundColor Gray; break }
        default { Write-Host "  Opcion invalida. Intenta de nuevo." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
} while ($opcion -ne "0")