# Testes do modulo HomeLabBackup.psm1 (copia "pull"). Sem rede: usa diretorios temporarios.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\Test-HomeLabBackup.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repo 'scripts\windows\HomeLabBackup.psm1') -Force
$script:pass = 0; $script:fail = 0
$base = Join-Path $env:USERPROFILE ("hl-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

function New-Fixture([string]$name) {
    $d = Join-Path $base $name
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'data\ab'), (Join-Path $d 'locks'), (Join-Path $d 'index') | Out-Null
    [IO.File]::WriteAllText((Join-Path $d 'config'), 'cfg')
    [IO.File]::WriteAllBytes((Join-Path $d 'data\ab\abcd'), [byte[]](1..200))
    [IO.File]::WriteAllText((Join-Path $d 'index\i1'), 'idx')
    $lines = foreach ($rel in 'config', 'data/ab/abcd', 'index/i1') {
        $h = (Get-FileHash (Join-Path $d ($rel -replace '/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$h  ./$rel"
    }
    [IO.File]::WriteAllText((Join-Path $d 'MANIFEST.sha256'), (($lines -join "`n") + "`n"))
    [IO.File]::WriteAllText((Join-Path $d 'GENERATION'), 'abc123 2026-11-27')
    return $d
}
function Check([string]$name, [scriptblock]$test) {
    try { if (& $test) { $script:pass++; Write-Host "  PASSOU $name" -ForegroundColor Green } else { throw 'resultado falso' } }
    catch { $script:fail++; Write-Host "  FALHOU $name : $($_.Exception.Message)" -ForegroundColor Red }
}

try {
    Check 'manifesto valido e aceito' { (Test-HomeLabManifest -Path (New-Fixture ok)).Ok }
    Check 'arquivo alterado e rejeitado' {
        $d = New-Fixture alterado; [IO.File]::WriteAllBytes((Join-Path $d 'data\ab\abcd'), [byte[]](1..199))
        $r = Test-HomeLabManifest -Path $d; (-not $r.Ok) -and ($r.Problems -match 'hash diferente')
    }
    Check 'arquivo ausente e rejeitado' {
        $d = New-Fixture ausente; Remove-Item (Join-Path $d 'index\i1')
        $r = Test-HomeLabManifest -Path $d; (-not $r.Ok) -and ($r.Problems -match 'ausente')
    }
    Check 'arquivo extra e rejeitado' {
        $d = New-Fixture extra; [IO.File]::WriteAllText((Join-Path $d 'data\intruso'), 'x')
        $r = Test-HomeLabManifest -Path $d; (-not $r.Ok) -and ($r.Problems -match 'fora do manifesto')
    }
    Check 'locks/ ignorado' {
        $d = New-Fixture locks; [IO.File]::WriteAllText((Join-Path $d 'locks\l1'), 'x'); (Test-HomeLabManifest -Path $d).Ok
    }
    Check 'sem manifesto e rejeitado' {
        $d = New-Fixture sem; Remove-Item (Join-Path $d 'MANIFEST.sha256'); -not (Test-HomeLabManifest -Path $d).Ok
    }
    Check 'caminho com .. e rejeitado' {
        $d = New-Fixture trav; Add-Content (Join-Path $d 'MANIFEST.sha256') ('0' * 64 + '  ./../fora')
        -not (Test-HomeLabManifest -Path $d).Ok
    }
    Check 'manifesto vazio e rejeitado' {
        $d = New-Fixture vazio; [IO.File]::WriteAllText((Join-Path $d 'MANIFEST.sha256'), '')
        Remove-Item (Join-Path $d 'config'), (Join-Path $d 'data'), (Join-Path $d 'index') -Recurse
        -not (Test-HomeLabManifest -Path $d).Ok
    }
    Check 'rotacao mantem atual e anterior' {
        $r = Join-Path $base 'rot'; New-Item -ItemType Directory $r | Out-Null
        foreach ($n in 'restic', 'restic.previous', 'restic.incoming') { New-Item -ItemType Directory (Join-Path $r $n) | Out-Null; Set-Content (Join-Path $r "$n\marca") $n }
        Invoke-HomeLabRotation -Incoming (Join-Path $r 'restic.incoming') -Current (Join-Path $r 'restic') -Previous (Join-Path $r 'restic.previous')
        ((Get-Content (Join-Path $r 'restic\marca')) -eq 'restic.incoming') -and ((Get-Content (Join-Path $r 'restic.previous\marca')) -eq 'restic') -and -not (Test-Path (Join-Path $r 'restic.incoming'))
    }
    Check 'pull nao usa scp do repositorio vivo' {
        $src = Get-Content (Join-Path $repo 'scripts\windows\pull-homelab-backup.ps1') -Raw
        ($src -notmatch 'scp\.exe') -and ($src -match 'flock -s') -and ($src -match 'Test-HomeLabManifest')
    }
} finally {
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
Write-Host "Resultado: $script:pass passaram, $script:fail falharam"
if ($script:fail -gt 0) { exit 1 }
