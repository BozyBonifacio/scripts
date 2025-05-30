param (
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [Parameter(Mandatory = $true)]
    [string]$LogDirectory,

    [string]$HashAlgorithm = "SHA256"
)

# Sample usage = CloneDirectory.ps1 -Source C:\axi\notes -Destination C:\axi\notes_copy -LogDirectory C:\axi\logs

# -----------------------------
# Setup and Validate
# -----------------------------

if (-not (Test-Path $Source)) {
    Write-Error "Source folder does not exist: $Source"
    exit 1
}


$BaseRobocopyLog = "robocopy_clone_log.txt"
$BaseHashLog = "hash_verification_log.txt"
$RobocopyLogFile = Join-Path $LogDirectory $BaseRobocopyLog
$HashLogFile = Join-Path $LogDirectory $BaseHashLog
$CheckpointFile = Join-Path $LogDirectory "verified_hashes.txt"
$MaxLogSizeBytes = 50MB

# Ensure log directory exists
if (!(Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force
}

# ----------------------------
# COMMON LOG ROTATION FUNCTION
# ----------------------------
function Get-NextLogFileName {
    param (
        [string]$logDir,
        [string]$baseName
    )

    $i = 1
    $baseNameOnly = [System.IO.Path]::GetFileNameWithoutExtension($baseName)
    $ext = [System.IO.Path]::GetExtension($baseName)

    do {
        $newName = "$baseNameOnly-$i$ext"
        $newPath = Join-Path $logDir $newName
        $i++
    } while (Test-Path $newPath)

    return $newPath
}

function Rotate-LogIfNeeded {
    param (
        [string]$logPath,
        [string]$baseName
    )

    if (Test-Path $logPath) {
        $logSize = (Get-Item $logPath).Length
        if ($logSize -ge $MaxLogSizeBytes) {
            $archiveName = Get-NextLogFileName -logDir (Split-Path $logPath) -baseName $baseName
            Rename-Item -Path $logPath -NewName $archiveName
            Write-Host "Log rotated: $archiveName"
        }
    }
}

# Rotate logs if needed
Rotate-LogIfNeeded -logPath $RobocopyLogFile -baseName $BaseRobocopyLog
Rotate-LogIfNeeded -logPath $HashLogFile -baseName $BaseHashLog

# ----------------------------
# STEP 1: Run Robocopy
# ----------------------------
if (!(Test-Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force
}

$RobocopyOptions = @(
    "`"$Source`"", "`"$Destination`"",
    "/E", "/Z", "/R:3", "/W:5",
    "/IPG:100", "/XO", "/XN", "/NP",
    "/TEE", "/LOG+:$RobocopyLogFile"
)

Write-Host "Running Robocopy from '$Source' to '$Destination'..."
Start-Process -FilePath robocopy.exe -ArgumentList $RobocopyOptions -Wait -NoNewWindow

if ($LASTEXITCODE -le 3) {
    Write-Host "Robocopy completed successfully."
} else {
    Write-Host "Robocopy encountered issues. Exit code: $LASTEXITCODE"
}

# ----------------------------
# STEP 2: Hash Verification
# ----------------------------
function Get-FileHashTable {
    param (
        [string]$PathRoot
    )

    $hashTable = @{}
    $files = Get-ChildItem -Path $PathRoot -Recurse -File
    foreach ($file in $files) {
        $hash = Get-FileHash -Path $file.FullName -Algorithm SHA256
        $relativePath = $file.FullName.Substring($PathRoot.Length).TrimStart('\')
        $hashTable[$relativePath] = $hash.Hash
    }
    return $hashTable
}

Write-Host "Starting SHA256 hash verification with resume support..."

# Load checkpoint
$VerifiedSet = @{}
if (Test-Path $CheckpointFile) {
    $VerifiedSet = Get-Content $CheckpointFile | ForEach-Object { $_.Trim() } | Sort-Object -Unique
}

# Compute hashes
$sourceHashes = Get-FileHashTable -PathRoot $Source
$destHashes = Get-FileHashTable -PathRoot $Destination

# Compare and log
$errors = @()
foreach ($file in $sourceHashes.Keys) {
    if ($VerifiedSet -contains $file) {
        continue
    }

    if ($destHashes.ContainsKey($file)) {
        if ($sourceHashes[$file] -ne $destHashes[$file]) {
            $msg = "Hash mismatch: $file"
            $errors += $msg
            Add-Content -Path $HashLogFile -Value $msg
        } else {
            Add-Content -Path $CheckpointFile -Value $file
            Add-Content -Path $HashLogFile -Value "Verified: $file"
        }
    } else {
        $msg = "Missing in destination: $file"
        $errors += $msg
        Add-Content -Path $HashLogFile -Value $msg
    }

    # Check and rotate hash log if needed
    Rotate-LogIfNeeded -logPath $HashLogFile -baseName $BaseHashLog
}

# Final status
if ($errors.Count -eq 0) {
    $successMsg = "All file hashes verified successfully."
    Write-Host $successMsg
    Add-Content -Path $HashLogFile -Value $successMsg
} else {
    $failMsg = "Hash verification failed. Issues found:"
    Write-Host $failMsg
    Add-Content -Path $HashLogFile -Value $failMsg
    $errors | ForEach-Object {
        Write-Host $_
    }
}
