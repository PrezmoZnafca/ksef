@echo off
chcp 65001 >nul
title KSeF - instalacja wymaganych programow
echo ============================================
echo  Instalacja: SumatraPDF i mutool
echo ============================================
echo.

where winget >nul 2>&1
if errorlevel 1 (
    echo BLAD: nie znaleziono narzedzia winget.
    echo Zainstaluj "Instalator aplikacji" ze Sklepu Microsoft ^(App Installer^)
    echo albo zaktualizuj Windows 10/11, a potem uruchom ten plik ponownie.
    echo.
    pause
    exit /b 1
)

echo [1/2] SumatraPDF...
winget install --id SumatraPDF.SumatraPDF -e --accept-package-agreements --accept-source-agreements
echo.
echo [2/2] mutool...
winget install --id ArtifexSoftware.mutool -e --accept-package-agreements --accept-source-agreements
echo.
echo ============================================
echo  Gotowe. Jesli powyzej nie ma bledow, mozesz
echo  uruchomic "Drukuj faktury KSeF.bat".
echo  ^(Komunikat "juz zainstalowano" jest w porzadku.^)
echo ============================================
echo.
pause
