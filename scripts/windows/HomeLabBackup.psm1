# HomeLab - funcoes da copia "pull" do backup (testaveis isoladamente).

function Test-HomeLabManifest {
    <#
      Valida uma copia do export: todo arquivo listado em MANIFEST.sha256 existe e tem
      o SHA256 correto, e nao ha arquivos fora do manifesto (exceto MANIFEST, GENERATION
      e locks/). Devolve um objeto com Ok, Checked e Problems.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $problems = New-Object System.Collections.Generic.List[string]
    $manifest = Join-Path $Path 'MANIFEST.sha256'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Checked = 0; Problems = @('MANIFEST.sha256 ausente') }
    }
    $listed = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($manifest)) {
        if ($line -notmatch '^([0-9a-f]{64})  \./(.+)$') { $problems.Add("linha invalida no manifesto: $line"); continue }
        $hash = $Matches[1]; $rel = $Matches[2]
        if ($rel -match '(^|/)\.\.(/|$)') { $problems.Add("caminho suspeito: $rel"); continue }
        $listed[$rel] = $true
        $file = Join-Path $Path ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $problems.Add("ausente: $rel"); continue }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $hash) { $problems.Add("hash diferente: $rel") }
    }
    $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    Get-ChildItem -LiteralPath $Path -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1) -replace '\\', '/'
        if ($rel -in @('MANIFEST.sha256', 'GENERATION') -or $rel -like 'locks/*') { return }
        if (-not $listed.ContainsKey($rel)) { $problems.Add("fora do manifesto: $rel") }
    }
    [pscustomobject]@{ Ok = ($problems.Count -eq 0 -and $listed.Count -gt 0); Checked = $listed.Count; Problems = @($problems) }
}

function Invoke-HomeLabRotation {
    <#
      Promove $Incoming para $Current, mantendo a anterior em $Previous.
      So chamar depois de Test-HomeLabManifest aprovar $Incoming.
    #>
    param([Parameter(Mandatory)][string]$Incoming,
          [Parameter(Mandatory)][string]$Current,
          [Parameter(Mandatory)][string]$Previous)
    # A copia anterior so e apagada no fim; qualquer falha devolve atual/anterior ao lugar.
    $parked = "$Previous.old"
    if (Test-Path -LiteralPath $parked) { Remove-Item -LiteralPath $parked -Recurse -Force }
    $movedPrev = $false; $movedCur = $false
    try {
        if (Test-Path -LiteralPath $Previous) { Rename-Item -LiteralPath $Previous -NewName (Split-Path $parked -Leaf); $movedPrev = $true }
        if (Test-Path -LiteralPath $Current)  { Rename-Item -LiteralPath $Current -NewName (Split-Path $Previous -Leaf); $movedCur = $true }
        Rename-Item -LiteralPath $Incoming -NewName (Split-Path $Current -Leaf)
    } catch {
        if ($movedCur -and -not (Test-Path -LiteralPath $Current) -and (Test-Path -LiteralPath $Previous)) {
            Rename-Item -LiteralPath $Previous -NewName (Split-Path $Current -Leaf)
        }
        if ($movedPrev -and -not (Test-Path -LiteralPath $Previous) -and (Test-Path -LiteralPath $parked)) {
            Rename-Item -LiteralPath $parked -NewName (Split-Path $Previous -Leaf)
        }
        throw "rotacao falhou; copia atual preservada: $($_.Exception.Message)"
    }
    if (Test-Path -LiteralPath $parked) { Remove-Item -LiteralPath $parked -Recurse -Force -ErrorAction SilentlyContinue }
}

function Enter-HomeLabPullLock {
    <#
      Lock exclusivo entre processos (arquivo aberto sem compartilhamento).
      Devolve o FileStream (manter aberto ate o fim) ou $null se outro pull estiver rodando.
    #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        return $null
    }
}

Export-ModuleMember -Function Test-HomeLabManifest, Invoke-HomeLabRotation, Enter-HomeLabPullLock
