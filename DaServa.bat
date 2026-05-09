@echo off
title Da Serva - Server Manager
color 0A

REM Da Serva - Minecraft Fabric Server Manager

where powershell >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo [ERROR] PowerShell is required but was not found.
    pause
    exit /b 1
)

set "TMPPS=%TEMP%\DaServa_%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f='%~f0'; $lines=[System.IO.File]::ReadAllLines($f); $start=($lines | Select-String -Pattern '^#---PSSTART---$' | Select-Object -First 1).LineNumber; [System.IO.File]::WriteAllLines('%TMPPS%', ($lines[($start)..($lines.Length-1)])); exit 0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%" %*
del "%TMPPS%" >nul 2>&1
exit /b
#---PSSTART---
#Requires -Version 5.1
# =============================================================================
#  DA SERVA  --  Minecraft Fabric Server Manager
#  Pure ASCII. No Unicode box chars, no smart quotes, no em-dashes.
# =============================================================================
param(
    [switch]$Quiet  # Unattended mode: skips prompts, uses defaults
)
$global:QUIET_MODE = $Quiet.IsPresent

# ---------------------------------------------------------------------------
#  STYLING
# ---------------------------------------------------------------------------

function Write-Banner {
    Clear-Host
    $line = "=" * 72
    Write-Host ""
    Write-Host $line -ForegroundColor DarkGreen
    Write-Host "  DA SERVA  --  Minecraft Fabric Server Manager" -ForegroundColor Green
    Write-Host "  Powered by Modrinth + FabricMC Meta API" -ForegroundColor DarkCyan
    Write-Host $line -ForegroundColor DarkGreen
    Write-Host ""
}

function Write-Step        { param([string]$T,[string]$C="Cyan")    Write-Host ""; Write-Host "  ** $T" -ForegroundColor $C }
function Write-SubStep     { param([string]$T,[string]$C="Gray")    Write-Host "     $T" -ForegroundColor $C }
function Write-OK          { param([string]$T)                      Write-Host "     [OK]  $T" -ForegroundColor Green }
function Write-WARN        { param([string]$T)                      Write-Host "     [!!]  $T" -ForegroundColor Yellow }
function Write-ERR         { param([string]$T)                      Write-Host "     [XX]  $T" -ForegroundColor Red }
function Write-Divider     { Write-Host ("-" * 72) -ForegroundColor DarkCyan }

# ---------------------------------------------------------------------------
#  PERSISTENT CONFIG  (remembers last used paths, theme, etc.)
# ---------------------------------------------------------------------------

function Get-AppConfigPath {
    return Join-Path (Split-Path -Parent $PSCommandPath) "daserva_config.json"
}

function Read-AppConfig {
    $path = Get-AppConfigPath
    $defaults = @{
        lastServerDir = ""
        theme         = "default"
        quietMode     = $false
    }
    if (-not (Test-Path $path)) { return $defaults }
    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json
        # Merge with defaults for any missing keys
        foreach ($k in $defaults.Keys) {
            if (-not ($obj.PSObject.Properties.Name -contains $k)) {
                $obj | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k]
            }
        }
        return $obj
    } catch { return $defaults }
}

function Write-AppConfig {
    param($Config)
    try {
        $Config | ConvertTo-Json | Set-Content -Path (Get-AppConfigPath) -Encoding UTF8
    } catch {}
}

function Save-LastServerDir {
    param([string]$Path)
    $cfg = Read-AppConfig
    $cfg.lastServerDir = $Path
    Write-AppConfig $cfg
}

$global:APP_CONFIG = Read-AppConfig


function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Divider
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Divider
}

function Pause-ForKey {
    param([string]$Msg = "Press any key to continue...")
    Write-Host ""
    Write-Host "  $Msg" -ForegroundColor DarkGray
    if ($global:QUIET_MODE) { return }
    while ($Host.UI.RawUI.KeyAvailable) {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    do { $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } while ($k.Character -eq [char]0 -or $k.VirtualKeyCode -in @(16,17,18))
}

function Confirm-YN {
    param([string]$Question, [bool]$DefaultYes = $true)
    Write-Host ""
    Write-Host "  $Question [Y/N] " -ForegroundColor Yellow -NoNewline
    if ($global:QUIET_MODE) {
        $ans = if ($DefaultYes) { "Y" } else { "N" }
        Write-Host "$ans (quiet mode)" -ForegroundColor DarkGray
        return $DefaultYes
    }
    # Flush any buffered keypresses from previous ReadKey interactions
    while ($Host.UI.RawUI.KeyAvailable) {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    # Now read the actual user intent
    do {
        $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } while ($k.Character -eq [char]0 -or $k.VirtualKeyCode -in @(16,17,18))
    Write-Host $k.Character
    return ($k.Character -eq 'y' -or $k.Character -eq 'Y')
}

function Show-Menu {
    param([string]$Title, [string[]]$Options, [string[]]$Descs = @())
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ""
    for ($i = 0; $i -lt $Options.Length; $i++) {
        Write-Host "    [$($i+1)] " -ForegroundColor Yellow -NoNewline
        Write-Host $Options[$i] -ForegroundColor White -NoNewline
        if ($Descs.Length -gt $i -and $Descs[$i]) { Write-Host "   ($($Descs[$i]))" -ForegroundColor DarkGray }
        else { Write-Host "" }
    }
    Write-Host ""
    Write-Host "  Choice (1-$($Options.Length)): " -ForegroundColor DarkCyan -NoNewline
    do {
        $inp = Read-Host; $n = 0
        if ([int]::TryParse($inp,[ref]$n) -and $n -ge 1 -and $n -le $Options.Length) { return $n-1 }
        Write-Host "  Invalid. Enter 1-$($Options.Length): " -ForegroundColor Red -NoNewline
    } while ($true)
}

# ---------------------------------------------------------------------------
#  HTTP
# ---------------------------------------------------------------------------

function Invoke-JsonApi {
    param([string]$Url)
    try {
        return Invoke-RestMethod -Uri $Url -Headers @{"User-Agent"="DaServa-ServerManager/1.0"} -ErrorAction Stop
    } catch { return $null }
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return "{0:0.0} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:0.0} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Download-File {
    param([string]$Url, [string]$Dest, [string]$Label = "")
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "DaServa-ServerManager/1.0")
        if ($Label) {
            Write-Host "     Downloading: $Label" -ForegroundColor DarkCyan -NoNewline
        }
        $wc.DownloadFile($Url, $Dest)
        if ($Label) {
            $size = (Get-Item $Dest).Length
            Write-Host "`r     [OK] $(Format-Bytes $size)  $Label                    " -ForegroundColor Green
        }
        return $true
    } catch {
        Write-Host ""
        Write-ERR "Download failed for ${Label}: $_"
        return $false
    }
}

# ---------------------------------------------------------------------------
#  JAVA
# ---------------------------------------------------------------------------

function Get-RequiredJavaVersion {
    # Returns the minimum Java major version required for a given MC version string.
    # Class file version 69.0 = Java 25 (class file = java + 44)
    param([string]$McVersion)
    if (-not $McVersion) { return 21 }
    $p = $McVersion -split "\."
    $maj = if ($p.Count -gt 0 -and $p[0] -match "^\d+$") { [int]$p[0] } else { 1 }
    $min = if ($p.Count -gt 1 -and $p[1] -match "^\d+$") { [int]$p[1] } else { 0 }
    $pat = if ($p.Count -gt 2 -and $p[2] -match "^\d+$") { [int]$p[2] } else { 0 }
    # MC 26.x (new versioning, 2025+) = Java 25
    if ($maj -ge 26) { return 25 }
    # MC 1.20.5+ = Java 21
    if ($maj -eq 1 -and ($min -gt 20 -or ($min -eq 20 -and $pat -ge 5))) { return 21 }
    # MC 1.18-1.20.4 = Java 17
    if ($maj -eq 1 -and $min -ge 18) { return 17 }
    # MC 1.17 = Java 16
    if ($maj -eq 1 -and $min -eq 17) { return 16 }
    # MC 1.16 and below = Java 8
    return 8
}

function Find-JavaExe {
    # Returns path to java.exe meeting minVersion, or $null
    param([int]$MinVersion = 21)
    $candidates = @()
    foreach ($root in @("C:\Program Files\Eclipse Adoptium","C:\Program Files\Java","C:\Program Files\Microsoft","C:\Program Files\Java\jdk-25",$env:ProgramFiles)) {
        if (Test-Path $root) {
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $j = Join-Path $_.FullName "bin\java.exe"
                if (Test-Path $j) { $candidates += $j }
            }
        }
    }
    if ($env:JAVA_HOME) { $j = Join-Path $env:JAVA_HOME "bin\java.exe"; if (Test-Path $j) { $candidates += $j } }
    $inPath = Get-Command java -ErrorAction SilentlyContinue
    if ($inPath) { $candidates += $inPath.Source }

    # Find best match: prefer exact minimum, accept higher
    $best = $null; $bestVer = 0
    foreach ($jexe in ($candidates | Select-Object -Unique)) {
        try {
            $ver = & "$jexe" -version 2>&1 | Select-Object -First 1
            if ($ver -match '"(\d+)') {
                $v = [int]$Matches[1]
                if ($v -ge $MinVersion -and $v -gt $bestVer) {
                    $best = $jexe; $bestVer = $v
                }
            }
        } catch {}
    }
    return $best
}

function Install-Java {
    param([int]$MinVersion = 21)
    # Winget IDs and download URLs for each supported Java version
    $javaInfo = @{
        8  = @{ winget="EclipseAdoptium.Temurin.8.JDK";  url="https://adoptium.net/temurin/releases/?version=8"  }
        11 = @{ winget="EclipseAdoptium.Temurin.11.JDK"; url="https://adoptium.net/temurin/releases/?version=11" }
        16 = @{ winget="EclipseAdoptium.Temurin.16.JDK"; url="https://adoptium.net/temurin/releases/?version=16" }
        17 = @{ winget="EclipseAdoptium.Temurin.17.JDK"; url="https://adoptium.net/temurin/releases/?version=17" }
        21 = @{ winget="EclipseAdoptium.Temurin.21.JDK"; url="https://adoptium.net/temurin/releases/?version=21" }
        25 = @{ winget="EclipseAdoptium.Temurin.25.JDK"; url="https://adoptium.net/temurin/releases/?version=25" }
    }
    # Use closest available version >= MinVersion
    $targetVer = @(8,11,16,17,21,25) | Where-Object { $_ -ge $MinVersion } | Select-Object -First 1
    if (-not $targetVer) { $targetVer = 25 }
    $info = $javaInfo[$targetVer]

    Write-Step "Java $targetVer Setup" "Cyan"
    Write-SubStep "No compatible Java $targetVer+ found for this Minecraft version." "Yellow"

    $choice = Show-Menu -Title "How would you like to install Java $targetVer?" `
        -Options @("Install via winget (recommended)","Open Adoptium download page","Enter path to existing java.exe") `
        -Descs   @("Requires Windows 10/11","Manual download from adoptium.net","If already installed somewhere")

    if ($choice -eq 0) {
        Write-SubStep "Running: winget install $($info.winget) ..." "DarkCyan"
        Start-Process "winget" -ArgumentList "install -e --id $($info.winget) --accept-package-agreements --accept-source-agreements" -Wait -NoNewWindow
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")
        $found = Find-JavaExe -MinVersion $targetVer
        if ($found) { Write-OK "Java $targetVer found: $found"; return $found }
        Write-ERR "Java not found after install. Please install manually."
        Pause-ForKey "Press any key to continue..."
        return $null

    } elseif ($choice -eq 1) {
        Start-Process $info.url
        Pause-ForKey "Install Eclipse Temurin $targetVer JDK then press any key..."
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")
        $found = Find-JavaExe -MinVersion $targetVer
        if ($found) { Write-OK "Java $targetVer found: $found"; return $found }
        Write-ERR "Java $targetVer not found after install."
        Pause-ForKey "Press any key to continue..."
        return $null

    } else {
        do {
            Write-Host "  Path to java.exe: " -ForegroundColor Cyan -NoNewline
            $p = (Read-Host).Trim('"').Trim("'")
            if ([string]::IsNullOrWhiteSpace($p)) { Write-ERR "Path cannot be empty."; continue }
            if (Test-Path $p) {
                try {
                    $ver = & "$p" -version 2>&1 | Select-Object -First 1
                    if ($ver -match '"(\d+)') {
                        $v = [int]$Matches[1]
                        if ($v -ge $targetVer) { Write-OK "Java $v found."; return $p }
                        Write-ERR "That is Java $v -- need $targetVer or higher."
                    }
                } catch { Write-ERR "Could not run that java.exe" }
            } else { Write-ERR "Path not found." }
        } while ($true)
    }
}

function Ensure-Java {
    # Called before starting a server install with a known MC version.
    # Returns a valid java.exe path, installing if needed.
    param([string]$McVersion, [string]$CurrentJavaExe = "")
    $required = Get-RequiredJavaVersion -McVersion $McVersion
    Write-SubStep "Minecraft $McVersion requires Java $required+" "Gray"

    # Check if current java exe already meets the requirement
    if ($CurrentJavaExe -and (Test-Path $CurrentJavaExe)) {
        try {
            $ver = & "$CurrentJavaExe" -version 2>&1 | Select-Object -First 1
            if ($ver -match '"(\d+)' -and [int]$Matches[1] -ge $required) {
                Write-OK "Current Java meets requirement (Java $([int]$Matches[1]) >= $required)"
                return $CurrentJavaExe
            }
            Write-WARN "Current Java is version $([int]$Matches[1]) but $McVersion needs $required+"
        } catch {}
    }

    # Search for any installed Java that meets requirement
    $found = Find-JavaExe -MinVersion $required
    if ($found) {
        Write-OK "Found compatible Java at: $found"
        return $found
    }

    # Need to install
    Write-WARN "No Java $required+ found. Installation required."
    return Install-Java -MinVersion $required
}

# ---------------------------------------------------------------------------
#  FOLDER PICKERS
# ---------------------------------------------------------------------------

