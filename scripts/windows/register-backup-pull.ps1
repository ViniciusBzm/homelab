# Registra a tarefa do USUARIO (sem administrador) que puxa o backup do HomeLab.
# Uso: .\register-backup-pull.ps1   (reexecutar e seguro)
# Fora de %LOCALAPPDATA%: apps empacotados (MSIX) tem essa pasta virtualizada,
# e a tarefa agendada nao enxergaria o script.
$dir = Join-Path $env:USERPROFILE '.homelab'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$dst = Join-Path $dir 'pull-homelab-backup.ps1'
Copy-Item (Join-Path $PSScriptRoot 'pull-homelab-backup.ps1') $dst -Force
Copy-Item (Join-Path $PSScriptRoot 'HomeLabBackup.psm1') (Join-Path $dir 'HomeLabBackup.psm1') -Force

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dst`""
$daily  = New-ScheduledTaskTrigger -Daily -At '12:00'
$logon  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$logon.Delay = 'PT10M'
$princ  = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$set    = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'HomeLab Backup Pull' -TaskPath '\HomeLab\' -Action $action -Trigger @($daily, $logon) -Principal $princ -Settings $set `
  -Description 'Copia o repositorio restic (criptografado) do servidor do HomeLab para este PC' -Force | Out-Null
Write-Host "Tarefa registrada; script em $dst"
