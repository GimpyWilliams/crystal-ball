# setup-crystal-ball.ps1
#
# One-shot bootstrap for the crystal-ball DFHack intel agent on a fresh Windows
# machine. Reproduces EVERYTHING that isn't carried by `git clone` alone:
#
#   1. Installs gh, git, and Python 3.13 (via winget) if missing
#   2. Logs in to GitHub and wires gh as git's credential helper
#   3. Clones GimpyWilliams/crystal-ball
#   4. Builds agent/.venv and installs the pinned runtime deps
#   5. Registers the `crystal-ball` MCP server with Claude Code (local scope)
#   6. Installs the Claude Code quality-of-life config that lives OUTSIDE the
#      repo tree and is therefore not cloned:
#        - global ~/.claude/  : statusline-command.sh, statusline_parse.py,
#                               commands/df-report.md, and the statusLine +
#                               dark-theme settings (merged, non-destructive)
#        - project .claude/   : settings.json (statusLine + SessionStart hook,
#                               with this clone's absolute path) and a baseline
#                               permission allowlist (settings.local.json)
#      The portable project scripts (.claude/statusline.sh, the hook itself)
#      ARE tracked in the repo, so they arrive with the clone.
#
# Re-runnable: every step is idempotent and skips work already done.


function Has-Command($name) {
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
}

function Write-FileNoBom($path, $content) {
    # Claude Code parses these as JSON / runs them under bash; a UTF-16 or
    # BOM-prefixed file breaks both. PowerShell 5.1's Out-File utf8 adds a BOM,
    # so write bytes directly with a BOM-less UTF-8 encoder.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $enc)
}

# --- 1. Install gh if missing ---
if (-not (Has-Command 'gh')) {
    Write-Host "gh not found. Installing via winget..."
    winget install --id GitHub.cli --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Has-Command 'gh')) {
        Write-Error "gh install failed or PATH not updated. Try opening a new terminal and re-running."
        exit 1
    }
    Write-Host "gh installed successfully."
} else {
    Write-Host "gh already installed: $(gh --version | Select-Object -First 1)"
}

# --- 2. Install git if missing ---
if (-not (Has-Command 'git')) {
    Write-Host "git not found. Installing via winget..."
    winget install --id Git.Git --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (-not (Has-Command 'git')) {
        Write-Error "git install failed. Try opening a new terminal and re-running."
        exit 1
    }
    Write-Host "git installed successfully."
} else {
    Write-Host "git already installed: $(git --version)"
}

# --- 3. Install Python 3.13 if missing (needed for agent/.venv) ---
# Prefer the `py` launcher; the bare `python` name on Windows is often a Store
# app-execution stub that isn't a real interpreter.
$pyLauncher = $null
if (Has-Command 'py') {
    & py -3.13 --version *> $null
    if ($LASTEXITCODE -eq 0) {
        $pyLauncher = @('py', '-3.13')
    } else {
        & py -3 --version *> $null
        if ($LASTEXITCODE -eq 0) { $pyLauncher = @('py', '-3') }
    }
}
if (-not $pyLauncher) {
    Write-Host "Python 3.13 not found. Installing via winget..."
    winget install --id Python.Python.3.13 --silent --accept-source-agreements --accept-package-agreements
    Refresh-Path
    if (Has-Command 'py') { $pyLauncher = @('py', '-3.13') }
    elseif (Has-Command 'python') { $pyLauncher = @('python') }
    if (-not $pyLauncher) {
        Write-Error "Python install failed. Open a new terminal and re-run."
        exit 1
    }
    Write-Host "Python installed successfully."
} else {
    Write-Host "Python already available: $(& $pyLauncher[0] $pyLauncher[1..($pyLauncher.Length-1)] --version)"
}

# --- 4. Log in to GitHub ---
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Logging in to GitHub. A browser window will open - sign in and authorize the app."
    Write-Host ""
    gh auth login --hostname github.com --git-protocol https --web
} else {
    Write-Host "Already logged in to GitHub."
}

# --- 5. Wire gh as git's credential helper (gives write access on push/pull) ---
gh auth setup-git

# --- 6. Clone the repo ---
$repoName = "crystal-ball"
if (Test-Path $repoName) {
    Write-Host ""
    Write-Host "Directory '$repoName' already exists - skipping clone (run 'git pull' inside it to update)."
} else {
    Write-Host ""
    Write-Host "Cloning GimpyWilliams/crystal-ball..."
    gh repo clone GimpyWilliams/crystal-ball
    Write-Host "Cloned into .\$repoName"
}

# --- 7. Resolve paths for this clone ---
$repoPath = (Resolve-Path $repoName).Path          # e.g. C:\Users\me\crystal-ball
$repoFwd  = $repoPath -replace '\\', '/'            # forward-slash form for bash
$agentDir = Join-Path $repoPath "agent"
$venvPy   = Join-Path $agentDir ".venv\Scripts\python.exe"

