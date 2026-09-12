# Технический паспорт проекта Contragenti

Один документ, по которому любой ИИ-агент или инженер — без переписки с
автором — разворачивает нужную часть этого комплекса на произвольном
Linux-хостинге, в том числе **по подпути** существующего сайта
(`https://хост/contragenti/…`). Паспорт самодостаточен: конкретные шаги для
конкретного компонента даны здесь целиком, а для глубокого понимания —
ссылки на остальную документацию репозитория в разделе 10.

Репозиторий: `git clone <URL_РЕПОЗИТОРИЯ>` (подставьте адрес вашего форка).

---

## 1. Что это

Контрагенти — не одна программа, а комплекс, ведущий сделку от карточки
организации в государственном реестре Молдовы до фискального чека на
кассе и обратно в учёт. Части написаны на разных языках и разворачиваются
независимо друг от друга:

| Компонент | Язык / стек | Тип | Нужен сервер? |
|---|---|---|---|
| **Contragenti** — поиск по реестру date.gov.md | Python + tkinter | десктоп-утилита | нет |
| **Demo CRM** (Delphi) | Delphi/VCL | десктоп, Windows | нет |
| **Demo CRM** (Swift) | Swift/AppKit | десктоп, macOS | нет |
| **Хаб** (`hub/`) — приём баз от рабочих мест, слияние в общий справочник | Python/FastAPI | **веб-служба** | да |
| **pos_bridge** — прослойка учёт↔касса | Python/FastAPI | **веб-служба** | да |
| **Имитатор FiscalCloud** (`pos_bridge/fc_emulator/`) | Python/FastAPI + tkinter | **веб-служба** (окно — опционально) | да |
| **Книга о комплексе** (`docs/book/`) | статический HTML | статика | да (просто раздать файлы) |
| **ERP OfficePlus** | C++Builder + Oracle/MySQL | внешняя система, не входит в этот репозиторий | — |

Десктопные программы (Contragenti, обе Demo CRM) **не разворачиваются на
сервере** — это приложения для рабочего места пользователя. На хостинг
имеет смысл выносить только компоненты с пометкой «веб-служба» и статику.

---

## 2. Архитектура и порты по умолчанию

```
Браузер / касса Sunmi
      │
      ▼
  nginx (TLS, подпуть /contragenti/…)
      │
      ├─ /contragenti/book/      → статика docs/book/  (просто файлы)
      ├─ /contragenti/hub/       → 127.0.0.1:8800       (hub/app.py)
      ├─ /contragenti/pos/       → 127.0.0.1:50800      (pos_bridge/app.py)
      └─ /contragenti/fiscal/    → 127.0.0.1:50700      (pos_bridge/fc_emulator)
```

| Служба | Порт по умолчанию | Слушает | Модуль запуска |
|---|---|---|---|
| Хаб | `8800` | `127.0.0.1` | `python -m hub.app` |
| Прослойка кассы (pos_bridge) | `50800` | `127.0.0.1` | `python -m pos_bridge serve` |
| Имитатор FiscalCloud | `50700` | `127.0.0.1` | `python -m pos_bridge.fc_emulator serve` |

Все три службы по умолчанию слушают только петлевой адрес — наружу их
выставляет reverse-proxy (nginx/Caddy). Открывать порты в интернет напрямую
не нужно и не безопасно.

---

## 3. Требования к хостингу

- Linux с systemd (Ubuntu/Debian/RHEL — любой; примеры ниже для
  Debian/Ubuntu, для RHEL заменить `useradd`/`apt` на аналоги).
- Python **3.10–3.12** (репозиторий разрабатывался и проверялся на 3.12;
  3.14 тоже подходит, но `oracledb`/`pymysql` проверяйте отдельно).
- Доступ по SSH с правом `sudo` (для systemd-юнитов) либо готовность
  запускать процессы под обычным пользователем через `screen`/`tmux`/
  supervisor, если `sudo` нет.
- nginx или другой reverse-proxy, если нужен внешний HTTPS-адрес.
- **Не требуется**: Xcode, Delphi/RAD Studio, Windows — это инструменты
  сборки десктопных программ, к серверной части отношения не имеют.
