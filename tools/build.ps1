# Build ElectroMan.pdx with pdc, then fuzz-test the Lua with the headless
# harness. Run from anywhere: & "D:\ElectroManPlaydate\ElectroMan\tools\build.ps1"
$root = Split-Path $PSScriptRoot -Parent
& "$env:PLAYDATE_SDK_PATH\bin\pdc.exe" (Join-Path $root 'source') (Join-Path $root 'ElectroMan.pdx') |
    Where-Object { $_ -notmatch '^(Copying |Unrecognized file types) ?' }
"pdc exit: $LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { exit 1 }
python (Join-Path $PSScriptRoot 'headless_smoke.py')
exit $LASTEXITCODE
