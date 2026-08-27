#!/bin/zsh
# Запуск GUI поиска компаний date.gov.md
cd "$(dirname "$0")"
exec ./.venv/bin/python company_search.py
