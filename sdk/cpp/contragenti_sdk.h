// SDK-обёртка вызова Contragenti из C++ приложения на Windows.
//
// Полный контракт (флаги CLI, формат XML, куда класть поля) — в
// ../../INTEGRATION.md. Единственная зависимость — WinAPI, никаких внешних
// XML-библиотек: элементы карточки простые (не вложены произвольно), поэтому
// разбор сделан минимальным строковым парсером ниже.
//
// Пример:
//   #include "contragenti_sdk.h"
//   ContragentiCard card;
//   if (PickCounterparty(L"Contragenti.exe", L"UNISIM", L"ru", 300000, card)) {
//       // card.idno, card.denumire, card.founders, card.debts ...
//   }
//
// Заголовок header-only: просто #include, компилировать вместе с проектом.

#pragma once

#include <windows.h>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>

struct ContragentiFounder {
    std::wstring name;
    std::wstring share;
};

struct ContragentiDebt {
    std::wstring nr;
    std::wstring type;
    std::wstring sum;
};

struct ContragentiCard {
    std::wstring idno;
    std::wstring denumire;
    std::wstring inregistrare;
    std::wstring formaJuridica;
    std::wstring lichidata;
    std::wstring adresa;
    std::wstring administratori;
    std::wstring detailsText;
    std::vector<ContragentiFounder> founders;
    std::vector<ContragentiDebt> debts;
    std::wstring debtsCurrency;

    bool IsEmpty() const { return idno.empty() && denumire.empty(); }
};

namespace contragenti_detail {

// ── минимальный UTF-8 <-> UTF-16 helper (WinAPI) ──

inline std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
    return w;
}

inline std::string WideToUtf8(const std::wstring& w) {
    if (w.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

// ── очень маленький XML-парсер, только под наш плоский формат ──
// Карточка Contragenti не содержит CDATA, вложенных тегов внутри полей и
// экранирует только &lt; &gt; &amp; &quot; &apos; — этого достаточно.

inline std::wstring XmlUnescape(const std::wstring& s) {
    std::wstring out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == L'&') {
            if (s.compare(i, 4, L"&lt;") == 0) { out += L'<'; i += 3; continue; }
            if (s.compare(i, 4, L"&gt;") == 0) { out += L'>'; i += 3; continue; }
            if (s.compare(i, 5, L"&amp;") == 0) { out += L'&'; i += 4; continue; }
            if (s.compare(i, 6, L"&quot;") == 0) { out += L'"'; i += 5; continue; }
            if (s.compare(i, 6, L"&apos;") == 0) { out += L'\''; i += 5; continue; }
        }
        out += s[i];
    }
    return out;
}

// Текст простого тега <tag>...</tag> (без атрибутов и без вложенных тегов).
inline std::wstring ExtractTagText(const std::wstring& xml, const std::wstring& tag) {
    std::wstring open = L"<" + tag;
    size_t p = xml.find(open);
    if (p == std::wstring::npos) return L"";
    // тег может быть самозакрывающимся: <tag/> или <tag ... />
    size_t gt = xml.find(L'>', p);
    if (gt == std::wstring::npos) return L"";
    if (xml[gt - 1] == L'/') return L"";  // <tag/> — пусто
    size_t start = gt + 1;
    std::wstring close = L"</" + tag + L">";
    size_t end = xml.find(close, start);
    if (end == std::wstring::npos) return L"";
    return XmlUnescape(xml.substr(start, end - start));
}

// Значение атрибута attr="..." внутри одного открывающего тега, начиная с offset.
// Возвращает позицию сразу после закрывающей ">" через outEnd.
inline std::wstring ExtractAttr(const std::wstring& tagXml, const std::wstring& attr) {
    std::wstring key = attr + L"=\"";
    size_t p = tagXml.find(key);
    if (p == std::wstring::npos) return L"";
    p += key.size();
    size_t end = tagXml.find(L'"', p);
    if (end == std::wstring::npos) return L"";
    return XmlUnescape(tagXml.substr(p, end - p));
}

// Перечисляет все самозакрывающиеся теги <tagName .../> внутри блока,
// заданного открывающим/закрывающим контейнером containerTag.
inline std::vector<std::wstring> ExtractItems(const std::wstring& xml,
                                               const std::wstring& containerTag,
                                               const std::wstring& itemTag) {
    std::vector<std::wstring> items;
    size_t cOpen = xml.find(L"<" + containerTag);
    if (cOpen == std::wstring::npos) return items;
    size_t cGt = xml.find(L'>', cOpen);
    if (cGt == std::wstring::npos) return items;
    if (xml[cGt - 1] == L'/') return items;  // <container/> — пусто, элементов нет
    size_t cClose = xml.find(L"</" + containerTag + L">", cGt);
    if (cClose == std::wstring::npos) cClose = xml.size();

    std::wstring body = xml.substr(cGt + 1, cClose - (cGt + 1));
    std::wstring open = L"<" + itemTag;
    size_t pos = 0;
    while (true) {
        size_t p = body.find(open, pos);
        if (p == std::wstring::npos) break;
        size_t gt = body.find(L'>', p);
        if (gt == std::wstring::npos) break;
        items.push_back(body.substr(p, gt - p + 1));
        pos = gt + 1;
    }
    return items;
}

}  // namespace contragenti_detail