- **Опционально**: Oracle Instant Client (только если хаб или pos_bridge
  подключаются к реальному Oracle OfficePlus, а не к MySQL/демо-каталогу);
  MySQL/MariaDB-клиент, если каталог берётся оттуда.

---

## 4. Состав репозитория (что копировать на сервер)

```
hub/                    служба-хаб (FastAPI)
pos_bridge/             прослойка кассы + имитатор FiscalCloud (FastAPI)
docs/book/              готовая книга-документация (статика, index.html + img/)
requirements-hub.txt    зависимости для hub/ и pos_bridge/ (fastapi, uvicorn, oracledb, pymysql)
tools/linux/            готовый systemd-unit и скрипт установки имитатора кассы
deploy/                 Dockerfile, docker-compose, systemd-unit для хаба
sql/                    SQL для стороны ERP (не нужен на веб-сервере)
crm_delphi/, crm_macos/ исходники десктопных CRM — на сервер не копируются
sdk/                    SDK для интеграции сторонних программ (справочно)
```

На сервер для веб-части достаточно скопировать: `hub/`, `pos_bridge/`,
`docs/book/`, `requirements-hub.txt`, `tools/linux/`. Остальное (десктопные
исходники, `sql/` для Oracle-триггеров, `sdk/`) не участвует в развёртывании
веб-служб, но полезно иметь в репозитории для контекста ИИ-агента.

---

## 5. Что развернуть как самостоятельный подпроект

Ниже — универсальный порядок для варианта **«подпуть на существующем
сайте»** (например, `https://ваш-домен/contragenti/`). Для отдельного
поддомена (`contragenti.ваш-домен`) шаги те же, только в nginx вместо
`location /contragenti/ { … }` используется отдельный `server { }` с
`server_name contragenti.ваш-домен;` и `location / { … }`.

### 5.1. Клонирование и окружение

```bash
sudo useradd --system --home /opt/contragenti --shell /usr/sbin/nologin contragenti || true
sudo mkdir -p /opt/contragenti
sudo git clone <URL_РЕПОЗИТОРИЯ> /opt/contragenti/src
cd /opt/contragenti/src

sudo python3 -m venv /opt/contragenti/.venv
sudo /opt/contragenti/.venv/bin/pip install --upgrade pip
sudo /opt/contragenti/.venv/bin/pip install -r requirements-hub.txt
sudo chown -R contragenti:contragenti /opt/contragenti
```

`requirements-hub.txt` ставит `fastapi`, `uvicorn`, `oracledb`, `pymysql` —
этого достаточно для хаба и прослойки кассы. Полный `requirements.txt`
(с `selenium`, `pillow`, `pystray`) нужен только для запуска Contragenti как
десктоп-приложения, на сервере — нет.

### 5.2. Настройки служб (секреты — только в файлах вне git)

```bash
sudo mkdir -p /etc/contragenti
sudo tee /etc/contragenti/hub_config.json >/dev/null <<'JSON'
{
  "host": "127.0.0.1",
  "port": 8800,
  "clients": { "СЮДА-СВОЙ-КЛЮЧ": "имя рабочего места" },
  "oracle": { "dsn": "", "user": "", "password": "" }
}
JSON

sudo tee /etc/contragenti/pos_bridge_config.json >/dev/null <<'JSON'
{
  "host": "127.0.0.1",
  "port": 50800,
  "fiscalcloud": { "base_url": "http://127.0.0.1:50700",
                   "api_key": "", "api_secret": "" },
  "catalog": { "source": "demo" }
}
JSON
sudo chown -R contragenti:contragenti /etc/contragenti
sudo chmod 600 /etc/contragenti/*.json
```

Оставьте `"clients": {}` в хабе только для проверки на петлевом адресе —
как только адрес слушает `0.0.0.0` за reverse-proxy, пустой список ключей
даёт ответ `503` (это встроенная защита, см. `deploy/README_ru.md`).
Реальные ключи Oracle/MySQL и `Api-Key`/`Api-Secret` FiscalCloud — только
в этих файлах на сервере или в переменных окружения, никогда не в git.

