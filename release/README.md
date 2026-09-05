# release/

Готовые сборки для Windows — скачиваются прямо из репозитория (кнопка
«Download raw» или ссылка `.../raw/main/release/...`).

| Файл | Что это | Кто пересобирает |
|---|---|---|
| `Contragenti-<версия>-win64.msi` | Установщик: Contragenti.exe, Demo CRM, SDK, мастер настройки. Git не нужен; если нет Python, мастер в PowerShell запускает `python` (Windows ставит сам) | `python setup.py bdist_msi`, затем `python tools/make_release.py` |
| `Contragenti-update-<версия>.zip` | Пакет обновления поверх установки: Demo CRM (exe, `lang.json`, `processes.json`), инструкции, SDK, стартовая база компаний, `setup_wizard.py`. Пути внутри = пути в каталоге установки | автоматически: `crm_delphi\build.bat` после каждой компиляции и pre-commit хук перед каждым коммитом (`tools/make_release.py --zip-only`) |

`release.json` в корне репозитория содержит версию, ссылки, размеры и
sha256 обоих файлов — по нему мастер настройки («Contragenti Setup.exe»,
меню «Пуск» → «Contragenti — настройка и обновление») находит новую версию
и докачивает zip, сверяя sha256.

Включить хук после клонирования (один раз):

```bash
git config core.hooksPath .githooks
```
