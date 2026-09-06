# release/

Готовые сборки для Windows — скачиваются прямо из репозитория (кнопка
«Download raw» или ссылка `.../raw/main/release/...`).

| Файл | Что это | Кто пересобирает |
|---|---|---|
| `Contragenti-<версия>-setup.exe` | **Рекомендуемый** установщик без Windows Installer. Тонкий: сам файл маленький (окно + загрузчик + корни certifi), Python и программу не содержит — при установке скачивает `app.zip` из `release.json`, проверяет sha256 и распаковывает в `%LOCALAPPDATA%\Contragenti` или `Program Files`; ярлыки, запись в «Программы и компоненты», запуск мастера. Нужен интернет во время установки (кроме `--offline-payload`). Не зависит от политик MSI (код 1625). `/S`, `/D=`, `--extract-only` | `python setup.py build_exe` (или `bdist_msi`), затем `python tools/build_exe_installer.py`, затем `python tools/make_release.py` |
| `Contragenti-<версия>-app.zip` | Полная сборка (`build/exe.win-*`), которую `setup.exe` докачивает и распаковывает при установке — не публикуется отдельной ссылкой на скачивание, только через `release.json`/`setup.exe` | `python tools/build_exe_installer.py`, затем `python tools/make_release.py` |
| `Contragenti-<версия>-win64.msi` | Установщик MSI: Contragenti.exe, Demo CRM, SDK, мастер настройки — всё внутри, интернет во время установки не нужен. Для сред без сети при установке или где ставят только MSI | `python setup.py bdist_msi`, затем `python tools/make_release.py` |
| `Contragenti-update-<версия>.zip` | Пакет обновления поверх установки: Demo CRM (exe, `lang.json`, `processes.json`), инструкции, SDK, стартовая база компаний, `setup_wizard.py`. Пути внутри = пути в каталоге установки | автоматически: `crm_delphi\build.bat` после каждой компиляции и pre-commit хук перед каждым коммитом (`tools/make_release.py --zip-only`) |

`release.json` в корне репозитория содержит версию, ссылки, размеры и
sha256 всех файлов — по нему мастер настройки («ContragentiSetup.exe»,
меню «Пуск» → «Contragenti — настройка и обновление») находит новую версию
и докачивает zip, сверяя sha256, а тонкий `Contragenti-<версия>-setup.exe`
(`installer_exe.py`) точно так же докачивает и проверяет `app.zip` во время
самой установки.

**Важно:** `Contragenti-update-<версия>.zip` **не содержит `Contragenti.exe`**
(замороженную сборку самой утилиты) — только Demo CRM, документацию, SDK и
мастер. Изменения в `company_search.py` (новый источник данных, логика
поиска и т.п.) в установленную копию через инкрементальный zip не попадают:
их получают только `setup.exe`/`MSI` при переустановке или обновлении. Если
менялся `company_search.py`, версию и `release/` нужно пересобирать
целиком (`python setup.py build_exe` → `bdist_msi` →
`tools/build_exe_installer.py` → `tools/make_release.py`), а не только
гонять `make_release.py --zip-only`.

Включить хук после клонирования (один раз):

```bash
git config core.hooksPath .githooks
```
