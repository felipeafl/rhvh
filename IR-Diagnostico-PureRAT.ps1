<#
.SYNOPSIS
    Diagnóstico forense de solo lectura para detectar indicadores de compromiso (IOCs)
    asociados a win.pure_rat / botnets C2, en servidores Windows (RDS/TS/standalone).

.DESCRIPTION
    NO modifica nada en el sistema. Recolecta evidencia, la exporta a CSV/TXT en
    C:\IR_<hostname>_<timestamp>, y genera un RESUMEN con hallazgos marcados como
    sospechosos según heurísticas conocidas de PureRAT/PureHVNC y RATs .NET en general.

.USAGE
    Ejecutar como Administrador en cada servidor a revisar:
        powershell.exe -ExecutionPolicy Bypass -File .\IR-Diagnostico-PureRAT.ps1

    Opcional: copiar a un share y correr en paralelo contra varios hosts vía
    Invoke-Command -ComputerName (Get-Content hosts.txt) -FilePath .\IR-Diagnostico-PureRAT.ps1

.OUTPUT
    C:\IR_<hostname>_<timestamp>\*.csv|*.txt
    C:\IR_<hostname>_<timestamp>.zip
    Resumen impreso en pantalla al finalizar.

.NOTES
    Autor: Generado para triage de incidente PureRAT (Hetzner BCL)
    Solo lectura. No aísla, no mata procesos, no borra nada.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'SilentlyContinue'
$hostname   = $env:COMPUTERNAME
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$outDir     = "C:\IR_${hostname}_${timestamp}"
$findings   = New-Object System.Collections.Generic.List[string]

New-Item -ItemType Directory -Path $outDir -Force | Out-Null
Write-Host "=== IR Diagnóstico PureRAT/C2 === Host: $hostname === $timestamp ===" -ForegroundColor Cyan
Write-Host "Output: $outDir`n"

