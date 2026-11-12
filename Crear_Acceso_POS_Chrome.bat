@echo off
chcp 65001 >nul
echo ========================================================
echo   CONFIGURADOR DE IMPRESION RAPIDA PARA EARENDEL X POS
echo ========================================================
echo.

set "CHROME_PATH="
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" (
    set "CHROME_PATH=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
) else if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" (
    set "CHROME_PATH=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
) else if exist "%LocalAppData%\Google\Chrome\Application\chrome.exe" (
    set "CHROME_PATH=%LocalAppData%\Google\Chrome\Application\chrome.exe"
)

if "%CHROME_PATH%"=="" (
    echo [ERROR] No se encontro Google Chrome instalado en las rutas habituales.
    echo Por favor instala Google Chrome para usar la impresion silenciosa.
    echo.
    pause
    exit /b 1
)

echo Encontrado Chrome en: "%CHROME_PATH%"
echo Creando acceso directo en tu Escritorio...

powershell -NoProfile -Command "$ws = New-Object -ComObject WScript.Shell; $desktop = [Environment]::GetFolderPath('Desktop'); $sc = $ws.CreateShortcut(\"$desktop\Earendel X - POS.lnk\"); $sc.TargetPath = '%CHROME_PATH%'; $sc.Arguments = '--kiosk-printing --app=https://earendelx.com'; $sc.Description = 'Earendel X Punto de Venta con Impresion Silenciosa'; $sc.Save()"

echo.
echo ========================================================
echo   ¡LISTO! Se creo el acceso directo "Earendel X - POS"
echo   en tu Escritorio con impresion silenciosa activada.
echo ========================================================
echo.
echo Recuerda:
echo 1. Pon tu impresora termica como Predeterminada en Windows.
echo 2. Abre Earendel X desde este nuevo icono en tu escritorio.
echo.
pause
