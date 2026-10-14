# ==============================================================================
# Fichier : MisesAJour.ps1
# Projet  : WinBox & Safe PC
# Version : 2.6.35 (messages d’absence de mises à jour harmonisés)
# ==============================================================================

$ConfirmPreference = 'None'
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'SilentlyContinue'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    $null = $_.Exception
}

# --- Initialisation de la détection du PC ---
# La détection du fabricant/modèle ne doit pas dépendre de BIOS/BaseBoard :
# une panne ponctuelle de CIM sur l'un de ces fournisseurs ne doit pas transformer
# un PC connu en « Inconnu PC ».
$fabricant = 'Inconnu'
$modele = 'PC'
$numeroSerie = ''
$carteMere = ''

try {
    $systemInfo = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop

    if ($systemInfo.Manufacturer) {
        $fabricant = $systemInfo.Manufacturer.Trim()
        $fabricant = $fabricant -replace '(?i)\s*Inc\..*', ''
        $fabricant = $fabricant -replace '(?i)\s*Corporation.*', ''
        $fabricant = $fabricant -replace '(?i)\s*Co\.,\s*Ltd\..*', ''
        $fabricant = $fabricant -replace '(?i)\s*Computer.*', ''
    }

    if ($systemInfo.Model) {
        $modele = $systemInfo.Model.Trim()
    }
} catch {
    $null = $_.Exception
}

try {
    $biosInfo = Get-CimInstance Win32_BIOS -ErrorAction Stop
    if ($biosInfo.SerialNumber) {
        $numeroSerie = $biosInfo.SerialNumber.Trim()
    }
} catch {
    $null = $_.Exception
}

try {
    $boardInfo = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
    if ($boardInfo.Product) {
        $carteMere = $boardInfo.Product.Trim()
    }
} catch {
    $null = $_.Exception
}

if (($modele -match '(?i)System Product Name' -or $modele -match '(?i)To be filled' -or $modele -match '(?i)O\.E\.M') -and $carteMere) {
    $modele = $carteMere
}

# Astuce pour faire taire l'avertissement PSScriptAnalyzer sur $numeroSerie
[void]$numeroSerie

# --- Recherche constructeur déportée vers MisesAJourConstructeur.ps1 ---

$win32Api = @'
[DllImport("shell32.dll", SetLastError = true)]
public static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@

if (-not ([System.Management.Automation.PSTypeName]'Win32Updates.Win32Utils').Type) {
    Add-Type -MemberDefinition $win32Api -Name Win32Utils -Namespace Win32Updates -ErrorAction SilentlyContinue
}

try {
    [Win32Updates.Win32Utils]::SetCurrentProcessExplicitAppUserModelID('WinBoxSafePC.UpdatesModule')
} catch {
    $null = $_.Exception
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Module de recherche constructeur ---
$ConstructeurModulePath = Join-Path $PSScriptRoot 'MisesAJourConstructeur.ps1'
if (Test-Path $ConstructeurModulePath) {
    try {
        . $ConstructeurModulePath
    } catch {
        $null = $_.Exception
    }
}

$AppRoot = $PSScriptRoot
if (-not $AppRoot) {
    $AppRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
if ($AppRoot -like '*\Source' -or $AppRoot -like '*\Dashboard' -or $AppRoot -like '*/Source' -or $AppRoot -like '*/Dashboard') {
    $AppRoot = Split-Path $AppRoot -Parent
}

$IconPath = Join-Path $AppRoot 'caisse-à-outils.ico'
if (-not (Test-Path $IconPath)) {
    $IconPath = Join-Path $AppRoot 'Assets\caisse-à-outils.ico'
}

$script:UpdateStore = @{
    WinUpdate    = @()
    ModernUpdate = @()
    Drivers      = @()
    Winget       = @()
    Constructeur = @()
}
$script:IsActionRunning = $false
$script:CancelRequested = $false
$script:ActiveProcess = $null

function Invoke-WuaSearchCancelable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Criteria,
        [string]$ServiceId = ''
    )

    $pwshCommand = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($pwshCommand) {
        $pwshPath = $pwshCommand.Source
    } elseif (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe')) {
        $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    } else {
        $powershellCommand = Get-Command 'powershell.exe' -ErrorAction SilentlyContinue
        if ($powershellCommand) {
            $pwshPath = $powershellCommand.Source
        } else {
            throw 'PowerShell est introuvable pour la recherche Windows Update asynchrone.'
        }
    }

    $criteriaJson = $Criteria | ConvertTo-Json -Compress
    $serviceJson = $ServiceId | ConvertTo-Json -Compress
    $childScript = @"
`$criteria = $criteriaJson | ConvertFrom-Json
`$serviceId = $serviceJson | ConvertFrom-Json
`$session = New-Object -ComObject Microsoft.Update.Session
`$session.ClientApplicationID = 'WinBoxSafePC'
`$searcher = `$session.CreateUpdateSearcher()
if ([string]::IsNullOrWhiteSpace([string]`$serviceId)) {
    `$searcher.ServerSelection = 2
    `$searcher.Online = `$true
} else {
    `$searcher.ServerSelection = 3
    `$searcher.ServiceID = [string]`$serviceId
}
`$result = `$searcher.Search([string]`$criteria)
`$items = @()
for (`$i = 0; `$i -lt `$result.Updates.Count; `$i++) {
    `$u = `$result.Updates.Item(`$i)
    `$items += [PSCustomObject]@{
        Title = [string]`$u.Title
        UpdateId = [string]`$u.Identity.UpdateID
    }
}
`$items | ConvertTo-Json -Compress
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwshPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $script:ActiveProcess = $process

    try {
        if (-not $process.Start()) {
            throw 'Impossible de démarrer la recherche Windows Update.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $process.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:CancelRequested) {
                try { $process.Kill() } catch { $null = $_.Exception }
                return @()
            }
            if ($sw.ElapsedMilliseconds -gt 300000) {
                try { $process.Kill() } catch { $null = $_.Exception }
                throw 'La recherche Windows Update a dépassé le délai de 5 minutes.'
            }
            Start-Sleep -Milliseconds 100
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($stderr)) { $stderr = 'Aucun détail fourni par le processus de recherche.' }
            throw $stderr.Trim()
        }
        if ([string]::IsNullOrWhiteSpace($stdout)) { return @() }
        $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    } finally {
        $script:ActiveProcess = $null
        try { $process.Dispose() } catch { $null = $_.Exception }
    }
}

function Get-WuaUpdateObjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Criteria,
        [string]$ServiceId = ''
    )

    # IMPORTANT : les objets IUpdate sont des objets COM appartenant au
    # processus courant. Ils doivent être conservés tels quels pour pouvoir
    # être passés ensuite à IUpdateDownloader/IUpdateInstaller.
    # Une recherche dans un processus PowerShell enfant ne peut pas nous
    # restituer ces objets COM utilisables pour l'installation.
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'WinBoxSafePC'
    $searcher = $session.CreateUpdateSearcher()

    if ([string]::IsNullOrWhiteSpace($ServiceId)) {
        $searcher.ServerSelection = 2
        $searcher.Online = $true
    } else {
        $searcher.ServerSelection = 3
        $searcher.ServiceID = [string]$ServiceId
        $searcher.Online = $true
    }

    $result = $searcher.Search($Criteria)
    $items = New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        if ($script:CancelRequested) { break }
        $update = $result.Updates.Item($i)
        if ($null -ne $update) {
            [void]$items.Add($update)
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    return @($items)
}

function Get-ModernWindowsUpdates {
    [CmdletBinding()]
    param()

    $candidatePaths = @(
        (Join-Path $AppRoot 'Tools\WinBoxSafePC.WindowsUpdate.exe'),
        (Join-Path $AppRoot 'Source\Tools\WinBoxSafePC.WindowsUpdate.exe'),
        (Join-Path $PSScriptRoot 'Tools\WinBoxSafePC.WindowsUpdate.exe')
    ) | Select-Object -Unique

    $toolPath = $null
    foreach ($candidate in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $toolPath = $candidate
            break
        }
    }

    if (-not $toolPath) {
        throw 'Outil Windows Update moderne introuvable : WinBoxSafePC.WindowsUpdate.exe.'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $toolPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $script:ActiveProcess = $process

    try {
        if (-not $process.Start()) {
            throw 'Impossible de démarrer l''outil Windows Update moderne.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $process.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()

            if ($script:CancelRequested) {
                try { $process.Kill() } catch { $null = $_.Exception }
                return @()
            }

            if ($sw.ElapsedMilliseconds -gt 60000) {
                try { $process.Kill() } catch { $null = $_.Exception }
                throw 'L''outil Windows Update moderne n''a pas répondu dans le délai imparti.'
            }

            Start-Sleep -Milliseconds 100
        }

        $sw.Stop()

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($stderr)) {
                $stderr = 'Aucun détail fourni par l''outil.'
            }
            throw "Outil Windows Update moderne : $stderr"
        }

        if ([string]::IsNullOrWhiteSpace($stdout)) {
            return @()
        }

        $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed) {
            return @()
        }

        if ($parsed.PSObject.Properties.Name -contains 'Error') {
            throw [string]$parsed.Message
        }

        return @($parsed)
    }
    finally {
        $script:ActiveProcess = $null
        try { $process.Dispose() } catch { $null = $_.Exception }
    }
}

function Install-ModernWindowsUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$UpdateId
    )

    $candidatePaths = @(
        (Join-Path $AppRoot 'Tools\WinBoxSafePC.WindowsUpdate.exe'),
        (Join-Path $AppRoot 'Source\Tools\WinBoxSafePC.WindowsUpdate.exe'),
        (Join-Path $PSScriptRoot 'Tools\WinBoxSafePC.WindowsUpdate.exe')
    ) | Select-Object -Unique

    $toolPath = $null
    foreach ($candidate in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $toolPath = $candidate
            break
        }
    }

    if (-not $toolPath) {
        throw 'Outil Windows Update moderne introuvable : WinBoxSafePC.WindowsUpdate.exe.'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $toolPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.Arguments = '--install "' + ($UpdateId -replace '"','') + '"'

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $script:ActiveProcess = $process

    try {
        if (-not $process.Start()) {
            throw 'Impossible de démarrer l''outil Windows Update moderne.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $process.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()

            if ($script:CancelRequested) {
                try { $process.Kill() } catch { $null = $_.Exception }
                return 'CANCELLED'
            }

            if ($sw.ElapsedMilliseconds -gt 3000000) {
                try { $process.Kill() } catch { $null = $_.Exception }
                throw 'L''installation Windows Update moderne n''a pas terminé dans le délai imparti (50 minutes).'
            }

            Start-Sleep -Milliseconds 100
        }

        $sw.Stop()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($stderr)) {
                $stderr = 'Aucun détail fourni par l''outil.'
            }
            throw "Outil Windows Update moderne : $stderr"
        }

        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            try {
                $result = $stdout | ConvertFrom-Json -ErrorAction Stop
                if ($result.PSObject.Properties.Name -contains 'RequiresUserAction' -and [bool]$result.RequiresUserAction) {
                    Start-Process 'ms-settings:windowsupdate'
                    return 'REDIRECTED'
                }
                if ($result.PSObject.Properties.Name -contains 'Success' -and -not [bool]$result.Success) {
                    throw [string]$result.Message
                }
            } catch {
                if ($_.Exception.Message -notlike 'Outil Windows Update moderne :*') {
                    throw
                }
            }
        }

        return 'SUCCESS'
    }
    finally {
        $script:ActiveProcess = $null
        try { $process.Dispose() } catch { $null = $_.Exception }
    }
}

