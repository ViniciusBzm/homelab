# Configura o ICS Wi-Fi -> Ethernet de forma persistente. Executar ELEVADO (uma vez).
# 1) EnableRebootPersistConnection=1 (KB4055559)  2) SharedAccess = Automatico
# 3) Watchdog como tarefa SYSTEM (boot + a cada 5 min)  4) Aplica o ICS agora
param([Parameter(Mandatory)][string]$LogPath)

Start-Transcript -Path $LogPath -Force | Out-Null
try {
    $src = Join-Path $PSScriptRoot 'ics-watchdog.ps1'
    $dir = 'C:\ProgramData\HomeLab'
    $dst = Join-Path $dir 'ics-watchdog.ps1'

    Write-Host '== Pasta protegida =='
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # Somente SYSTEM/Administradores escrevem; Usuarios apenas leem (o script roda como SYSTEM)
    icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Host
    Copy-Item $src $dst -Force
    icacls $dst /reset | Out-Null

    Write-Host '== Registro: EnableRebootPersistConnection =='
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\SharedAccess'
    New-ItemProperty -Path $key -Name EnableRebootPersistConnection -PropertyType DWord -Value 1 -Force | Out-Null
    Get-ItemProperty $key | Select-Object EnableRebootPersistConnection | Format-List | Out-Host

    Write-Host '== Servico SharedAccess =='
    Set-Service -Name SharedAccess -StartupType Automatic
    if ((Get-Service SharedAccess).Status -ne 'Running') { Start-Service SharedAccess }
    Get-Service SharedAccess | Select-Object Name, Status, StartType | Format-List | Out-Host

    Write-Host '== Tarefa agendada =='
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dst`""
    $tBoot  = New-ScheduledTaskTrigger -AtStartup
    $tBoot.Delay = 'PT1M'
    $tRep   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $princ  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'HomeLab ICS Watchdog' -TaskPath '\HomeLab\' -Action $action -Trigger @($tBoot, $tRep) -Principal $princ -Settings $set -Description 'Mantem o ICS Wi-Fi -> Ethernet ativo para o servidor do HomeLab' -Force | Out-Null
    Get-ScheduledTask -TaskPath '\HomeLab\' | Select-Object TaskName, State | Format-List | Out-Host

    Write-Host '== Aplicando ICS agora (via watchdog) =='
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dst
    Get-Content (Join-Path $dir 'ics-watchdog.log') -Tail 5 -ErrorAction SilentlyContinue | Out-Host

    Write-Host '== Estado final ICS =='
    $m = New-Object -ComObject HNetCfg.HNetShare
    foreach ($c in $m.EnumEveryConnection) {
        $p = $m.NetConnectionProps.Invoke($c); $cfg = $m.INetSharingConfigurationForINetConnection.Invoke($c)
        if ($cfg.SharingEnabled) { Write-Host "  $($p.Name): compartilhamento ativo, tipo $($cfg.SharingConnectionType)" }
    }
    Write-Host 'SETUP_OK'
} catch {
    Write-Host "SETUP_ERRO: $($_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
