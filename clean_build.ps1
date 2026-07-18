taskkill /f /im xmate.exe 2>$null
taskkill /f /im dart.exe 2>$null
taskkill /f /im flutter.exe 2>$null
taskkill /f /im cmake.exe 2>$null
Start-Sleep -Seconds 3
Remove-Item -Recurse -Force "e:\AI\XMate\build\windows\x64\runner\Debug" -ErrorAction Stop
Write-Host "Done"