# --- 8. Build the venv and install pinned deps ---
if (-not (Test-Path $venvPy)) {
    Write-Host ""
    Write-Host "Creating agent/.venv..."
    & $pyLauncher[0] $pyLauncher[1..($pyLauncher.Length-1)] -m venv (Join-Path $agentDir ".venv")
}
if (Test-Path $venvPy) {
    Write-Host "Installing runtime deps (protobuf, mcp)..."
    & $venvPy -m pip install --quiet --upgrade pip
    & $venvPy -m pip install --quiet -r (Join-Path $agentDir "requirements.txt")
    Write-Host "Dependencies installed."
} else {
    Write-Error "venv python not found at $venvPy - skipping deps + MCP registration."
}

# --- 9. Install global ~/.claude/ dotfiles (statusline + df-report command) ---
$claudeHome = Join-Path $env:USERPROFILE ".claude"
$claudeCmds = Join-Path $claudeHome "commands"
New-Item -ItemType Directory -Force -Path $claudeHome, $claudeCmds | Out-Null
$g = Join-Path $repoPath "setup\dotfiles\global"
Copy-Item (Join-Path $g "statusline_parse.py")       $claudeHome -Force
Copy-Item (Join-Path $g "statusline-command.sh")     $claudeHome -Force
Copy-Item (Join-Path $g "commands\df-report.md")     $claudeCmds -Force
Write-Host "Installed global ~/.claude statusline + df-report command."

# --- 10. Render project .claude/settings.json + settings.local.json ---
$projClaude = Join-Path $repoPath ".claude"
New-Item -ItemType Directory -Force -Path $projClaude | Out-Null
$tpl = Join-Path $repoPath "setup\dotfiles\project"
$settings = (Get-Content (Join-Path $tpl "settings.json") -Raw).Replace('__REPO_FWD__', $repoFwd)
Write-FileNoBom (Join-Path $projClaude "settings.json") $settings
# Don't clobber an existing local permission allowlist; only seed a baseline.
$localPath = Join-Path $projClaude "settings.local.json"
if (-not (Test-Path $localPath)) {
    Copy-Item (Join-Path $tpl "settings.local.json") $localPath -Force
}
Write-Host "Wrote project .claude/settings.json (statusLine + SessionStart hook)."

# --- 11. Merge global ~/.claude/settings.json (statusLine + DF-friendly defaults) ---
$globalSettingsPath = Join-Path $claudeHome "settings.json"
if (Test-Path $globalSettingsPath) {
    $gs = Get-Content $globalSettingsPath -Raw | ConvertFrom-Json
} else {
    $gs = [PSCustomObject]@{}
}
$statusLine = [PSCustomObject]@{ type = "command"; command = "bash ~/.claude/statusline-command.sh" }
$gs | Add-Member -NotePropertyName statusLine -NotePropertyValue $statusLine -Force
if (-not $gs.PSObject.Properties['theme']) {
    $gs | Add-Member -NotePropertyName theme -NotePropertyValue "dark"
}
if (-not $gs.PSObject.Properties['autoUpdatesChannel']) {
    $gs | Add-Member -NotePropertyName autoUpdatesChannel -NotePropertyValue "latest"
}
Write-FileNoBom $globalSettingsPath (($gs | ConvertTo-Json -Depth 20))
Write-Host "Merged statusLine into global ~/.claude/settings.json (kept your model/other keys)."

# --- 12. Register the crystal-ball MCP server with Claude Code (local scope) ---
if ((Test-Path $venvPy) -and (Has-Command 'claude')) {
    $mcpScript = Join-Path $agentDir "mcp_server.py"
    Push-Location $repoPath
    & claude mcp remove crystal-ball *> $null   # ignore "not found" on first run
    & claude mcp add crystal-ball -- "$venvPy" "$mcpScript"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Registered 'crystal-ball' MCP server (local scope)."
    } else {
        Write-Host "Could not auto-register the MCP server. Register it manually from '$repoPath':"
        Write-Host "  claude mcp add crystal-ball -- `"$venvPy`" `"$mcpScript`""
    }
    Pop-Location
} else {
    Write-Host "Skipping MCP registration (claude CLI or venv missing)."
}

Write-Host ""
Write-Host "Done. Everything is wired up:"
Write-Host "  - Repo:        $repoPath"
Write-Host "  - MCP server:  crystal-ball (start Dwarf Fortress + DFHack, then open Claude Code here)"
Write-Host "  - Status line: fort snapshot appears once DF is running (background-refreshed)"
Write-Host ""
Write-Host "Quick check (with a fort loaded):"
Write-Host "  cd `"$agentDir`"; .\.venv\Scripts\python.exe cli.py briefing"
