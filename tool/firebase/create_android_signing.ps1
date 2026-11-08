param(
    [string]$Keytool = 'C:\Program Files\Java\jdk-23\bin\keytool.exe'
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$propertiesPath = Join-Path $repoRoot 'android/key.properties'
$keyDirectory = Join-Path $repoRoot ('android/keys/production_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$keyPath = Join-Path $keyDirectory 'material_lab_production.jks'
$certificatePath = Join-Path $keyDirectory 'material_lab_production.cer'
$resultPath = Join-Path $repoRoot 'output/android-production-signing.json'

function Read-Required([string]$Prompt) {
    do { $value = (Read-Host $Prompt).Trim() } while (-not $value)
    return $value
}

function Protect-LocalPath([string]$Path) {
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${owner}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict signing file permissions.' }
}

function Escape-Dn([string]$Value) {
    return $Value.Replace('\', '\\').Replace(',', '\,').Replace('+', '\+').Replace('"', '\"').Replace('<', '\<').Replace('>', '\>').Replace(';', '\;').Replace('=', '\=').Replace('#', '\#')
}

function Property-Value([string]$Value) {
    return -join ($Value.ToCharArray() | ForEach-Object { '\u{0:x4}' -f [int]$_ })
}

function Fingerprint([byte[]]$Bytes) {
    return ([BitConverter]::ToString($Bytes)).Replace('-', ':')
}

try {
    if (-not (Test-Path -LiteralPath $Keytool)) { throw 'keytool.exe was not found.' }
    if (Test-Path -LiteralPath $propertiesPath) { throw 'android/key.properties already exists. Nothing was replaced.' }
    Write-Host 'Create a NEW Android production signing identity. Existing keys and installed apps are not changed.'
    Write-Host 'Enter passwords here only; do not send them in chat. Use your password manager to keep a separate copy.'
    $alias = Read-Required 'Key alias (letters, digits, underscore, dot, dash)'
    if ($alias -notmatch '^[a-zA-Z0-9_.-]{1,64}$') { throw 'Invalid alias.' }
    $commonName = Read-Required 'Certificate owner / common name'
    $organization = Read-Required 'Organization name'
    $unit = (Read-Host 'Organizational unit (optional)').Trim()
    $city = Read-Required 'City'
    $state = Read-Required 'State / governorate'
    $country = (Read-Required 'Two-letter country code (for example EG)').ToUpperInvariant()
    if ($country -notmatch '^[A-Z]{2}$') { throw 'Country must contain two letters.' }
    $backupInput = (Read-Required 'Protected backup folder OUTSIDE the project').Trim('"').Trim()
    $backupRoot = [IO.Path]::GetFullPath($backupInput)
    if ($backupRoot.TrimEnd('\', '/') -eq $repoRoot -or $backupRoot.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Choose a backup folder outside the project.'
    }
    $passwordSecure = Read-Host 'Keystore password (at least 12 characters)' -AsSecureString
    $confirmSecure = Read-Host 'Confirm password' -AsSecureString
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passwordSecure)
    $confirmPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmSecure)
    try {
        $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        $confirm = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($confirmPointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmPointer)
    }
    if ($password.Length -lt 12 -or $password -cne $confirm) { throw 'Passwords must match and contain at least 12 characters.' }
    $parts = @(('CN=' + (Escape-Dn $commonName)), ('O=' + (Escape-Dn $organization)), ('L=' + (Escape-Dn $city)), ('ST=' + (Escape-Dn $state)), ('C=' + $country))
    if ($unit) { $parts += 'OU=' + (Escape-Dn $unit) }
    $dn = $parts -join ','
    Write-Host "Certificate: $dn"
    Write-Host "Key: $keyPath"
    Write-Host "Backup root: $backupRoot"
    if ((Read-Host 'Type CREATE to generate this identity') -cne 'CREATE') { throw 'Cancelled; no signing identity was created.' }

    New-Item -ItemType Directory -Path $keyDirectory -ErrorAction Stop | Out-Null
    Protect-LocalPath $keyDirectory
    $env:MATERIAL_LAB_SIGNING_SECRET = $password
    & $Keytool -genkeypair -keystore $keyPath -storetype PKCS12 -alias $alias -keyalg RSA -keysize 3072 -sigalg SHA256withRSA -validity 10000 -dname $dn -storepass:env MATERIAL_LAB_SIGNING_SECRET -keypass:env MATERIAL_LAB_SIGNING_SECRET
    if ($LASTEXITCODE -ne 0) { throw 'Key generation failed. Any generated key was preserved for inspection.' }
    & $Keytool -exportcert -keystore $keyPath -alias $alias -file $certificatePath -storepass:env MATERIAL_LAB_SIGNING_SECRET
    if ($LASTEXITCODE -ne 0) { throw 'Certificate export failed. The key was preserved.' }
    Remove-Item Env:MATERIAL_LAB_SIGNING_SECRET
    $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($certificatePath)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $sha256Fingerprint = Fingerprint ($sha256.ComputeHash($certificate.RawData)) } finally { $sha256.Dispose() }
    $sha1Fingerprint = Fingerprint ($certificate.GetCertHash())
    $backupDirectory = Join-Path $backupRoot ([IO.Path]::GetFileName($keyDirectory))
    New-Item -ItemType Directory -Path $backupDirectory -ErrorAction Stop | Out-Null
    Protect-LocalPath $backupDirectory
    $backupPath = Join-Path $backupDirectory 'material_lab_production.jks'
    Copy-Item -LiteralPath $keyPath -Destination $backupPath -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $keyPath).Hash -ne (Get-FileHash -LiteralPath $backupPath).Hash) { throw 'Backup verification failed.' }

    # Java Properties uses explicit Unicode escapes so passwords containing
    # backslashes, spaces, separators or non-ASCII characters round-trip.
    $relativeStore = '../keys/' + [IO.Path]::GetFileName($keyDirectory) + '/material_lab_production.jks'
    $lines = @(('storeFile=' + (Property-Value $relativeStore)), ('storePassword=' + (Property-Value $password)), ('keyAlias=' + (Property-Value $alias)), ('keyPassword=' + (Property-Value $password)))
    New-Item -ItemType File -Path $propertiesPath -ErrorAction Stop | Out-Null
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $propertiesPath /inheritance:r /grant:r "${owner}:F" '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect key.properties; its contents remain empty.' }
    [IO.File]::WriteAllLines($propertiesPath, $lines, (New-Object Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Path (Join-Path $repoRoot 'output') -Force | Out-Null
    [ordered]@{ alias = $alias; keystore = $keyPath; certificate = $certificatePath; backup = $backupPath; sha1 = $sha1Fingerprint; sha256 = $sha256Fingerprint; package = 'com.materiallab'; createdAt = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Host "SHA-1:   $sha1Fingerprint"
    Write-Host "SHA-256: $sha256Fingerprint"
    Write-Host "SUCCESS. Public fingerprints: $resultPath"
    Write-Host 'The password is saved only in ignored, access-restricted android/key.properties. Keep your password-manager copy.'
} catch {
    Write-Host ('STOPPED: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Existing keys, installed apps and organization data were not changed.'
} finally {
    Remove-Item Env:MATERIAL_LAB_SIGNING_SECRET -ErrorAction SilentlyContinue
    $password = $null
    $confirm = $null
    if ($passwordSecure) { $passwordSecure.Dispose() }
    if ($confirmSecure) { $confirmSecure.Dispose() }
    Read-Host 'Press Enter to close'
}
