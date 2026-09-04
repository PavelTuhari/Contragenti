// Пример использования contragenti_sdk.h: разбор XML-карточки без запуска
// самого Contragenti (для проверки парсера без Chrome/сети — как self-test).
//
// Сборка (MinGW):  g++ -std=c++17 -municode example.cpp -o example.exe
// Сборка (MSVC):   cl /std:c++17 /EHsc example.cpp
//
// Реальный вызов показан в комментарии внизу main().

#include "contragenti_sdk.h"
#include <cstdio>
#include <cassert>

int wmain() {
    const wchar_t* sample =
        L"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        L"<counterparty source=\"date.gov.md\" idno=\"1003600116460\">"
        L"<idno>1003600116460</idno>"
        L"<denumire>CENTRUL DE ELABORARE UNISIM-SOFT S.R.L.</denumire>"
        L"<forma_juridica>Societate cu raspundere limitata</forma_juridica>"
        L"<adresa>mun. Chisinau, str. Alba-Iulia 75/B</adresa>"
        L"<administratori>TUHARI PAVEL [Administrator]</administratori>"
        L"<founders><founder name=\"TUHARI PAVEL\" share=\"100,00\"/></founders>"
        L"<debts currency=\"MDL\"><debt nr=\"1\" type=\"Bugetul de stat\" sum=\"0,98\"/></debts>"
        L"</counterparty>";

    ContragentiCard card = ParseContragentiCardXml(sample);

    assert(card.idno == L"1003600116460");
    assert(card.denumire.rfind(L"CENTRUL", 0) == 0);
    assert(card.founders.size() == 1 && card.founders[0].name == L"TUHARI PAVEL");
    assert(card.debts.size() == 1 && card.debts[0].sum == L"0,98");
    assert(card.debtsCurrency == L"MDL");

    wprintf(L"OK: ParseContragentiCardXml self-test passed (%s / %s)\n",
            card.idno.c_str(), card.denumire.c_str());

    // Реальный вызов с запуском Contragenti (закомментировано — нужен живой
    // портал/окно):
    //
    // ContragentiCard real;
    // if (PickCounterparty(L"Contragenti.exe", L"UNISIM", L"ru", 300000, real)) {
    //     wprintf(L"выбрано: %s (%s)\n", real.denumire.c_str(), real.idno.c_str());
    //     // db.Insert(real.idno, real.denumire, real.adresa, real.formaJuridica);
    // } else {
    //     wprintf(L"отмена или ошибка, код %lu\n", GetLastError());
    // }

    return 0;
}