// Разбирает XML-текст карточки (прочитанный из файла --out) в структуру.
inline ContragentiCard ParseContragentiCardXml(const std::wstring& xml) {
    using namespace contragenti_detail;
    ContragentiCard card;
    card.idno = ExtractTagText(xml, L"idno");
    card.denumire = ExtractTagText(xml, L"denumire");
    card.inregistrare = ExtractTagText(xml, L"inregistrare");
    card.formaJuridica = ExtractTagText(xml, L"forma_juridica");
    card.lichidata = ExtractTagText(xml, L"lichidata");
    card.adresa = ExtractTagText(xml, L"adresa");
    card.administratori = ExtractTagText(xml, L"administratori");
    card.detailsText = ExtractTagText(xml, L"details_text");

    for (const auto& tag : ExtractItems(xml, L"founders", L"founder")) {
        ContragentiFounder f;
        f.name = ExtractAttr(tag, L"name");
        f.share = ExtractAttr(tag, L"share");
        card.founders.push_back(f);
    }

    size_t debtsOpen = xml.find(L"<debts");
    if (debtsOpen != std::wstring::npos) {
        size_t debtsGt = xml.find(L'>', debtsOpen);
        if (debtsGt != std::wstring::npos)
            card.debtsCurrency = ExtractAttr(
                xml.substr(debtsOpen, debtsGt - debtsOpen + 1), L"currency");
    }
    for (const auto& tag : ExtractItems(xml, L"debts", L"debt")) {
        ContragentiDebt d;
        d.nr = ExtractAttr(tag, L"nr");
        d.type = ExtractAttr(tag, L"type");
        d.sum = ExtractAttr(tag, L"sum");
        card.debts.push_back(d);
    }
    return card;
}

// Читает файл UTF-8 целиком и возвращает его как std::wstring.
inline bool ReadUtf8File(const std::wstring& path, std::wstring& outText) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    std::string bytes = ss.str();
    // пропустить UTF-8 BOM, если есть
    size_t off = (bytes.size() >= 3 && (unsigned char)bytes[0] == 0xEF &&
                  (unsigned char)bytes[1] == 0xBB && (unsigned char)bytes[2] == 0xBF) ? 3 : 0;
    outText = contragenti_detail::Utf8ToWide(bytes.substr(off));
    return true;
}

// Запускает Contragenti в режиме одноразового выбора и ждёт завершения.
//
//   launcherExe  — путь к Contragenti.exe (собранному) либо к company_search.py
//                  (тогда команда собирается как "python.exe <launcherExe> ...").
//   filter       — стартовый фильтр поиска (может быть пустым).
//   lang         — "ru" / "ro" / "en".
//   timeoutMs    — сколько ждать выбора пользователем (по умолчанию вызывающий
//                  код может передать, например, 300000 = 5 минут).
//   outCard      — заполняется при успехе.
//
// Возвращает true, если пользователь выбрал контрагента и карточка разобрана.
// false — окно закрыто без выбора, процесс не запустился или истёк таймаут;
// причину можно получить через GetLastError() сразу после вызова.
inline bool PickCounterparty(const std::wstring& launcherExe,
                              const std::wstring& filter,
                              const std::wstring& lang,
                              DWORD timeoutMs,
                              ContragentiCard& outCard) {
    wchar_t tempDir[MAX_PATH];
    GetTempPathW(MAX_PATH, tempDir);
    wchar_t outFile[MAX_PATH];
    swprintf_s(outFile, L"%scontragenti_%lu.xml", tempDir, GetTickCount());
    DeleteFileW(outFile);  // не должно быть, но на всякий случай

    std::wstring exe;
    std::wstring args;
    bool isPython = launcherExe.size() > 3 &&
        launcherExe.compare(launcherExe.size() - 3, 3, L".py") == 0;
    if (isPython) {
        exe = L"python.exe";
        args = L"\"" + exe + L"\" \"" + launcherExe + L"\"";
    } else {
        exe = launcherExe;
        args = L"\"" + exe + L"\"";
    }
    args += L" --pick --out \"" + std::wstring(outFile) + L"\" --lang " + lang +
            L" --no-server --no-tray";
    if (!filter.empty())
        args += L" --q \"" + filter + L"\"";

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_SHOWNORMAL;
    PROCESS_INFORMATION pi{};

    std::vector<wchar_t> cmdBuf(args.begin(), args.end());
    cmdBuf.push_back(L'\0');

    if (!CreateProcessW(isPython ? nullptr : exe.c_str(), cmdBuf.data(),
                         nullptr, nullptr, FALSE, CREATE_UNICODE_ENVIRONMENT,
                         nullptr, nullptr, &si, &pi)) {
        return false;  // GetLastError() уже содержит причину
    }

    DWORD waitRes = WaitForSingleObject(pi.hProcess, timeoutMs);
    if (waitRes == WAIT_TIMEOUT) {
        TerminateProcess(pi.hProcess, 1);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        SetLastError(ERROR_TIMEOUT);
        return false;
    }
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    std::wstring xml;
    bool haveFile = ReadUtf8File(outFile, xml);
    DeleteFileW(outFile);
    if (!haveFile)
        return false;  // окно закрыто без выбора — это не ошибка, а отказ пользователя

    outCard = ParseContragentiCardXml(xml);
    return !outCard.IsEmpty();
}