function Pick-Folder {
    param([string]$Default, [string]$Prompt)
    Write-Host ""
    Write-Host "  $Prompt" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    [1] Use default path" -ForegroundColor Yellow -NoNewline
    Write-Host "   --  $Default" -ForegroundColor DarkGray
    Write-Host "    [2] Enter a custom path" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Choice (1/2): " -ForegroundColor DarkCyan -NoNewline
    do {
        $inp = Read-Host
        if ($inp -eq "1" -or [string]::IsNullOrWhiteSpace($inp)) { return $Default }
        if ($inp -eq "2") {
            Write-Host "  Path: " -ForegroundColor Yellow -NoNewline
            $p = (Read-Host).Trim('"').Trim("'")
            if ([string]::IsNullOrWhiteSpace($p)) { return $Default }
            return $p
        }
        Write-Host "  Enter 1 or 2: " -ForegroundColor Red -NoNewline
    } while ($true)
}

function Pick-ExistingFolder {
    param([string]$Prompt, [string]$Default = "")

    # Auto-scan script directory for Fabric server folders
    $scriptDir   = Split-Path -Parent $PSCommandPath
    $serverDirs  = @(Get-ChildItem $scriptDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { (Get-ChildItem $_.FullName -Filter "fabric-server-mc.*.jar" -ErrorAction SilentlyContinue).Count -gt 0 })

    Write-Host ""
    Write-Host "  $Prompt" -ForegroundColor Cyan
    Write-Host ""

    $options = [System.Collections.Generic.List[string]]::new()

    # List found server folders first
    if ($serverDirs.Count -gt 0) {
        Write-Host "  Found server folders in script directory:" -ForegroundColor DarkCyan
        foreach ($dir in $serverDirs) {
            # Try to detect version from jar name
            $jar = Get-ChildItem $dir.FullName -Filter "fabric-server-mc.*.jar" | Select-Object -First 1
            $ver = ""
            if ($jar -and $jar.Name -match "fabric-server-mc\.([^-]+)-") { $ver = "  [MC $($Matches[1])]" }
            $n = $options.Count + 1
            Write-Host "    [$n] " -ForegroundColor Yellow -NoNewline
            Write-Host "$($dir.Name)$ver" -ForegroundColor White
            $options.Add($dir.FullName) | Out-Null
        }
        Write-Host ""
    }

    # (no raw default path option -- script dir itself is not a valid server folder)

    # Always offer manual entry
    $manualN = $options.Count + 1
    Write-Host "    [$manualN] " -ForegroundColor Yellow -NoNewline
    Write-Host "Enter a path manually" -ForegroundColor DarkGray
    Write-Host ""

    do {
        Write-Host "  Choice (1-$manualN): " -ForegroundColor DarkCyan -NoNewline
        $inp = Read-Host
        if ([string]::IsNullOrWhiteSpace($inp)) {
            Write-Host "  Please enter a number (1-$manualN): " -ForegroundColor Red -NoNewline
            continue
        }
        $n = 0
        if ([int]::TryParse($inp.Trim(), [ref]$n)) {
            if ($n -ge 1 -and $n -le $options.Count) { return $options[$n-1] }
            if ($n -eq $manualN) { break }
        }
        Write-Host "  Invalid. Enter 1-$manualN`: " -ForegroundColor Red -NoNewline
    } while ($true)

    # Manual entry -- loop until valid, never return empty
    do {
        Write-Host "  Path: " -ForegroundColor Yellow -NoNewline
        $raw = Read-Host
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-ERR "Path cannot be empty. Try again."
            continue
        }
        $p = $raw.Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($p)) {
            Write-ERR "Path cannot be empty. Try again."
            continue
        }
        if (Test-Path $p -PathType Container) { return $p }
        Write-ERR "Folder not found: $p -- check the path and try again."
    } while ($true)
}

# ---------------------------------------------------------------------------
#  VERSION HELPERS
# ---------------------------------------------------------------------------

function Sort-McVersions {
    param([string[]]$Versions)
    $filtered = @($Versions | Where-Object { $_ -match "^\d+\.\d+(\.\d+)?$" })
    if ($filtered.Count -eq 0) { return @() }
    return @($filtered | Sort-Object {
        $p = $_ -split "\."
        $maj = if ($p.Count -gt 0 -and $p[0] -match "^\d+$") { [int]$p[0] } else { 0 }
        $min = if ($p.Count -gt 1 -and $p[1] -match "^\d+$") { [int]$p[1] } else { 0 }
        $pat = if ($p.Count -gt 2 -and $p[2] -match "^\d+$") { [int]$p[2] } else { 0 }
        [long](($maj * 100000) + ($min * 1000) + $pat)
    } -Descending)
}

function Get-BestVersion {
    param([string[]]$Versions)
    $s = Sort-McVersions $Versions
    if ($s.Count -eq 0) { return "" }
    return [string]($s | Select-Object -First 1)
}

function Get-FabricStableVersions {
    $data = Invoke-JsonApi "https://meta.fabricmc.net/v2/versions/game"
    if (-not $data) { throw "Cannot reach meta.fabricmc.net" }
    return @($data | Where-Object { $_.stable -eq $true } | ForEach-Object { $_.version } | Where-Object {
        if ($_ -notmatch "^\d+\.\d+(\.\d+)?$") { return $false }
        $p = $_ -split "\."; $maj = [int]$p[0]; $min = [int]$p[1]
        ($maj -gt 1) -or ($maj -eq 1 -and $min -ge 14)
    })
}

