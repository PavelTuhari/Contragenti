# Хаб справочника контрагентов una.md
#
# Образ содержит только серверную часть: приём пакетов и импорт в Oracle.
# Сам Contragenti остаётся на рабочих местах и сюда не входит.

FROM python:3.12-slim

# Oracle Instant Client нужен для сервера 11.2 (thin-режим его не поддерживает).
# libaio — обязательная зависимость клиента.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libaio1 unzip curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Положите архив instantclient-basiclite-linux.x64-*.zip рядом с Dockerfile
COPY instantclient-*.zip /tmp/
RUN mkdir -p /opt/oracle && unzip -q /tmp/instantclient-*.zip -d /opt/oracle \
    && rm /tmp/instantclient-*.zip \
    && echo /opt/oracle/instantclient* > /etc/ld.so.conf.d/oracle.conf \
    && ldconfig
ENV ORACLE_CLIENT_DIR=/opt/oracle/instantclient

WORKDIR /app
COPY requirements-hub.txt .
RUN pip install --no-cache-dir -r requirements-hub.txt

COPY hub/ ./hub/
COPY tms_export.py legal_forms.py ./

# данные хаба (реестр и inbox) выносим в том, чтобы переживали пересборку
ENV HUB_DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 8800

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
  CMD curl -fsS http://127.0.0.1:8800/api/v1/health || exit 1

CMD ["python", "-m", "hub.app", "--host", "0.0.0.0", "--port", "8800"]