function Test-PendingReboot {
    [CmdletBinding()]
    param()

    $rebootRequired = $false
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $rebootRequired = $true
    }
    if (Test-Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $rebootRequired = $true
    }
    if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue) {
        $rebootRequired = $true
    }
    return $rebootRequired
}

$largeurFenetre = 880
$hauteurFenetre = 820
$fenetre = New-Object System.Windows.Forms.Form
$fenetre.Text = 'WinBox & Safe PC - Centre de Mises à Jour & Optimisation'
$fenetre.Size = New-Object System.Drawing.Size($largeurFenetre, $hauteurFenetre)
$fenetre.MinimumSize = New-Object System.Drawing.Size(760, 650)
$fenetre.StartPosition = 'CenterScreen'
$fenetre.FormBorderStyle = 'Sizable'
$fenetre.MaximizeBox = $true
$fenetre.MinimizeBox = $true
$fenetre.ShowInTaskbar = $true
$fenetre.BackColor = [System.Drawing.Color]::FromArgb(25, 30, 40)

if (Test-Path $IconPath) {
    try {
        $fenetre.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($IconPath)
    } catch {
        $null = $_.Exception
    }
}

$lblTitre = New-Object System.Windows.Forms.Label
$lblTitre.Text = 'Gestionnaire de Mises à Jour'
$lblTitre.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$lblTitre.ForeColor = [System.Drawing.Color]::Cyan
$lblTitre.Size = New-Object System.Drawing.Size(($largeurFenetre - 40), 35)
$lblTitre.Location = New-Object System.Drawing.Point(20, 15)
$lblTitre.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
                  [System.Windows.Forms.AnchorStyles]::Left -bor
                  [System.Windows.Forms.AnchorStyles]::Right
$lblTitre.TextAlign = 'MiddleCenter'
$fenetre.Controls.Add($lblTitre)

$lblSystemInfo = New-Object System.Windows.Forms.Label
$lblSystemInfo.Text = "Système détecté : $fabricant $modele"
$lblSystemInfo.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
$lblSystemInfo.ForeColor = [System.Drawing.Color]::LightGray
$lblSystemInfo.Size = New-Object System.Drawing.Size(($largeurFenetre - 40), 20)
$lblSystemInfo.Location = New-Object System.Drawing.Point(20, 50)
$lblSystemInfo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
                        [System.Windows.Forms.AnchorStyles]::Left -bor
                        [System.Windows.Forms.AnchorStyles]::Right
$lblSystemInfo.TextAlign = 'MiddleCenter'
$fenetre.Controls.Add($lblSystemInfo)

$panelAccueil = New-Object System.Windows.Forms.Panel
$panelAccueil.Size = New-Object System.Drawing.Size(($largeurFenetre - 80), 580)
$panelAccueil.Location = New-Object System.Drawing.Point(40, 85)
$panelAccueil.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
                       [System.Windows.Forms.AnchorStyles]::Bottom -bor
                       [System.Windows.Forms.AnchorStyles]::Left -bor
                       [System.Windows.Forms.AnchorStyles]::Right
$panelAccueil.BackColor = [System.Drawing.Color]::FromArgb(35, 40, 55)
$panelAccueil.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$fenetre.Controls.Add($panelAccueil)

function Add-CategoryOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][int]$PosY,
        [Parameter(Mandatory=$true)][string]$Name
    )
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Name = $Name
    $chk.Text = '   ' + $Title
    $chk.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $chk.ForeColor = [System.Drawing.Color]::White
    $chk.Size = New-Object System.Drawing.Size(720, 30)
    $chk.Location = New-Object System.Drawing.Point(40, $PosY)
    $chk.Checked = $true
    $chk.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
                   [System.Windows.Forms.AnchorStyles]::Left -bor
                   [System.Windows.Forms.AnchorStyles]::Right
    $panelAccueil.Controls.Add($chk)
    return $chk
}

$chkWinUpdate = Add-CategoryOption -Title 'Mises à jour Windows (Windows Update)' -PosY 55 -Name 'chkWinUpdate'
$chkWinget    = Add-CategoryOption -Title 'Logiciels classiques et Microsoft Store (Winget)' -PosY 120 -Name 'chkWinget'
$chkDrivers   = Add-CategoryOption -Title 'Pilotes matériels (Drivers)' -PosY 185 -Name 'chkDrivers'

# Astuce pour faire taire les avertissements PSScriptAnalyzer
[void]$chkWinUpdate
[void]$chkWinget
[void]$chkDrivers

# --- Information sur la vérification constructeur ---
$panelInfoConstructeur = New-Object System.Windows.Forms.Panel
$panelInfoConstructeur.Size = New-Object System.Drawing.Size(720, 130)
$panelInfoConstructeur.Location = New-Object System.Drawing.Point(40, 250)
$panelInfoConstructeur.BackColor = [System.Drawing.Color]::FromArgb(30, 35, 48)
$panelInfoConstructeur.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$panelInfoConstructeur.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
                                 [System.Windows.Forms.AnchorStyles]::Left -bor
                                 [System.Windows.Forms.AnchorStyles]::Right
$panelAccueil.Controls.Add($panelInfoConstructeur)

$lblInfoConstructeur = New-Object System.Windows.Forms.Label
$lblInfoConstructeur.Text = 'VÉRIFICATION CONSTRUCTEUR'
$lblInfoConstructeur.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblInfoConstructeur.ForeColor = [System.Drawing.Color]::Cyan
$lblInfoConstructeur.Size = New-Object System.Drawing.Size(680, 22)
$lblInfoConstructeur.Location = New-Object System.Drawing.Point(12, 8)
$panelInfoConstructeur.Controls.Add($lblInfoConstructeur)

$lblInfoConstructeurDetails = New-Object System.Windows.Forms.Label
$lblInfoConstructeurDetails.Text = 'WinBox recherche les mises à jour Windows, applications et pilotes, ainsi que les mises à jour constructeur lorsqu''elles sont disponibles.' + [Environment]::NewLine + [Environment]::NewLine + 'Pour une vérification complète du BIOS, du firmware et des pilotes spécifiques à votre modèle, utilisez également l''outil officiel du constructeur de votre ordinateur.'
$lblInfoConstructeurDetails.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
$lblInfoConstructeurDetails.ForeColor = [System.Drawing.Color]::LightGray
$lblInfoConstructeurDetails.Size = New-Object System.Drawing.Size(690, 88)
$lblInfoConstructeurDetails.Location = New-Object System.Drawing.Point(12, 32)
$panelInfoConstructeur.Controls.Add($lblInfoConstructeurDetails)

$btnAnalyse = New-Object System.Windows.Forms.Button
$btnAnalyse.Text = 'Lancer l''analyse des mises à jour'
$btnAnalyse.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnAnalyse.Size = New-Object System.Drawing.Size(360, 45)
$btnAnalyse.Location = New-Object System.Drawing.Point(215, 395)
$btnAnalyse.BackColor = [System.Drawing.Color]::DarkCyan
$btnAnalyse.ForeColor = [System.Drawing.Color]::White
$btnAnalyse.FlatStyle = 'Flat'
$panelAccueil.Controls.Add($btnAnalyse)

$progressBarAnalyse = New-Object System.Windows.Forms.ProgressBar
$progressBarAnalyse.Location = New-Object System.Drawing.Point(40, 465)
$progressBarAnalyse.Size = New-Object System.Drawing.Size(560, 16)
$progressBarAnalyse.Minimum = 0
$progressBarAnalyse.Maximum = 100
$progressBarAnalyse.Value = 0
$progressBarAnalyse.Visible = $true 
$panelAccueil.Controls.Add($progressBarAnalyse)

$btnAnnulerAnalyse = New-Object System.Windows.Forms.Button
$btnAnnulerAnalyse.Text = 'Annuler'
$btnAnnulerAnalyse.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnAnnulerAnalyse.Size = New-Object System.Drawing.Size(140, 26)
$btnAnnulerAnalyse.Location = New-Object System.Drawing.Point(610, 459)
$btnAnnulerAnalyse.BackColor = [System.Drawing.Color]::FromArgb(160, 80, 50)
$btnAnnulerAnalyse.ForeColor = [System.Drawing.Color]::White
$btnAnnulerAnalyse.FlatStyle = 'Flat'
$btnAnnulerAnalyse.Visible = $true  
$btnAnnulerAnalyse.Enabled = $false 

$btnAnnulerAnalyse.Add_Click({
    $script:CancelRequested = $true
    $btnAnnulerAnalyse.Enabled = $false
    $lblStatusAnalyse.Text = 'Annulation demandée, arrêt propre en cours...'
    if ($script:ActiveProcess -and -not $script:ActiveProcess.HasExited) {
        try {
            $script:ActiveProcess.Kill()
        } catch {
            $null = $_.Exception
        }
    }
})
$panelAccueil.Controls.Add($btnAnnulerAnalyse)

$lblStatusAnalyse = New-Object System.Windows.Forms.Label
$lblStatusAnalyse.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
$lblStatusAnalyse.ForeColor = [System.Drawing.Color]::Cyan
$lblStatusAnalyse.Size = New-Object System.Drawing.Size(710, 25)
$lblStatusAnalyse.Location = New-Object System.Drawing.Point(40, 490)
$lblStatusAnalyse.TextAlign = 'MiddleCenter'
$lblStatusAnalyse.Visible = $true
$lblStatusAnalyse.Text = ''
$panelAccueil.Controls.Add($lblStatusAnalyse)

$panelResultats = New-Object System.Windows.Forms.Panel
$panelResultats.Size = $panelAccueil.Size
$panelResultats.Location = $panelAccueil.Location
$panelResultats.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
                         [System.Windows.Forms.AnchorStyles]::Bottom -bor
                         [System.Windows.Forms.AnchorStyles]::Left -bor
                         [System.Windows.Forms.AnchorStyles]::Right
$panelResultats.BackColor = $panelAccueil.BackColor
$panelResultats.Visible = $false
$fenetre.Controls.Add($panelResultats)

$script:DirectSectionRatio = 0.68
$script:DraggingSectionSplitter = $false
$script:SplitterDragStartY = 0
$script:SplitterDragStartRatio = 0.68

# --- Zone 1 : mises à jour installables directement ---
$lblSectionDirect = New-Object System.Windows.Forms.Label
$lblSectionDirect.Text = 'MISES À JOUR INSTALLABLES DIRECTEMENT'
$lblSectionDirect.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$lblSectionDirect.ForeColor = [System.Drawing.Color]::Cyan
$lblSectionDirect.Location = New-Object System.Drawing.Point(15, 8)
$lblSectionDirect.Size = New-Object System.Drawing.Size(500, 24)
$panelResultats.Controls.Add($lblSectionDirect)

$listView = New-Object System.Windows.Forms.ListView
$listView.View = [System.Windows.Forms.View]::Details
$listView.GridLines = $false
$listView.CheckBoxes = $true
$listView.BackColor = [System.Drawing.Color]::FromArgb(30, 35, 48)
$listView.ForeColor = [System.Drawing.Color]::White
$listView.Location = New-Object System.Drawing.Point(15, 34)
$listView.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
[void]$listView.Columns.Add('Source', 155)
[void]$listView.Columns.Add('Élément disponible', 515)
[void]$listView.Columns.Add('État', 120)
$panelResultats.Controls.Add($listView)

# --- Zone 2 : mises à jour nécessitant Windows Update ---
$lblSectionWindowsUpdate = New-Object System.Windows.Forms.Label
$lblSectionWindowsUpdate.Text = 'MISES À JOUR NÉCESSITANT WINDOWS UPDATE'
$lblSectionWindowsUpdate.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$lblSectionWindowsUpdate.ForeColor = [System.Drawing.Color]::Cyan
$lblSectionWindowsUpdate.Location = New-Object System.Drawing.Point(15, 0)
$lblSectionWindowsUpdate.Size = New-Object System.Drawing.Size(600, 24)