function Add-Finding {
    param([string]$Severity, [string]$Msg)
    $line = "[$Severity] $Msg"
    $findings.Add($line)
    $color = switch ($Severity) { 'ALTO' {'Red'} 'MEDIO' {'Yellow'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
}

# ------------------------------------------------------------------
# 1. CONEXIONES DE RED — listeners y conexiones establecidas
# ------------------------------------------------------------------
Write-Host "[1/10] Conexiones de red..." -ForegroundColor Cyan

$netconn = Get-NetTCPConnection | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess,
    @{n='ProcName'; e={ (Get-Process -Id $_.OwningProcess -ea 0).ProcessName }},
    @{n='ProcPath'; e={ (Get-Process -Id $_.OwningProcess -ea 0).Path }}
$netconn | Sort-Object State, LocalPort | Export-Csv "$outDir\01_netconn.csv" -NoTypeInformation

# Listeners en puertos no estándar (fuera de los servicios Windows/apps conocidas)
$puertosEsperados = 80,443,3389,445,135,139,88,389,636,53,5985,5986,3306,1433,8080,8443
$listeners = $netconn | Where-Object { $_.State -eq 'Listen' -and $_.LocalPort -notin $puertosEsperados } |
    Select-Object -Unique LocalPort, ProcName, ProcPath
$listeners | Export-Csv "$outDir\02_listeners_no_estandar.csv" -NoTypeInformation
foreach ($l in $listeners) {
    Add-Finding 'MEDIO' "Listener en puerto no estándar $($l.LocalPort) -> $($l.ProcName) ($($l.ProcPath))"
}

# Top IPs remotas por conexiones establecidas (un C2/panel recibe de muchas IPs distintas)
$topRemote = $netconn | Where-Object State -eq 'Established' | Group-Object RemoteAddress |
    Sort-Object Count -Descending | Select-Object -First 40 Count, Name
$topRemote | Out-File "$outDir\03_top_remote_ips.txt"
$topRemoteAlto = $topRemote | Where-Object Count -gt 15
foreach ($r in $topRemoteAlto) {
    Add-Finding 'ALTO' "IP remota $($r.Name) con $($r.Count) conexiones establecidas (patrón tipo C2/panel)"
}

# ------------------------------------------------------------------
# 2. PROCESOS — línea de comando, ruta y firma digital
# ------------------------------------------------------------------
Write-Host "[2/10] Procesos y firmas..." -ForegroundColor Cyan

$procs = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, CommandLine, ExecutablePath, CreationDate
$procs | Export-Csv "$outDir\04_procesos.csv" -NoTypeInformation

# Binarios "living off the land" frecuentemente usados para inyección .NET (RegAsm, MSBuild, InstallUtil, etc.)
$lolbins = 'regasm','regsvcs','msbuild','installutil','aspnet_compiler','vbc','csc','mshta','wscript','cscript','rundll32','tabtip32'
foreach ($p in $procs) {
    $nombreLower = $p.Name.ToLower()
    foreach ($lol in $lolbins) {
        if ($nombreLower -like "*$lol*") {
            # Sospechoso si tiene padre inusual o commandline vacío/raro para ese binario
            Add-Finding 'MEDIO' "Proceso LOLBin: $($p.Name) (PID $($p.ProcessId), PPID $($p.ParentProcessId)) CmdLine: $($p.CommandLine)"
        }
    }
    # Procesos con ruta ejecutable en carpetas de usuario/temp (poco común para binarios legítimos del sistema)
    if ($p.ExecutablePath -match '\\Users\\.*\\(AppData|Temp|Downloads)\\' -or $p.ExecutablePath -match '\\ProgramData\\[^\\]+\.exe$') {
        Add-Finding 'ALTO' "Ejecutable corriendo desde ruta de usuario/temp: $($p.ExecutablePath) (PID $($p.ProcessId))"
    }
}

# Firma digital de cada binario en ejecución (Authenticode)
$firmas = foreach ($proc in (Get-Process | Where-Object Path)) {
    $sig = Get-AuthenticodeSignature -FilePath $proc.Path -ea 0
    [PSCustomObject]@{
        ProcName = $proc.ProcessName
        Path     = $proc.Path
        Status   = $sig.Status
        Signer   = $sig.SignerCertificate.Subject
    }
}
$firmas | Export-Csv "$outDir\05_firmas_procesos.csv" -NoTypeInformation
$noFirmados = $firmas | Where-Object { $_.Status -ne 'Valid' -and $_.Path -notmatch '\\Windows\\' }
foreach ($nf in $noFirmados) {
    Add-Finding 'MEDIO' "Proceso sin firma válida fuera de Windows: $($nf.ProcName) -> $($nf.Path) [$($nf.Status)]"
}

# Hashes únicos (para threat-hunting cruzado con otros hosts / VirusTotal)
Get-Process | Where-Object Path | ForEach-Object { Get-FileHash $_.Path -Algorithm SHA256 -ea 0 } |
    Sort-Object Hash -Unique | Export-Csv "$outDir\06_hashes_procesos.csv" -NoTypeInformation

# ------------------------------------------------------------------
# 3. PERSISTENCIA — tareas programadas, servicios, Run keys, startup
# ------------------------------------------------------------------
Write-Host "[3/10] Persistencia..." -ForegroundColor Cyan

Get-ScheduledTask | Where-Object State -ne 'Disabled' |
    Select-Object TaskName, TaskPath, State, Author,
        @{n='Exec'; e={ ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' | ' }} |
    Export-Csv "$outDir\07_tareas_programadas.csv" -NoTypeInformation

Get-CimInstance Win32_Service | Where-Object StartMode -eq 'Auto' |
    Select-Object Name, DisplayName, PathName, StartName, State |
    Export-Csv "$outDir\08_servicios.csv" -NoTypeInformation

$runKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
           'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
           'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
foreach ($k in $runKeys) { Get-ItemProperty $k -ea 0 | Out-File "$outDir\09_run_hklm.txt" -Append }

Get-ChildItem Registry::HKEY_USERS -ea 0 | ForEach-Object {
    Get-ItemProperty "Registry::$($_.Name)\Software\Microsoft\Windows\CurrentVersion\Run" -ea 0
} | Out-File "$outDir\10_run_hku.txt"

Get-ChildItem "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\*" -ea 0 |
    Select-Object FullName, LastWriteTime | Out-File "$outDir\11_startup_folders.txt"

Get-ChildItem "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\*" -ea 0 |
    Select-Object FullName, LastWriteTime | Out-File -Append "$outDir\11_startup_folders.txt"

# WMI Event Subscriptions (persistencia fileless muy usada por RATs modernos)
$wmiCons = Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ea 0
if ($wmiCons) {
    $wmiCons | Export-Csv "$outDir\12_wmi_consumers.csv" -NoTypeInformation
    Add-Finding 'ALTO' "Existen WMI Event Consumers ($($wmiCons.Count)) - revisar 12_wmi_consumers.csv (persistencia fileless)"
}

# ------------------------------------------------------------------
# 4. FIREWALL — reglas inbound Allow (el panel suele abrirse su puerto)
# ------------------------------------------------------------------
Write-Host "[4/10] Reglas de firewall..." -ForegroundColor Cyan

$fwRules = Get-NetFirewallRule -Direction Inbound -Enabled True | Where-Object Action -eq 'Allow'
$fwDetail = foreach ($r in $fwRules) {
    $filter = $r | Get-NetFirewallPortFilter -ea 0
    [PSCustomObject]@{
        DisplayName = $r.DisplayName
        Program     = ($r | Get-NetFirewallApplicationFilter -ea 0).Program
        Protocol    = $filter.Protocol
        LocalPort   = $filter.LocalPort
    }
}
$fwDetail | Export-Csv "$outDir\13_firewall_inbound.csv" -NoTypeInformation

# ------------------------------------------------------------------
# 5. LOGONS — RDP exitosos, tipo 10 (remoto interactivo), cuentas creadas
# ------------------------------------------------------------------
Write-Host "[5/10] Logs de logon / RDP (30 días)..." -ForegroundColor Cyan

Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624; StartTime=(Get-Date).AddDays(-30)} -ea 0 |
    Where-Object { $_.Properties[8].Value -in 3,10 } |
    Select-Object TimeCreated,
        @{n='User'; e={$_.Properties[5].Value}},
        @{n='SrcIP'; e={$_.Properties[18].Value}},
        @{n='LogonType'; e={$_.Properties[8].Value}} |
    Export-Csv "$outDir\14_logons.csv" -NoTypeInformation

Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4720,4732,4728,4756; StartTime=(Get-Date).AddDays(-30)} -ea 0 |
    Select-Object TimeCreated, Id, @{n='User'; e={$_.Properties[0].Value}} |
    Export-Csv "$outDir\15_cuentas_nuevas_o_grupos.csv" -NoTypeInformation

Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id=21,25; StartTime=(Get-Date).AddDays(-30)} -ea 0 |
    Select-Object TimeCreated, Id, Message | Export-Csv "$outDir\16_rdp_sesiones.csv" -NoTypeInformation

