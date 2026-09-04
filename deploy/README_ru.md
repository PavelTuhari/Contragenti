# Вынос хаба на хостинг

Локально хаб работает на `127.0.0.1` и принимает пакеты без ключа. При выносе
наружу этот режим отключается сам: если хаб слушает внешний адрес, а список
`clients` пуст, приём отвечает `503` — чтобы в общий справочник не мог писать
любой, кто знает адрес.

---

## 1. Ключи клиентов

Каждому рабочему месту — свой ключ: видно, кто прислал пакет, и можно отозвать
доступ одной машине, не трогая остальные.

```bash
python tools/hub_keygen.py "Бухгалтерия" --save
python tools/hub_keygen.py "Отдел продаж" --save
python tools/hub_keygen.py --list
python tools/hub_keygen.py --revoke <ключ>
```

На рабочем месте ключ прописывается в `tms_config.json` (`hub_key`) или в
переменной `HUB_API_KEY`.

---

## 2. Вариант A — Docker

Понадобится архив Oracle Instant Client (`basiclite`, Linux x64) — положите его
рядом с `Dockerfile`: драйвер обязателен, thin-режим сервер 11.2 не поддерживает.

```bash
cd deploy
cp .env.example .env          # заполнить TMS_PASSWORD
cp ../hub_config.json .       # либо создать: ключи клиентов и настройки
docker compose up -d
docker compose logs -f
```

Контейнер публикует порт только на петлю (`127.0.0.1:8800`), данные лежат в
именованном томе и переживают пересборку.

## 2. Вариант B — systemd

```bash
sudo useradd -r -s /usr/sbin/nologin una
sudo mkdir -p /opt/una-hub && sudo chown una:una /opt/una-hub
# скопировать hub/, tms_export.py, legal_forms.py, requirements-hub.txt
sudo -u una python3 -m venv /opt/una-hub/.venv
sudo -u una /opt/una-hub/.venv/bin/pip install -r /opt/una-hub/requirements-hub.txt
sudo cp deploy/una-hub.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now una-hub
```

---

## 3. Reverse-proxy и TLS

Хаб слушает петлю; наружу его выставляет nginx с сертификатом. Пакеты — это
база организаций, они не должны ходить по открытому HTTP.

```nginx
server {
    listen 443 ssl http2;
    server_name hub.una.md;

    ssl_certificate     /etc/letsencrypt/live/hub.una.md/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/hub.una.md/privkey.pem;

    # пакет — это сжатая база; лимит должен быть не меньше max_upload_mb
    client_max_body_size 64m;

    location / {
        proxy_pass         http://127.0.0.1:8800;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;   # импорт идёт в фоне, но загрузка может быть долгой
    }
}

server {
    listen 80;
    server_name hub.una.md;
    return 301 https://$host$request_uri;
}
```

---

## 4. Что проверить после переноса

```bash
curl -fsS https://hub.una.md/api/v1/health
# без ключа — должно быть 401
curl -si -X POST https://hub.una.md/api/v1/batches --data-binary @batch.gz | head -1
# с ключом — 202
curl -s -X POST https://hub.una.md/api/v1/batches \
     -H "X-Api-Key: <ключ>" --data-binary @batch.gz
```

Дашборд `https://hub.una.md/` показывает пакеты и счётчики. Если хаб отдаёт
`503` с упоминанием `clients` — ключи не заданы, приём намеренно закрыт.

---

## 5. Обслуживание

- **Уборка.** Архивы обработанных пакетов удаляются через `keep_inbox_days`
  (по умолчанию 14). Реестр заданий остаётся — по нему видна история.
- **Повторы.** Одинаковый пакет от того же клиента не импортируется дважды:
  сверка идёт по SHA-256 содержимого.
- **Незавершённое.** Пакеты, не доехавшие до конца при остановке, хаб
  дочитывает при следующем запуске.
- **Резервная копия.** Достаточно каталога `HUB_DATA_DIR`: там реестр и
  принятые архивы.

---

## 6. Переход на Oracle APEX

Клиентов менять не придётся: контракт API, формат пакета и логика
дедупликации остаются прежними. Заменяется только приёмник внутри
`hub/importer.py` — функция `import_rows`.
