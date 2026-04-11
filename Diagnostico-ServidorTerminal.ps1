# ============================================================
#  DIAGNOSTICO DE SERVIDOR TERMINAL - FUGAS DE MEMORIA Y CPU
#  Uso: .\Diagnostico-ServidorTerminal.ps1
#  Ejecutar como Administrador
#  Compatible: Windows Server 2012 R2+ / PowerShell 4+
# ============================================================

#region CONFIGURACION
$UmbralCPU_Proceso = 15
$UmbralRAM_MB      = 500
$UmbralHandles     = 5000
$UmbralThreads     = 200
$TopProcesos       = 15
$ReportePath       = "$env:USERPROFILE\Desktop\Diagnostico_Servidor_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"
#endregion

#region FUNCIONES
function Write-Header {
    param([string]$Titulo)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "  $Titulo" -ForegroundColor White
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-SubHeader {
    param([string]$Titulo)
    Write-Host ""
    Write-Host "--- $Titulo ---" -ForegroundColor Yellow
}

function Get-ColorEstado {
    param([string]$Estado)
    switch ($Estado) {
        "CRITICO"     { return "Red" }
        "ADVERTENCIA" { return "Yellow" }
        "OK"          { return "Green" }
        default       { return "White" }
    }
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}
#endregion

$Reporte = [System.Collections.Generic.List[string]]::new()
function Add-R { param([string]$L) $Reporte.Add($L) | Out-Null }

Clear-Host
$FechaInicio = Get-Date
Write-Host ""
Write-Host "  INICIANDO DIAGNOSTICO COMPLETO DEL SERVIDOR TERMINAL" -ForegroundColor Cyan
Write-Host "  $($FechaInicio.ToString('dd/MM/yyyy HH:mm:ss'))" -ForegroundColor Gray

Add-R "DIAGNOSTICO DE SERVIDOR TERMINAL"
Add-R "Fecha   : $($FechaInicio.ToString('dd/MM/yyyy HH:mm:ss'))"
Add-R "Servidor: $env:COMPUTERNAME"
Add-R ("=" * 70)

# ============================================================
# SECCION 1: INFORMACION GENERAL DEL SISTEMA
# ============================================================
Write-Header "1. INFORMACION GENERAL DEL SISTEMA"
Add-R ""
Add-R "[1. INFORMACION GENERAL]"

try {
    $OS  = Get-WmiObject Win32_OperatingSystem
    $CS  = Get-WmiObject Win32_ComputerSystem
    $CPU = Get-WmiObject Win32_Processor | Select-Object -First 1

    $BootTime  = $OS.ConvertToDateTime($OS.LastBootUpTime)
    $Uptime    = (Get-Date) - $BootTime
    $UptimeDias = [math]::Floor($Uptime.TotalDays)
    $UptimeStr  = "$($Uptime.Days)d $($Uptime.Hours)h $($Uptime.Minutes)m"

    $Lineas = @(
        "Nombre del servidor : $($CS.Name)",
        "Sistema operativo   : $($OS.Caption) ($($OS.OSArchitecture))",
        "Version             : $($OS.Version)",
        "Procesador          : $($CPU.Name.Trim())",
        "Nucleos logicos     : $($CS.NumberOfLogicalProcessors)",
        "RAM total           : $(Format-Bytes ([long]$CS.TotalPhysicalMemory))",
        "Tiempo activo       : $UptimeStr",
        "Ultimo reinicio     : $($BootTime.ToString('dd/MM/yyyy HH:mm'))"
    )
    foreach ($L in $Lineas) {
        Write-Host "  $L" -ForegroundColor White
        Add-R "  $L"
    }

    if ($UptimeDias -gt 30) {
        Write-Host ""
        Write-Host "  [!] ADVERTENCIA: El servidor lleva $UptimeDias dias sin reiniciarse." -ForegroundColor Yellow
        Write-Host "      Servidores terminales con alto uptime acumulan fugas de memoria gradualmente." -ForegroundColor Yellow
        Add-R "  [!] $UptimeDias dias sin reinicio - riesgo de fugas acumuladas"
    }
} catch {
    Write-Host "  [ERROR] No se pudo obtener info del sistema: $_" -ForegroundColor Red
    Add-R "  [ERROR] Info sistema: $_"
}

# ============================================================
# SECCION 2: ESTADO DE CPU
# ============================================================
Write-Header "2. ESTADO DE CPU"
Add-R ""
Add-R "[2. ESTADO DE CPU]"

Write-Host "  Midiendo carga de CPU (3 muestras de 2 segundos)..." -ForegroundColor Gray
$MuestrasCPU = @()
for ($i = 1; $i -le 3; $i++) {
    $Val = (Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $MuestrasCPU += $Val
    Start-Sleep -Seconds 2
}
$CPUPromedio = [math]::Round(($MuestrasCPU | Measure-Object -Average).Average, 1)
$CPUMax      = ($MuestrasCPU | Measure-Object -Maximum).Maximum

$EstadoCPU = if ($CPUPromedio -ge 90) { "CRITICO" } elseif ($CPUPromedio -ge 70) { "ADVERTENCIA" } else { "OK" }
$ColorCPU  = Get-ColorEstado $EstadoCPU

$BarraLlena = [math]::Floor($CPUPromedio / 5)
$BarraVacia = 20 - $BarraLlena
$Barra      = "[" + ("X" * $BarraLlena) + ("-" * $BarraVacia) + "]"

Write-Host "  CPU Promedio (3 muestras) : $CPUPromedio %" -ForegroundColor $ColorCPU
Write-Host "  CPU Maximo detectado      : $CPUMax %"      -ForegroundColor $ColorCPU
Write-Host "  Uso visual                : $Barra"         -ForegroundColor $ColorCPU
Write-Host "  Estado                    : $EstadoCPU"     -ForegroundColor $ColorCPU
Add-R "  CPU promedio: ${CPUPromedio}% | Maximo: ${CPUMax}% | Estado: $EstadoCPU"

# ============================================================
# SECCION 3: ESTADO DE MEMORIA RAM
# ============================================================
Write-Header "3. ESTADO DE MEMORIA RAM"
Add-R ""
Add-R "[3. ESTADO DE RAM]"

try {
    $OS2          = Get-WmiObject Win32_OperatingSystem
    $TotalRAM_MB  = [math]::Round($OS2.TotalVisibleMemorySize / 1024, 0)
    $LibreRAM_MB  = [math]::Round($OS2.FreePhysicalMemory / 1024, 0)
    $UsadaRAM_MB  = $TotalRAM_MB - $LibreRAM_MB
    $PctUsada     = [math]::Round(($UsadaRAM_MB / $TotalRAM_MB) * 100, 1)

    $EstadoRAM = if ($PctUsada -ge 90) { "CRITICO" } elseif ($PctUsada -ge 75) { "ADVERTENCIA" } else { "OK" }
    $ColorRAM  = Get-ColorEstado $EstadoRAM

    $BarraLlenaR = [math]::Floor($PctUsada / 5)
    $BarraVaciaR = 20 - $BarraLlenaR
    $BarraR      = "[" + ("X" * $BarraLlenaR) + ("-" * $BarraVaciaR) + "]"

    Write-Host "  RAM Total    : $TotalRAM_MB MB"                     -ForegroundColor White
    Write-Host "  RAM Usada    : $UsadaRAM_MB MB (${PctUsada}%)"        -ForegroundColor $ColorRAM
    Write-Host "  RAM Libre    : $LibreRAM_MB MB"                     -ForegroundColor $ColorRAM
    Write-Host "  Uso visual   : $BarraR ${PctUsada}%"                  -ForegroundColor $ColorRAM
    Write-Host "  Estado       : $EstadoRAM"                          -ForegroundColor $ColorRAM
    Add-R "  RAM: $UsadaRAM_MB MB / $TotalRAM_MB MB (${PctUsada}%) - Estado: $EstadoRAM"

    $PageFiles = Get-WmiObject Win32_PageFileUsage -ErrorAction SilentlyContinue
    if ($PageFiles) {
        $PFTotal = ($PageFiles | Measure-Object AllocatedBaseSize -Sum).Sum
        $PFUsada = ($PageFiles | Measure-Object CurrentUsage -Sum).Sum
        $PFPeak  = ($PageFiles | Measure-Object PeakUsage -Sum).Sum
        $ColorPF = if ($PFUsada -gt ($PFTotal * 0.7)) { "Yellow" } else { "White" }
        $ColorPeak = if ($PFPeak -gt ($PFTotal * 0.9)) { "Red" } else { "White" }
        Write-Host ""
        Write-Host "  PageFile Total : $PFTotal MB"            -ForegroundColor White
        Write-Host "  PageFile En uso: $PFUsada MB"            -ForegroundColor $ColorPF
        Write-Host "  PageFile Pico  : $PFPeak MB"             -ForegroundColor $ColorPeak
        Add-R "  PageFile: $PFUsada MB / $PFTotal MB (pico: $PFPeak MB)"

        if ($PFTotal -gt 0) {
            $PctPF = [math]::Round(($PFUsada / $PFTotal) * 100, 0)
            if ($PctPF -gt 70) {
                Write-Host ""
                Write-Host "  [!] Uso alto del PageFile (${PctPF}%) - RAM insuficiente o fuga grave." -ForegroundColor Yellow
                Add-R "  [!] PageFile al ${PctPF}% - posible fuga de memoria severa"
            }
        }
    }
} catch {
    Write-Host "  [ERROR]: $_" -ForegroundColor Red
    Add-R "  [ERROR] RAM: $_"
}

# ============================================================
# SECCION 4: TOP PROCESOS POR CPU
# ============================================================
Write-Header "4. PROCESOS POR CONSUMO DE CPU"
Add-R ""
Add-R "[4. TOP PROCESOS POR CPU]"

try {
    $NumCores = (Get-WmiObject Win32_ComputerSystem).NumberOfLogicalProcessors
    Write-Host "  Capturando dos snapshots para calcular CPU real por proceso..." -ForegroundColor Gray
    $Snap1 = Get-WmiObject Win32_PerfRawData_PerfProc_Process |
             Where-Object { $_.Name -ne "_Total" -and $_.Name -ne "Idle" }
    Start-Sleep -Seconds 3
    $Snap2 = Get-WmiObject Win32_PerfRawData_PerfProc_Process |
             Where-Object { $_.Name -ne "_Total" -and $_.Name -ne "Idle" }

    $ResultadosCPU = @()
    foreach ($S2 in $Snap2) {
        $S1 = $Snap1 | Where-Object { $_.IDProcess -eq $S2.IDProcess } | Select-Object -First 1
        if ($null -eq $S1) { continue }
        $DeltaTime = $S2.Timestamp_Sys100NS - $S1.Timestamp_Sys100NS
        if ($DeltaTime -le 0) { continue }
        $DeltaProc = $S2.PercentProcessorTime - $S1.PercentProcessorTime
        $PctCPU    = [math]::Round(($DeltaProc / $DeltaTime) * 100 / $NumCores, 1)
        if ($PctCPU -lt 0) { $PctCPU = 0 }
        $ResultadosCPU += [PSCustomObject]@{
            Proceso    = $S2.Name
            PID        = $S2.IDProcess
            CPU_Pct    = $PctCPU
            Sospechoso = ($PctCPU -ge $UmbralCPU_Proceso)
        }
    }

    $TopCPU = $ResultadosCPU | Sort-Object CPU_Pct -Descending | Select-Object -First $TopProcesos
    Write-Host ""
    Write-Host ("  {0,-40}  {1,6}  {2,8}  {3}" -f "Proceso", "PID", "CPU %", "Estado") -ForegroundColor Gray
    Write-Host "  $('-' * 70)" -ForegroundColor Gray

    foreach ($P in $TopCPU) {
        $Alerta = if ($P.Sospechoso) { "[!] ALTO CPU" } else { "" }
        $Color  = if ($P.Sospechoso) { "Red" } elseif ($P.CPU_Pct -ge 5) { "Yellow" } else { "White" }
        $Linea  = "  {0,-40}  {1,6}  {2,7}%  {3}" -f $P.Proceso, $P.PID, $P.CPU_Pct, $Alerta
        Write-Host $Linea -ForegroundColor $Color
        Add-R $Linea
    }
} catch {
    Write-Host "  [ERROR al analizar CPU]: $_" -ForegroundColor Red
    Write-Host "  Usando fallback con Get-Process..." -ForegroundColor Gray
    Add-R "  [ERROR CPU snapshot, usando fallback]"
    Get-Process | Sort-Object CPU -Descending | Select-Object -First $TopProcesos | ForEach-Object {
        $Linea = "  {0,-40}  {1,6}  CPU_time: {2}" -f $_.ProcessName, $_.Id, $_.CPU
        Write-Host $Linea
        Add-R $Linea
    }
}

# ============================================================
# SECCION 5: ANALISIS DE MEMORIA POR PROCESO
# ============================================================
Write-Header "5. ANALISIS DE MEMORIA POR PROCESO"
Add-R ""
Add-R "[5. MEMORIA POR PROCESO]"

Write-Host "  Recopilando datos de procesos (fuente unica WMI)..." -ForegroundColor Gray

# Una sola consulta WMI con todos los campos necesarios - sin loops secundarios
$WMIProcs = Get-WmiObject Win32_Process -ErrorAction SilentlyContinue
$OwnerMap  = @{}
foreach ($W in $WMIProcs) {
    $Owner = "SYSTEM"
    try { $o = $W.GetOwner(); if ($o.User) { $Owner = $o.User } } catch { }
    $OwnerMap[[int]$W.ProcessId] = $Owner
}

# Usar List para evitar el costo de += que recrea el array en cada iteracion
$ProcMemoria = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($W in $WMIProcs) {
    if ($W.ProcessId -eq 0) { continue }
    $StartStr = "N/A"
    if ($W.CreationDate) {
        try { $StartStr = $W.ConvertToDateTime($W.CreationDate).ToString("dd/MM HH:mm") } catch { }
    }
    $Owner = if ($OwnerMap.ContainsKey([int]$W.ProcessId)) { $OwnerMap[[int]$W.ProcessId] } else { "SYSTEM" }
    $ProcMemoria.Add([PSCustomObject]@{
        Proceso        = $W.Name.Replace('.exe', '').Replace('.EXE', '')
        PID            = [int]$W.ProcessId
        RAM_MB         = [math]::Round($W.WorkingSetSize / 1MB, 1)
        RAM_Privada_MB = [math]::Round($W.PrivatePageCount / 1MB, 1)
        RAM_Virtual_MB = [math]::Round($W.VirtualSize / 1MB, 1)
        Handles        = [int]$W.HandleCount
        Threads        = [int]$W.ThreadCount
        Inicio         = $StartStr
        Propietario    = $Owner
    })
}


$TopRAM = $ProcMemoria | Sort-Object RAM_Privada_MB -Descending | Select-Object -First $TopProcesos

Write-Host ""
Write-Host ("  {0,-35}  {1,6}  {2,10}  {3,10}  {4,8}  {5,7}  {6,12}  {7,-12}" -f `
    "Proceso", "PID", "RAM MB", "RAM Priv.", "Handles", "Threads", "Inicio", "Usuario") -ForegroundColor Gray
Write-Host "  $('-' * 100)" -ForegroundColor Gray

foreach ($P in $TopRAM) {
    $AlertaRAM    = if ($P.RAM_MB         -ge $UmbralRAM_MB)  { " [RAM!]"     } else { "" }
    $AlertaHandle = if ($P.Handles        -ge $UmbralHandles) { " [HANDLES!]" } else { "" }
    $AlertaThread = if ($P.Threads        -ge $UmbralThreads) { " [THREADS!]" } else { "" }
    $Alertas      = "$AlertaRAM$AlertaHandle$AlertaThread"

    $Color = if ($P.RAM_Privada_MB -ge ($UmbralRAM_MB * 2)) { "Red" } `
             elseif ($Alertas.Length -gt 0)                 { "Yellow" } `
             else                                           { "White" }

    $Linea = "  {0,-35}  {1,6}  {2,10}  {3,10}  {4,8}  {5,7}  {6,12}  {7,-12}{8}" -f `
        $P.Proceso, $P.PID, $P.RAM_MB, $P.RAM_Privada_MB,
        $P.Handles, $P.Threads, $P.Inicio, $P.Propietario, $Alertas
    Write-Host $Linea -ForegroundColor $Color
    Add-R $Linea
}

# ============================================================
# SECCION 6: DETECCION DE FUGAS
# ============================================================
Write-Header "6. DETECCION DE FUGAS DE MEMORIA Y RECURSOS"
Add-R ""
Add-R "[6. DETECCION DE FUGAS]"

$FugasDetectadas = @()

$AltaRAM = $ProcMemoria | Where-Object { $_.RAM_Privada_MB -ge $UmbralRAM_MB }
if ($AltaRAM) {
    Write-SubHeader "Procesos con RAM privada mayor a $UmbralRAM_MB MB"
    Add-R "  >> RAM privada alta (mayor $UmbralRAM_MB MB):"
    foreach ($P in ($AltaRAM | Sort-Object RAM_Privada_MB -Descending)) {
        $Linea = "  [FUGA RAM] $($P.Proceso) (PID $($P.PID)) - $($P.RAM_Privada_MB) MB privados"
        Write-Host $Linea -ForegroundColor Red
        Add-R $Linea
        $FugasDetectadas += $Linea
    }
}

$AltosHandles = $ProcMemoria | Where-Object { $_.Handles -ge $UmbralHandles }
if ($AltosHandles) {
    Write-SubHeader "Procesos con handles excesivos (mayor $UmbralHandles)"
    Add-R "  >> Handles excesivos:"
    foreach ($P in ($AltosHandles | Sort-Object Handles -Descending)) {
        $Linea = "  [FUGA HANDLES] $($P.Proceso) (PID $($P.PID)) - $($P.Handles) handles abiertos"
        Write-Host $Linea -ForegroundColor Red
        Add-R $Linea
        $FugasDetectadas += $Linea
    }
}

$AltosThreads = $ProcMemoria | Where-Object { $_.Threads -ge $UmbralThreads }
if ($AltosThreads) {
    Write-SubHeader "Procesos con threads excesivos (mayor $UmbralThreads)"
    Add-R "  >> Threads excesivos:"
    foreach ($P in ($AltosThreads | Sort-Object Threads -Descending)) {
        $Linea = "  [FUGA THREADS] $($P.Proceso) (PID $($P.PID)) - $($P.Threads) threads activos"
        Write-Host $Linea -ForegroundColor Yellow
        Add-R $Linea
        $FugasDetectadas += $Linea
    }
}

if ($FugasDetectadas.Count -eq 0) {
    Write-Host ""
    Write-Host "  [OK] No se detectaron indicadores de fuga de memoria o recursos." -ForegroundColor Green
    Add-R "  [OK] Sin indicadores de fuga."
} else {
    Write-Host ""
    Write-Host "  [ATENCION] $($FugasDetectadas.Count) indicadores de posible fuga detectados." -ForegroundColor Red
    Add-R "  [ATENCION] $($FugasDetectadas.Count) indicadores de fuga."
}

# ============================================================
# SECCION 7: SESIONES DE USUARIO
# ============================================================
Write-Header "7. SESIONES DE USUARIO EN EL SERVIDOR TERMINAL"
Add-R ""
Add-R "[7. SESIONES DE USUARIO]"

try {
    $Sesiones = & query session 2>&1
    foreach ($S in $Sesiones) {
        Write-Host "  $S" -ForegroundColor White
        Add-R "  $S"
    }
} catch {
    Write-Host "  [INFO] No se pudo ejecutar query session: $_" -ForegroundColor Gray
    Add-R "  [INFO] query session no disponible."
}

# ============================================================
# SECCION 8: EVENTOS CRITICOS (ultimas 24h)
# ============================================================
Write-Header "8. EVENTOS CRITICOS DEL SISTEMA (ultimas 24h)"
Add-R ""
Add-R "[8. EVENTOS CRITICOS]"

try {
    $Desde   = (Get-Date).AddHours(-24)
    $Eventos = Get-EventLog -LogName System -EntryType Error,Warning -After $Desde `
               -ErrorAction SilentlyContinue |
               Sort-Object TimeGenerated -Descending |
               Select-Object -First 20

    if ($Eventos) {
        Write-Host ("  {0,-20}  {1,-10}  {2,-10}  {3}" -f "Fecha/Hora", "Tipo", "EventID", "Fuente / Mensaje") -ForegroundColor Gray
        Write-Host "  $('-' * 85)" -ForegroundColor Gray
        foreach ($E in $Eventos) {
            $Color = if ($E.EntryType -eq "Error") { "Red" } else { "Yellow" }
            $MsgRaw = $E.Message -replace "`n", " " -replace "`r", ""
            $Msg    = if ($MsgRaw.Length -gt 55) { $MsgRaw.Substring(0, 55) + "..." } else { $MsgRaw }
            $Linea  = "  {0,-20}  {1,-10}  {2,-10}  {3}: {4}" -f `
                $E.TimeGenerated.ToString("dd/MM HH:mm:ss"), $E.EntryType, $E.EventID, $E.Source, $Msg
            Write-Host $Linea -ForegroundColor $Color
            Add-R $Linea
        }
    } else {
        Write-Host "  [OK] Sin eventos criticos en las ultimas 24 horas." -ForegroundColor Green
        Add-R "  [OK] Sin eventos criticos."
    }
} catch {
    Write-Host "  [INFO] No se pudieron leer eventos: $_" -ForegroundColor Gray
    Add-R "  [INFO] Eventos no disponibles."
}