# Fuerza bruta / intentos fallidos masivos (4625) agrupados por IP origen
$fallidos = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625; StartTime=(Get-Date).AddDays(-7)} -ea 0 |
    Select-Object @{n='SrcIP'; e={$_.Properties[19].Value}} |
    Group-Object SrcIP | Sort-Object Count -Descending | Select-Object -First 20 Count, Name
$fallidos | Out-File "$outDir\17_logon_fallidos_top_ip.txt"
foreach ($f in ($fallidos | Where-Object Count -gt 50)) {
    Add-Finding 'MEDIO' "$($f.Count) intentos de logon fallidos desde $($f.Name) en los últimos 7 días"
}

# ------------------------------------------------------------------
# 6. ARCHIVOS RECIENTES — binarios/scripts modificados en los últimos 30 días
# ------------------------------------------------------------------
Write-Host "[6/10] Archivos recientes en rutas sensibles..." -ForegroundColor Cyan

$rutas = 'C:\Users','C:\Windows\Temp','C:\ProgramData','C:\Windows\Tasks'
Get-ChildItem $rutas -Recurse -Include *.exe,*.dll,*.ps1,*.bat,*.vbs,*.hta -ea 0 |
    Where-Object LastWriteTime -gt (Get-Date).AddDays(-30) |
    Select-Object FullName, Length, LastWriteTime, CreationTime |
    Export-Csv "$outDir\18_archivos_recientes.csv" -NoTypeInformation

# ------------------------------------------------------------------
# 7. PREFETCH — evidencia de ejecución aunque el binario ya no exista
# ------------------------------------------------------------------
Write-Host "[7/10] Prefetch..." -ForegroundColor Cyan

Get-ChildItem 'C:\Windows\Prefetch\*.pf' -ea 0 |
    Where-Object LastWriteTime -gt (Get-Date).AddDays(-30) |
    Select-Object Name, LastWriteTime | Sort-Object LastWriteTime -Descending |
    Export-Csv "$outDir\19_prefetch_reciente.csv" -NoTypeInformation