$panelWindowsUpdate = New-Object System.Windows.Forms.Panel
$panelWindowsUpdate.Location = New-Object System.Drawing.Point(15, 0)
$panelWindowsUpdate.BackColor = $panelResultats.BackColor
$panelWindowsUpdate.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$panelResultats.Controls.Add($panelWindowsUpdate)
$panelWindowsUpdate.Controls.Add($lblSectionWindowsUpdate)

# Barre de séparation déplaçable : permet d'agrandir la première liste à la souris.
$panelSectionSplitter = New-Object System.Windows.Forms.Panel
$panelSectionSplitter.Height = 7
$panelSectionSplitter.BackColor = [System.Drawing.Color]::FromArgb(75, 90, 110)
$panelSectionSplitter.Cursor = [System.Windows.Forms.Cursors]::HSize
$panelSectionSplitter.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$panelResultats.Controls.Add($panelSectionSplitter)
$panelSectionSplitter.BringToFront()
$panelSectionSplitter.Add_MouseDown({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:DraggingSectionSplitter = $true
        $script:SplitterDragStartY = [System.Windows.Forms.Control]::MousePosition.Y
        $script:SplitterDragStartRatio = $script:DirectSectionRatio
        $panelSectionSplitter.Capture = $true
    }
})
$panelSectionSplitter.Add_MouseMove({
    if ($script:DraggingSectionSplitter) {
        $delta = [System.Windows.Forms.Control]::MousePosition.Y - $script:SplitterDragStartY
        $available = [Math]::Max(1, $panelResultats.Height - 220)
        $script:DirectSectionRatio = [Math]::Max(0.35, [Math]::Min(0.82, $script:SplitterDragStartRatio + ($delta / $available)))
        Set-UpdatesLayout
    }
})
$panelSectionSplitter.Add_MouseUp({
    $script:DraggingSectionSplitter = $false
    $panelSectionSplitter.Capture = $false
})

$listViewWindowsUpdate = New-Object System.Windows.Forms.ListView
$listViewWindowsUpdate.View = [System.Windows.Forms.View]::Details
$listViewWindowsUpdate.GridLines = $false
$listViewWindowsUpdate.CheckBoxes = $true
$listViewWindowsUpdate.BackColor = [System.Drawing.Color]::FromArgb(30, 35, 48)
$listViewWindowsUpdate.ForeColor = [System.Drawing.Color]::White
$listViewWindowsUpdate.Location = New-Object System.Drawing.Point(0, 28)
$listViewWindowsUpdate.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
[void]$listViewWindowsUpdate.Columns.Add('Source', 155)
[void]$listViewWindowsUpdate.Columns.Add('Élément disponible', 515)
[void]$listViewWindowsUpdate.Columns.Add('État', 170)
$panelWindowsUpdate.Controls.Add($listViewWindowsUpdate)

$lblWindowsUpdateInfo = New-Object System.Windows.Forms.Label
$lblWindowsUpdateInfo.Text = 'Ces mises à jour sont détectées par WinBox mais doivent être téléchargées et installées par Windows Update.'
$lblWindowsUpdateInfo.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Italic)
$lblWindowsUpdateInfo.ForeColor = [System.Drawing.Color]::LightGray
$lblWindowsUpdateInfo.AutoSize = $false
$lblWindowsUpdateInfo.TextAlign = 'MiddleLeft'
$lblWindowsUpdateInfo.Location = New-Object System.Drawing.Point(0, 0)
$lblWindowsUpdateInfo.Size = New-Object System.Drawing.Size(600, 24)
$lblWindowsUpdateInfo.Visible = $false
$panelResultats.Controls.Add($lblWindowsUpdateInfo)

$btnOuvrirWindowsUpdate = New-Object System.Windows.Forms.Button
$btnOuvrirWindowsUpdate.Text = 'Ouvrir Windows Update'
$btnOuvrirWindowsUpdate.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnOuvrirWindowsUpdate.Size = New-Object System.Drawing.Size(210, 36)
$btnOuvrirWindowsUpdate.BackColor = [System.Drawing.Color]::FromArgb(60, 90, 120)
$btnOuvrirWindowsUpdate.ForeColor = [System.Drawing.Color]::White
$btnOuvrirWindowsUpdate.FlatStyle = 'Flat'
$btnOuvrirWindowsUpdate.Visible = $false
$btnOuvrirWindowsUpdate.Add_Click({
    if ($script:IsActionRunning) { return }
    try {
        Start-Process 'ms-settings:windowsupdate'
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Impossible d'ouvrir Windows Update : $($_.Exception.Message)", 'Windows Update', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})
$panelResultats.Controls.Add($btnOuvrirWindowsUpdate)

function Set-UpdateRowStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][System.Windows.Forms.ListViewItem]$Row,
        [Parameter(Mandatory=$true)][string]$Status,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::White
    )

    if ($Row.SubItems.Count -lt 3) {
        [void]$Row.SubItems.Add('')
    }

    $Row.SubItems[2].Text = $Status
    $Row.ForeColor = $Color
}

function Get-NormalizedUpdateTitle {
    [CmdletBinding()]
    param([AllowNull()][string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ''
    }

    $value = $Title.ToLowerInvariant()
    $value = $value -replace '\([^)]*\)', ' '
    $value = $value -replace '\|\s*v?\s*[0-9][0-9a-zA-Z.\-]*', ' '
    $value = $value -replace 'v[0-9][0-9a-zA-Z.\-]*', ' '
    $value = $value -replace '[^a-z0-9]+', ''
    return $value
}

function New-UpdateRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Title
    )

    $row = New-Object System.Windows.Forms.ListViewItem($Source)
    [void]$row.SubItems.Add($Title)
    [void]$row.SubItems.Add('Disponible')
    $row.Checked = $true
    return $row
}

$lblEmpty = New-Object System.Windows.Forms.Label
$lblEmpty.Text = '✓ Aucune mise à jour installable directement détectée.'
$lblEmpty.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblEmpty.ForeColor = [System.Drawing.Color]::MediumSpringGreen
$lblEmpty.TextAlign = 'MiddleCenter'
$lblEmpty.Visible = $false
$panelResultats.Controls.Add($lblEmpty)

$lblEmptyWindowsUpdate = New-Object System.Windows.Forms.Label
$lblEmptyWindowsUpdate.Text = "✓ Aucune mise à jour nécessitant Windows Update n'a été détectée."
$lblEmptyWindowsUpdate.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblEmptyWindowsUpdate.ForeColor = [System.Drawing.Color]::MediumSpringGreen
$lblEmptyWindowsUpdate.TextAlign = 'MiddleCenter'
$lblEmptyWindowsUpdate.Visible = $false
$panelWindowsUpdate.Controls.Add($lblEmptyWindowsUpdate)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 435)
$progressBar.Size = New-Object System.Drawing.Size(615, 16)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$progressBar.Visible = $false 
$panelResultats.Controls.Add($progressBar)
$btnAnnulerInst = New-Object System.Windows.Forms.Button
$btnAnnulerInst.Text = 'Annuler'
$btnAnnulerInst.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnAnnulerInst.Size = New-Object System.Drawing.Size(140, 26)
$btnAnnulerInst.Location = New-Object System.Drawing.Point(640, 430)
$btnAnnulerInst.BackColor = [System.Drawing.Color]::FromArgb(160, 80, 50)
$btnAnnulerInst.ForeColor = [System.Drawing.Color]::White
$btnAnnulerInst.FlatStyle = 'Flat'
$btnAnnulerInst.Visible = $false 
$btnAnnulerInst.Enabled = $false 

$btnAnnulerInst.Add_Click({
    $script:CancelRequested = $true
    $btnAnnulerInst.Enabled = $false
    $lblProgressStatus.Text = 'Annulation demandée, arrêt propre en cours...'
    if ($script:ActiveProcess -and -not $script:ActiveProcess.HasExited) {
        try {
            $script:ActiveProcess.Kill()
        } catch {
            $null = $_.Exception
        }
    }
})
$panelResultats.Controls.Add($btnAnnulerInst)

$lblProgressStatus = New-Object System.Windows.Forms.Label
$lblProgressStatus.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Italic)
$lblProgressStatus.ForeColor = [System.Drawing.Color]::Cyan
$lblProgressStatus.Size = New-Object System.Drawing.Size(($panelResultats.Width - 30), 20)
$lblProgressStatus.Location = New-Object System.Drawing.Point(15, 455)
$lblProgressStatus.Visible = $true
$lblProgressStatus.Text = ''
$panelResultats.Controls.Add($lblProgressStatus)

$btnRetour = New-Object System.Windows.Forms.Button
$btnRetour.Text = '<- Retour'
$btnRetour.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnRetour.Size = New-Object System.Drawing.Size(90, 42)
$btnRetour.Location = New-Object System.Drawing.Point(15, 510)
$btnRetour.BackColor = [System.Drawing.Color]::FromArgb(60, 70, 90)
$btnRetour.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor
                   [System.Windows.Forms.AnchorStyles]::Left
$btnRetour.ForeColor = [System.Drawing.Color]::White
$btnRetour.FlatStyle = 'Flat'
$btnRetour.Add_Click({
    $panelResultats.Visible = $false
    $panelAccueil.Visible = $true
})
$panelResultats.Controls.Add($btnRetour)

$btnInstaller = New-Object System.Windows.Forms.Button
$btnInstaller.Text = 'Installer les mises à jour sélectionnées'
$btnInstaller.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$btnInstaller.Size = New-Object System.Drawing.Size(300, 36)
$btnInstaller.Location = New-Object System.Drawing.Point(0, 0)
$btnInstaller.BackColor = [System.Drawing.Color]::DarkCyan
$btnInstaller.ForeColor = [System.Drawing.Color]::White
$btnInstaller.FlatStyle = 'Flat'
$btnInstaller.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$panelResultats.Controls.Add($btnInstaller)

# ==============================================================================
# AJUSTEMENT AUTOMATIQUE DE LA FENÊTRE DE RÉSULTATS
# ==============================================================================
function Set-ResultsWindowHeight {
    # La fenêtre de résultats s'adapte au nombre réel de lignes, avec une
    # hauteur minimale et une limite à la zone de travail de l'écran.
    $directCount = $listView.Items.Count
    $windowsUpdateCount = $listViewWindowsUpdate.Items.Count

    $rowHeight = 20
    $listHeaderHeight = 24
    $directListHeight = if ($directCount -gt 0) {
        $listHeaderHeight + ($directCount * $rowHeight) + 8
    } else {
        70
    }
    $wuListHeight = if ($windowsUpdateCount -gt 0) {
        $listHeaderHeight + ($windowsUpdateCount * $rowHeight) + 8
    } else {
        70
    }

    # Les deux sections utilisent désormais le même principe d'espacement :
    # liste -> 12 px -> bouton. La zone informative de Windows Update est
    # placée au-dessus de sa liste pour ne pas créer un écart visuel différent.
    $actionGap = 12
    $buttonHeight = 38
    $wuInfoHeight = 24
    $wuInfoGap = 6
    $directSectionHeight = [Math]::Max(145, 34 + $directListHeight + $actionGap + $buttonHeight + 8)
    $wuListTop = 28 + $wuInfoHeight + $wuInfoGap
    $wuSectionHeight = [Math]::Max(150, $wuListTop + $wuListHeight + $actionGap + 36 + 8)
    $gapsAndFooter = 18 + 54 + 45
    $panelHeight = $directSectionHeight + 18 + $wuSectionHeight + $gapsAndFooter

    # Marge de sécurité pour éviter toute coupure des contrôles.
    $desiredFormHeight = [Math]::Max(650, 115 + $panelHeight)
    $screen = [System.Windows.Forms.Screen]::FromControl($fenetre)
    $maxFormHeight = $screen.WorkingArea.Height
    $desiredFormHeight = [Math]::Min($desiredFormHeight, $maxFormHeight)

    $fenetre.Height = $desiredFormHeight
}