### 5.3. Службы systemd

```bash
sudo tee /etc/systemd/system/contragenti-hub.service >/dev/null <<UNIT
[Unit]
Description=Contragenti hub (una.md)
After=network-online.target

[Service]
Type=simple
User=contragenti
Environment=HUB_CONFIG=/etc/contragenti/hub_config.json
ExecStart=/opt/contragenti/.venv/bin/python -m hub.app --host 127.0.0.1 --port 8800
WorkingDirectory=/opt/contragenti/src
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

sudo tee /etc/systemd/system/contragenti-pos-bridge.service >/dev/null <<UNIT
[Unit]
Description=Contragenti POS bridge
After=network-online.target contragenti-fiscal-emulator.service

[Service]
Type=simple
User=contragenti
Environment=POS_BRIDGE_CONFIG=/etc/contragenti/pos_bridge_config.json
ExecStart=/opt/contragenti/.venv/bin/python -m pos_bridge serve --port 50800
WorkingDirectory=/opt/contragenti/src
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now contragenti-hub contragenti-pos-bridge
```

Для имитатора кассы (FiscalCloud) готовый unit и однострочный установщик
уже есть в репозитории — используйте их вместо ручного:

```bash
sudo bash /opt/contragenti/src/tools/linux/install-fiscalcloud-emulator.sh \
  /opt/contragenti/fiscal contragenti
```

Скрипт сам заводит пользователя, окружение Python, настройки в
`/etc/fiscalcloud-emulator/config.json`, unit `fiscalcloud-emulator.service`
и включает его. Подробности — `POS_ERP_ru.md`, раздел «Служба на Linux».

### 5.4. Книга (статика) — раздать без служб

```bash
sudo mkdir -p /var/www/contragenti-book
sudo cp -r /opt/contragenti/src/docs/book/* /var/www/contragenti-book/
```

### 5.5. nginx: всё под одним подпутём

```nginx
location /contragenti/book/ {
    alias /var/www/contragenti-book/;
    try_files $uri $uri/ /contragenti/book/index.html;
}

location /contragenti/hub/ {
    proxy_pass http://127.0.0.1:8800/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 128m;   # приём баз companies.db
}

location /contragenti/pos/ {
    proxy_pass http://127.0.0.1:50800/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}

location /contragenti/fiscal/ {
    proxy_pass http://127.0.0.1:50700/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Обе FastAPI-службы отдают собственную документацию на `/api-docs` и
`/api-playground` (или `/openapi.json`) — за проксированием по подпути они
окажутся на `https://хост/contragenti/pos/api-docs` и т. п., ссылки внутри
Swagger/ReDoc используют относительные пути и работают без правок.

Проверить и включить конфиг:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

---

## 6. Переменные окружения (альтернатива файлам настроек)

| Переменная | Для чего | Компонент |
|---|---|---|
| `HUB_CONFIG` | путь к `hub_config.json` | хаб |
| `HUB_DATA_DIR` | каталог приёма пакетов и БД реестра заданий | хаб |
| `POS_BRIDGE_CONFIG` | путь к `pos_bridge_config.json` | pos_bridge |
| `POS_BRIDGE_DATA` | каталог собственной БД прослойки | pos_bridge |
| `FC_EMULATOR_CONFIG` | путь к настройкам имитатора | fc_emulator |
| `FC_EMULATOR_PORT` | порт имитатора (иначе — из конфига, 50700) | fc_emulator |
| `TMS_DSN`, `TMS_USER`, `TMS_PASSWORD` | подключение к Oracle (una.md/OfficePlus) | хаб, pos_bridge |
| `GOODS_DSN`, `GOODS_USER`, `GOODS_PASSWORD` | подключение к Oracle (товары) | pos_bridge |
| `MYSQL_HOST`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE` | подключение к MySQL/MariaDB как альтернативе Oracle | pos_bridge |
| `ORACLE_CLIENT_DIR` | путь к Oracle Instant Client (thick-режим для старых серверов) | хаб, pos_bridge |

На macOS пароли можно также брать из связки ключей
(`keychain_service`/`keychain_account` в `pos_bridge_config.json`) — на
Linux‑сервере эта возможность недоступна, используйте переменные окружения
или файл настроек с правами `600`.

---

## 7. Проверка после развёртывания

```bash
# хаб
curl -s http://127.0.0.1:8800/api/v1/health

