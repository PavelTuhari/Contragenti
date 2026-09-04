# SDK-обёртки Contragenti

Готовые обёртки вызова Contragenti на трёх языках — скопируй нужный файл
целиком в свой проект. Полный контракт (флаги, формат XML, таблица
соответствия полей) описан в **[../INTEGRATION.md](../INTEGRATION.md)**.

| Язык | Файл | Зависимости |
|---|---|---|
| Python | [`python/contragenti_sdk.py`](python/contragenti_sdk.py) | только стандартная библиотека |
| C++ (Windows) | [`cpp/contragenti_sdk.h`](cpp/contragenti_sdk.h) + [`cpp/example.cpp`](cpp/example.cpp) | только WinAPI, без внешних библиотек |
| Delphi | [`../crm_delphi/uContragenti.pas`](../crm_delphi/uContragenti.pas) | только `System.*`, без VCL — используй как есть |

Все три реализуют одну и ту же логику: собрать командную строку с
`--pick --out <tmp.xml>`, запустить процесс, дождаться завершения,
прочитать и разобрать XML, вернуть структуру с полями карточки.