# ------------------------------------------------------------------
# 8. DEFENDER / EXCLUSIONES — un atacante suele agregar exclusiones para su malware
# ------------------------------------------------------------------
Write-Host "[8/10] Exclusiones de Defender / AV..." -ForegroundColor Cyan

try {
    $mp = Get-MpPreference -ea Stop
    [PSCustomObject]@{
        ExclusionPath      = ($mp.ExclusionPath -join '; ')
        ExclusionExtension = ($mp.ExclusionExtension -join '; ')
        ExclusionProcess   = ($mp.ExclusionProcess -join '; ')
        RealTimeMonitoring = -not $mp.DisableRealtimeMonitoring
    } | Format-List | Out-File "$outDir\20_defender_exclusiones.txt"

    if ($mp.ExclusionPath -or $mp.ExclusionProcess) {
        Add-Finding 'ALTO' "Existen exclusiones de Windows Defender configuradas - revisar 20_defender_exclusiones.txt"
    }
    if ($mp.DisableRealtimeMonitoring) {
        Add-Finding 'ALTO' "Windows Defender Real-Time Monitoring está DESHABILITADO"
    }
} catch {
    "Defender no disponible (posible AV de terceros - ej. Cylance). Revisar consola del AV manualmente." |
        Out-File "$outDir\20_defender_exclusiones.txt"
}

# ------------------------------------------------------------------
# 9. USUARIOS LOCALES Y GRUPOS — cuentas administrativas
# ------------------------------------------------------------------
Write-Host "[9/10] Usuarios locales y grupo Administradores..." -ForegroundColor Cyan

Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordLastSet |
    Export-Csv "$outDir\21_usuarios_locales.csv" -NoTypeInformation
Get-LocalGroupMember -Group 'Administradores' -ea 0 | Select-Object Name, PrincipalSource |
    Export-Csv "$outDir\22_admins_locales.csv" -NoTypeInformation
if (-not (Test-Path "$outDir\22_admins_locales.csv") -or (Get-Item "$outDir\22_admins_locales.csv").Length -eq 0) {
    Get-LocalGroupMember -Group 'Administrators' -ea 0 | Select-Object Name, PrincipalSource |
        Export-Csv "$outDir\22_admins_locales.csv" -NoTypeInformation
}

# ------------------------------------------------------------------
# 10. HOSTS FILE / PROXY — redirección de tráfico o proxy malicioso
# ------------------------------------------------------------------
Write-Host "[10/10] hosts file y configuración de proxy..." -ForegroundColor Cyan

Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ea 0 |
    Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' } |
    Out-File "$outDir\23_hosts_file.txt"

$proxy = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ea 0
if ($proxy.ProxyEnable -eq 1) {
    "$($proxy.ProxyServer)" | Out-File "$outDir\24_proxy_config.txt"
    Add-Finding 'MEDIO' "Proxy del sistema habilitado: $($proxy.ProxyServer)"
}

# ------------------------------------------------------------------
# RESUMEN FINAL
# ------------------------------------------------------------------
$resumenPath = "$outDir\00_RESUMEN.txt"
@"
=== RESUMEN DIAGNÓSTICO IR ===
Host: $hostname
Fecha: $(Get-Date)
Hallazgos: $($findings.Count)

$(if ($findings.Count -eq 0) { "Sin hallazgos automáticos marcados como sospechosos. Esto NO garantiza que el host esté limpio - revisar manualmente 01-24.csv/.txt, especialmente netconn y procesos." } else { $findings -join "`n" })

--- Siguiente paso recomendado ---
1. Revisar 03_top_remote_ips.txt y 04_procesos.csv cruzando OwningProcess.
2. Cruzar 06_hashes_procesos.csv contra VirusTotal / threat intel.
3. Si hay hallazgos ALTO: aislar el host (firewall, no apagar) y conservar evidencia antes de reimaginar.
4. Comparar 14_logons.csv entre todos los hosts del incidente para encontrar cuenta/IP origen común.
"@ | Out-File $resumenPath

Compress-Archive -Path "$outDir\*" -DestinationPath "$outDir.zip" -Force

Write-Host "`n=== COMPLETADO ===" -ForegroundColor Cyan
Write-Host "Carpeta: $outDir"
Write-Host "ZIP:     $outDir.zip"
Write-Host "Hallazgos automáticos: $($findings.Count)" -ForegroundColor $(if ($findings.Count -gt 0) {'Yellow'} else {'Green'})
Get-Content $resumenPath
