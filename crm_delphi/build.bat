@echo off
rem Build Demo CRM with the Delphi command-line compiler (no IDE needed).
rem Requires RAD Studio 10.2 Tokyo or compatible. ASCII only: cmd reads
rem this file in the OEM code page and chokes on UTF-8 comments.

setlocal
if "%BDS%"=="" set "BDS=C:\Program Files (x86)\Embarcadero\Studio\19.0"
set "LIB=%BDS%\lib\Win32\release"

if not exist dcu mkdir dcu

rem project resource (icon/manifest are optional for the demo)
if not exist ContragentiCRM.res "%BDS%\bin\brcc32.exe" ContragentiCRM.rc

"%BDS%\bin\dcc32.exe" -B --no-config ^
  "-U%LIB%" "-I%LIB%" "-R%LIB%" "-O%LIB%" ^
  "-NU.\dcu" "-E.\" ^
  ContragentiCRM.dpr

if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)
echo Done: ContragentiCRM.exe
endlocal