# ==============================================================================
# MISE EN PAGE RESPONSIVE
# ==============================================================================
function Set-UpdatesLayout {
    $clientWidth = $fenetre.ClientSize.Width
    $clientHeight = $fenetre.ClientSize.Height

    $headerWidth = [Math]::Max(200, $clientWidth - 40)
    $lblTitre.Width = $headerWidth
    $lblSystemInfo.Width = $headerWidth

    $panelWidth = [Math]::Max(500, $clientWidth - 80)
    $panelHeight = [Math]::Max(400, $clientHeight - 115)

    $panelAccueil.Size = New-Object System.Drawing.Size($panelWidth, $panelHeight)
    $panelResultats.Size = $panelAccueil.Size
    $panelResultats.Location = $panelAccueil.Location

    $contentWidth = [Math]::Max(300, $panelWidth - 80)

    $chkWinUpdate.Width = $contentWidth
    $chkWinget.Width = $contentWidth
    $chkDrivers.Width = $contentWidth

    $panelInfoConstructeur.Width = $contentWidth
    $lblInfoConstructeur.Width = [Math]::Max(200, $panelInfoConstructeur.Width - 30)
    $lblInfoConstructeurDetails.Width = [Math]::Max(200, $panelInfoConstructeur.Width - 30)

    $btnAnalyse.Left = [Math]::Max(20, [int](($panelWidth - $btnAnalyse.Width) / 2))
    $btnAnalyse.Top = [Math]::Max(320, $panelHeight - 185)

    # Zone d'analyse : barre pleine largeur, puis bouton Annuler dessous à droite.
    $progressBarAnalyse.Left = 40
    $progressBarAnalyse.Width = [Math]::Max(260, $panelWidth - 80)
    $progressBarAnalyse.Top = $panelHeight - 92

    $btnAnnulerAnalyse.Left = [Math]::Max(40, $panelWidth - $btnAnnulerAnalyse.Width - 40)
    $btnAnnulerAnalyse.Top = $panelHeight - 58

    $lblStatusAnalyse.Left = 40
    $lblStatusAnalyse.Width = [Math]::Max(300, $panelWidth - 80)
    $lblStatusAnalyse.Top = $panelHeight - 122

    # Organisation ergonomique : chaque action est placée directement sous la zone
    # qu'elle concerne. La barre de navigation reste séparée tout en bas.
    $resultWidth = [Math]::Max(400, $panelResultats.Width - 30)
    $resultHeight = [Math]::Max(220, $panelResultats.Height - 125)
    $splitGap = 18
    $footerHeight = 54
    $directActionHeight = 48
    $wuActionHeight = 58
    $usableHeight = [Math]::Max(220, $resultHeight - $footerHeight - $splitGap)
    $directHeight = [Math]::Max(180, [int](($usableHeight - $splitGap) * $script:DirectSectionRatio))
    $wuHeight = [Math]::Max(125, $usableHeight - $directHeight - $splitGap)

    $lblSectionDirect.Left = 15
    $lblSectionDirect.Top = 8
    $lblSectionDirect.Width = $resultWidth

    $listView.Left = 15
    $listView.Top = 34
    $listView.Width = $resultWidth
    $listView.Height = [Math]::Max(65, $directHeight - 34 - 12 - 38 - 8)

    $lblEmpty.Left = 15
    $lblEmpty.Top = 34
    $lblEmpty.Width = $resultWidth
    $lblEmpty.Height = [Math]::Max(65, $directHeight - 34 - 12 - 38 - 8)

    # Action de la première section : même écart visuel que pour Windows Update.
    $btnInstaller.Width = [Math]::Min(340, [Math]::Max(280, $resultWidth - 30))
    $btnInstaller.Height = 38
    $btnInstaller.Left = [int](($resultWidth - $btnInstaller.Width) / 2)
    $btnInstaller.Top = $listView.Top + $listView.Height + 12

    $panelWindowsUpdate.Left = 15
    $panelWindowsUpdate.Top = 34 + $directHeight + $splitGap
    $panelSectionSplitter.Left = 15
    $panelSectionSplitter.Top = $panelWindowsUpdate.Top - [int]($splitGap / 2) - 3
    $panelSectionSplitter.Width = $resultWidth
    $panelSectionSplitter.BringToFront()
    $panelWindowsUpdate.Width = $resultWidth
    $panelWindowsUpdate.Height = [Math]::Max(100, $wuHeight)

    $lblSectionWindowsUpdate.Left = 0
    $lblSectionWindowsUpdate.Top = 0
    $lblSectionWindowsUpdate.Width = $resultWidth

    # Le texte explicatif est placé au-dessus de la liste : le bouton reste ainsi
    # à exactement 12 px du bord inférieur du tableau, comme le bouton Installer.
    $lblWindowsUpdateInfo.Left = 15
    $lblWindowsUpdateInfo.Top = $panelWindowsUpdate.Top + 28
    $lblWindowsUpdateInfo.Width = $resultWidth - 30
    $lblWindowsUpdateInfo.Height = 24

    $listViewWindowsUpdate.Left = 0
    $listViewWindowsUpdate.Top = 58
    $listViewWindowsUpdate.Width = $resultWidth
    $listViewWindowsUpdate.Height = [Math]::Max(45, $wuHeight - 58 - 12 - 36 - 8)

    $lblEmptyWindowsUpdate.Left = 15
    $lblEmptyWindowsUpdate.Top = 58
    $lblEmptyWindowsUpdate.Width = $resultWidth
    $lblEmptyWindowsUpdate.Height = [Math]::Max(45, $wuHeight - 58 - 12 - 36 - 8)

    $btnOuvrirWindowsUpdate.Width = 220
    $btnOuvrirWindowsUpdate.Height = 36
    $btnOuvrirWindowsUpdate.Left = [int](($resultWidth - $btnOuvrirWindowsUpdate.Width) / 2)
    $btnOuvrirWindowsUpdate.Top = $panelWindowsUpdate.Top + $listViewWindowsUpdate.Top + $listViewWindowsUpdate.Height + 12
    $btnOuvrirWindowsUpdate.BringToFront()

    # Pendant une installation, la barre occupe toute la largeur utile.
    # Le bouton Annuler est placé dessous, à droite, dans la même zone basse.
    $progressBar.Left = 15
    $progressBar.Top = $panelResultats.Height - 110
    $progressBar.Width = [Math]::Max(300, $panelResultats.Width - 30)
    if (-not $script:IsActionRunning) {
        $progressBar.Visible = $false
    }

    $btnAnnulerInst.Left = [Math]::Max(15, $panelResultats.Width - $btnAnnulerInst.Width - 15)
    $btnAnnulerInst.Top = $panelResultats.Height - 72

    $lblProgressStatus.Left = 15
    $lblProgressStatus.Width = [Math]::Max(300, $panelResultats.Width - 30)
    $lblProgressStatus.Top = $panelResultats.Height - 140

    # Navigation générale : uniquement Retour, isolé de la zone d'actions.
    $btnRetour.Top = $panelResultats.Height - $btnRetour.Height - 12
    $btnRetour.Left = 15
    $btnRetour.Size = New-Object System.Drawing.Size(90, 38)

    # Les colonnes occupent toute la largeur disponible dans les deux zones.
    foreach ($lv in @($listView, $listViewWindowsUpdate)) {
        $listWidth = [Math]::Max(300, $lv.ClientSize.Width)
        $sourceWidth = [Math]::Min(180, [Math]::Max(120, [int]($listWidth * 0.18)))
        $stateWidth = [Math]::Min(170, [Math]::Max(120, [int]($listWidth * 0.16)))
        $titleWidth = [Math]::Max(200, $listWidth - $sourceWidth - $stateWidth)
        if ($lv.Columns.Count -ge 3) {
            $lv.Columns[0].Width = $sourceWidth
            $lv.Columns[1].Width = $titleWidth
            $lv.Columns[2].Width = $stateWidth
        }
    }
}

$fenetre.Add_Resize({
    Set-UpdatesLayout
})