function Get-ModFabricVersions {
    param([string]$Slug)
    $enc  = [Uri]::EscapeDataString($Slug)
    $data = Invoke-JsonApi "https://api.modrinth.com/v2/project/$enc/version?loaders=%5B%22fabric%22%5D"
    if (-not $data -or $data.Count -eq 0) {
        $data = Invoke-JsonApi "https://api.modrinth.com/v2/project/$enc/version"
        if ($data) { $data = $data | Where-Object { $_.loaders -contains "fabric" } }
    }
    if (-not $data) { return @() }
    $versions = @()
    foreach ($v in $data) {
        if ($v.version_type -in @("release","beta","alpha")) { $versions += $v.game_versions }
    }
    if ($versions.Count -eq 0) { foreach ($v in $data) { $versions += $v.game_versions } }
    return @($versions | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
#  DEPENDENCY RESOLUTION
# ---------------------------------------------------------------------------

function Get-ModDependencies {
    # Returns array of REQUIRED dependency project slugs for a given mod+version.
    # Uses the bulk /versions endpoint to resolve all dep version_ids in one call,
    # which also gives us project_ids directly -- no per-dep round trips needed.
    param([string]$Slug, [string]$McVersion)
    $enc    = [Uri]::EscapeDataString($Slug)
    $encVer = [Uri]::EscapeDataString($McVersion)
    $url    = "https://api.modrinth.com/v2/project/$enc/version?loaders=%5B%22fabric%22%5D&game_versions=%5B%22$encVer%22%5D"
    $data   = Invoke-JsonApi $url
    if (-not $data -or $data.Count -eq 0) { return @() }

    $ver = $data | Where-Object { $_.version_type -in @("release","beta","alpha") } | Select-Object -First 1
    if (-not $ver) { $ver = $data | Select-Object -First 1 }

    if (-not $ver.dependencies -or $ver.dependencies.Count -eq 0) { return @() }

    # Collect only required deps
    $requiredDeps = @($ver.dependencies | Where-Object { $_.dependency_type -eq "required" })
    if ($requiredDeps.Count -eq 0) { return @() }

    # Separate deps that already have project_id from those that only have version_id
    $projectIds = [System.Collections.Generic.List[string]]::new()
    $versionIds = [System.Collections.Generic.List[string]]::new()
    foreach ($dep in $requiredDeps) {
        if (-not [string]::IsNullOrWhiteSpace($dep.project_id)) {
            $projectIds.Add($dep.project_id) | Out-Null
        } elseif (-not [string]::IsNullOrWhiteSpace($dep.version_id)) {
            $versionIds.Add($dep.version_id) | Out-Null
        }
    }

    # Resolve version_ids -> project_ids using bulk versions endpoint
    # POST /v2/versions with a list of IDs returns full version objects
    if ($versionIds.Count -gt 0) {
        $idsJson = ($versionIds | ForEach-Object { "`"$_`"" }) -join ","
        $bulkUrl = "https://api.modrinth.com/v2/versions?ids=%5B$([Uri]::EscapeDataString($idsJson))%5D"
        $bulkData = Invoke-JsonApi $bulkUrl
        if ($bulkData) {
            foreach ($v in $bulkData) {
                if (-not [string]::IsNullOrWhiteSpace($v.project_id)) {
                    $projectIds.Add($v.project_id) | Out-Null
                }
            }
        }
    }

    if ($projectIds.Count -eq 0) { return @() }

    # Bulk-fetch all projects at once to get their slugs
    # GET /v2/projects?ids=["id1","id2",...]
    $uniqueIds  = @($projectIds | Select-Object -Unique)
    $idsJson2   = ($uniqueIds | ForEach-Object { "`"$_`"" }) -join ","
    $projUrl    = "https://api.modrinth.com/v2/projects?ids=%5B$([Uri]::EscapeDataString($idsJson2))%5D"
    $projects   = Invoke-JsonApi $projUrl
    Start-Sleep -Milliseconds 100

    $slugs = @()
    if ($projects) {
        foreach ($p in $projects) {
            if (-not [string]::IsNullOrWhiteSpace($p.slug)) { $slugs += $p.slug }
        }
    }
    return $slugs
}

function Resolve-AllDependencies {
    # Recursively resolves all required dependencies.
    # Returns the complete flat list of slugs (originals + all transitive deps).
    param([string[]]$Slugs, [string]$McVersion)
    $resolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $added    = [System.Collections.Generic.List[string]]::new()
    # Queue holds [slug, parentSlug] pairs
    $queue    = [System.Collections.Queue]::new()
    foreach ($s in $Slugs) { $queue.Enqueue(@($s, "root")) }

    while ($queue.Count -gt 0) {
        $item   = $queue.Dequeue()
        $slug   = $item[0]
        $parent = $item[1]
        if ($resolved.Contains($slug)) { continue }
        $resolved.Add($slug) | Out-Null

        $deps = Get-ModDependencies -Slug $slug -McVersion $McVersion

        # Apply known-missing-dep overrides for mods that don't declare them properly
        if ($global:KNOWN_EXTRA_DEPS.ContainsKey($slug)) {
            foreach ($extra in $global:KNOWN_EXTRA_DEPS[$slug]) {
                if ($deps -notcontains $extra) {
                    Write-SubStep ("  Patching known dep: " + $extra + " -> " + $slug) "DarkGray"
                    $deps += $extra
                }
            }
        }

        foreach ($d in $deps) {
            if (-not $resolved.Contains($d)) {
                $queue.Enqueue(@($d, $slug))
                if ($Slugs -notcontains $d) {
                    $added.Add($d) | Out-Null
                }
            }
        }
    }

    if ($added.Count -gt 0) {
        Write-SubStep "Auto-added dependencies: $($added -join ', ')" "DarkGray"
    }
    return @($resolved)
}

# ---------------------------------------------------------------------------
#  BUILD MOD LIST FROM EXISTING MODS FOLDER
#  Scans installed .jar files, matches via Modrinth SHA1 hash lookup,
#  merges with the default list (so defaults not installed are still shown).
# ---------------------------------------------------------------------------

function Build-ModListFromFolder {
    param([string]$ModsDir)
    $mods = [System.Collections.ArrayList]@()
    $defaultSlugs = @($global:DEFAULT_MODS | ForEach-Object { $_.slug })
    $foundSlugs   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (Test-Path $ModsDir) {
        $jarFiles = @(Get-ChildItem $ModsDir -Filter "*.jar")
        if ($jarFiles.Count -gt 0) {
            Write-Step "Detecting installed mods..." "Cyan"
            Write-SubStep "Hashing $($jarFiles.Count) jar files and querying Modrinth..." "Gray"

            # SHA1 hash every jar
            $hashes = @{}
            foreach ($jar in $jarFiles) {
                try {
                    $sha1 = [System.BitConverter]::ToString(
                        [System.Security.Cryptography.SHA1]::Create().ComputeHash(
                            [System.IO.File]::ReadAllBytes($jar.FullName)
                        )
                    ).Replace("-","").ToLower()
                    $hashes[$sha1] = $jar.Name
                } catch { Write-WARN "Could not hash: $($jar.Name)" }
            }

            # POST all hashes to Modrinth version_files endpoint
            $foundProjectIds = @{}
            if ($hashes.Count -gt 0) {
                $body    = @{ hashes = @($hashes.Keys); algorithm = "sha1" } | ConvertTo-Json
                $headers = @{ "User-Agent"="DaServa-ServerManager/1.0"; "Content-Type"="application/json" }
                try {
                    $resp = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/version_files" `
                        -Method POST -Body $body -Headers $headers -ErrorAction Stop
                    $resp.PSObject.Properties | ForEach-Object {
                        if ($_.Value.project_id) { $foundProjectIds[$_.Value.project_id] = $true }
                    }
                } catch { Write-WARN "Modrinth hash lookup failed: $_" }
            }

            if ($foundProjectIds.Count -gt 0) {
                # Bulk fetch project slugs/names
                $idList  = ($foundProjectIds.Keys | ForEach-Object { "`"$_`"" }) -join ","
                $projUrl = "https://api.modrinth.com/v2/projects?ids=%5B$([Uri]::EscapeDataString($idList))%5D"
                $projects = Invoke-JsonApi $projUrl
                foreach ($proj in $projects) {
                    if ([string]::IsNullOrWhiteSpace($proj.slug)) { continue }
                    $foundSlugs.Add($proj.slug) | Out-Null
                    $isDefault = $defaultSlugs -contains $proj.slug
                    $mods.Add(@{
                        slug    = $proj.slug
                        name    = $proj.title
                        enabled = $true
                        default = $isDefault
                    }) | Out-Null
                }
                $unmatched = $jarFiles.Count - $foundProjectIds.Count
                Write-OK "Identified $($mods.Count) / $($jarFiles.Count) mods"
                if ($unmatched -gt 0) {
                    Write-WARN "$unmatched jar(s) not on Modrinth (deps/custom) -- re-downloaded automatically"
                }
            } else {
                Write-WARN "Could not identify installed mods. Using default list."
            }
        }
    }

    # Merge: add any default mods NOT already found, with enabled=$false
    # so the user can see them and opt in
    foreach ($m in $global:DEFAULT_MODS) {
        if (-not $foundSlugs.Contains($m.slug)) {
            $mods.Add(@{
                slug    = $m.slug
                name    = $m.name
                enabled = $false    # not currently installed -- off by default
                default = $true
            }) | Out-Null
        }
    }

    return $mods
}

# ---------------------------------------------------------------------------
#  DEFAULT MOD PROFILES
# ---------------------------------------------------------------------------

$global:DEFAULT_MODS = @(
    @{ slug="attributefix";          name="AttributeFix";                                enabled=$true },
    @{ slug="c2me-fabric";           name="Concurrent Chunk Management Engine (Fabric)"; enabled=$true },
    @{ slug="chunky";                name="Chunky";                                      enabled=$true },
    @{ slug="clumps";                name="Clumps";                                      enabled=$true },
    @{ slug="collective";            name="Collective";                                  enabled=$true },
    @{ slug="cristel-lib";           name="Cristel Lib";                                 enabled=$true },
    @{ slug="debugify";              name="Debugify";                                    enabled=$true },
    @{ slug="distanthorizons";       name="Distant Horizons";                            enabled=$true },
    @{ slug="prickle";               name="Prickle";                                     enabled=$true },
    @{ slug="scalablelux";           name="ScalableLux";                                 enabled=$true },
    @{ slug="sswaystones";           name="Server-Side Waystones";                       enabled=$true },
    @{ slug="tectonic";              name="Tectonic";                                    enabled=$true },
    @{ slug="terralith";             name="Terralith";                                   enabled=$true },
    @{ slug="towns-and-towers";      name="Towns and Towers";                            enabled=$true },
    @{ slug="vanish";                name="Vanish";                                      enabled=$true },
    @{ slug="villager-names-serilum";name="Villager Names";                              enabled=$true },
    @{ slug="worldedit";             name="WorldEdit";                                   enabled=$true },
    @{ slug="worldedit-hang-fix";    name="WorldEdit Hang Fix";                          enabled=$true },
    @{ slug="journeymap";            name="JourneyMap";                                  enabled=$true },
    @{ slug="just-player-heads";     name="Just Player Heads";                           enabled=$true },
    @{ slug="just-mob-heads";        name="Just Mob Heads";                              enabled=$true },
    @{ slug="krypton";               name="Krypton";                                     enabled=$true },
    @{ slug="lithium";               name="Lithium";                                     enabled=$true },
    @{ slug="lithostitched";         name="Lithostitched";                               enabled=$true },
    @{ slug="luckperms";             name="LuckPerms";                                   enabled=$true },
    @{ slug="not-enough-animations"; name="Not Enough Animations";                       enabled=$true },
    @{ slug="packet-fixer";          name="Packet Fixer";                                enabled=$true },
    @{ slug="geyser";                name="Geyser";                                      enabled=$true },
    @{ slug="image2map";             name="Image2Map";                                   enabled=$true },
    @{ slug="im-fast";               name="I'm Fast";                                    enabled=$true },
    @{ slug="invsee++-fabric";       name="Invsee++";                                    enabled=$true },
    @{ slug="ferrite-core";          name="FerriteCore";                                 enabled=$true },
    @{ slug="floodgate";             name="Floodgate";                                   enabled=$true },
    @{ slug="fabric-api";            name="Fabric API";                                  enabled=$true },
    @{ slug="carpet";                name="Carpet";                                      enabled=$true }
)

# ---------------------------------------------------------------------------
#  KNOWN MISSING DEPENDENCIES
#  Some mods don't correctly declare deps on older Modrinth versions.
#  This table patches them in manually.
# ---------------------------------------------------------------------------

$global:KNOWN_EXTRA_DEPS = @{
    "tectonic" = @("lithostitched")
}

# ---------------------------------------------------------------------------
#  MOD SELECTOR  (arrow-key checklist + search)
# ---------------------------------------------------------------------------

function Get-ModCompatLabel {
    param([string]$Slug)
    $enc  = [Uri]::EscapeDataString($Slug)

    # Side label from project endpoint
    $proj = Invoke-JsonApi "https://api.modrinth.com/v2/project/$enc"
    $side = ""
    if ($proj) {
        $cs = $proj.client_side; $ss = $proj.server_side
        if     ($cs -eq "required"    -and $ss -eq "required")     { $side = "Both"   }
        elseif ($cs -eq "required"    -and $ss -eq "unsupported")  { $side = "Client" }
        elseif ($cs -eq "unsupported" -and $ss -eq "required")     { $side = "Server" }
        elseif ($ss -eq "required")                                { $side = "Server" }
        elseif ($cs -eq "required")                                { $side = "Client" }
        elseif ($cs -eq "optional"    -and $ss -eq "optional")     { $side = "Both"   }
        elseif ($ss -eq "optional")                                { $side = "Server" }
        elseif ($cs -eq "optional")                                { $side = "Client" }
    }

    # Versions from fabric-filtered version endpoint
    $data = Invoke-JsonApi "https://api.modrinth.com/v2/project/$enc/version?loaders=%5B%22fabric%22%5D"
    if (-not $data -or $data.Count -eq 0) {
        $data = Invoke-JsonApi "https://api.modrinth.com/v2/project/$enc/version"
        if ($data) { $data = $data | Where-Object { $_.loaders -contains "fabric" } }
    }
    if (-not $data) { return @{ versions=""; side=$side; updated="" } }

    $releaseVersions = @()
    foreach ($v in $data) {
        if ($v.version_type -in @("release","beta","alpha")) { $releaseVersions += $v.game_versions }
    }
    if ($releaseVersions.Count -eq 0) { foreach ($v in $data) { $releaseVersions += $v.game_versions } }
    $releaseVersions = @($releaseVersions | Select-Object -Unique | Where-Object { $_ -match "^\d+\.\d+(\.\d+)?$" })

    # Last updated date from most recent version
    $latestVer = $data | Sort-Object { $_.date_published } -Descending | Select-Object -First 1
    $updated = ""
    if ($latestVer -and $latestVer.date_published) {
        try {
            $dt = [DateTime]::Parse($latestVer.date_published)
            $days = ([DateTime]::Now - $dt).Days
            $updated = if ($days -eq 0) { "today" }
                       elseif ($days -lt 7) { "${days}d ago" }
                       elseif ($days -lt 30) { "$([int]($days/7))w ago" }
                       elseif ($days -lt 365) { "$([int]($days/30))mo ago" }
                       else { "$([int]($days/365))y ago" }
        } catch {}
    }

    if ($releaseVersions.Count -eq 0) { return @{ versions=""; side=$side; updated=$updated } }

    $buckets = @($releaseVersions | ForEach-Object {
        $p = $_ -split "\."; "$($p[0]).$($p[1])"
    } | Select-Object -Unique)

    $sorted = @($buckets | Sort-Object {
        $p = $_ -split "\."
        $maj = if ($p[0] -match "^\d+$") { [int]$p[0] } else { 0 }
        $min = if ($p.Count -gt 1 -and $p[1] -match "^\d+$") { [int]$p[1] } else { 0 }
        [long](($maj * 100000) + ($min * 1000))
    } -Descending)

    $shown  = $sorted | Select-Object -First 4
    $verStr = ($shown | ForEach-Object { "$_.x" }) -join "  "
    if ($sorted.Count -gt 4) { $verStr += "  ..." }

    return @{ versions=$verStr; side=$side; updated=$updated }
}

function Fetch-ModVersionLabels {
    # Fetches compatibility info for all mods, returns hashtable slug -> @{versions;side}
    param([System.Collections.ArrayList]$Mods, [string]$McVersion = "")
    $labels = @{}
    $total  = $Mods.Count
    $i      = 0
    foreach ($mod in $Mods) {
        $i++
        Write-Host "`r     Fetching mod info ($i/$total)...    " -NoNewline -ForegroundColor DarkCyan
        $labels[$mod.slug] = Get-ModCompatLabel -Slug $mod.slug
        Start-Sleep -Milliseconds 120
    }
    Write-Host "`r                                          `r" -NoNewline
    return $labels
}

function Show-ModSelector {
    param([System.Collections.ArrayList]$Mods)

    Write-Host ""
    Write-Host "  Loading mod info from Modrinth..." -ForegroundColor DarkCyan
    $vLabels = Fetch-ModVersionLabels -Mods $Mods

    $cursor    = 0
    $offset    = 0
    $pageH     = 16
    $msg       = ""
    $filter    = "All"
    $filterCycle = @("All","Server","Client","Both","Enabled","Disabled")
    $filterIdx = 0
    $search    = ""
    $searchMode = $false   # when true, all typing goes to search, no keybinds fire
    $showHelp  = $false
    $capDirty  = $true
    $capInfo   = @{ version=""; cappers=@() }

    while ($true) {
        # Build visible list from filter + search
        $visible = [System.Collections.ArrayList]@()
        foreach ($mod in $Mods) {
            $info = if ($vLabels.ContainsKey($mod.slug)) { $vLabels[$mod.slug] } else { $null }
            $side = if ($info) { $info.side } else { "" }
            $passFilter = switch ($filter) {
                "Server"   { $side -eq "Server" }
                "Client"   { $side -eq "Client" }
                "Both"     { $side -eq "Both" }
                "Enabled"  { $mod.enabled }
                "Disabled" { -not $mod.enabled }
                default    { $true }
            }
            $passSearch = ($search -eq "") -or ($mod.name -match [regex]::Escape($search))
            if ($passFilter -and $passSearch) { $visible.Add($mod) | Out-Null }
        }

        if ($visible.Count -gt 0 -and $cursor -ge $visible.Count) { $cursor = $visible.Count - 1 }
        if ($cursor -lt 0) { $cursor = 0 }
        if ($cursor -lt $offset)          { $offset = $cursor }
        if ($cursor -ge $offset + $pageH) { $offset = $cursor - $pageH + 1 }
        $visEnd = [Math]::Min($offset + $pageH, $visible.Count)

        # Version cap
        if ($capDirty) {
            # Cap calculation only considers mods that actually affect the SERVER.
            # Client-only mods don't constrain the server version.
            function Get-BucketScore([string]$bucket) {
                $p = $bucket -split "\."
                if ($p.Count -lt 2 -or $p[0] -notmatch "^\d+$" -or $p[1] -notmatch "^\d+$") { return -1 }
                return [int]$p[0]*100000 + [int]$p[1]*1000
            }

            $modScores = @{}
            $modLabels = @{}
            foreach ($mod in ($Mods | Where-Object { $_.enabled })) {
                $info = if ($vLabels.ContainsKey($mod.slug)) { $vLabels[$mod.slug] } else { $null }
                if (-not $info -or -not $info.versions) { continue }
                # Include all mods in cap calculation -- even client-side mods
                # constrain the version since they're in the enabled list
                $firstBucket = ($info.versions -split "\s+")[0] -replace "\.x",""
                $score = Get-BucketScore $firstBucket
                if ($score -lt 0) { continue }
                $modScores[$mod.name] = $score
                $modLabels[$mod.name] = $firstBucket
            }

            if ($modScores.Count -gt 0) {
                $capScore    = ($modScores.Values | Measure-Object -Minimum).Minimum
                $capLabelStr = $modLabels.GetEnumerator() |
                    Where-Object { (Get-BucketScore $_.Value) -eq $capScore } |
                    Select-Object -First 1 -ExpandProperty Value
                $cappers = @($modScores.GetEnumerator() |
                    Where-Object { $_.Value -le $capScore } |
                    ForEach-Object { $_.Key })
                $capInfo = @{ version=$capLabelStr; cappers=$cappers }
            } else { $capInfo = @{ version=""; cappers=@() } }
            $capDirty = $false
        }

        Clear-Host
        Write-Host ("=" * 72) -ForegroundColor DarkGreen
        Write-Host "  MOD SELECTOR  --  $($Mods.Count) mods  ($( ($Mods | Where-Object { $_.enabled }).Count ) enabled)" -ForegroundColor Green
        if ($searchMode) {
            Write-Host "  SEARCH MODE: type to filter, ESC=exit search, ENTER=confirm selection" -ForegroundColor Yellow
        } else {
            Write-Host "  SPACE=toggle  A=add  D=remove  F=filter  E=on  N=off  /=search  H=help  B=back" -ForegroundColor DarkCyan
        }
        Write-Host ("=" * 72) -ForegroundColor DarkGreen

        # Filter + search bar
        Write-Host "  Filter: " -ForegroundColor DarkGray -NoNewline
        $filterColor = if ($filter -eq "All") { "DarkGray" } else { "Yellow" }
        Write-Host $filter -ForegroundColor $filterColor -NoNewline
        Write-Host "   Search: " -ForegroundColor DarkGray -NoNewline
        if ($searchMode) {
            Write-Host "$search|" -ForegroundColor Yellow
        } elseif ($search) {
            Write-Host "$search  (/ to edit, ESC to clear)" -ForegroundColor Yellow
        } else {
            Write-Host "(press / to search)" -ForegroundColor DarkGray
        }
        Write-Host ""

        if ($showHelp) {
            Write-Host "  +-----------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host "  |  KEYBINDS (normal mode)                                         |" -ForegroundColor Cyan
            Write-Host "  |  UP / DOWN      Navigate mod list                               |" -ForegroundColor Gray
            Write-Host "  |  PgUp / PgDn    Scroll by page                                  |" -ForegroundColor Gray
            Write-Host "  |  Home / End     Jump to top / bottom                            |" -ForegroundColor Gray
            Write-Host "  |  SPACE          Toggle mod on/off                               |" -ForegroundColor Gray
            Write-Host "  |  A              Add mod (search Modrinth)                       |" -ForegroundColor Gray
            Write-Host "  |  D              Remove custom mod (default = disable only)      |" -ForegroundColor Gray
            Write-Host "  |  F              Cycle filter (All/Server/Client/Both/On/Off)    |" -ForegroundColor Gray
            Write-Host "  |  E              Enable all currently visible mods               |" -ForegroundColor Gray
            Write-Host "  |  N              Disable all currently visible mods              |" -ForegroundColor Gray
            Write-Host "  |  /              Enter search mode (type freely, no conflicts)   |" -ForegroundColor Gray
            Write-Host "  |  H              Toggle this help panel                          |" -ForegroundColor Gray
            Write-Host "  |  B              Back to main menu                               |" -ForegroundColor Gray
            Write-Host "  |  ENTER          Confirm and continue                            |" -ForegroundColor Gray
            Write-Host "  |                                                                 |" -ForegroundColor DarkCyan
            Write-Host "  |  SEARCH MODE (press /)                                         |" -ForegroundColor Cyan
            Write-Host "  |  Type anything  Filter list by mod name                        |" -ForegroundColor Gray
            Write-Host "  |  Backspace       Delete last character                          |" -ForegroundColor Gray
            Write-Host "  |  ESC             Exit search mode (keeps filter)               |" -ForegroundColor Gray
            Write-Host "  |  ENTER           Exit search mode and confirm selection         |" -ForegroundColor Gray
            Write-Host "  |                                                                 |" -ForegroundColor DarkCyan
            Write-Host "  |  SIDE LABELS                                                    |" -ForegroundColor Cyan
            Write-Host "  |  [Server]  Server only -- clients dont need this mod           |" -ForegroundColor Gray
            Write-Host "  |  [Client]  Client only -- not needed on server                 |" -ForegroundColor Gray
            Write-Host "  |  [Both]    Required on both server AND clients                 |" -ForegroundColor Gray
            Write-Host "  |                                                                 |" -ForegroundColor DarkCyan
            Write-Host "  |  VERSION CAP (shown in yellow)                                 |" -ForegroundColor Cyan
            Write-Host "  |  The server version is limited by the oldest mod enabled.      |" -ForegroundColor Gray
            Write-Host "  |  Mods marked [caps version] are the limiting ones.             |" -ForegroundColor Gray
            Write-Host "  |  Disable or replace them to unlock a newer MC version.         |" -ForegroundColor Gray
            Write-Host "  +-----------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host ""
            Write-Host "  Press H to close help..." -ForegroundColor DarkGray
            do { $k = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } while ($k.VirtualKeyCode -in @(16,17,18))
            $showHelp = $false
            continue
        }

        # Mod list
        if ($visible.Count -eq 0) {
            Write-Host "  (no mods match current filter/search)" -ForegroundColor DarkGray
        } else {
            for ($i = $offset; $i -lt $visEnd; $i++) {
                $mod      = $visible[$i]
                $info     = if ($vLabels.ContainsKey($mod.slug)) { $vLabels[$mod.slug] } else { $null }
                $tick     = if ($mod.enabled) { "[X]" } else { "[ ]" }
                $isCapper = $capInfo.cappers -contains $mod.name
                $baseColor = if ($mod.enabled) { if ($isCapper) { "Yellow" } else { "Green" } } else { "DarkGray" }
                $fc       = if ($i -eq $cursor) { "White" } else { $baseColor }
                $prefix   = if ($i -eq $cursor) { " >> " } else { "    " }
                $marker   = if ($mod.default) { "" } else { " [custom]" }
                $capMark  = if ($isCapper -and $mod.enabled) { " [caps version]" } else { "" }
                $verStr     = if ($info -and $info.versions) { "  $($info.versions)" } else { "" }
                $sideStr    = if ($info -and $info.side)     { "  [$($info.side)]"   } else { "" }
                $updatedStr = if ($info -and $info.updated)  { "  ($($info.updated))"} else { "" }
                Write-Host "$prefix$tick  $($mod.name)$marker$capMark" -ForegroundColor $fc -NoNewline
                Write-Host $sideStr    -ForegroundColor Cyan    -NoNewline
                Write-Host $verStr     -ForegroundColor DarkGray -NoNewline
                Write-Host $updatedStr -ForegroundColor DarkGray
            }
        }

        if ($offset -gt 0)              { Write-Host "     ^ more above (PgUp/Home) ^" -ForegroundColor DarkGray }
        if ($visEnd -lt $visible.Count) { Write-Host "     v more below (PgDn/End) v"  -ForegroundColor DarkGray }

        Write-Host ""
        if ($capInfo.version) {
            Write-Host "  Max version: " -ForegroundColor DarkGray -NoNewline
            Write-Host $capInfo.version -ForegroundColor Yellow -NoNewline
            $capList = ($capInfo.cappers | Select-Object -First 3) -join ", "
            if ($capInfo.cappers.Count -gt 3) { $capList += " +$($capInfo.cappers.Count-3) more" }
            Write-Host "   Capped by: $capList" -ForegroundColor DarkGray
        }
        if ($msg) { Write-Host "  $msg" -ForegroundColor Yellow; $msg = "" }
        Write-Host "  Showing $($visible.Count) of $($Mods.Count)   H=help   ENTER=continue" -ForegroundColor DarkGray

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $vk  = $key.VirtualKeyCode
        $ch  = $key.Character

        if ($vk -in @(16,17,18)) { continue }

        # -- Search mode: all input goes to search string --
        if ($searchMode) {
            switch ($vk) {
                27 { $searchMode = $false }                              # ESC exit search mode
                13 { $searchMode = $false }                              # ENTER exit search + confirm handled below
                8  { if ($search.Length -gt 0) { $search = $search.Substring(0,$search.Length-1) } }  # Backspace
                default {
                    if ($ch -ge 32 -and [int]$ch -le 126) { $search += $ch }
                }
            }
            # If Enter was pressed in search mode, also confirm selection
            if ($vk -eq 13) { return $Mods }
            continue
        }

        # -- Normal mode keybinds --
        switch ($vk) {
            38  { if ($cursor -gt 0)               { $cursor-- } }
            40  { if ($cursor -lt $visible.Count-1) { $cursor++ } }
            33  { $cursor = [Math]::Max(0, $cursor - $pageH) }
            34  { $cursor = [Math]::Min([Math]::Max(0,$visible.Count-1), $cursor+$pageH) }
            36  { $cursor = 0 }
            35  { $cursor = [Math]::Max(0, $visible.Count-1) }
            13  { return $Mods }                                         # Enter confirm
            27  { $search = "" }                                         # ESC clear search
            32  {                                                        # Space toggle
                if ($visible.Count -gt 0) {
                    $t = $visible[$cursor]; $idx = $Mods.IndexOf($t)
                    if ($idx -ge 0) {
                        $Mods[$idx].enabled = -not $Mods[$idx].enabled
                        $capDirty = $true
                        # If we just enabled a mod, check KNOWN_EXTRA_DEPS and auto-enable deps
                        if ($Mods[$idx].enabled -and $global:KNOWN_EXTRA_DEPS.ContainsKey($Mods[$idx].slug)) {
                            foreach ($depSlug in $global:KNOWN_EXTRA_DEPS[$Mods[$idx].slug]) {
                                $depMod = $Mods | Where-Object { $_.slug -eq $depSlug } | Select-Object -First 1
                                if ($depMod -and -not $depMod.enabled) {
                                    $depIdx = $Mods.IndexOf($depMod)
                                    $Mods[$depIdx].enabled = $true
                                    $msg = "Auto-enabled dependency: $($depMod.name)"
                                }
                            }
                        }
                    }
                }
            }
            default {
                switch ([char]::ToUpper($ch)) {
                    '/' { $searchMode = $true }                          # / enter search mode
                    'F' {                                                # F filter
                        $filterIdx = ($filterIdx+1) % $filterCycle.Count
                        $filter = $filterCycle[$filterIdx]; $cursor=0; $offset=0
                    }
                    'E' {                                                # E enable all visible
                        foreach ($m in $visible) { $idx=$Mods.IndexOf($m); if($idx-ge 0){$Mods[$idx].enabled=$true} }
                        $capDirty=$true; $msg="Enabled all visible mods."
                    }
                    'N' {                                                # N disable all visible
                        foreach ($m in $visible) { $idx=$Mods.IndexOf($m); if($idx-ge 0){$Mods[$idx].enabled=$false} }
                        $capDirty=$true; $msg="Disabled all visible mods."
                    }
                    'A' {                                                # A add mod
                        $result = Search-AndAddMod
                        if ($result) {
                            if ($Mods | Where-Object { $_.slug -eq $result.slug }) {
                                $msg = "'$($result.name)' is already in the list."
                            } else {
                                $Mods.Add(@{ slug=$result.slug; name=$result.name; enabled=$true; default=$false }) | Out-Null
                                $vLabels[$result.slug] = Get-ModCompatLabel -Slug $result.slug
                                $capDirty=$true; $msg="Added: $($result.name)"
                            }
                        }
                    }
                    'D' {                                                # D remove
                        if ($visible.Count -gt 0) {
                            $mod = $visible[$cursor]
                            if ($mod.default) { $msg="Default mods cannot be removed -- use SPACE to disable." }
                            else { $name=$mod.name; $Mods.Remove($mod); if($cursor-ge $visible.Count-and $cursor-gt 0){$cursor--}; $capDirty=$true; $msg="Removed: $name" }
                        }
                    }
                    'H' { $showHelp = $true }                           # H help
                    'B' { return $null }                                 # B back
                }
            }
        }
    }
}

function Search-AndAddMod {
    # Returns @{slug; name} or $null
    Clear-Host
    Write-Host ("=" * 72) -ForegroundColor DarkGreen
    Write-Host "  MODRINTH SEARCH  (Fabric mods only)" -ForegroundColor Green
    Write-Host ("=" * 72) -ForegroundColor DarkGreen
    Write-Host ""
    Write-Host "  Enter search term (or paste a Modrinth URL/slug):" -ForegroundColor Cyan
    Write-Host "  (Leave blank to cancel)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Search: " -ForegroundColor Yellow -NoNewline
    $query = Read-Host
    if ([string]::IsNullOrWhiteSpace($query)) { return $null }

    # Check if it looks like a direct URL or slug
    $directSlug = $null
    if ($query -match "modrinth\.com/(?:mod|plugin)/([^/?#\s]+)") {
        $directSlug = $Matches[1].Trim("/")
    } elseif ($query -notmatch "\s") {
        # No spaces -- treat as possible slug
        $directSlug = $query.Trim("/")
    }

    if ($directSlug) {
        $enc  = [Uri]::EscapeDataString($directSlug)
        $proj = Invoke-JsonApi "https://api.modrinth.com/v2/project/$enc"
        if ($proj) {
            Write-OK "Found: $($proj.title)"
            return @{ slug=$proj.slug; name=$proj.title }
        }
    }

    # Full text search filtered to fabric
    $encQ = [Uri]::EscapeDataString($query)
    $url  = "https://api.modrinth.com/v2/search?query=$encQ&facets=%5B%5B%22categories%3Afabric%22%5D%5D&limit=10&index=relevance"
    $results = Invoke-JsonApi $url

    if (-not $results -or $results.hits.Count -eq 0) {
        Write-ERR "No results found for '$query'."
        Pause-ForKey
        return $null
    }

    $hits = $results.hits
    Clear-Host
    Write-Host ("=" * 72) -ForegroundColor DarkGreen
    Write-Host "  SEARCH RESULTS for: $query" -ForegroundColor Green
    Write-Host ("=" * 72) -ForegroundColor DarkGreen
    Write-Host ""

    $options = @()
    $descs   = @()
    foreach ($h in $hits) {
        $options += $h.title
        $dl = if ($h.downloads -gt 1000000) { "$([int]($h.downloads/1000000))M downloads" }
               elseif ($h.downloads -gt 1000) { "$([int]($h.downloads/1000))K downloads" }
               else { "$($h.downloads) downloads" }
        $descs += "$dl  --  $($h.description.Substring(0,[Math]::Min(50,$h.description.Length)))..."
    }
    $options += "Cancel"
    $descs   += ""

    $choice = Show-Menu -Title "Select a mod to add:" -Options $options -Descs $descs
    if ($choice -eq $hits.Count) { return $null }

    $selected = $hits[$choice]
    return @{ slug=$selected.slug; name=$selected.title }
}

# ---------------------------------------------------------------------------
#  VERSION SELECTOR
# ---------------------------------------------------------------------------

function Show-VersionSelector {
    param([string[]]$CompatibleVersions, [System.Collections.ArrayList]$ActiveMods = $null)
    $all    = @($CompatibleVersions)
    $cursor = 0
    $offset = 0
    $pageH  = 18
    $total  = if ($ActiveMods) { ($ActiveMods | Where-Object { $_.enabled }).Count } else { 0 }

    while ($true) {
        Clear-Host
        Write-Host ("=" * 72) -ForegroundColor DarkGreen
        Write-Host "  VERSION SELECTOR  --  $($all.Count) compatible versions" -ForegroundColor Green
        Write-Host "  UP/DOWN/PgUp/PgDn = navigate   ENTER = select   B = back   H = help" -ForegroundColor DarkCyan
        Write-Host ("=" * 72) -ForegroundColor DarkGreen
        Write-Host ""

        if ($cursor -lt $offset)          { $offset = $cursor }
        if ($cursor -ge $offset + $pageH) { $offset = $cursor - $pageH + 1 }
        $visEnd = [Math]::Min($offset + $pageH, $all.Count)

        for ($i = $offset; $i -lt $visEnd; $i++) {
            $ver    = $all[$i]
            $tag    = if ($i -eq 0) { "  <-- recommended" } else { "" }
            $prefix = if ($i -eq $cursor) { " >> " } else { "    " }
            $fc     = if ($i -eq $cursor) { "White" } elseif ($i -eq 0) { "Green" } else { "Gray" }
            Write-Host "$prefix$ver$tag" -ForegroundColor $fc
        }

        Write-Host ""
        if ($offset -gt 0)          { Write-Host "     ^ more above (PgUp/Home) ^" -ForegroundColor DarkGray }
        if ($visEnd -lt $all.Count) { Write-Host "     v more below (PgDn/End) v"  -ForegroundColor DarkGray }
        Write-Host ""
        Write-Host "  Selected: $($all[$cursor])   |   B=back   H=help" -ForegroundColor DarkCyan

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $vk  = $key.VirtualKeyCode
        if ($vk -in @(16,17,18)) { continue }

        switch ($vk) {
            38 { if ($cursor -gt 0)              { $cursor-- } }
            40 { if ($cursor -lt $all.Count - 1) { $cursor++ } }
            33 { $cursor = [Math]::Max(0, $cursor - $pageH) }
            34 { $cursor = [Math]::Min($all.Count - 1, $cursor + $pageH) }
            36 { $cursor = 0 }
            35 { $cursor = $all.Count - 1 }
            66 { return $null }
            72 {
                Clear-Host
                Write-Host ("=" * 72) -ForegroundColor DarkGreen
                Write-Host "  VERSION SELECTOR -- HELP" -ForegroundColor Cyan
                Write-Host ("=" * 72) -ForegroundColor DarkGreen
                Write-Host ""
                Write-Host "  The list shows every Minecraft version that ALL your selected" -ForegroundColor Gray
                Write-Host "  mods support on Fabric. The recommended (top) is the newest." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  To unlock a newer version, go back and disable mods shown" -ForegroundColor Gray
                Write-Host "  in yellow with [caps version] in the mod selector." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  KEYBINDS:" -ForegroundColor Cyan
                Write-Host "  UP/DOWN    Navigate" -ForegroundColor Gray
                Write-Host "  PgUp/PgDn  Page scroll" -ForegroundColor Gray
                Write-Host "  Home/End   Jump to top/bottom" -ForegroundColor Gray
                Write-Host "  ENTER      Select this version" -ForegroundColor Gray
                Write-Host "  B          Back to mod selector" -ForegroundColor Gray
                Write-Host ""
                Pause-ForKey "Press any key to return..."
            }
            13 { return [string]($all[$cursor]) }
        }
    }
}

# ---------------------------------------------------------------------------
#  CONFLICT RESOLUTION
# ---------------------------------------------------------------------------

function Resolve-ModConflict {
    param([string]$ModName, [string]$ModSlug, [string[]]$ModVersions, [string[]]$CurrentIntersection)
    Write-Host ""
    Write-Host "  +----------------------------------------------------+" -ForegroundColor Red
    Write-Host "  |  CONFLICT: $ModName" -ForegroundColor Red
    Write-Host "  +----------------------------------------------------+" -ForegroundColor Red
    Write-Host ""
    Write-Host "  This mod has no overlap with the versions other mods need." -ForegroundColor Yellow
    if ($ModVersions.Count -gt 0) {
        $top = (Sort-McVersions $ModVersions | Select-Object -First 5) -join ", "
        Write-Host "  $ModName supports  : $top ..." -ForegroundColor DarkCyan
    }
    if ($CurrentIntersection.Count -gt 0) {
        $top2 = (Sort-McVersions $CurrentIntersection | Select-Object -First 5) -join ", "
        Write-Host "  Other mods need    : $top2 ..." -ForegroundColor DarkCyan
    }
    Write-Host ""
    $choice = Show-Menu -Title "How do you want to handle this?" `
        -Options @("Disable this mod","Replace with a different mod (search Modrinth)")
    if ($choice -eq 0) { Write-WARN "$ModName disabled."; return @{ action="exclude" } }

    # Replace via search
    do {
        $result = Search-AndAddMod
        if (-not $result) { Write-WARN "Disabling $ModName instead."; return @{ action="exclude" } }
        $newVersions  = Get-ModFabricVersions -Slug $result.slug
        $newIntersect = @($CurrentIntersection | Where-Object { $newVersions -contains $_ })
        if ($newIntersect.Count -eq 0) {
            Write-ERR "'$($result.name)' also has no overlap with the other mods."
            if (-not (Confirm-YN "Try another replacement?")) { Write-WARN "Disabling $ModName instead."; return @{ action="exclude" } }
            continue
        }
        $best = Get-BestVersion $newIntersect
        Write-OK "'$($result.name)' works -- best shared version: $best"
        return @{ action="replace"; slug=$result.slug; name=$result.name }
    } while ($true)
}

# ---------------------------------------------------------------------------
#  COMPATIBLE VERSION DETECTION
# ---------------------------------------------------------------------------

function Find-CompatibleVersions {
    param([System.Collections.ArrayList]$ActiveMods)
    # Returns sorted list of ALL versions that are compatible with all active enabled mods
    Write-SectionHeader "Detecting Compatible Minecraft Versions"
    Write-SubStep "Querying Modrinth + FabricMC for each mod..." "Gray"

    $fabricVersions = Get-FabricStableVersions
    Write-OK "Fabric supports $($fabricVersions.Count) modern stable versions"

    $maxPasses = $ActiveMods.Count + 2
    $pass = 0

    do {
        $pass++
        $intersection = @($fabricVersions)
        $conflictMod  = $null
        $conflictVers = @()
        $preConflict  = @()

        $enabled = @($ActiveMods | Where-Object { $_.enabled })
        $total   = $enabled.Count
        $i       = 0
        Write-Host ""

        foreach ($mod in $enabled) {
            $i++
            Write-Host "     Checking ($i/$total): $($mod.name)..." -ForegroundColor DarkCyan
            $modVers = Get-ModFabricVersions -Slug $mod.slug
            Start-Sleep -Milliseconds 150

            if ($modVers.Count -eq 0) {
                Write-WARN "$($mod.name): could not fetch versions, skipping."
                continue
            }
            $top = (Sort-McVersions $modVers | Select-Object -First 3) -join ", "
            Write-SubStep "$($mod.name): $($modVers.Count) versions. Top: $top" "DarkGray"

            $newIntersection = @($intersection | Where-Object { $modVers -contains $_ })
            if ($newIntersection.Count -eq 0) {
                $conflictMod  = $mod
                $conflictVers = $modVers
                $preConflict  = $intersection
                break
            }
            $intersection = $newIntersection
        }
        Write-Host ""

        if ($conflictMod) {
            $res = Resolve-ModConflict -ModName $conflictMod.name -ModSlug $conflictMod.slug `
                -ModVersions $conflictVers -CurrentIntersection $preConflict
            if ($res.action -eq "exclude") {
                $idx = $ActiveMods.IndexOf($conflictMod)
                $ActiveMods[$idx].enabled = $false
            } else {
                $idx = $ActiveMods.IndexOf($conflictMod)
                $ActiveMods[$idx] = @{ slug=$res.slug; name=$res.name; enabled=$true; default=$false }
            }
            Write-SubStep "Re-checking with updated mod list..." "DarkCyan"
            continue
        }
        break
    } while ($pass -lt $maxPasses)

    if ($intersection.Count -eq 0) {
        Write-ERR "Could not find any compatible version. Check your mod list."
        Pause-ForKey "Press any key to return to menu..."; return
    }

    return @(Sort-McVersions $intersection)
}

# ---------------------------------------------------------------------------
#  FABRIC SERVER DOWNLOAD
# ---------------------------------------------------------------------------

function Get-FabricLoaderVersion {
    param([string]$McVersion)
    $enc  = [Uri]::EscapeDataString($McVersion)
    $data = Invoke-JsonApi "https://meta.fabricmc.net/v2/versions/loader/$enc"
    if (-not $data) { throw "Cannot fetch loader versions for $McVersion" }
    $s = $data | Where-Object { $_.loader.stable -eq $true } | Select-Object -First 1
    if (-not $s) { $s = $data | Select-Object -First 1 }
    return $s.loader.version
}

function Get-FabricInstallerVersion {
    $data = Invoke-JsonApi "https://meta.fabricmc.net/v2/versions/installer"
    if (-not $data) { throw "Cannot fetch installer versions" }
    $s = $data | Where-Object { $_.stable -eq $true } | Select-Object -First 1
    if (-not $s) { $s = $data | Select-Object -First 1 }
    return $s.version
}

function Download-FabricServer {
    param([string]$McVersion, [string]$ServerDir)
    Write-Step "Downloading Fabric Server" "Cyan"
    $loaderVer    = Get-FabricLoaderVersion -McVersion $McVersion
    $installerVer = Get-FabricInstallerVersion
    Write-SubStep "MC: $McVersion  |  Loader: $loaderVer  |  Installer: $installerVer" "Gray"
    $jarName = "fabric-server-mc.$McVersion-loader.$loaderVer-launcher.$installerVer.jar"
    $jarPath = Join-Path $ServerDir $jarName
    $dlUrl   = "https://meta.fabricmc.net/v2/versions/loader/$McVersion/$loaderVer/$installerVer/server/jar"
    if (-not (Download-File -Url $dlUrl -Dest $jarPath -Label "Fabric server jar")) { throw "Failed to download Fabric server jar." }
    Write-OK "Server jar: $jarName"
    return $jarName
}

# ---------------------------------------------------------------------------
#  MOD DOWNLOAD  (with dependency resolution)
# ---------------------------------------------------------------------------

function Get-LatestModFile {
    param([string]$Slug, [string]$McVersion)
    $encSlug = [Uri]::EscapeDataString($Slug)
    $encVer  = [Uri]::EscapeDataString($McVersion)
    $data    = Invoke-JsonApi "https://api.modrinth.com/v2/project/$encSlug/version?loaders=%5B%22fabric%22%5D&game_versions=%5B%22$encVer%22%5D"
    if (-not $data -or $data.Count -eq 0) { return $null }
    $release = $data | Where-Object { $_.version_type -in @("release","beta","alpha") } | Select-Object -First 1
    if (-not $release) { $release = $data | Select-Object -First 1 }
    $file = $release.files | Where-Object { $_.primary -eq $true } | Select-Object -First 1
    if (-not $file) { $file = $release.files | Select-Object -First 1 }
    # Extract sha1 from hashes object
    $sha1 = ""
    if ($file.hashes -and $file.hashes.sha1) { $sha1 = $file.hashes.sha1 }
    return @{ version=$release.version_number; filename=$file.filename; url=$file.url; sha1=$sha1 }
}

function Get-ModFileSize {
    param([string]$Url)
    try {
        $req = [System.Net.WebRequest]::Create($Url)
        $req.Method = "HEAD"
        $req.Headers.Add("User-Agent","DaServa-ServerManager/1.0")
        $resp = $req.GetResponse()
        $size = $resp.ContentLength
        $resp.Close()
        return $size
    } catch { return 0 }
}

function Download-AllMods {
    param([System.Collections.ArrayList]$Mods, [string]$McVersion, [string]$ModsDir)
    Write-Step "Resolving Dependencies + Downloading Mods" "Cyan"

    if (-not (Test-Path $ModsDir)) { New-Item -ItemType Directory -Path $ModsDir -Force | Out-Null }
    Get-ChildItem $ModsDir -Filter "*.jar" | Remove-Item -Force

    $enabledSlugs = @($Mods | Where-Object { $_.enabled } | ForEach-Object { $_.slug })
    Write-SubStep "Resolving dependencies..." "DarkCyan"
    $allSlugs = Resolve-AllDependencies -Slugs $enabledSlugs -McVersion $McVersion

    $newDeps = @($allSlugs | Where-Object { $enabledSlugs -notcontains $_ })
    if ($newDeps.Count -gt 0) {
        Write-SubStep "Auto-adding $($newDeps.Count) dependencies: $($newDeps -join ', ')" "DarkGray"
    }

    # Resolve file info for all mods first (for size estimation)
    Write-SubStep "Fetching mod file info..." "DarkCyan"
    $fileInfos = @{}
    $totalSize = 0L
    foreach ($slug in $allSlugs) {
        $info = Get-LatestModFile -Slug $slug -McVersion $McVersion
        if ($info) {
            $fileInfos[$slug] = $info
            # Quick HEAD request for size
            $sz = Get-ModFileSize -Url $info.url
            if ($sz -gt 0) { $totalSize += $sz }
        }
        Start-Sleep -Milliseconds 100
    }

    Write-Host ""
    Write-Host "  Downloading " -ForegroundColor Cyan -NoNewline
    Write-Host "$($allSlugs.Count) mods" -ForegroundColor White -NoNewline
    if ($totalSize -gt 0) {
        Write-Host " (~$(Format-Bytes $totalSize) total)" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
    Write-Host ""

    $success = 0; $failed = @()
    $total   = $allSlugs.Count; $i = 0

    foreach ($slug in $allSlugs) {
        $i++
        $info = $fileInfos[$slug]
        if (-not $info) {
            Write-WARN "($i/$total) $slug -- no release for $McVersion, skipping."
            $failed += $slug; Start-Sleep -Milliseconds 200; continue
        }
        $dest  = Join-Path $ModsDir $info.filename
        $label = "$slug  v$($info.version)  ($i/$total)"
        if (Download-File -Url $info.url -Dest $dest -Label $label) {
            # Verify checksum if available
            if ($info.sha1 -and -not (Verify-ModChecksum -FilePath $dest -ExpectedSha1 $info.sha1)) {
                Write-WARN ($slug + ": checksum mismatch -- re-downloading...")
                Remove-Item $dest -Force
                if (Download-File -Url $info.url -Dest $dest -Label "$slug (retry)") {
                    if (Verify-ModChecksum -FilePath $dest -ExpectedSha1 $info.sha1) {
                        $success++
                    } else {
                        Write-ERR ($slug + ": checksum failed after retry -- skipping")
                        Remove-Item $dest -Force -ErrorAction SilentlyContinue
                        $failed += $slug
                    }
                } else { $failed += $slug }
            } else { $success++ }
        } else { $failed += $slug }
        Start-Sleep -Milliseconds 100
    }

    Write-Host ""
    Write-OK "Downloaded $success / $total mods+deps  ($(Format-Bytes (Get-ChildItem $ModsDir -Filter '*.jar' | Measure-Object -Property Length -Sum).Sum) on disk)"
    if ($failed.Count -gt 0) {
        Write-WARN "Could not download: $($failed -join ', ')"
        Write-WARN "Add these manually from modrinth.com"
    }
}

# ---------------------------------------------------------------------------
#  GEYSER CONFIG
# ---------------------------------------------------------------------------

function Write-GeyserConfig {
    param([string]$ServerDir)
    Write-Step "Writing Geyser config" "Cyan"
    $geyserDir = Join-Path $ServerDir "config\Geyser-Fabric"
    New-Item -ItemType Directory -Path $geyserDir -Force | Out-Null
    @"
bedrock:
  address: 0.0.0.0
  port: 19132
  clone-remote-port: false
java:
  auth-type: floodgate
motd:
  primary-motd: Da Serva
  secondary-motd: Da Serva
  passthrough-motd: true
  max-players: 100
  passthrough-player-counts: true
  integrated-ping-passthrough: true
  ping-passthrough-interval: 3
gameplay:
  server-name: Da Serva
  cooldown-type: crosshair
  command-suggestions: true
  show-coordinates: true
  disable-bedrock-scaffolding: false
  nether-roof-workaround: true
  emotes-enabled: true
  block-legacy-codes: true
  unusable-space-block: minecraft:barrier
  enable-custom-content: true
  force-resource-packs: true
  enable-integrated-pack: true
  forward-player-ping: false
  xbox-achievements-enabled: false
  max-visible-custom-skulls: 128
  custom-skull-render-distance: 32
default-locale: system
log-player-ip-addresses: true
saved-user-logins:
  - ThisExampleUsernameShouldBeLongEnoughToNeverBeAnXboxUsername
  - ThisOtherExampleUsernameShouldAlsoBeLongEnough
pending-authentication-timeout: 120
notify-on-new-bedrock-update: true
advanced:
  cache-images: 0
  scoreboard-packet-threshold: 20
  add-team-suggestions: true
  resource-pack-urls: []
  floodgate-key-file: key.pem
  java:
    use-haproxy-protocol: false
    use-direct-connection: true
    disable-compression: true
  bedrock:
    broadcast-port: 0
    compression-level: 6
    use-haproxy-protocol: false
    haproxy-protocol-whitelisted-ips: []
    use-waterdogpe-forwarding: false
    mtu: 1400
    validate-bedrock-login: true
enable-metrics: true
metrics-uuid: 80cebf59-77fd-41c5-8d7b-eea8c9ff88fe
debug-mode: false
config-version: 7
"@ | Set-Content -Path (Join-Path $geyserDir "config.yml") -Encoding UTF8
    Write-OK "Geyser config.yml written"
}

# ---------------------------------------------------------------------------
#  SERVER.PROPERTIES  (merge -- only sets our keys, preserves the rest)
# ---------------------------------------------------------------------------

$global:DESIRED_PROPS = [ordered]@{
    "gamemode"              = "creative"
    "difficulty"            = "easy"
    "online-mode"           = "true"
    "server-port"           = "25565"
    "view-distance"         = "10"
    "motd"                  = "Da Serva"
    "max-players"           = "20"
    "white-list"            = "false"
    "pvp"                   = "true"
    "allow-nether"          = "true"
    "resource-pack"         = "https\://download.mc-packs.net/pack/84d81186eaed0747db48e66fd57d721f8736a1c3.zip"
    "resource-pack-sha1"    = "84d81186eaed0747db48e66fd57d721f8736a1c3"
    "enforce-secure-profile" = "false"
}

function Merge-ServerProperties {
    param([string]$PropsFile)
    # Read existing lines if file exists
    $lines = @()
    if (Test-Path $PropsFile) {
        $lines = @(Get-Content $PropsFile)
    }

    # Track which desired keys we've already set
    $applied = @{}

    $newLines = @()
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        # Keep comments and blanks
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            $newLines += $line
            continue
        }
        # Parse key
        $eqIdx = $line.IndexOf("=")
        if ($eqIdx -lt 0) { $newLines += $line; continue }
        $key = $line.Substring(0, $eqIdx).Trim()

        if ($global:DESIRED_PROPS.Contains($key)) {
            # Replace with our value
            $newLines += "$key=$($global:DESIRED_PROPS[$key])"
            $applied[$key] = $true
        } else {
            $newLines += $line
        }
    }

    # Append any desired keys that weren't in the file yet
    foreach ($key in $global:DESIRED_PROPS.Keys) {
        if (-not $applied.ContainsKey($key)) {
            $newLines += "$key=$($global:DESIRED_PROPS[$key])"
        }
    }

    $newLines -join "`r`n" | Set-Content -Path $PropsFile -Encoding UTF8
    Write-OK "server.properties merged ($($global:DESIRED_PROPS.Count) keys applied)"
}

# ---------------------------------------------------------------------------
#  EULA
# ---------------------------------------------------------------------------

function Write-Eula {
    param([string]$ServerDir)
    $content = "#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA).`r`n#Wed Apr 29 21:29:38 MDT 2026`r`neula=true"
    $content | Set-Content -Path (Join-Path $ServerDir "eula.txt") -Encoding UTF8
    Write-OK "eula.txt written"
}

# ---------------------------------------------------------------------------
#  START.BAT  (with server.properties merge on every launch)
# ---------------------------------------------------------------------------

function Write-StartBat {
    param([string]$ServerDir, [string]$JavaExe, [string]$JarName)
    Write-Step "Writing start.bat" "Cyan"

    # Write a standalone helper PS1 file for merging server.properties and eula.
    # The bat calls it with -File, which has zero quoting issues.
    $helperPath = Join-Path $ServerDir "_startup_helper.ps1"

    # Build helper script content as plain PS -- no escaping needed here
    $h = @()
    $h += "# Auto-generated by Da Serva Server Manager -- do not edit manually"
    $h += 'Set-Location -Path $PSScriptRoot'
    $h += ""
    $h += "# --- Write eula.txt ---"
    $h += '@"'
    $h += "#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/MinecraftEULA)."
    $h += "#Wed Apr 29 21:29:38 MDT 2026"
    $h += "eula=true"
    $h += '"@ | Set-Content -Path "eula.txt" -Encoding UTF8'
    $h += ""
    $h += "# --- Merge server.properties (our keys win, rest preserved) ---"
    $h += '$propsFile = "server.properties"'
    $h += '$desired = [ordered]@{'
    foreach ($key in $global:DESIRED_PROPS.Keys) {
        $val = $global:DESIRED_PROPS[$key]
        $h += "    '$key' = '$val'"
    }
    $h += "}"
    $h += 'if (Test-Path $propsFile) { $lines = Get-Content $propsFile } else { $lines = @() }'
    $h += '$used = @{}'
    $h += '$out  = [System.Collections.Generic.List[string]]::new()'
    $h += 'foreach ($line in $lines) {'
    $h += '    if ($line -match "^#" -or $line.Trim() -eq "") { $out.Add($line); continue }'
    $h += '    $eq = $line.IndexOf("=")'
    $h += '    if ($eq -lt 0) { $out.Add($line); continue }'
    $h += '    $k = $line.Substring(0, $eq).Trim()'
    $h += '    if ($desired.Contains($k)) { $out.Add("$k=$($desired[$k])"); $used[$k] = 1 }'
    $h += '    else { $out.Add($line) }'
    $h += '}'
    $h += 'foreach ($k in $desired.Keys) { if (-not $used.ContainsKey($k)) { $out.Add("$k=$($desired[$k])") } }'
    $h += '($out -join "`r`n") | Set-Content -Path $propsFile -Encoding UTF8'

    ($h -join "`r`n") | Set-Content -Path $helperPath -Encoding UTF8

    # Now write the bat -- it only needs to call the helper and start the server
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("@echo off")
    $lines.Add("title Da Serva - Minecraft Server")
    $lines.Add('cd /d "%~dp0"')
    $lines.Add("")
    $lines.Add("REM -- Auto-copy Floodgate key.pem into Geyser config --")
    $lines.Add('if exist "configloodgate\key.pem" (')
    $lines.Add('    if not exist "config\Geyser-Fabric" mkdir "config\Geyser-Fabric"')
    $lines.Add('    copy /Y "configloodgate\key.pem" "config\Geyser-Fabric\key.pem" >nul')
    $lines.Add(")")
    $lines.Add('if exist "pluginsloodgate\key.pem" (')
    $lines.Add('    if not exist "plugins\Geyser-Fabric" mkdir "plugins\Geyser-Fabric"')
    $lines.Add('    copy /Y "pluginsloodgate\key.pem" "plugins\Geyser-Fabric\key.pem" >nul')
    $lines.Add(")")
    $lines.Add("")
    $lines.Add("REM -- Write eula.txt and merge server.properties --")
    $lines.Add('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_startup_helper.ps1"')
    $lines.Add("")
    $lines.Add('REM -- Start playit tunnel if installed --')
    $lines.Add('where playit >nul 2>&1')
    $lines.Add('if %ERRORLEVEL% equ 0 (')
    $lines.Add('    start cmd /k "playit"')
    $lines.Add(')')
    $lines.Add("")
    $lines.Add("REM -- Start Minecraft Server --")
    $lines.Add("`"$JavaExe`" -Xms512M -Xmx5G -XX:+UseG1GC -jar `"$JarName`" nogui")
    $lines.Add("")
    $lines.Add("pause")

    ($lines -join "`r`n") | Set-Content -Path (Join-Path $ServerDir "start.bat") -Encoding ASCII
    Write-OK "start.bat + _startup_helper.ps1 written"
}

# ---------------------------------------------------------------------------
#  WORLD BACKUP / RESTORE
# ---------------------------------------------------------------------------

function Backup-World {
    param([string]$ServerDir)
    Write-Step "Backing up world + config" "Yellow"
    $ts     = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $backupsDir = Join-Path $ServerDir "_backups"
    $backup     = Join-Path $backupsDir ("backup_" + $ts)
    New-Item -ItemType Directory -Path $backup -Force | Out-Null

    $backed = @()
    foreach ($folder in @("world", "config")) {
        $src = Join-Path $ServerDir $folder
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $backup -Recurse -Force
            $backed += $folder
        }
    }

    if ($backed.Count -eq 0) {
        Write-WARN "Nothing to back up (no world or config folder found)."
        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-OK "Backed up: $($backed -join ', ')  -->  $backup"
    return $backup
}

function Restore-World {
    param([string]$ServerDir, [string]$BackupPath)
    if (-not $BackupPath -or -not (Test-Path $BackupPath)) { return }
    Write-Step "Restoring world + config" "Cyan"

    foreach ($folder in @("world", "config")) {
        $src  = Join-Path $BackupPath $folder
        $dest = Join-Path $ServerDir  $folder
        if (-not (Test-Path $src)) { continue }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Copy-Item -Path $src -Destination $ServerDir -Recurse -Force
        Write-OK "Restored: $folder"
    }

    $backups = Join-Path $ServerDir "_backups"
    if (Test-Path $backups) { Remove-Item $backups -Recurse -Force; Write-OK "_backups removed" }
}

# ---------------------------------------------------------------------------
#  CLEAN FOR UPDATE
# ---------------------------------------------------------------------------

function Clean-ServerDir {
    param([string]$ServerDir)
    Write-Step "Cleaning old server files" "Yellow"
    foreach ($item in @("mods","plugins","libraries","versions","crash-reports","logs",".fabric")) {
        # Note: "config" is intentionally excluded -- it is backed up and restored separately
        $p = Join-Path $ServerDir $item
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-SubStep "Removed: $item" "DarkGray" }
    }
    Get-ChildItem $ServerDir -Filter "*.jar"             | Remove-Item -Force
    Get-ChildItem $ServerDir -Filter "*.bat"             | Remove-Item -Force
    Get-ChildItem $ServerDir -Filter "server.properties" | Remove-Item -Force
    Get-ChildItem $ServerDir -Filter "eula.txt"          | Remove-Item -Force
    Write-OK "Server directory cleaned"
}

# ---------------------------------------------------------------------------
#  CHECKSUM VERIFICATION
# ---------------------------------------------------------------------------

function Verify-ModChecksum {
    param([string]$FilePath, [string]$ExpectedSha1)
    if (-not $ExpectedSha1) { return $true }  # no checksum provided, skip
    try {
        $actual = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA1]::Create().ComputeHash(
                [System.IO.File]::ReadAllBytes($FilePath)
            )
        ).Replace("-","").ToLower()
        return ($actual -eq $ExpectedSha1.ToLower())
    } catch { return $false }
}

# ---------------------------------------------------------------------------
#  MOD PROFILE EXPORT / IMPORT
# ---------------------------------------------------------------------------

function Export-ModProfile {
    param([System.Collections.ArrayList]$Mods, [string]$ServerDir)
    $profilePath = Join-Path $ServerDir "mod_profile.json"
    $data = @{
        exportedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        mods = @($Mods | ForEach-Object { @{ slug=$_.slug; name=$_.name; enabled=$_.enabled; default=$_.default } })
    }
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $profilePath -Encoding UTF8
    Write-OK "Mod profile exported to: $profilePath"
    return $profilePath
}

function Import-ModProfile {
    param([string]$ProfilePath)
    if (-not (Test-Path $ProfilePath)) { Write-ERR "Profile not found: $ProfilePath"; return $null }
    try {
        $data = Get-Content $ProfilePath -Raw | ConvertFrom-Json
        $mods = [System.Collections.ArrayList]@()
        foreach ($m in $data.mods) {
            $mods.Add(@{ slug=$m.slug; name=$m.name; enabled=[bool]$m.enabled; default=[bool]$m.default }) | Out-Null
        }
        Write-OK "Loaded $($mods.Count) mods from profile (exported $($data.exportedAt))"
        return $mods
    } catch { Write-ERR "Failed to read profile: $_"; return $null }
}

# ---------------------------------------------------------------------------
#  LAUNCH SERVER
# ---------------------------------------------------------------------------

function Invoke-LaunchServer {
    param([string]$ServerDir)
    $startBat = Join-Path $ServerDir "start.bat"
    if (-not (Test-Path $startBat)) { Write-WARN "start.bat not found in $ServerDir"; return }
    Write-Step "Launching server..." "Green"
    Start-Process "cmd.exe" -ArgumentList "/k `"$startBat`"" -WorkingDirectory $ServerDir
    Write-OK "Server launched in a new window."
}

# ---------------------------------------------------------------------------
#  NEW SERVER
# ---------------------------------------------------------------------------

function New-MinecraftServer {
    param([string]$JavaExe)
    Write-SectionHeader "Creating New Fabric Server"

    # Check for saved mod profile to import
    $cfg = Read-AppConfig
    $importProfile = $false
    $scriptDir = Split-Path -Parent $PSCommandPath
    $defaultProfile = Join-Path $scriptDir "mod_profile.json"
    if (Test-Path $defaultProfile) {
        if (Confirm-YN "Found a saved mod profile. Import it?") {
            $importProfile = $true
        }
    }

    while ($true) {
        $mods = [System.Collections.ArrayList]@()
        if ($importProfile) {
            $imported = Import-ModProfile -ProfilePath $defaultProfile
            if ($imported) { $mods = $imported } else { $importProfile = $false }
        }
        if ($mods.Count -eq 0) {
            foreach ($m in $global:DEFAULT_MODS) {
                $mods.Add(@{ slug=$m.slug; name=$m.name; enabled=$m.enabled; default=$true }) | Out-Null
            }
        }

        Write-Step "Mod Configuration" "Cyan"
        Pause-ForKey "Press any key to open the mod selector..."
        $mods = Show-ModSelector -Mods $mods
        if ($null -eq $mods) { return }

        $enabledCount = ($mods | Where-Object { $_.enabled }).Count
        Write-OK "$enabledCount mods selected"

        $compatible = Find-CompatibleVersions -ActiveMods $mods
        if ($compatible.Count -eq 0) { Write-ERR "No compatible version found."; continue }

        $mcVersion = Show-VersionSelector -CompatibleVersions $compatible -ActiveMods $mods
        if ($null -eq $mcVersion) { continue }

        Write-Step "Checking Java version for Minecraft $mcVersion" "Cyan"
        $javaExe = Ensure-Java -McVersion $mcVersion -CurrentJavaExe $javaExe
        if (-not $javaExe) { Write-ERR "Cannot proceed without compatible Java."; continue }
        Write-OK "Using Minecraft $mcVersion"
        break
    }

    $folderName = "Minecraft $mcVersion Fabric Server"
    $default    = Join-Path $scriptDir $folderName
    $serverDir  = Pick-Folder -Default $default -Prompt "Where should the server be installed?"

    if (Test-Path $serverDir) {
        $items = @(Get-ChildItem $serverDir)
        if ($items.Count -gt 0) {
            Write-WARN "Folder already exists and is not empty."
            if (-not (Confirm-YN "Continue anyway?")) { return }
        }
    }
    New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
    Write-OK "Server directory: $serverDir"

    $jarName = Download-FabricServer -McVersion $mcVersion -ServerDir $serverDir
    Download-AllMods   -Mods $mods -McVersion $mcVersion -ModsDir (Join-Path $serverDir "mods")
    Write-GeyserConfig -ServerDir $serverDir
    Write-Eula         -ServerDir $serverDir
    Write-StartBat     -ServerDir $serverDir -JavaExe $JavaExe -JarName $jarName

    # Save last used dir and export mod profile
    Save-LastServerDir -Path $serverDir
    Export-ModProfile  -Mods $mods -ServerDir $serverDir

    Write-SectionHeader "Setup Complete!"
    Write-Host "  Server folder : $serverDir" -ForegroundColor White
    Write-Host "  MC Version    : $mcVersion"  -ForegroundColor White
    Write-Host "  Server jar    : $jarName"    -ForegroundColor White
    Write-Host ""
    Write-WARN "On first startup Floodgate generates key.pem."
    Write-WARN "start.bat auto-copies it to Geyser on every launch."
    Write-Host ""
    if (Confirm-YN "Launch the server now?") {
        Invoke-LaunchServer -ServerDir $serverDir
    }
}

# ---------------------------------------------------------------------------
#  UPDATE SERVER
# ---------------------------------------------------------------------------

function Scan-ServerMods {
    # Scans a server mods folder and returns an ArrayList of mod hashtables
    # with enabled=$true for all detected mods.
    # Falls back to DEFAULT_MODS if detection fails.
    param([string]$ServerDir)

    $modsDir  = Join-Path $ServerDir "mods"
    $result   = [System.Collections.ArrayList]@()
    $defaultSlugs = @($global:DEFAULT_MODS | ForEach-Object { $_.slug })

    if (-not (Test-Path $modsDir)) {
        Write-SubStep "No mods folder found -- using default mod list." "Gray"
        foreach ($m in $global:DEFAULT_MODS) {
            $result.Add(@{ slug=$m.slug; name=$m.name; enabled=$true; default=$true }) | Out-Null
        }
        return $result
    }

    $jarFiles = @(Get-ChildItem $modsDir -Filter "*.jar")
    if ($jarFiles.Count -eq 0) {
        Write-SubStep "Mods folder is empty -- using default mod list." "Gray"
        foreach ($m in $global:DEFAULT_MODS) {
            $result.Add(@{ slug=$m.slug; name=$m.name; enabled=$true; default=$true }) | Out-Null
        }
        return $result
    }

    Write-SubStep "Hashing $($jarFiles.Count) jar(s) and querying Modrinth..." "DarkCyan"

    # SHA1 hash all jars
    $hashes = @{}
    foreach ($jar in $jarFiles) {
        try {
            $sha1 = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA1]::Create().ComputeHash(
                    [System.IO.File]::ReadAllBytes($jar.FullName)
                )
            ).Replace("-","").ToLower()
            $hashes[$sha1] = $jar.Name
        } catch { Write-WARN "Could not hash: $($jar.Name)" }
    }

    # Bulk lookup via Modrinth hash API
    $foundProjectIds = @{}
    if ($hashes.Count -gt 0) {
        $body    = @{ hashes=@($hashes.Keys); algorithm="sha1" } | ConvertTo-Json
        $headers = @{ "User-Agent"="DaServa-ServerManager/1.0"; "Content-Type"="application/json" }
        try {
            $resp = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/version_files" `
                -Method POST -Body $body -Headers $headers -ErrorAction Stop
            $resp.PSObject.Properties | ForEach-Object {
                if ($_.Value.project_id) { $foundProjectIds[$_.Value.project_id] = $true }
            }
        } catch { Write-WARN "Modrinth hash lookup failed: $_" }
    }

    if ($foundProjectIds.Count -gt 0) {
        # Bulk fetch project info
        $idList   = ($foundProjectIds.Keys | ForEach-Object { "`"$_`"" }) -join ","
        $projects = Invoke-JsonApi "https://api.modrinth.com/v2/projects?ids=%5B$([Uri]::EscapeDataString($idList))%5D"

        # Build mod list from detected projects
        # Start with default mods in default order, marking which are found
        $detectedSlugs = @{}
        if ($projects) {
            foreach ($p in $projects) { $detectedSlugs[$p.slug] = $p.title }
        }

        # First: all default mods, enabled only if detected in the folder
        foreach ($m in $global:DEFAULT_MODS) {
            $isInstalled = $detectedSlugs.ContainsKey($m.slug)
            $result.Add(@{
                slug    = $m.slug
                name    = $m.name
                enabled = $isInstalled
                default = $true
            }) | Out-Null
        }

        # Then: any detected mods that aren't in the default list (custom mods)
        foreach ($slug in $detectedSlugs.Keys) {
            if ($defaultSlugs -notcontains $slug) {
                $result.Add(@{
                    slug    = $slug
                    name    = $detectedSlugs[$slug]
                    enabled = $true
                    default = $false
                }) | Out-Null
            }
        }

        $enabledCount = ($result | Where-Object { $_.enabled }).Count
        Write-OK "Identified $($detectedSlugs.Count) mod(s) in folder -- $enabledCount matched to default list, rest disabled"
        $unmatched = $jarFiles.Count - $foundProjectIds.Count
        if ($unmatched -gt 0) {
            Write-WARN "$unmatched jar(s) unrecognised (deps/custom) -- will be re-downloaded automatically"
        }
    } else {
        Write-WARN "Could not identify mods via Modrinth -- using default list with all enabled."
        foreach ($m in $global:DEFAULT_MODS) {
            $result.Add(@{ slug=$m.slug; name=$m.name; enabled=$true; default=$true }) | Out-Null
        }
    }

    return $result
}

function Update-MinecraftServer {
    param([string]$JavaExe)
    Write-SectionHeader "Updating Existing Fabric Server"

    $cfg = Read-AppConfig
    $scriptDir = Split-Path -Parent $PSCommandPath
    $defaultDir = if ($cfg.lastServerDir -and (Test-Path $cfg.lastServerDir)) { $cfg.lastServerDir } else { $scriptDir }
    $serverDir = Pick-ExistingFolder -Prompt "Select the server to update:" -Default $defaultDir
    Write-OK "Server directory: $serverDir"

    if (-not @(Get-ChildItem $serverDir -Filter "*.jar" -ErrorAction SilentlyContinue)) {
        Write-WARN "No .jar files found -- are you sure this is a server folder?"
        if (-not (Confirm-YN "Continue anyway?")) { return }
    }

    Write-Step "Scanning installed mods..." "Cyan"
    $baseMods = Scan-ServerMods -ServerDir $serverDir

    $mods = $null; $mcVersion = $null
    while ($true) {
        $mods = [System.Collections.ArrayList]@()
        foreach ($m in $baseMods) {
            $mods.Add(@{ slug=$m.slug; name=$m.name; enabled=$m.enabled; default=$m.default }) | Out-Null
        }
        Write-Step "Mod Configuration" "Cyan"
        Pause-ForKey "Press any key to open the mod selector..."
        $mods = Show-ModSelector -Mods $mods
        if ($null -eq $mods) { return }

        $enabledCount = ($mods | Where-Object { $_.enabled }).Count
        Write-OK "$enabledCount mods selected"

        $compatible = Find-CompatibleVersions -ActiveMods $mods
        if ($compatible.Count -eq 0) { Write-ERR "No compatible version found."; continue }

        $mcVersion = Show-VersionSelector -CompatibleVersions $compatible -ActiveMods $mods
        if ($null -eq $mcVersion) { continue }

        Write-Step "Checking Java version for Minecraft $mcVersion" "Cyan"
        $javaExe = Ensure-Java -McVersion $mcVersion -CurrentJavaExe $javaExe
        if (-not $javaExe) { Write-ERR "Cannot proceed without compatible Java."; continue }
        Write-OK "Using Minecraft $mcVersion"
        break
    }

    Write-Host ""
    Write-Host "  This will:" -ForegroundColor Cyan
    Write-Host "    1. Back up your world + config" -ForegroundColor White
    Write-Host "    2. Remove old server files" -ForegroundColor White
    Write-Host "    3. Install Fabric $mcVersion + selected mods" -ForegroundColor White
    Write-Host "    4. Restore your world + config" -ForegroundColor White
    Write-Host ""
    if (-not (Confirm-YN "Proceed?")) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return }

    $backupPath = Backup-World          -ServerDir $serverDir
    Clean-ServerDir                     -ServerDir $serverDir
    $jarName    = Download-FabricServer -McVersion $mcVersion -ServerDir $serverDir
    Download-AllMods   -Mods $mods -McVersion $mcVersion -ModsDir (Join-Path $serverDir "mods")
    Write-GeyserConfig -ServerDir $serverDir
    Write-Eula         -ServerDir $serverDir
    Write-StartBat     -ServerDir $serverDir -JavaExe $JavaExe -JarName $jarName
    Restore-World      -ServerDir $serverDir -BackupPath $backupPath

    Save-LastServerDir -Path $serverDir
    Export-ModProfile  -Mods $mods -ServerDir $serverDir

    Write-SectionHeader "Update Complete!"
    Write-Host "  Server folder : $serverDir" -ForegroundColor White
    Write-Host "  MC Version    : $mcVersion"  -ForegroundColor White
    Write-Host "  Server jar    : $jarName"    -ForegroundColor White
    Write-Host ""
    Write-Host "  World + config restored." -ForegroundColor Green
    Write-Host ""
    if (Confirm-YN "Launch the server now?") {
        Invoke-LaunchServer -ServerDir $serverDir
    }
}

# ---------------------------------------------------------------------------
#  MANAGE MODS  (edit mods on existing server, no world wipe)
# ---------------------------------------------------------------------------

function Manage-ServerMods {
    param([string]$JavaExe)
    Write-SectionHeader "Manage Mods on Existing Server"

    $cfg = Read-AppConfig
    $scriptDir = Split-Path -Parent $PSCommandPath
    $defaultDir = if ($cfg.lastServerDir -and (Test-Path $cfg.lastServerDir)) { $cfg.lastServerDir } else { $scriptDir }
    $serverDir = Pick-ExistingFolder -Prompt "Select the server to manage mods for:" -Default $defaultDir
    Write-OK "Server directory: $serverDir"

    $existingJar = Get-ChildItem $serverDir -Filter "fabric-server-mc.*.jar" | Select-Object -First 1
    $detectedVersion = ""
    if ($existingJar -and $existingJar.Name -match "fabric-server-mc\.([^-]+)-") {
        $detectedVersion = $Matches[1]
        Write-OK "Detected server version: $detectedVersion"
    }

    Write-Step "Scanning installed mods..." "Cyan"
    $baseMods = Scan-ServerMods -ServerDir $serverDir

    # Note: we intentionally do NOT offer profile import here --
    # the scan result reflects what's actually installed, which is the right starting point.
    # Profiles can be imported via Create Server instead.

    Write-Step "Mod Configuration" "Cyan"
    Pause-ForKey "Press any key to open the mod selector..."
    $mods = [System.Collections.ArrayList]@()
    foreach ($m in $baseMods) {
        $mods.Add(@{ slug=$m.slug; name=$m.name; enabled=$m.enabled; default=$m.default }) | Out-Null
    }
    $mods = Show-ModSelector -Mods $mods
    if ($null -eq $mods) { return }

    $enabledCount = ($mods | Where-Object { $_.enabled }).Count
    Write-OK "$enabledCount mods selected"

    if ($detectedVersion) {
        Write-Host ""
        Write-Host "  Detected version: $detectedVersion" -ForegroundColor Cyan
        if (-not (Confirm-YN "Use this version? (N to pick a different one)")) {
            $compatible = Find-CompatibleVersions -ActiveMods $mods
            if ($compatible.Count -gt 0) {
                $chosen = Show-VersionSelector -CompatibleVersions $compatible -ActiveMods $mods
                if ($chosen) { $detectedVersion = $chosen }
            }
        }
    } else {
        $compatible = Find-CompatibleVersions -ActiveMods $mods
        if ($compatible.Count -gt 0) {
            $chosen = Show-VersionSelector -CompatibleVersions $compatible -ActiveMods $mods
            if ($chosen) { $detectedVersion = $chosen }
        }
    }

    Write-Step "Checking Java version for Minecraft $detectedVersion" "Cyan"
    $javaExe = Ensure-Java -McVersion $detectedVersion -CurrentJavaExe $JavaExe
    if ($javaExe) { Write-OK "Using Java: $javaExe" }
    Write-OK "Using Minecraft $detectedVersion"

    Write-Host ""
    Write-Host "  This will:" -ForegroundColor Cyan
    Write-Host "    1. Clear the mods folder" -ForegroundColor White
    Write-Host "    2. Download selected mods + dependencies" -ForegroundColor White
    Write-Host "    3. NOT touch your world or server jar" -ForegroundColor White
    Write-Host ""
    if (-not (Confirm-YN "Proceed?")) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return }

    $modsDir = Join-Path $serverDir "mods"
    Download-AllMods -Mods $mods -McVersion $detectedVersion -ModsDir $modsDir

    Save-LastServerDir -Path $serverDir
    Export-ModProfile  -Mods $mods -ServerDir $serverDir

    Write-SectionHeader "Done!"
    Write-Host "  Mods updated in: $modsDir" -ForegroundColor White
    Write-Host ""
    if (Confirm-YN "Launch the server now?") {
        Invoke-LaunchServer -ServerDir $serverDir
    }
}

# ---------------------------------------------------------------------------
#  ENTRY POINT
# ---------------------------------------------------------------------------

function Show-HelpMenu {
    while ($true) {
        Clear-Host
        Write-Host ("=" * 72) -ForegroundColor DarkGreen
        Write-Host "  DA SERVA -- HELP" -ForegroundColor Green
        Write-Host ("=" * 72) -ForegroundColor DarkGreen
        Write-Host ""

        $choice = Show-Menu -Title "What do you need help with?" `
            -Options @(
                "Overview -- What is Da Serva?",
                "Create a New Server",
                "Update an Existing Server",
                "Manage Mods",
                "Mod Selector -- Controls and features",
                "Version Selector -- Controls and features",
                "Mod Profiles -- Export and import",
                "Quiet Mode -- Unattended / scripted use",
                "Geyser and Floodgate -- Bedrock support",
                "server.properties -- What gets set and why",
                "Back to main menu"
            )

        Clear-Host
        Write-Host ("=" * 72) -ForegroundColor DarkGreen
        Write-Host "  DA SERVA -- HELP" -ForegroundColor Green
        Write-Host ("=" * 72) -ForegroundColor DarkGreen
        Write-Host ""

        switch ($choice) {
            0 {
                Write-Host "  OVERVIEW" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Da Serva is a Minecraft Fabric server manager for Windows." -ForegroundColor Gray
                Write-Host "  It handles everything needed to run a server:" -ForegroundColor Gray
                Write-Host ""
                Write-Host "    - Downloads and installs the Fabric server jar" -ForegroundColor White
                Write-Host "    - Downloads all your mods + their dependencies" -ForegroundColor White
                Write-Host "    - Verifies mod file integrity via SHA1 checksum" -ForegroundColor White
                Write-Host "    - Configures Geyser + Floodgate for Bedrock support" -ForegroundColor White
                Write-Host "    - Writes server.properties with your preferred settings" -ForegroundColor White
                Write-Host "    - Checks and installs the correct Java version" -ForegroundColor White
                Write-Host "    - Backs up your world and config before any update" -ForegroundColor White
                Write-Host ""
                Write-Host "  Everything lives in a single DaServa.bat file." -ForegroundColor DarkGray
                Write-Host "  No installer, no dependencies, no setup required." -ForegroundColor DarkGray
            }
            1 {
                Write-Host "  CREATE A NEW SERVER" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Walks you through creating a fresh Fabric server from scratch." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Flow:" -ForegroundColor White
                Write-Host "    1. Open the mod selector -- pick which mods to include" -ForegroundColor Gray
                Write-Host "    2. Da Serva queries Modrinth to find the newest MC version" -ForegroundColor Gray
                Write-Host "       where ALL your selected mods have a Fabric release" -ForegroundColor Gray
                Write-Host "    3. Pick a version from the compatible list" -ForegroundColor Gray
                Write-Host "    4. Choose an install folder (default: next to DaServa.bat)" -ForegroundColor Gray
                Write-Host "    5. Downloads everything and sets it all up" -ForegroundColor Gray
                Write-Host "    6. Optionally launch the server immediately" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Output:" -ForegroundColor White
                Write-Host "    start.bat       -- run this to start your server" -ForegroundColor Gray
                Write-Host "    mod_profile.json -- your mod list, importable later" -ForegroundColor Gray
                Write-Host "    _startup_helper.ps1 -- merges server.properties on launch" -ForegroundColor Gray
            }
            2 {
                Write-Host "  UPDATE AN EXISTING SERVER" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Updates a server to a new MC version while keeping your world." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Flow:" -ForegroundColor White
                Write-Host "    1. Select your server folder (auto-detected from script dir)" -ForegroundColor Gray
                Write-Host "    2. Da Serva scans your existing mods via SHA1 hash lookup" -ForegroundColor Gray
                Write-Host "       to pre-populate the mod selector with what is installed" -ForegroundColor Gray
                Write-Host "    3. Adjust mods, pick version, confirm" -ForegroundColor Gray
                Write-Host "    4. World + config are backed up to _backups\" -ForegroundColor Gray
                Write-Host "    5. Old server files wiped, new ones downloaded" -ForegroundColor Gray
                Write-Host "    6. World + config restored, backup deleted" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Your world data is never permanently deleted." -ForegroundColor Green
                Write-Host "  If something goes wrong, the backup stays until restore succeeds." -ForegroundColor DarkGray
            }
            3 {
                Write-Host "  MANAGE MODS" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Add, remove, or swap mods on an existing server without" -ForegroundColor Gray
                Write-Host "  touching the world, server jar, or config." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Use this when:" -ForegroundColor White
                Write-Host "    - You want to add a new mod mid-playthrough" -ForegroundColor Gray
                Write-Host "    - A mod update broke something and you want to roll it back" -ForegroundColor Gray
                Write-Host "    - You want to disable a mod without updating the server" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Only the mods folder is affected. Everything else is untouched." -ForegroundColor Green
            }
            4 {
                Write-Host "  MOD SELECTOR" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  NAVIGATION" -ForegroundColor White
                Write-Host "    UP / DOWN      Move cursor" -ForegroundColor Gray
                Write-Host "    PgUp / PgDn    Scroll by page" -ForegroundColor Gray
                Write-Host "    Home / End     Jump to top / bottom" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  ACTIONS" -ForegroundColor White
                Write-Host "    SPACE          Toggle mod on/off" -ForegroundColor Gray
                Write-Host "    A              Add a mod (search Modrinth or paste URL/slug)" -ForegroundColor Gray
                Write-Host "    D              Remove a custom mod (default mods: disable only)" -ForegroundColor Gray
                Write-Host "    E              Enable all mods currently visible" -ForegroundColor Gray
                Write-Host "    N              Disable all mods currently visible" -ForegroundColor Gray
                Write-Host "    ENTER          Confirm and continue" -ForegroundColor Gray
                Write-Host "    B              Back to main menu" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  SEARCH + FILTER" -ForegroundColor White
                Write-Host "    /              Enter search mode -- type freely to filter by name" -ForegroundColor Gray
                Write-Host "    ESC            Exit search mode (keeps current filter text)" -ForegroundColor Gray
                Write-Host "    F              Cycle filter: All > Server > Client > Both > On > Off" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  INFO COLUMNS" -ForegroundColor White
                Write-Host "    [Server]       Only needed on the server" -ForegroundColor Gray
                Write-Host "    [Client]       Only needed on the client" -ForegroundColor Gray
                Write-Host "    [Both]         Required on both server and connecting clients" -ForegroundColor Gray
                Write-Host "    26.1.x 1.21.x  MC versions with a Fabric release for this mod" -ForegroundColor Gray
                Write-Host "    (3d ago)       How long since the mod was last updated" -ForegroundColor Gray
                Write-Host "    [caps version] This mod is limiting the max server version" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  VERSION CAP BAR" -ForegroundColor White
                Write-Host "    Shows the highest MC version your current selection supports." -ForegroundColor Gray
                Write-Host "    Mods in yellow are the ones limiting it. Disable them to" -ForegroundColor Gray
                Write-Host "    unlock a newer version." -ForegroundColor Gray
            }
            5 {
                Write-Host "  VERSION SELECTOR" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Shows all MC versions where every enabled mod has a Fabric release." -ForegroundColor Gray
                Write-Host "  The top entry (green) is the recommended newest compatible version." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  CONTROLS" -ForegroundColor White
                Write-Host "    UP / DOWN      Navigate" -ForegroundColor Gray
                Write-Host "    PgUp / PgDn    Scroll by page" -ForegroundColor Gray
                Write-Host "    Home / End     Jump to top / bottom" -ForegroundColor Gray
                Write-Host "    ENTER          Select this version" -ForegroundColor Gray
                Write-Host "    B              Back to mod selector" -ForegroundColor Gray
                Write-Host "    H              Help" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  To get a newer version available, go back to the mod selector" -ForegroundColor DarkGray
                Write-Host "  and disable mods marked [caps version]." -ForegroundColor DarkGray
            }
            6 {
                Write-Host "  MOD PROFILES" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  After every Create / Update / Manage, Da Serva saves a" -ForegroundColor Gray
                Write-Host "  mod_profile.json file in the server folder." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  It records every mod slug, name, and enabled/disabled state." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  IMPORTING A PROFILE" -ForegroundColor White
                Write-Host "    When you create a new server or manage mods, if a profile" -ForegroundColor Gray
                Write-Host "    is found in the default location, you'll be asked whether" -ForegroundColor Gray
                Write-Host "    to load it. Say yes to restore your exact mod configuration." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  SHARING A PROFILE" -ForegroundColor White
                Write-Host "    Copy mod_profile.json next to DaServa.bat on another machine." -ForegroundColor Gray
                Write-Host "    It will be detected and offered on the next Create run." -ForegroundColor Gray
            }
            7 {
                Write-Host "  QUIET MODE  (-Quiet flag)" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Run DaServa.bat with the -Quiet flag for unattended use:" -ForegroundColor Gray
                Write-Host ""
                Write-Host "    DaServa.bat -Quiet" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  In quiet mode:" -ForegroundColor White
                Write-Host "    - All yes/no prompts auto-confirm with their default answer" -ForegroundColor Gray
                Write-Host "    - All pause prompts are skipped" -ForegroundColor Gray
                Write-Host "    - Interactive selectors (mod selector, version selector)" -ForegroundColor Gray
                Write-Host "      are NOT skipped -- quiet mode only affects confirmations" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Useful for:" -ForegroundColor White
                Write-Host "    - Scheduled update scripts" -ForegroundColor Gray
                Write-Host "    - CI/CD pipelines that spin up test servers" -ForegroundColor Gray
                Write-Host "    - Automation where you just want defaults" -ForegroundColor Gray
            }
            8 {
                Write-Host "  GEYSER + FLOODGATE  (Bedrock support)" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Geyser is a bridge that lets Minecraft: Bedrock Edition clients" -ForegroundColor Gray
                Write-Host "  connect to a Java Edition server." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Floodgate lets Bedrock players join without a Java account." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  SETUP (automatic)" -ForegroundColor White
                Write-Host "    Da Serva writes a pre-configured Geyser config.yml to:" -ForegroundColor Gray
                Write-Host "    config\Geyser-Fabric\config.yml" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  KEY.PEM (automatic)" -ForegroundColor White
                Write-Host "    Floodgate generates key.pem on first server startup." -ForegroundColor Gray
                Write-Host "    start.bat automatically copies it to Geyser on every launch" -ForegroundColor Gray
                Write-Host "    so you never have to do it manually." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  BEDROCK PORT" -ForegroundColor White
                Write-Host "    Bedrock clients connect on UDP port 19132." -ForegroundColor Gray
                Write-Host "    Make sure this port is open in your firewall/router." -ForegroundColor Gray
            }
            9 {
                Write-Host "  SERVER.PROPERTIES" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  Da Serva uses a MERGE strategy -- it only sets specific keys" -ForegroundColor Gray
                Write-Host "  and leaves everything else in the file untouched." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  This merge runs every time start.bat launches the server," -ForegroundColor Gray
                Write-Host "  so your settings always win even if the server rewrites them." -ForegroundColor Gray
                Write-Host ""
                Write-Host "  KEYS SET BY DA SERVA" -ForegroundColor White
                Write-Host "    gamemode              = creative" -ForegroundColor Gray
                Write-Host "    difficulty            = easy" -ForegroundColor Gray
                Write-Host "    online-mode           = true" -ForegroundColor Gray
                Write-Host "    server-port           = 25565" -ForegroundColor Gray
                Write-Host "    motd                  = Da Serva" -ForegroundColor Gray
                Write-Host "    resource-pack         = (your pack URL)" -ForegroundColor Gray
                Write-Host "    enforce-secure-profile = false" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Everything else (seed, ops, whitelist, etc.) is yours to set" -ForegroundColor DarkGray
                Write-Host "  in server.properties and it will be preserved across updates." -ForegroundColor DarkGray
            }
            10 { return }
        }

        Write-Host ""
        Pause-ForKey "Press any key to return to help menu..."
    }
}

# Initial Java check before entering the main loop
Write-Banner
Write-Step "Checking for Java 21+" "Cyan"
$javaExe = Find-JavaExe -MinVersion 21
if (-not $javaExe) { $javaExe = Install-Java -MinVersion 21 }
if (-not $javaExe) {
    Write-ERR "Java 21 is required to run this tool. Please install it and try again."
    Pause-ForKey "Press any key to exit."
    exit 1
}

# Main loop -- the ONLY way out is selecting Exit from the menu.
# Every error, cancellation, and back-button loops here.
while ($true) {
    try {
        Write-Banner
        Write-OK "Java: $javaExe"

        $choice = Show-Menu -Title "What would you like to do?" `
            -Options @("Create a New Server","Update an Existing Server","Manage Mods","Help","Exit") `
            -Descs   @(
                "Fresh install -- auto-detects best MC version",
                "Updates server + mods, preserves world",
                "Add/remove mods on an existing server without touching world",
                "How to use Da Serva, keybinds, and feature explanations",
                ""
            )

        switch ($choice) {
            0 { New-MinecraftServer    -JavaExe $javaExe }
            1 { Update-MinecraftServer -JavaExe $javaExe }
            2 { Manage-ServerMods      -JavaExe $javaExe }
            3 { Show-HelpMenu }
            4 {
                Write-Host ""
                Write-Host "  Goodbye!" -ForegroundColor DarkCyan
                Write-Host ""
                exit 0
            }
        }

    } catch {
        # Any unhandled error -- show it, wait for keypress, then loop back to menu
        Write-Host ""
        Write-ERR "Unexpected error:"
        Write-ERR $_.Exception.Message
        Write-ERR $_.ScriptStackTrace
        Write-Host ""
        Pause-ForKey "Press any key to return to the main menu..."
        # Loop continues -- menu will re-appear
    }
}

