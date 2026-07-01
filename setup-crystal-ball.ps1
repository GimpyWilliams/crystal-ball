# setup-crystal-ball.ps1
# Installs gh CLI, logs in to GitHub, and clones GimpyWilliams/crystal-ball


function Has-Command($name) {
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

# --- 1. Install gh if missing ---
if (-not (Has-Command 'gh')) {
    Write-Host "gh not found. Installing via winget..."
    winget install --id GitHub.cli --silent --accept-source-agreements --accept-package-agreements
    # Refresh PATH for this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
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
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not (Has-Command 'git')) {
        Write-Error "git install failed. Try opening a new terminal and re-running."
        exit 1
    }
    Write-Host "git installed successfully."
} else {
    Write-Host "git already installed: $(git --version)"
}

# --- 3. Log in to GitHub ---
$authStatus = & gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Logging in to GitHub. A browser window will open — sign in and authorize the app."
    Write-Host ""
    gh auth login --hostname github.com --git-protocol https --web
} else {
    Write-Host "Already logged in to GitHub."
    Write-Host $authStatus
}

# --- 4. Wire gh as git's credential helper (gives write access on push/pull) ---
gh auth setup-git

# --- 5. Clone the repo ---
$repoName = "crystal-ball"
if (Test-Path $repoName) {
    Write-Host ""
    Write-Host "Directory '$repoName' already exists — skipping clone."
    Write-Host "To update it: cd $repoName; git pull"
} else {
    Write-Host ""
    Write-Host "Cloning GimpyWilliams/crystal-ball..."
    gh repo clone GimpyWilliams/crystal-ball
    Write-Host "Cloned into .\$repoName"
}

Write-Host ""
Write-Host "Done. You can now push to the repo (assuming your GitHub account has write access):"
Write-Host "  cd $repoName"
Write-Host "  git push"