# прослойка кассы
curl -s http://127.0.0.1:50800/health

# имитатор FiscalCloud
curl -s http://127.0.0.1:50700/health

# сквозной прогон прослойки без реальной кассы (создаёт временную песочницу,
# рабочие базы не трогает)
/opt/contragenti/.venv/bin/python -m pos_bridge selftest --no-export

# сверка имитатора с описанием API FiscalCloud (35 точек, должно быть 0 расхождений)
/opt/contragenti/.venv/bin/python -m pos_bridge fc-conformance

# systemd
sudo systemctl status contragenti-hub contragenti-pos-bridge fiscalcloud-emulator
```

Через reverse-proxy:

```bash
curl -sk https://ваш-домен/contragenti/hub/api/v1/health
curl -sk https://ваш-домен/contragenti/pos/health
curl -sk https://ваш-домен/contragenti/book/index.html | head -5
```

---

## 8. Обновление

```bash
cd /opt/contragenti/src
sudo -u contragenti git pull --ff-only
sudo /opt/contragenti/.venv/bin/pip install -r requirements-hub.txt --upgrade
sudo cp -r docs/book/* /var/www/contragenti-book/
sudo systemctl restart contragenti-hub contragenti-pos-bridge fiscalcloud-emulator
```

Состояние имитатора кассы (сквозные номера чеков, накопительные суммы)
хранится отдельно от кода — в `/var/lib/fiscalcloud-emulator/state.json` —
и переживает `git pull` и перезапуск службы.

---

## 9. Чек-лист безопасности перед публикацией наружу

- [ ] Все три службы слушают `127.0.0.1`, наружу отдаёт только nginx с TLS.
- [ ] В `hub_config.json` заполнен `clients` (непустой) — иначе приём пакетов
      отключается сам с кодом 503, но лучше не полагаться на это как на
      единственную защиту.
- [ ] Пароли Oracle/MySQL и ключи FiscalCloud — только в файлах с правами
      `600` от отдельного системного пользователя или в переменных
      окружения юнита; в git не попадают (проверьте `.gitignore`).
- [ ] `client_max_body_size` в nginx достаточен для приёма баз компаний
      (пакеты `companies.db` могут быть десятки мегабайт).
- [ ] Резервные копии `hub_data/`, `pos_bridge_data/`,
      `/var/lib/fiscalcloud-emulator/` — это единственное место, где
      хранится состояние.

---

## 10. Остальная документация репозитория

| Документ | О чём |
|---|---|
| [README.md](README.md) | Общее описание Contragenti и всего комплекса, таблица всех документов |
| [POS_ERP_ru.md](POS_ERP_ru.md) | Прослойка кассы, имитатор FiscalCloud, MySQL как альтернатива Oracle, служба на Linux — подробно |
| [HUB_ru.md](HUB_ru.md) | Протокол приёма пакетов, слияние баз организаций |
| [deploy/README_ru.md](deploy/README_ru.md) | Docker- и systemd-варианты для хаба, ключи клиентов, TLS |
| [STAFF_ERP_ru.md](STAFF_ERP_ru.md) | Обмен сотрудниками между CRM и ERP OfficePlus через триггеры |
| [INTEGRATION.md](INTEGRATION.md) | Контракт для сторонних программ: CLI, XML, SDK |
| [AGENTS.md](AGENTS.md) | Правила разработки для ИИ-агентов, работающих с этим репозиторием |
| [docs/book/index.html](docs/book/index.html) | Книга о комплексе целиком — схема, все документы, скриншоты, живые прогоны проверок |

---

*Документ поддерживается вручную и не собирается автоматически (в отличие
от `docs/book/`) — при изменении портов, имён служб или структуры каталогов
поправьте его вместе с кодом.*
