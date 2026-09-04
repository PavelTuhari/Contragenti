@echo off
cd /d "%~dp0"
start "Contragenti" "%~dp0.venv\Scripts\pythonw.exe" "%~dp0company_search.py" --lang ru