# ============================================================
# SECCION 9: USO DE DISCO
# ============================================================
Write-Header "9. USO DE DISCO"
Add-R ""
Add-R "[9. USO DE DISCO]"

Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $UsoPct = if ($_.Size -gt 0) {
        [math]::Round((($_.Size - $_.FreeSpace) / $_.Size) * 100, 1)
    } else { 0 }
    $Color = if ($UsoPct -ge 90) { "Red" } elseif ($UsoPct -ge 75) { "Yellow" } else { "Green" }
    $Linea = "  Disco {0}  Total: {1,8}  Libre: {2,8}  Usado: {3,5}%" -f `
        $_.DeviceID, (Format-Bytes $_.Size), (Format-Bytes $_.FreeSpace), $UsoPct
    Write-Host $Linea -ForegroundColor $Color
    Add-R $Linea
}

# ============================================================
# RESUMEN EJECUTIVO
# ============================================================
Write-Header "RESUMEN EJECUTIVO"
Add-R ""
Add-R "[RESUMEN EJECUTIVO]"
Add-R "Servidor : $env:COMPUTERNAME"
Add-R "Fecha    : $(Get-Date -Format 'dd/MM/yyyy HH:mm')"

$Hallazgos = @()
if ($CPUPromedio -ge 70)           { $Hallazgos += "CPU alta: ${CPUPromedio}%" }
if ($FugasDetectadas.Count -gt 0) { $Hallazgos += "$($FugasDetectadas.Count) indicadores de fuga de memoria/handles/threads" }

$AltoDisco = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" |
             Where-Object { $_.Size -gt 0 -and ((($_.Size - $_.FreeSpace) / $_.Size) * 100) -ge 90 }
if ($AltoDisco) { $Hallazgos += "Disco con uso critico detectado" }

Write-Host ""
if ($Hallazgos.Count -eq 0) {
    Write-Host "  [OK] El servidor opera dentro de parametros normales." -ForegroundColor Green
    Add-R "  RESULTADO: Operacion normal"
} else {
    Write-Host "  [ATENCION] Se detectaron los siguientes problemas:" -ForegroundColor Red
    foreach ($H in $Hallazgos) {
        Write-Host "    - $H" -ForegroundColor Yellow
        Add-R "  - $H"
    }
    Write-Host ""
    Write-Host "  Revise las secciones marcadas con [!] en el reporte." -ForegroundColor Yellow
}

try {
    $Reporte | Out-File -FilePath $ReportePath -Encoding UTF8
    Write-Host ""
    Write-Host "  Reporte guardado en: $ReportePath" -ForegroundColor Cyan
} catch {
    Write-Host "  [ERROR] No se pudo guardar el reporte: $_" -ForegroundColor Red
}

$Dur = [math]::Round(((Get-Date) - $FechaInicio).TotalSeconds, 0)
Write-Host "  Diagnostico completado en $Dur segundos." -ForegroundColor Gray
Write-Host ""