# ==============================================================================
# LOGIQUE D'ANALYSE
# ==============================================================================
$btnAnalyse.Add_Click({
    if ($script:IsActionRunning) {
        return
    }
    
    $script:IsActionRunning = $true
    $script:CancelRequested = $false

    try {
        $listView.Items.Clear()
        $listViewWindowsUpdate.Items.Clear()
        $script:UpdateStore = @{
            WinUpdate    = @()
            ModernUpdate = @()
            Drivers      = @()
            Winget       = @()
            Constructeur = @()
        }
        $seenUpdateIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        $btnAnalyse.Enabled = $false
        $btnAnalyse.Text = 'Analyse en cours...'
        $progressBarAnalyse.Value = 0
        $btnAnnulerAnalyse.Enabled = $true
        $lblStatusAnalyse.Text = 'Initialisation...'
        [System.Windows.Forms.Application]::DoEvents()

        $totalSteps = 0
        if ($chkWinUpdate.Checked) {
            $totalSteps++
        }
        if ($chkWinget.Checked) {
            $totalSteps++
        }
        if ($chkDrivers.Checked) {
            $totalSteps++
        }
        if ($totalSteps -eq 0) {
            $totalSteps = 1
        }
        
        $currentStep = 0

        # --- 1. Windows Update ---
        # WUA direct : conserver les objets COM IUpdate dans ce processus.
        if (-not $script:CancelRequested -and $chkWinUpdate.Checked) {
            $currentStep++
            $progressBarAnalyse.Value = [int](($currentStep / $totalSteps) * 100)
            $lblStatusAnalyse.Text = 'Recherche des mises à jour système (Windows Update)...'
            [System.Windows.Forms.Application]::DoEvents()
            
            try {
                $sysUpdatesList = @(Get-WuaUpdateObjects -Criteria "IsInstalled=0 AND IsHidden=0 AND Type='Software'")

                if (-not $script:CancelRequested) {
                    foreach ($upd in $sysUpdatesList) {
                        [System.Windows.Forms.Application]::DoEvents()
                        if ($script:CancelRequested) { break }
                        $updId = [string]$upd.Identity.UpdateID

                        # Exclure les deux faux positifs Lenovo confirmés par les essais :
                        # ils ne sont proposés ni par Windows Update ni par Vantage et
                        # leur téléchargement WUA échoue. Filtrage avant tout affichage.
                        $knownUnusableLenovoIds = @(
                            '26b90eb7-113d-4aa6-b1b0-fb7489510a6e' # SoftwareComponent 26.9.1.9
                            '8d0d0d47-6402-436d-aaa5-824079adfd9a' # System Driver 26.9.0.9
                        )
                        if ($knownUnusableLenovoIds -contains $updId) { continue }

                        if (-not $seenUpdateIds.Contains($updId)) {
                            [void]$seenUpdateIds.Add($updId)
                            $item = New-UpdateRow -Source 'Windows Update' -Title ([string]$upd.Title)
                            [void]$listView.Items.Add($item)
                            $script:UpdateStore.WinUpdate += $upd
                        }
                    }
                }

                # --- Recherche complémentaire via le service Windows Update ---
                # Certaines mises à jour constructeur (notamment firmware Lenovo)
                # peuvent être exposées par un service WUA dédié sans apparaître
                # dans la recherche Type='Software' standard. On les rattache donc
                # au circuit WUA installable directement.
                if (-not $script:CancelRequested) {
                    try {
                        $serviceUpdates = @(Get-WuaUpdateObjects -Criteria "IsInstalled=0 AND IsHidden=0" -ServiceId '8B24B027-1DEE-BABB-9A95-3517DFB9C552')
                        foreach ($serviceUpd in $serviceUpdates) {
                            if ($script:CancelRequested) { break }
                            $serviceId = [string]$serviceUpd.Identity.UpdateID

                            # Ne pas afficher comme directement installables les deux
                            # mises à jour Lenovo identifiées lors des tests comme
                            # non proposées par Windows Update/Vantage et dont le
                            # téléchargement WUA échoue (ResultCode 4).
                            # On conserve la recherche complémentaire pour les autres
                            # mises à jour constructeur, notamment le firmware.
                            $knownUnusableLenovoIds = @(
                                '26b90eb7-113d-4aa6-b1b0-fb7489510a6e' # SoftwareComponent 26.9.1.9
                                '8d0d0d47-6402-436d-aaa5-824079adfd9a' # System Driver 26.9.0.9
                            )
                            if ($knownUnusableLenovoIds -contains $serviceId) {
                                continue
                            }

                            if (-not $seenUpdateIds.Contains($serviceId)) {
                                [void]$seenUpdateIds.Add($serviceId)
                                $serviceItem = New-UpdateRow -Source 'Windows Update' -Title ([string]$serviceUpd.Title)
                                [void]$listView.Items.Add($serviceItem)
                                $script:UpdateStore.WinUpdate += [PSCustomObject]@{
                                    Title = [string]$serviceUpd.Title
                                    UpdateId = $serviceId
                                    ServiceId = '8B24B027-1DEE-BABB-9A95-3517DFB9C552'
                                    SearchType = 'Service'
                                }
                            }
                        }
                    } catch {
                        # Le service complémentaire est facultatif : la recherche
                        # standard reste valide si ce service n'est pas accessible.
                    }
                }

                # --- Détection moderne Windows Update ---
                # Windows 11 26H2 peut être proposé par l'orchestrateur moderne
                # sans être retourné par la recherche WUA/COM classique.
                if (-not $script:CancelRequested) {
                    try {
                        $modernUpdates = Get-ModernWindowsUpdates

                        foreach ($modernUpdate in $modernUpdates) {
                            if ($script:CancelRequested) {
                                break
                            }

                            if ($null -eq $modernUpdate -or [string]::IsNullOrWhiteSpace([string]$modernUpdate.Title)) {
                                continue
                            }

                            $modernId = [string]$modernUpdate.UpdateId
                            $modernBaseId = ($modernId -split ':')[0]

                            # Même exclusion pour la source moderne : les deux entrées
                            # Lenovo ne doivent réapparaître dans aucune des deux listes.
                            $knownUnusableLenovoIds = @(
                                '26b90eb7-113d-4aa6-b1b0-fb7489510a6e'
                                '8d0d0d47-6402-436d-aaa5-824079adfd9a'
                            )
                            if (($knownUnusableLenovoIds -contains $modernId) -or ($knownUnusableLenovoIds -contains $modernBaseId)) {
                                continue
                            }

                            if ([string]::IsNullOrWhiteSpace($modernId)) {
                                $modernId = [string]$modernUpdate.Title
                                $modernBaseId = $modernId
                            }

                            if ($seenUpdateIds.Contains($modernId) -or $seenUpdateIds.Contains($modernBaseId)) {
                                continue
                            }

                            [void]$seenUpdateIds.Add($modernId)
                            if ($modernBaseId -ne $modernId) {
                                [void]$seenUpdateIds.Add($modernBaseId)
                            }

                            $item = New-UpdateRow -Source 'Windows Update' -Title ([string]$modernUpdate.Title)
                            Set-UpdateRowStatus -Row $item -Status 'Disponible' -Color ([System.Drawing.Color]::White)
                            [void]$listViewWindowsUpdate.Items.Add($item)

                            $script:UpdateStore.ModernUpdate += [PSCustomObject]@{
                                Title            = [string]$modernUpdate.Title
                                UpdateId         = $modernId
                                IsFeatureUpdate  = [bool]$modernUpdate.IsFeatureUpdate
                                IsForOS          = [bool]$modernUpdate.IsForOS
                                IsDriver         = [bool]$modernUpdate.IsDriver
                                IsSecurity       = [bool]$modernUpdate.IsSecurity
                                IsCritical       = [bool]$modernUpdate.IsCritical
                                IsMandatory      = [bool]$modernUpdate.IsMandatory
                                IsSeeker         = [bool]$modernUpdate.IsSeeker
                                ProviderId       = [string]$modernUpdate.ProviderId
                            }
                        }
                    } catch {
                        # L'outil auxiliaire n'est pas une mise à jour : ne pas l'ajouter à la liste installable.
                        $messageModern = $_.Exception.Message
                        if ($messageModern -notlike '*WinBoxSafePC.WindowsUpdate.exe*introuvable*') {
                            $lblProgressStatus.Text = 'Recherche Windows Update moderne : ' + $messageModern
                        }
                    }
                }
            } catch {
                $null = $_.Exception
            }
        }

        # --- 2. Winget ---
        if (-not $script:CancelRequested -and $chkWinget.Checked) {
            $currentStep++
            $progressBarAnalyse.Value = [int](($currentStep / $totalSteps) * 100)
            $lblStatusAnalyse.Text = 'Analyse des applications et paquets (Winget)...'
            [System.Windows.Forms.Application]::DoEvents()
            
            try {
                $wingetPath = $null
                try {
                    $wingetPath = (Get-Command winget.exe -ErrorAction Stop).Source
                } catch {
                    $null = $_.Exception
                }
                
                if ([string]::IsNullOrWhiteSpace($wingetPath)) {
                    $possiblePaths = @("$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe")
                    for ($idxP = 0; $idxP -lt $possiblePaths.Count; $idxP++) {
                        $candidate = $possiblePaths[$idxP]
                        if (Test-Path $candidate) {
                            $wingetPath = $candidate
                            break
                        }
                    }
                }
                
                if ([string]::IsNullOrWhiteSpace($wingetPath)) {
                    throw 'Winget.exe est introuvable sur ce PC.'
                }

                $wingetArguments = @(
                    'list',
                    '--upgrade-available',
                    '--include-unknown',
                    '--accept-source-agreements',
                    '--disable-interactivity'
                )
                
                $formattedArgsList = New-Object System.Collections.ArrayList
                for ($idxA = 0; $idxA -lt $wingetArguments.Count; $idxA++) {
                    $argItem = $wingetArguments[$idxA]
                    if ($argItem -match '\s') {
                        [void]$formattedArgsList.Add('"' + $argItem.Replace('"', '\"') + '"')
                    } else {
                        [void]$formattedArgsList.Add($argItem)
                    }
                }

                $psiWinget = New-Object System.Diagnostics.ProcessStartInfo
                $psiWinget.FileName = $wingetPath
                $psiWinget.Arguments = $formattedArgsList -join ' '
                $psiWinget.UseShellExecute = $false
                $psiWinget.CreateNoWindow = $true
                $psiWinget.RedirectStandardOutput = $true
                $psiWinget.RedirectStandardError = $true
                $psiWinget.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $psiWinget.StandardErrorEncoding = [System.Text.Encoding]::UTF8

                $processWinget = New-Object System.Diagnostics.Process
                $processWinget.StartInfo = $psiWinget
                $script:ActiveProcess = $processWinget
                
                if (-not $processWinget.Start()) {
                    throw 'Impossible de démarrer Winget.'
                }

                $stdoutTask = $processWinget.StandardOutput.ReadToEndAsync()
                $stderrTask = $processWinget.StandardError.ReadToEndAsync()
                
                $timeoutMs = 180000 
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                
                while (-not $processWinget.HasExited) {
                    [System.Windows.Forms.Application]::DoEvents()
                    if ($script:CancelRequested) {
                        try {
                            $processWinget.Kill()
                        } catch {
                            $null = $_.Exception
                        }
                        break
                    }
                    if ($sw.ElapsedMilliseconds -gt $timeoutMs) {
                        try {
                            $processWinget.Kill()
                        } catch {
                            $null = $_.Exception
                        }
                        throw 'Winget n''a pas répondu dans le délai imparti.'
                    }
                    Start-Sleep -Milliseconds 100
                }
                $sw.Stop()

                $rawOutput = ''
                try {
                    $rawOutput = $stdoutTask.GetAwaiter().GetResult()
                } catch {
                    $null = $_.Exception
                }
                
                $rawError = ''
                try {
                    $rawError = $stderrTask.GetAwaiter().GetResult()
                } catch {
                    $null = $_.Exception
                }
                
                $script:ActiveProcess = $null

                if ($script:CancelRequested) {
                    throw 'Analyse Winget annulée proprement.'
                }
                if ([string]::IsNullOrWhiteSpace($rawOutput) -and -not [string]::IsNullOrWhiteSpace($rawError)) {
                    throw "Winget : $rawError"
                }
                if ([string]::IsNullOrWhiteSpace($rawOutput)) {
                    throw 'Winget n''a retourné aucune donnée.'
                }

                $rawLines = $rawOutput -split '\r?\n'
                $cleanLines = New-Object System.Collections.Generic.List[string]
                
                for ($idxRaw = 0; $idxRaw -lt $rawLines.Count; $idxRaw++) {
                    $rawLine = $rawLines[$idxRaw]
                    if ($null -eq $rawLine) {
                        continue
                    }
                    $cleanLine = ($rawLine -replace '\x1B\[[0-9;]*[mK]', '').TrimEnd()
                    [void]$cleanLines.Add($cleanLine)
                }

                $headerIndex = -1
                $separatorIndex = -1
                
                for ($i = 0; $i -lt $cleanLines.Count; $i++) {
                    if ($cleanLines[$i] -match '\bID\b' -and $cleanLines[$i] -match '\bVersion\b') {
                        $headerIndex = $i
                        break
                    }
                }
                
                if ($headerIndex -ge 0) {
                    for ($i = $headerIndex + 1; $i -lt $cleanLines.Count; $i++) {
                        if ($cleanLines[$i] -match '^\s*-{3,}') {
                            $separatorIndex = $i
                            break
                        }
                    }
                }

                if ($headerIndex -ge 0 -and $separatorIndex -gt $headerIndex) {
                    $headerLine = $cleanLines[$headerIndex]
                    $idPos = $headerLine.IndexOf('ID', [System.StringComparison]::OrdinalIgnoreCase)
                    $verPos = $headerLine.IndexOf('Version', [System.StringComparison]::OrdinalIgnoreCase)
                    $availPos = $headerLine.IndexOf('Disponible', [System.StringComparison]::OrdinalIgnoreCase)
                    
                    if ($availPos -lt 0) {
                        $availPos = $headerLine.IndexOf('Available', [System.StringComparison]::OrdinalIgnoreCase)
                    }

                    if ($idPos -ge 0 -and $verPos -gt $idPos -and $availPos -gt $verPos) {
                        for ($i = $separatorIndex + 1; $i -lt $cleanLines.Count; $i++) {
                            $line = $cleanLines[$i]
                            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^[0-9]+\s+mises?\s+à\s+jour' -or $line -match '^[0-9]+\s+upgrade') {
                                continue
                            }
                            if ($line.Length -le $availPos) {
                                continue
                            }
                            try {
                                $pkgName = $line.Substring(0, $idPos).Trim()
                                $pkgId = $line.Substring($idPos, ($verPos - $idPos)).Trim()
                                $pkgVer = $line.Substring($verPos, ($availPos - $verPos)).Trim()
                                $rem = $line.Substring($availPos).Trim()
                                
                                if ([string]::IsNullOrWhiteSpace($pkgName) -or [string]::IsNullOrWhiteSpace($pkgId)) {
                                    continue
                                }

                                $availParts = $rem -split '\s+', 2
                                if ($availParts.Count -eq 0) {
                                    continue
                                }
                                
                                $pkgAvail = $availParts[0]
                                if ([string]::IsNullOrWhiteSpace($pkgAvail)) {
                                    continue
                                }

                                $versions = "$pkgVer -> $pkgAvail"
                                if (-not $seenUpdateIds.Contains($pkgId)) {
                                    [void]$seenUpdateIds.Add($pkgId)
                                    $displayName = "$pkgName ($pkgId) - $versions"
                                    $item = New-UpdateRow -Source 'Winget' -Title $displayName
                                    [void]$listView.Items.Add($item)
                                    $script:UpdateStore.Winget += [PSCustomObject]@{ Title = $displayName; Id = $pkgId }
                                }
                            } catch {
                                continue
                            }
                        }
                    }
                }

                if ($script:UpdateStore.Winget.Count -eq 0) {
                    for ($idxCln = 0; $idxCln -lt $cleanLines.Count; $idxCln++) {
                        $line = $cleanLines[$idxCln]
                        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*-{3,}' -or $line -match '^\s*Nom\s+ID\s+Version' -or $line -match '^\s*Name\s+Id\s+Version') {
                            continue
                        }
                        $parts = $line.Trim() -split '\s{2,}'
                        if ($parts.Count -lt 4) {
                            continue
                        }
                        
                        $candidateName = $parts[0].Trim()
                        $candidateId = $parts[1].Trim()
                        $candidateCurrent = $parts[2].Trim()
                        $candidateAvailable = $parts[3].Trim()

                        if ([string]::IsNullOrWhiteSpace($candidateName) -or [string]::IsNullOrWhiteSpace($candidateId)) {
                            continue
                        }
                        if ($candidateId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                            continue
                        }
                        if ($candidateAvailable -match '^(Source|Available|Disponible)$') {
                            continue
                        }

                        if (-not $seenUpdateIds.Contains($candidateId)) {
                            [void]$seenUpdateIds.Add($candidateId)
                            $displayName = "$candidateName ($candidateId) - $candidateCurrent -> $candidateAvailable"
                            $item = New-UpdateRow -Source 'Winget' -Title $displayName
                            [void]$listView.Items.Add($item)
                            $script:UpdateStore.Winget += [PSCustomObject]@{ Title = $displayName; Id = $candidateId }
                        }
                    }
                }
            } catch {
                $null = $_.Exception
                $script:ActiveProcess = $null
            }
        }

        # --- 3. Pilotes ---
        if (-not $script:CancelRequested -and $chkDrivers.Checked) {
            $currentStep++
            $progressBarAnalyse.Value = [int](($currentStep / $totalSteps) * 100)
            $lblStatusAnalyse.Text = "Recherche des pilotes Windows et préparation de la recherche constructeur ($fabricant)..."
            [System.Windows.Forms.Application]::DoEvents()
            
            try {
                $drvUpdatesList = @(Invoke-WuaSearchCancelable -Criteria "IsInstalled=0 AND IsHidden=0 AND Type='Driver'")

                if (-not $script:CancelRequested) {
                    foreach ($drv in $drvUpdatesList) {
                        [System.Windows.Forms.Application]::DoEvents()
                        if ($script:CancelRequested) { break }
                        $drvId = [string]$drv.UpdateId

                        # Exclure aussi ces deux faux positifs de la recherche Type=Driver.
                        # Le filtrage précédent ne couvrait que les résultats Windows Update :
                        # ils réapparaissaient donc dans « Mises à jour installables directement ».
                        $knownUnusableLenovoDriverIds = @(
                            '26b90eb7-113d-4aa6-b1b0-fb7489510a6e' # SoftwareComponent 26.9.1.9
                            '8d0d0d47-6402-436d-aaa5-824079adfd9a' # System Driver 26.9.0.9
                        )
                        if ($knownUnusableLenovoDriverIds -contains $drvId.Trim('{}')) {
                            continue
                        }

                        if (-not $seenUpdateIds.Contains($drvId)) {
                            [void]$seenUpdateIds.Add($drvId)
                            $item = New-UpdateRow -Source 'Pilotes / Drivers' -Title ([string]$drv.Title)
                            [void]$listView.Items.Add($item)
                            $script:UpdateStore.Drivers += [PSCustomObject]@{
                                Title = [string]$drv.Title
                                UpdateId = $drvId
                                ServiceId = ''
                                SearchType = 'Driver'
                            }
                        }
                    }
                }
            } catch {
                $null = $_.Exception
            }
        }

        # --- 4. Mises à jour constructeur ---
        $constructorStatus = ''
        if (-not $script:CancelRequested -and (Get-Command Get-ConstructeurUpdates -ErrorAction SilentlyContinue)) {
            $lblStatusAnalyse.Text = "Recherche des mises à jour constructeur ($fabricant)..."
            [System.Windows.Forms.Application]::DoEvents()

            try {
                $constructorResult = Get-ConstructeurUpdates -Fabricant $fabricant -Modele $modele
                if ($constructorResult) {
                    if ($constructorResult.StatusMessage) {
                        $constructorStatus = [string]$constructorResult.StatusMessage
                    }

                    foreach ($constructorUpdate in @($constructorResult.Updates)) {
                        if ($null -eq $constructorUpdate) {
                            continue
                        }

                        $constructorId = if ($constructorUpdate.PackageID) {
                            [string]$constructorUpdate.PackageID
                        } else {
                            "$($constructorUpdate.Title)|$($constructorUpdate.Version)"
                        }

                        if ([string]::IsNullOrWhiteSpace($constructorId)) {
                            continue
                        }

                        $seenKey = "OEM:$constructorId"
                        if (-not $seenUpdateIds.Contains($seenKey)) {
                            [void]$seenUpdateIds.Add($seenKey)

                            $category = if ($constructorUpdate.Category) {
                                [string]$constructorUpdate.Category
                            } else {
                                'Pilote / Firmware'
                            }

                            $displayTitle = if ($constructorUpdate.Version) {
                                "$($constructorUpdate.Title) | v$($constructorUpdate.Version)"
                            } else {
                                [string]$constructorUpdate.Title
                            }

                            $sourceText = "$fabricant - $category"
                            $item = New-UpdateRow -Source $sourceText -Title $displayTitle
                            [void]$listView.Items.Add($item)

                            $script:UpdateStore.Constructeur += $constructorUpdate
                        }
                    }
                }
            } catch {
                $constructorStatus = "Recherche constructeur indisponible : $($_.Exception.Message)"
            }
        }

        # --- Réconciliation finale des résultats modernes ---
        # Une même mise à jour peut être exposée par plusieurs mécanismes.
        # Si elle est déjà couverte par WUA, un pilote ou le module constructeur,
        # elle doit rester dans la zone d'installation directe et ne pas être
        # affichée une seconde fois dans « Windows Update requis ».
        if (-not $script:CancelRequested -and $script:UpdateStore.ModernUpdate.Count -gt 0) {
            $directTitles = @()
            foreach ($directRow in @($listView.Items)) {
                if ($directRow.SubItems.Count -gt 1) {
                    $directTitles += Get-NormalizedUpdateTitle -Title ([string]$directRow.SubItems[1].Text)
                }
            }

            $modernToKeep = @()
            foreach ($modernUpdate in @($script:UpdateStore.ModernUpdate)) {
                $modernKey = Get-NormalizedUpdateTitle -Title ([string]$modernUpdate.Title)
                $isDirectDuplicate = $false

                if ($modernKey) {
                    foreach ($directKey in $directTitles) {
                        if (-not $directKey) { continue }
                        if ($modernKey -eq $directKey -or $modernKey.Contains($directKey) -or $directKey.Contains($modernKey)) {
                            $isDirectDuplicate = $true
                            break
                        }
                    }
                }

                if ($isDirectDuplicate) {
                    for ($rowIndex = $listViewWindowsUpdate.Items.Count - 1; $rowIndex -ge 0; $rowIndex--) {
                        $row = $listViewWindowsUpdate.Items[$rowIndex]
                        if ($row.SubItems.Count -gt 1 -and
                            (Get-NormalizedUpdateTitle -Title ([string]$row.SubItems[1].Text)) -eq $modernKey) {
                            $listViewWindowsUpdate.Items.RemoveAt($rowIndex)
                        }
                    }
                } else {
                    $modernToKeep += $modernUpdate
                }
            }

            $script:UpdateStore.ModernUpdate = @($modernToKeep)
        }

        if ($script:CancelRequested) {
            $lblStatusAnalyse.Text = 'Analyse annulée proprement.'
            Start-Sleep -Milliseconds 600
        } else {
            $progressBarAnalyse.Value = 100
            $lblStatusAnalyse.Text = 'Analyse terminée !'
        }
        
        [System.Windows.Forms.Application]::DoEvents()

        if (-not $script:CancelRequested) {
            $directCount = $listView.Items.Count
            $windowsUpdateCount = $listViewWindowsUpdate.Items.Count

            $listView.Visible = ($directCount -gt 0)
            $lblEmpty.Visible = ($directCount -eq 0)
            if ($directCount -eq 0) {
                $lblEmpty.Text = if ($constructorStatus) { "✓ Aucune mise à jour installable directement détectée.`n`n$constructorStatus" } else { '✓ Aucune mise à jour installable directement détectée.' }
            }

            $listViewWindowsUpdate.Visible = ($windowsUpdateCount -gt 0)
            $lblEmptyWindowsUpdate.Visible = ($windowsUpdateCount -eq 0)
            if ($windowsUpdateCount -eq 0) {
                $lblEmptyWindowsUpdate.Text = "✓ Aucune mise à jour nécessitant Windows Update n'a été détectée."
                $lblEmptyWindowsUpdate.BackColor = [System.Drawing.Color]::FromArgb(35, 40, 55)
            }
            $btnOuvrirWindowsUpdate.Visible = ($windowsUpdateCount -gt 0)
            if ($btnOuvrirWindowsUpdate.Visible) { $btnOuvrirWindowsUpdate.BringToFront() }
            $lblWindowsUpdateInfo.Visible = ($windowsUpdateCount -gt 0)

            $btnInstaller.Visible = ($directCount -gt 0)

            # Adapter la hauteur de la fenêtre au contenu avant d'afficher les résultats.
            Set-ResultsWindowHeight
            $progressBar.Visible = $false
            $btnAnnulerInst.Visible = $false
            $panelAccueil.Visible = $false
            $panelResultats.Visible = $true
            Set-UpdatesLayout
        }

        $btnAnalyse.Enabled = $true
        $btnAnalyse.Text = 'Lancer l''analyse des mises à jour'
        $btnAnnulerAnalyse.Enabled = $false
        $progressBarAnalyse.Value = 0
        $lblStatusAnalyse.Text = ''
        
    } finally {
        $script:IsActionRunning = $false
        $script:CancelRequested = $false
        $script:ActiveProcess = $null
    }
})
# ==============================================================================
# LOGIQUE D'INSTALLATION UNITAIRE
# ==============================================================================
$btnInstaller.Add_Click({
    if ($script:IsActionRunning) {         return;     }$checkedItemsList = New-Object System.Collections.ArrayList;
    for ($idxLvi = 0; $idxLvi -lt$listView.Items.Count; $idxLvi++) {$lvi = $listView.Items[$idxLvi];
        if ($lvi.Checked) {
            [void]$checkedItemsList.Add($lvi);
        }
    }
    
    if ($checkedItemsList.Count -eq 0) {
        return;
    }

    $script:IsActionRunning =$true;
    $script:CancelRequested =$false;
    
    try {
        $btnInstaller.Enabled =$false;
        $btnRetour.Enabled =$false;
        $btnAnnulerInst.Enabled =$true;
        $btnAnnulerInst.Visible =$true;
        $progressBar.Value = 0;
        $errorDetailsList = New-Object System.Collections.ArrayList;
        $redirectedCount = 0
        $directInstallPerformed = $false
        $progressBar.Visible = $true
        $lblProgressStatus.Text = 'Initialisation de l''installation...';$winUpdateItemsToProcess = New-Object System.Collections.ArrayList;
        $modernItemsToProcess = New-Object System.Collections.ArrayList;
        $driverItemsToProcess = New-Object System.Collections.ArrayList;
        $wingetLinesToProcess = New-Object System.Collections.ArrayList;
$constructorItemsToProcess = New-Object System.Collections.ArrayList;

        for ($idxRow = 0; $idxRow -lt$checkedItemsList.Count; $idxRow++) {$row = $checkedItemsList[$idxRow];
            $source =$row.Text;
            $desc =$row.SubItems[1].Text;
            
            if ($source -eq 'Windows Update') {
                $modernMatch = $null
                for ($idxM = 0; $idxM -lt $script:UpdateStore.ModernUpdate.Count; $idxM++) {
                    $m = $script:UpdateStore.ModernUpdate[$idxM]
                    if ($m.Title -eq $desc) {
                        $modernMatch = $m
                        break
                    }
                }

                if ($null -ne $modernMatch) {
                    [void]$modernItemsToProcess.Add([PSCustomObject]@{
                        Item = $modernMatch
                        Row = $row
                        Title = $desc
                        UpdateId = [string]$modernMatch.UpdateId
                    })
                } elseif ($desc -match 'Defender' -or $desc -match 'Antivirus') {
                    try {
                        Update-MpSignature -ErrorAction Stop
                        $listView.Items.Remove($row)
                    } catch {
                        [void]$errorDetailsList.Add("Windows Defender : $($_.Exception.Message)")
                    }
                } else {
                    for ($idxU = 0; $idxU -lt $script:UpdateStore.WinUpdate.Count; $idxU++) {
                        $u = $script:UpdateStore.WinUpdate[$idxU]
                        if ($u.Title -eq $desc) {
                            [void]$winUpdateItemsToProcess.Add([PSCustomObject]@{
                                Item = $u
                                Row = $row
                                Title = $desc
                            })
                            break
                        }
                    }
                }
            } elseif ($source -match ' - (BIOS|Driver|Firmware|Pilote)') {
                for ($idxC = 0; $idxC -lt $script:UpdateStore.Constructeur.Count; $idxC++) {
                    $c = $script:UpdateStore.Constructeur[$idxC]
                    $displayTitle = if ($c.Version) { "$($c.Title) | v$($c.Version)" } else { [string]$c.Title }
                    if ($displayTitle -eq $desc) {
                        [void]$constructorItemsToProcess.Add([PSCustomObject]@{
                            Item = $c
                            Row = $row
                            Title = $desc
                        })
                        break
                    }
                }
            } elseif ($source -eq 'Winget') {
                for ($idxW = 0; $idxW -lt$script:UpdateStore.Winget.Count; $idxW++) {$w = $script:UpdateStore.Winget[$idxW];
                    if ($w.Title -eq$desc) {
                        [void]$wingetLinesToProcess.Add([PSCustomObject]@{ Item = $w; Row =$row });
                    }
                }
            } elseif ($source -eq 'Pilotes / Drivers') {
                for ($idxD = 0; $idxD -lt$script:UpdateStore.Drivers.Count; $idxD++) {$d = $script:UpdateStore.Drivers[$idxD];
                    if ($d.Title -eq$desc) {
                        [void]$driverItemsToProcess.Add([PSCustomObject]@{ Item =$d; Row = $row; Title =$desc });
                    }
                }
            }
        }

        $totalToProcess = $winUpdateItemsToProcess.Count + $modernItemsToProcess.Count + $driverItemsToProcess.Count + $constructorItemsToProcess.Count + $wingetLinesToProcess.Count;
        if ($totalToProcess -eq 0) {$progressBar.Value = 100;
            $lblProgressStatus.Text = 'Opération terminée.';
            [System.Windows.Forms.Application]::DoEvents();
            Start-Sleep -Milliseconds 500;
            
            $btnInstaller.Enabled =$true;
            $btnRetour.Enabled =$true;
            $btnAnnulerInst.Enabled =$false;
            
            if ($listView.Items.Count -eq 0) {
                $listView.Visible =$false;
                $lblEmpty.Visible =$true;
                $btnInstaller.Visible =$false;
            }
            return;
        }

        $currentProcessed = 0;
        $Session = New-Object -ComObject Microsoft.Update.Session;
        
        function Resolve-WuaUpdateObject {
            [CmdletBinding()]
            param([Parameter(Mandatory=$true)]$TargetItem)

            # Les recherches utilisées pour l'interface peuvent conserver des
            # métadonnées (Title/UpdateId/ServiceId/SearchType). Pour l'installation,
            # IUpdateColl.Add exige obligatoirement un véritable objet COM IUpdate.
            $candidate = $TargetItem.Item
            if ($null -eq $candidate) {
                throw 'Objet WUA introuvable pour cette mise à jour.'
            }

            if ($candidate.PSObject.BaseObject -is [System.__ComObject]) {
                return $candidate.PSObject.BaseObject
            }

            $updateId = [string]$TargetItem.UpdateId
            if ([string]::IsNullOrWhiteSpace($updateId)) {
                $updateId = [string]$candidate.UpdateId
            }
            if ([string]::IsNullOrWhiteSpace($updateId)) {
                throw 'Identifiant UpdateID absent pour cette mise à jour.'
            }

            $serviceId = [string]$TargetItem.ServiceId
            if ([string]::IsNullOrWhiteSpace($serviceId)) {
                $serviceId = [string]$candidate.ServiceId
            }

            $searchSession = New-Object -ComObject Microsoft.Update.Session
            $searcher = $searchSession.CreateUpdateSearcher()
            if ([string]::IsNullOrWhiteSpace($serviceId)) {
                $searcher.ServerSelection = 2
                $searcher.Online = $true
            } else {
                $searcher.ServerSelection = 3
                $searcher.ServiceID = $serviceId
            }

            $result = $searcher.Search('IsInstalled=0 AND IsHidden=0')
            for ($i = 0; $i -lt $result.Updates.Count; $i++) {
                $u = $result.Updates.Item($i)
                if ([string]$u.Identity.UpdateID -ieq $updateId) {
                    try { if (-not $u.EulaAccepted) { [void]$u.AcceptEula() } } catch { }
                    return $u
                }
            }

            throw "Mise à jour WUA introuvable pour installation : $updateId"
        }

        function Install-WUItem {
            [CmdletBinding()]
            param([Parameter(Mandatory=$true)]$TargetItem)

            if ($script:CancelRequested) { return 'CANCELLED'; }

            # Toujours fournir à UpdateColl un vrai objet COM IUpdate.
            $updateObject = Resolve-WuaUpdateObject -TargetItem $TargetItem
            $col = New-Object -ComObject Microsoft.Update.UpdateColl;
            [void]$col.Add($updateObject);
            
            $Downloader = $Session.CreateUpdateDownloader();
            $Downloader.Updates = $col;
            $dlResult = $Downloader.Download();
            
            if ($script:CancelRequested) { return 'CANCELLED'; }
            if ($dlResult.ResultCode -ne 2) {
                return "Échec du téléchargement (Code $($dlResult.ResultCode))";
            }
            
            $Installer = $Session.CreateUpdateInstaller();
            $Installer.Updates = $col;
            $instResult = $Installer.Install();
            
            if ($script:CancelRequested) { return 'CANCELLED'; }
            # WUA OperationResultCode : 2 = Succeeded. 0 = NotStarted et ne
            # doit JAMAIS être présenté comme une installation réussie.
            # Vérifier aussi le résultat de l'update individuelle : une opération
            # globale réussie ne suffit pas à garantir que l'update a été installée.
            $updateResult = $null
            try { $updateResult = $instResult.GetUpdateResult(0) } catch { $null = $_.Exception }

            if ($instResult.ResultCode -eq 2 -and ($null -eq $updateResult -or $updateResult.ResultCode -eq 2)) {
                return 'SUCCESS'
            }

            $globalCode = [string]$instResult.ResultCode
            $itemCode = if ($null -ne $updateResult) { [string]$updateResult.ResultCode } else { 'inconnu' }
            $hresult = if ($null -ne $updateResult) { [string]$updateResult.HResult } else { 'inconnu' }
            return "Échec/non confirmé de l'installation (résultat global $globalCode ; résultat mise à jour $itemCode ; HRESULT $hresult)";
        }

        # --- 1. Windows Update ---
        for ($idxT = 0; $idxT -lt$winUpdateItemsToProcess.Count; $idxT++) {$target = $winUpdateItemsToProcess[$idxT];
            [System.Windows.Forms.Application]::DoEvents();
            if ($script:CancelRequested) { break; }$currentProcessed++;
            $percent = [int](($currentProcessed / $totalToProcess) * 100);$progressBar.Value = [Math]::Min(100, [Math]::Max(0, $percent));$lblProgressStatus.Text = "Installation (WinUpdate) : $($target.Title)...";
            [System.Windows.Forms.Application]::DoEvents();
            
            try {
                $resultMsg = Install-WUItem -TargetItem $target;
                if ($resultMsg -eq 'SUCCESS') {
                    $listView.Items.Remove($target.Row);
                    $directInstallPerformed = $true
                } elseif ($resultMsg -ne 'CANCELLED') {
                    Set-UpdateRowStatus -Row $target.Row -Status 'Échec' -Color ([System.Drawing.Color]::Gold)
                    $target.Row.Checked = $false
                    [void]$errorDetailsList.Add("$($target.Title) :$resultMsg");
                }
            } catch {
                Set-UpdateRowStatus -Row $target.Row -Status 'Échec' -Color ([System.Drawing.Color]::Gold)
                $target.Row.Checked = $false
                [void]$errorDetailsList.Add("$($target.Title) : $($_.Exception.Message)");
            }
        }

        # --- 2. Windows Update moderne / 26H2 ---
        # IMPORTANT : 26H2 est DETECTEE uniquement.
        # Elle ne passe jamais par Install-ModernWindowsUpdate.
        # Son installation est laissée au workflow Windows Update de Windows.
        for ($idxT = 0; $idxT -lt $modernItemsToProcess.Count; $idxT++) {
            $target = $modernItemsToProcess[$idxT]
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:CancelRequested) { break }

            $currentProcessed++
            $percent = [int](($currentProcessed / $totalToProcess) * 100)
            $progressBar.Value = [Math]::Min(100, [Math]::Max(0, $percent))
            $lblProgressStatus.Text = "Windows Update : $($target.Title)..."
            [System.Windows.Forms.Application]::DoEvents()

            try {
                Start-Process -FilePath 'ms-settings:windowsupdate' -ErrorAction Stop
                Set-UpdateRowStatus -Row $target.Row -Status 'Windows Update ouvert' -Color ([System.Drawing.Color]::White)
                $target.Row.Checked = $false
                $redirectedCount++
            } catch {
                Set-UpdateRowStatus -Row $target.Row -Status 'Échec' -Color ([System.Drawing.Color]::Gold)
                $target.Row.Checked = $false
                [void]$errorDetailsList.Add("$($target.Title) : $($_.Exception.Message)")
            }
        }

        # --- 3. Pilotes ---
        for ($idxT = 0; $idxT -lt$driverItemsToProcess.Count; $idxT++) {$target = $driverItemsToProcess[$idxT];
            [System.Windows.Forms.Application]::DoEvents();
            if ($script:CancelRequested) { break; }$currentProcessed++;
            $percent = [int](($currentProcessed / $totalToProcess) * 100);$progressBar.Value = [Math]::Min(100, [Math]::Max(0, $percent));$lblProgressStatus.Text = "Installation (Pilote) : $($target.Title)...";
            [System.Windows.Forms.Application]::DoEvents();
            
            try {
                $resultMsg = Install-WUItem -TargetItem $target;
                if ($resultMsg -eq 'SUCCESS') {
                    $listView.Items.Remove($target.Row);
                    $directInstallPerformed = $true
                } elseif ($resultMsg -ne 'CANCELLED') {
                    Set-UpdateRowStatus -Row $target.Row -Status 'Échec' -Color ([System.Drawing.Color]::Gold)
                    $target.Row.Checked = $false
                    [void]$errorDetailsList.Add("$($target.Title) :$resultMsg");
                }
            } catch {
                Set-UpdateRowStatus -Row $target.Row -Status 'Échec' -Color ([System.Drawing.Color]::Gold)
                $target.Row.Checked = $false
                [void]$errorDetailsList.Add("$($target.Title) : $($_.Exception.Message)");
            }
        }

        # --- 3. Mises à jour constructeur ---
        for ($idxT = 0; $idxT -lt$constructorItemsToProcess.Count; $idxT++) {
            $target = $constructorItemsToProcess[$idxT]
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:CancelRequested) { break }

            $currentProcessed++
            $percent = [int](($currentProcessed / $totalToProcess) * 100)
            $progressBar.Value = [Math]::Min(100, [Math]::Max(0, $percent))
            $lblProgressStatus.Text = "Installation ($fabricant) : $($target.Title)..."
            [System.Windows.Forms.Application]::DoEvents()

            try {
                $constructorResult = Install-ConstructeurUpdate -Update $target.Item

                if ($constructorResult.Success) {
                    if ($constructorResult.Status -eq 'REBOOT_REQUIRED') {
                        Set-UpdateRowStatus -Row $target.Row -Status 'Redémarrage requis' -Color ([System.Drawing.Color]::Gold)
                        $target.Row.Checked = $false
                    } else {
                        $listView.Items.Remove($target.Row)
                        $directInstallPerformed = $true
                    }
                } elseif (-not $script:CancelRequested) {
                    $detail = if ($constructorResult.FailureReason) { [string]$constructorResult.FailureReason } else { "Échec de l'installation constructeur." }
                    $statusText = if ($constructorResult.Status -eq 'INCOMPATIBLE') { 'Incompatible' } else { 'Échec' }
                    $statusColor = if ($statusText -eq 'Incompatible') { [System.Drawing.Color]::OrangeRed } else { [System.Drawing.Color]::Gold }
                    Set-UpdateRowStatus -Row $target.Row -Status $statusText -Color $statusColor
                    $target.Row.Checked = $false
                    [void]$errorDetailsList.Add("$($target.Title) : $detail")
                }
            } catch {
                if (-not $script:CancelRequested) {
                    Set-UpdateRowStatus -Row $target.Row -Status 'Échec' -Color ([System.Drawing.Color]::Gold)
                    $target.Row.Checked = $false
                    [void]$errorDetailsList.Add("$($target.Title) : $($_.Exception.Message)")
                }
            }
        }

        # --- 4. Winget ---
        for ($idxT = 0; $idxT -lt$wingetLinesToProcess.Count; $idxT++) {$target = $wingetLinesToProcess[$idxT];
            [System.Windows.Forms.Application]::DoEvents();
            if ($script:CancelRequested) { break; }
            
            $currentProcessed++;$percent = [int](($currentProcessed / $totalToProcess) * 100);
            $progressBar.Value = [Math]::Min(100, [Math]::Max(0,$percent));
            
            $pkgId =$target.Item.Id;
            $lblProgressStatus.Text = "Mise à jour (Winget) : $pkgId...";
            [System.Windows.Forms.Application]::DoEvents();
            
            try {
                $wingetPath =$null;
                try {
                    $wingetPath = (Get-Command winget.exe -ErrorAction Stop).Source;
                } catch {
                    $null =$_.Exception;
                }
                
                if ([string]::IsNullOrWhiteSpace($wingetPath)) {
                    $wingetPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe";
                }
                
                if (-not (Test-Path $wingetPath)) {
                    throw 'Winget.exe est introuvable.';
                }

                $psiInstall = New-Object System.Diagnostics.ProcessStartInfo;
                $psiInstall.FileName =$wingetPath;
                $psiInstall.Arguments = "upgrade --id `"$pkgId`" --exact --accept-source-agreements --accept-package-agreements --disable-interactivity";
                $psiInstall.UseShellExecute =$false;
                $psiInstall.CreateNoWindow =$true;
                $psiInstall.RedirectStandardOutput =$true;
                $psiInstall.RedirectStandardError =$true;
                $psiInstall.StandardOutputEncoding = [System.Text.Encoding]::UTF8;
                $psiInstall.StandardErrorEncoding = [System.Text.Encoding]::UTF8;

                $script:ActiveProcess = New-Object System.Diagnostics.Process;
                $script:ActiveProcess.StartInfo =$psiInstall;
                
                if (-not $script:ActiveProcess.Start()) {
                    throw 'Impossible de démarrer Winget.';
                }

                $installStdoutTask =$script:ActiveProcess.StandardOutput.ReadToEndAsync();
                $installStderrTask =$script:ActiveProcess.StandardError.ReadToEndAsync();
                
                $sw = [System.Diagnostics.Stopwatch]::StartNew();$timeoutInstallMs = 600000;
                
                while (-not $script:ActiveProcess.HasExited) {
                    [System.Windows.Forms.Application]::DoEvents();
                    if ($script:CancelRequested) {
                        try {
                            $script:ActiveProcess.Kill();
                        } catch {
                            $null =$_.Exception;
                        }
                        break;
                    }
                    if ($sw.ElapsedMilliseconds -gt$timeoutInstallMs) {
                        try {
                            $script:ActiveProcess.Kill();
                        } catch {
                            $null =$_.Exception;
                        }
                        throw 'Winget n''a pas terminé dans le délai imparti (50 minutes).';
                    }
                    Start-Sleep -Milliseconds 100;
                }
                $sw.Stop();

                $installStdout = '';
                try {
                    $installStdout =$installStdoutTask.GetAwaiter().GetResult();
                } catch {
                    $null =$_.Exception;
                }
                
                $installStderr = '';
                try {
                    $installStderr =$installStderrTask.GetAwaiter().GetResult();
                } catch {
                    $null =$_.Exception;
                }

                if (-not $script:CancelRequested) {
                    $exitCode =$script:ActiveProcess.ExitCode;
                    if ($exitCode -eq 0) {
                        $listView.Items.Remove($target.Row);
                        $directInstallPerformed = $true
                    } else {
                        $errorText =$installStderr.Trim();
                        if ([string]::IsNullOrWhiteSpace($errorText)) {
                            $errorText =$installStdout.Trim();
                        }
                        if ([string]::IsNullOrWhiteSpace($errorText)) {$errorText = 'Aucun détail fourni par Winget.';
                        }
                        Set-UpdateRowStatus -Row $target.Row -Status 'Échec' -Color ([System.Drawing.Color]::Gold)
                        $target.Row.Checked = $false
                        [void]$errorDetailsList.Add("Winget ($pkgId) : Échec (Code de sortie : $exitCode)`n$errorText");
                    }
                }
            } catch {
                if (-not $script:CancelRequested) {
                    Set-UpdateRowStatus -Row $target.Row -Status 'Échec' -Color ([System.Drawing.Color]::Gold)
                    $target.Row.Checked = $false
                    [void]$errorDetailsList.Add("Winget ($pkgId) : $($_.Exception.Message)");
                }
            }
            $script:ActiveProcess = $null;
        }

        $progressBar.Value = 100;
        if ($script:CancelRequested) {
            $lblProgressStatus.Text = 'Installation annulée proprement.';
            Start-Sleep -Milliseconds 600;
        } else {
            $lblProgressStatus.Text = 'Opération terminée.';
            [System.Windows.Forms.Application]::DoEvents();
            
            $listView.Visible = ($listView.Items.Count -gt 0)
            $lblEmpty.Visible = ($listView.Items.Count -eq 0)
            $listViewWindowsUpdate.Visible = ($listViewWindowsUpdate.Items.Count -gt 0)
            $lblEmptyWindowsUpdate.Visible = ($listViewWindowsUpdate.Items.Count -eq 0)
            $btnOuvrirWindowsUpdate.Visible = ($listViewWindowsUpdate.Items.Count -gt 0)
            if ($btnOuvrirWindowsUpdate.Visible) { $btnOuvrirWindowsUpdate.BringToFront() }
            $lblWindowsUpdateInfo.Visible = ($listViewWindowsUpdate.Items.Count -gt 0)
            $btnInstaller.Visible = ($listView.Items.Count -gt 0)
            
            if ($errorDetailsList.Count -gt 0) {
                $msgError = "Avertissements :`n`n" + ($errorDetailsList -join "`n");
                if ($redirectedCount -gt 0) {
                    $msgError += "`n`n$redirectedCount mise(s) à jour a/ont été transmises à Windows Update pour l'installation.";
                }
                [void][System.Windows.Forms.MessageBox]::Show($msgError, 'Fin de traitement', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning);
            } elseif ($redirectedCount -gt 0) {
                if ($redirectedCount -eq 1) {
                    $msgRedirect = if ($directInstallPerformed) { 'Les mises à jour installables directement ont été traitées. Windows Update a été ouvert pour poursuivre l''installation de la mise à jour sélectionnée.' } else { 'Windows Update a été ouvert pour poursuivre l''installation de la mise à jour sélectionnée.' }
                } else {
                    $msgRedirect = if ($directInstallPerformed) { "Les mises à jour installables directement ont été traitées. Windows Update a été ouvert pour poursuivre l'installation de $redirectedCount mises à jour sélectionnées." } else { "Windows Update a été ouvert pour poursuivre l'installation de $redirectedCount mises à jour sélectionnées." }
                }
                [void][System.Windows.Forms.MessageBox]::Show($msgRedirect, 'Windows Update', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information);
            } else {
                [void][System.Windows.Forms.MessageBox]::Show('Toutes les mises à jour sélectionnées ont été installées avec succès !', 'Succès', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information);
            }
            
            if ($directInstallPerformed -and (Test-PendingReboot)) {
                $msgReboot = "Attention : Windows nécessite un redémarrage pour finaliser l'installation.`n`nVoulez-vous redémarrer le PC maintenant ?";
                $reponse = [System.Windows.Forms.MessageBox]::Show($msgReboot, 'Redémarrage requis', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning);
                if ($reponse -eq [System.Windows.Forms.DialogResult]::Yes) {
                    [void](Start-Process 'shutdown.exe' -ArgumentList '/r /f /t 00' -NoNewWindow);
                }
            }
        }

        $btnInstaller.Enabled =$true;
        $btnRetour.Enabled =$true;
        $btnAnnulerInst.Enabled =$false;
        $btnAnnulerInst.Visible =$false;
        $progressBar.Visible =$false;
        $progressBar.Value = 0;
        $lblProgressStatus.Text = '';

        # Une fois le traitement terminé et les éventuels messages acquittés,
        # le gestionnaire de mises à jour se ferme proprement.
        if (-not $script:CancelRequested -and -not $fenetre.IsDisposed) {
            $fenetre.Close()
        }
        
    } finally {
        $script:IsActionRunning =$false;
        $script:CancelRequested =$false;
        $script:ActiveProcess =$null;
    }
})

Set-UpdatesLayout
[void]$fenetre.ShowDialog();
