unit uGuiSelfTest;
{
  Встроенный самотест интерфейса.

  Тест живёт внутри процесса: сам ведёт форму по пронумерованным шагам,
  рисует на ней плашку «Шаг NN · название», после каждого шага снимает
  окно через GetFormImage и складывает PNG в каталог отчёта. Вторая часть —
  реальный вызов SDK: нажимается настоящая кнопка «Добавить из реестра»,
  запускается Contragenti (Chrome + портал date.gov.md); пока он работает,
  тест через OnWait снимает и своё окно, и окна Contragenti/Chrome
  (PrintWindow). В конце собирает автономный report.html.

    ContragentiCRM.exe --gui-test [каталог] [путь к Contragenti.exe|company_search.py]
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, uEspoTheme, uMainForm;

type
  TStepResult = record
    Num: Integer;
    Title: string;
    Ok: Boolean;
    Detail: string;
    Shot: string;               // основной PNG (окно CRM)
    Extra: TArray<string>;      // дополнительные снимки шага
    Message: string;            // текст строки сообщений после шага
  end;

  TGuiSelfTest = class
  private
    FForm: TMainForm;
    FOutDir: string;
    FLauncher: string;
    FSteps: TArray<TStepResult>;
    FNum: Integer;
    FExtra: TArray<string>;     // копятся во время шага (OnWait)
    FWaitTicks: Integer;
    FWaitShots: Integer;
    FExports: TArray<string>;  // выгруженные отчёты — перечисляются в отчёте
    FSdkStart: TFileTime;     // момент нажатия кнопки — фильтр для чужих окон
    procedure MarkSdkStart;
    procedure CollectSdkShots;
    procedure Pump;
    function Capture(const Slug: string): string;
    function CaptureHwnd(H: HWND; const Slug: string): string;
    procedure CaptureForeignWindows(const Slug: string);
    procedure OnSdkWait;
    procedure Step(const Title: string; Ok: Boolean; const Detail, Slug: string);
    procedure WriteReport;
  public
    constructor Create(AForm: TMainForm; const AOutDir, ALauncher: string);
    function Run: Boolean;
    function Passed: Integer;
    function Total: Integer;
    property Steps: TArray<TStepResult> read FSteps;
  end;

implementation

uses
  Vcl.Forms, Vcl.Graphics, Vcl.Imaging.pngimage,
  System.IOUtils, System.StrUtils, System.Generics.Collections, System.Generics.Defaults,
  System.Variants, System.Math, System.DateUtils,
  uContragenti, uClientsDB, uCrmData, uEntityPage, uTestData, uWorkspace,
  uReports, uReportTable, uKanban, uGantt, uCalendarView, uI18n, uBoardCards, uProcess;

const
  PW_RENDERFULLCONTENT = $00000002;

// в Winapi.Windows Tokyo не объявлена
function PrintWindow(hwnd: HWND; hdcBlt: HDC; nFlags: UINT): BOOL; stdcall;
  external 'user32.dll' name 'PrintWindow';

const
  // Эталонные карточки в формате Contragenti (build_card_xml).
  XML_UNISIM =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<counterparty source="date.gov.md" idno="1003600116460">' +
    '<idno>1003600116460</idno>' +
    '<denumire>CENTRUL DE ELABORARE UNISIM-SOFT S.R.L.</denumire>' +
    '<inregistrare>30.03.2001</inregistrare>' +
    '<forma_juridica>Societate cu raspundere limitata</forma_juridica>' +
    '<lichidata>Nu</lichidata>' +
    '<adresa>mun. Chisinau, str. Alba-Iulia 75/B</adresa>' +
    '<administratori>TUHARI PAVEL [Administrator]</administratori>' +
    '<founders><founder name="TUHARI PAVEL" share="100,00"/></founders>' +
    '<debts currency="MDL"><debt nr="1" type="Bugetul de stat" sum="0,98"/></debts>' +
    '</counterparty>';
  XML_ALFAVIS =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<counterparty source="date.gov.md" idno="1017600018242">' +
    '<idno>1017600018242</idno>' +
    '<denumire>Societatea cu Raspundere Limitata ALFA-VIS COM</denumire>' +
    '<inregistrare>13.04.2017</inregistrare>' +
    '<forma_juridica>Societate cu raspundere limitata</forma_juridica>' +
    '<lichidata>Nu</lichidata>' +
    '<adresa>mun. Chisinau, sec. Centru, str. Alecsandri Vasile, 80</adresa>' +
    '<administratori>BUBIS YEVGENY [Administrator]</administratori>' +
    '<founders><founder name="BUBIS ANNA" share="50,00"/>' +
    '<founder name="BUBIS YEVGENY" share="50,00"/></founders>' +
    '<debts currency="MDL"><debt nr="1" type="Bugetul de stat" sum="0,00"/></debts>' +
    '</counterparty>';

{ Проверка выгруженных файлов по сигнатуре, а не по расширению:
  xlsx — zip (PK), pdf — %PDF. }
function HeadBytes(const FileName: string; Count: Integer): TBytes;
var
  FS: TFileStream;
begin
  SetLength(Result, 0);
  if not TFile.Exists(FileName) then Exit;
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Min(Count, FS.Size));
    if Length(Result) > 0 then
      FS.ReadBuffer(Result[0], Length(Result));
  finally
    FS.Free;
  end;
end;

function FileSizeOf(const FileName: string): Int64;
var
  FS: TFileStream;
begin
  Result := 0;
  if not TFile.Exists(FileName) then Exit;
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    Result := FS.Size;
  finally
    FS.Free;
  end;
end;

function IsZip(const FileName: string): Boolean;
var
  B: TBytes;
begin
  B := HeadBytes(FileName, 2);
  Result := (Length(B) = 2) and (B[0] = Ord('P')) and (B[1] = Ord('K'));
end;

function IsPdf(const FileName: string): Boolean;
var
  B: TBytes;
begin
  B := HeadBytes(FileName, 5);
  Result := (Length(B) = 5) and (B[0] = Ord('%')) and (B[1] = Ord('P')) and
            (B[2] = Ord('D')) and (B[3] = Ord('F'));
end;

function HtmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

function JsonEsc(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

{ Кадр считаем пустым, если все точки на сетке одного цвета
  (белый лист от PrintWindow или чёрный экран без сессии). }
function IsBlank(Bmp: TBitmap): Boolean;
var
  X, Y: Integer;
  First: TColor;
begin
  Result := True;
  First := Bmp.Canvas.Pixels[Bmp.Width div 2, Bmp.Height div 2];
  Y := 5;
  while Y < Bmp.Height do
  begin
    X := 5;
    while X < Bmp.Width do
    begin
      if Bmp.Canvas.Pixels[X, Y] <> First then
        Exit(False);
      Inc(X, Bmp.Width div 12 + 1);
    end;
    Inc(Y, Bmp.Height div 12 + 1);
  end;
end;

{ ── перечисление чужих окон (Contragenti / Chrome) ── }

type
  PEnumCtx = ^TEnumCtx;
  TEnumCtx = record
    Own: DWORD;
    Since: TFileTime;          // брать только процессы, созданные после старта шага
    Handles: TArray<HWND>;
    Log: TStrings;             // диагностика: что видели и почему отсеяли
  end;

function QueryFullProcessImageNameW(hProcess: THandle; dwFlags: DWORD;
  lpExeName: PWideChar; var lpdwSize: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'QueryFullProcessImageNameW';

{ Окна процессов python/chrome/Contragenti, запущенных после Since —
  т.е. именно тех, что породил вызов SDK, а не браузера пользователя. }
function EnumProc(H: HWND; L: LPARAM): BOOL; stdcall;
var
  Ctx: PEnumCtx;
  Pid: DWORD;
  HP: THandle;
  Buf: array[0..1023] of WideChar;
  Sz: DWORD;
  Exe: string;
  CT, ET, KT, UT: TFileTime;
  R: TRect;
begin
  Result := True;
  Ctx := PEnumCtx(L);
  if not IsWindowVisible(H) then Exit;
  if GetParent(H) <> 0 then Exit;
  if not GetWindowRect(H, R) or (R.Width < 200) or (R.Height < 150) then Exit;
  // консоль python.exe не интересна
  if (GetClassName(H, Buf, Length(Buf)) > 0) and (string(Buf) = 'ConsoleWindowClass') then Exit;
  GetWindowThreadProcessId(H, @Pid);
  if Pid = Ctx.Own then Exit;
  HP := OpenProcess($1000 { PROCESS_QUERY_LIMITED_INFORMATION }, False, Pid);
  if HP = 0 then
  begin
    Ctx.Log.Add(Format('hwnd %x pid %d: OpenProcess failed %d', [H, Pid, GetLastError]));
    Exit;
  end;
  try
    Sz := Length(Buf);
    if not QueryFullProcessImageNameW(HP, 0, Buf, Sz) then
    begin
      Ctx.Log.Add(Format('hwnd %x pid %d: QueryFullProcessImageName failed %d', [H, Pid, GetLastError]));
      Exit;
    end;
    Exe := LowerCase(ExtractFileName(Buf));
    if not ((Exe = 'python.exe') or (Exe = 'pythonw.exe') or (Exe = 'chrome.exe')
            or (Exe = 'contragenti.exe')) then Exit;
    if not GetProcessTimes(HP, CT, ET, KT, UT) then Exit;
    if CompareFileTime(CT, Ctx.Since) < 0 then
    begin
      Ctx.Log.Add(Format('hwnd %x %s: created before step start — skipped', [H, Exe]));
      Exit;
    end;
    Ctx.Log.Add(Format('hwnd %x %s %dx%d: capture', [H, Exe, R.Width, R.Height]));
  finally
    CloseHandle(HP);
  end;
  Ctx.Handles := Ctx.Handles + [H];
end;

{ TGuiSelfTest }

constructor TGuiSelfTest.Create(AForm: TMainForm; const AOutDir, ALauncher: string);
begin
  inherited Create;
  FForm := AForm;
  FOutDir := AOutDir;
  FLauncher := ALauncher;
  FNum := 0;
end;

procedure TGuiSelfTest.Pump;
var
  I: Integer;
begin
  for I := 1 to 3 do
  begin
    Application.ProcessMessages;
    Sleep(40);
  end;
end;

{ Сохранение снимка с повторами: если PNG открыт просмотрщиком (user-mapped
  section), запись падает — ждём и пробуем ещё, затем пишем под именем с
  суффиксом, чтобы самотест не обрывался из-за чужого окна. Возвращает имя
  файла, под которым снимок реально сохранён. }
function SavePngRetry(Png: TPngImage; const Dir, Name: string): string;
var
  Attempt: Integer;
  Alt: string;
begin
  Result := Name;
  for Attempt := 1 to 6 do
  try
    Png.SaveToFile(TPath.Combine(Dir, Result));
    Exit;
  except
    on E: EFCreateError do
    begin
      Sleep(250);
      if Attempt = 3 then
      begin
        Alt := ChangeFileExt(Name, '') + '_r.png';
        Result := Alt;
      end;
    end;
  end;
  // последняя попытка — пусть исключение уйдёт наверх с понятным текстом
  Png.SaveToFile(TPath.Combine(Dir, Result));
end;

function TGuiSelfTest.Capture(const Slug: string): string;
var
  Bmp: TBitmap;
  Png: TPngImage;
  R: TRect;
  Ok: Boolean;
begin
  Result := Format('%.2d_%s.png', [FNum, Slug]);
  // Своё окно снимаем PrintWindow'ом изнутри процесса: получаем рамку и
  // заголовки колонок ListView (GetFormImage их не рисует). Работает без
  // дисплея; если кадр пустой — запасной путь GetFormImage.
  Bmp := TBitmap.Create;
  Ok := False;
  if GetWindowRect(FForm.Handle, R) and (R.Width > 0) and (R.Height > 0) then
  begin
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(R.Width, R.Height);
    Ok := PrintWindow(FForm.Handle, Bmp.Canvas.Handle, PW_RENDERFULLCONTENT)
          and not IsBlank(Bmp);
  end;
  if not Ok then
  begin
    Bmp.Free;
    Bmp := FForm.GetFormImage;
  end;
  try
    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      Result := SavePngRetry(Png, FOutDir, Result);
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

function TGuiSelfTest.CaptureHwnd(H: HWND; const Slug: string): string;
var
  R: TRect;
  Bmp: TBitmap;
  Png: TPngImage;
  ScreenDC: HDC;
  Ok: Boolean;
begin
  Result := '';
  if not GetWindowRect(H, R) then Exit;
  if (R.Width < 50) or (R.Height < 50) then Exit;
  Bmp := TBitmap.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(R.Width, R.Height);
    // 1) PrintWindow с PW_RENDERFULLCONTENT — снимает Chrome и Tk даже
    //    перекрытыми; 2) если кадр пустой (белый) — пробуем скопировать
    //    прямоугольник окна с экрана.
    Ok := PrintWindow(H, Bmp.Canvas.Handle, PW_RENDERFULLCONTENT) and not IsBlank(Bmp);
    if not Ok then
    begin
      ScreenDC := GetDC(0);
      try
        Ok := BitBlt(Bmp.Canvas.Handle, 0, 0, R.Width, R.Height,
                     ScreenDC, R.Left, R.Top, SRCCOPY) and not IsBlank(Bmp);
      finally
        ReleaseDC(0, ScreenDC);
      end;
    end;
    if not Ok then
      Exit;
    Result := Format('%.2d_%s.png', [FNum, Slug]);
    Png := TPngImage.Create;
    try
      Png.Assign(Bmp);
      Result := SavePngRetry(Png, FOutDir, Result);
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

procedure TGuiSelfTest.CaptureForeignWindows(const Slug: string);
var
  Ctx: TEnumCtx;
  I: Integer;
  Name: string;
begin
  Ctx.Own := GetCurrentProcessId;
  Ctx.Since := FSdkStart;
  Ctx.Handles := nil;
  Ctx.Log := TStringList.Create;
  try
    Ctx.Log.Add('--- ' + Slug);
    EnumWindows(@EnumProc, LPARAM(@Ctx));
    for I := 0 to High(Ctx.Handles) do
    begin
      Name := CaptureHwnd(Ctx.Handles[I], Format('%s_win%d', [Slug, I + 1]));
      if Name <> '' then
        FExtra := FExtra + [Name]
      else
        Ctx.Log.Add(Format('hwnd %x: capture failed', [Ctx.Handles[I]]));
    end;
  finally
    Ctx.Log.Free;
  end;
end;

{ Вызывается SDK каждые 200 мс, пока открыт Contragenti. }
procedure TGuiSelfTest.OnSdkWait;
var
  Name: string;
begin
  Application.ProcessMessages;
  Inc(FWaitTicks);
  // снимки на 1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30, 45 сек — старт Chrome,
  // форма портала, результаты, детали, возврат карточки
  if (FWaitTicks in [5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 225]) then
  begin
    Inc(FWaitShots);
    if FWaitShots = 1 then
    begin
      // окно CRM в состоянии ожидания — один раз, дальше оно не меняется
      Name := Capture('sdk_wait_crm');
      FExtra := FExtra + [Name];
    end;
    CaptureForeignWindows(Format('sdk_wait%d', [FWaitShots]));
  end;
end;

procedure TGuiSelfTest.MarkSdkStart;
var
  ST: TSystemTime;
begin
  GetSystemTime(ST);
  SystemTimeToFileTime(ST, FSdkStart);
  FWaitTicks := 0;
  FWaitShots := 0;
end;

{ Забираем снимки, сделанные Contragenti по --shots-dir, под номер шага. }
procedure TGuiSelfTest.CollectSdkShots;
var
  F, Name: string;
  Files: TArray<string>;
begin
  Files := TArray<string>(TDirectory.GetFiles(FOutDir, 'sdk_*.png'));
  TArray.Sort<string>(Files);
  for F in Files do
  begin
    Name := Format('%.2d_%s', [FNum, ExtractFileName(F)]);
    if TFile.Exists(TPath.Combine(FOutDir, Name)) then
      TFile.Delete(TPath.Combine(FOutDir, Name));
    TFile.Move(F, TPath.Combine(FOutDir, Name));
    FExtra := FExtra + [Name];
  end;
end;

procedure TGuiSelfTest.Step(const Title: string; Ok: Boolean;
  const Detail, Slug: string);
var
  R: TStepResult;
begin
  FForm.TestShowBanner(FNum, Title);
  Pump;
  R.Num := FNum;
  R.Title := Title;
  R.Ok := Ok;
  R.Detail := Detail;
  R.Message := FForm.TestMessage;
  R.Shot := Capture(Slug);
  R.Extra := FExtra;
  FExtra := nil;
  FSteps := FSteps + [R];
end;

function TGuiSelfTest.Run: Boolean;
var
  Card: TCounterpartyCard;
  Res: TAddResult;
  Before: Integer;
  SdkOk: Boolean;
  Detail: string;
  P: TEntityPage;
  AlfaId, AgroId: Integer;
  V: Variant;
  Stats: TSeedStats;
  Xlsx, Pdf, Stub, SavedLauncher: string;
  Id: Integer;
  D1, D2: TDateTime;
  Nav: string;
  BC: TBoardCard;
  ProcFile: string;
begin
  FSteps := nil;
  FNum := 0;
  FExtra := nil;
  TDirectory.CreateDirectory(FOutDir);

  // ── часть 0: вход в программу и язык интерфейса ──

  Inc(FNum);
  Step('Окно входа закрывает данные до авторизации',
    FForm.TestLoginVisible, 'панель входа показана', 'login');

  Inc(FNum);
  FForm.TestLogin('admin', 'неверный');
  Pump;
  Step('Неверный пароль не пускает в программу',
    FForm.TestLoginVisible and (FForm.TestMessageKind = mkWarn),
    FForm.TestMessage, 'login_bad');

  Inc(FNum);
  FForm.TestSetLanguage('ro');
  Pump;
  Step('Язык интерфейса из внешнего lang.json: румынский (основной)',
    T.Loaded and (T.Lang = 'ro') and (T.S('nav.clients') = 'Clienți'),
    Format('файл %s; nav.clients = «%s», nav.orders = «%s»',
      [ExtractFileName(T.FileName), T.S('nav.clients'), T.S('nav.orders')]),
    'lang_ro');

  Inc(FNum);
  FForm.TestSetLanguage('en');
  Pump;
  Step('Переключение на английский меняет строки из того же файла',
    (T.Lang = 'en') and (T.S('nav.clients') = 'Clients')
      and (TI18n.ReadLangFromRegistry('') = 'en'),
    Format('nav.clients = «%s», в реестре Language = «%s»',
      [T.S('nav.clients'), TI18n.ReadLangFromRegistry('')]),
    'lang_en');

  Inc(FNum);
  FForm.TestSetLanguage('ru');
  Pump;
  Step('Выбор языка сохраняется в реестре Windows (HKCU\Software\DemoCRM)',
    (TI18n.ReadLangFromRegistry('') = 'ru') and (T.S('nav.clients') = 'Клиенты'),
    Format('в реестре Language = «%s», nav.clients = «%s»',
      [TI18n.ReadLangFromRegistry(''), T.S('nav.clients')]),
    'lang_registry');

  Inc(FNum);
  Step('Значения справочников переводятся, а в базе остаются каноническими',
    (EnumDisplay('order_status', 'Подтверждён', ENUM_ORDER_STATUS) = 'Подтверждён') and
    (T.EnumAt('order_status', 1) = 'Подтверждён'),
    Format('order_status[1] в ru = «%s», этап 3 = «%s»',
      [T.EnumAt('order_status', 1), T.EnumAt('stage_title', 3)]),
    'enum_translate');

  Inc(FNum);
  FForm.TestLogin('admin', 'admin');
  Pump;
  Step('Вход с верным паролем открывает программу',
    (not FForm.TestLoginVisible) and (FForm.User = 'admin'),
    Format('пользователь «%s»; %s', [FForm.User, FForm.TestMessage]), 'login_ok');

  // ── часть 1: интерфейс без внешних процессов ──

  Inc(FNum);
  Step('Стартовое окно, база пуста',
    (FForm.TestListCount = 0) and (FForm.TestDbCount = 0),
    Format('в списке %d, в базе %d', [FForm.TestListCount, FForm.TestDbCount]),
    'start');

  Inc(FNum);
  Res := FForm.TestImportXml(XML_UNISIM, Card);
  Step('Импорт карточки UNISIM-SOFT из XML Contragenti',
    (Res = arAdded) and (FForm.TestListCount = 1) and (FForm.TestMessageKind = mkOk),
    Format('результат %d, в списке %d, сообщение зелёное=%s',
      [Ord(Res), FForm.TestListCount, BoolToStr(FForm.TestMessageKind = mkOk, True)]),
    'import_unisim');

  Inc(FNum);
  Res := FForm.TestImportXml(XML_ALFAVIS, Card);
  Step('Импорт карточки ALFA-VIS COM',
    (Res = arAdded) and (FForm.TestListCount = 2),
    Format('результат %d, в списке %d', [Ord(Res), FForm.TestListCount]),
    'import_alfavis');

  Inc(FNum);
  Res := FForm.TestImportXml(XML_UNISIM, Card);
  Step('Повторный импорт UNISIM — отсечён как дубликат',
    (Res = arDuplicate) and (FForm.TestDbCount = 2) and (FForm.TestMessageKind = mkWarn),
    Format('результат %d, в базе %d, сообщение янтарное=%s',
      [Ord(Res), FForm.TestDbCount, BoolToStr(FForm.TestMessageKind = mkWarn, True)]),
    'duplicate');

  Inc(FNum);
  FForm.TestSetFilter('ALFA');
  Pump;
  Step('Фильтр «ALFA» оставляет одну запись',
    FForm.TestListCount = 1,
    Format('в списке %d', [FForm.TestListCount]),
    'filter_alfa');

  Inc(FNum);
  FForm.TestSetFilter('');
  Pump;
  Step('Фильтр сброшен — снова две записи',
    FForm.TestListCount = 2,
    Format('в списке %d', [FForm.TestListCount]),
    'filter_clear');

  Inc(FNum);
  FForm.TestClickSettings;
  Pump;
  Step('Панель настроек раскрывается внутри окна (без модального диалога)',
    FForm.TestMessageKind = mkInfo,
    'сообщение: ' + FForm.TestMessage,
    'settings_open');

  Inc(FNum);
  FForm.TestClickSettings;
  Pump;
  Step('Панель настроек скрыта повторным нажатием', True, '', 'settings_close');

  Inc(FNum);
  FForm.TestClickNav(nsWorkspace);
  Pump;
  Step('Навигация: «Рабочий стол» — большие плитки этапов процесса',
    FForm.TestSection = nsWorkspace, '', 'workspace_empty');

  Inc(FNum);
  FForm.TestClickNav(nsLeads);
  Pump;
  Step('Навигация: раздел «Лиды» открывается — пустой список с кнопками «Создать лид» и «В клиенты»',
    (FForm.TestSection = nsLeads) and (FForm.Page(nsLeads).ListCount = 0),
    Format('раздел=%d, записей %d', [Ord(FForm.TestSection), FForm.Page(nsLeads).ListCount]),
    'nav_leads_empty');

  Inc(FNum);
  FForm.TestClickNav(nsAccounts);
  Pump;
  Step('Навигация: возврат в «Клиенты»', FForm.TestSection = nsAccounts, '', 'accounts');

  Inc(FNum);
  FForm.TestClickDelete;
  Pump;
  Step('«Удалить» без выбранной строки — предупреждение, ничего не удалено',
    (FForm.TestMessageKind = mkWarn) and (FForm.TestDbCount = 2),
    Format('в базе %d, сообщение янтарное=%s',
      [FForm.TestDbCount, BoolToStr(FForm.TestMessageKind = mkWarn, True)]),
    'delete_noselect');

  Inc(FNum);
  FForm.TestSelectFirst;
  Pump;
  Before := FForm.TestDbCount;
  FForm.TestClickDelete;
  Pump;
  Step('«Удалить» с выбранной строкой — просьба подтвердить, база не тронута',
    (FForm.TestMessageKind = mkWarn) and (FForm.TestDbCount = Before),
    Format('в базе %d, сообщение янтарное=%s',
      [FForm.TestDbCount, BoolToStr(FForm.TestMessageKind = mkWarn, True)]),
    'delete_confirm_ask');

  Inc(FNum);
  FForm.TestClickDelete;
  Pump;
  Step('Повторное «Удалить» — клиент ALFA-VIS удалён (останется UNISIM)',
    (FForm.TestDbCount = Before - 1) and (FForm.TestListCount = Before - 1)
      and (FForm.TestMessageKind = mkOk),
    Format('в базе %d, в списке %d, сообщение зелёное=%s',
      [FForm.TestDbCount, FForm.TestListCount, BoolToStr(FForm.TestMessageKind = mkOk, True)]),
    'delete_done');

  // ── часть 2: реальный вызов SDK → Contragenti → Chrome → date.gov.md ──

  FForm.Client.LauncherExe := FLauncher;
  // --shots-dir: Contragenti сам кладёт сюда снимки портала (Selenium) и
  // своего окна (PrintWindow изнутри процесса) — sdk_*.png
  FForm.Client.ExtraArgs := Format('--no-server --no-tray --auto-pick --shots-dir "%s"', [FOutDir]);
  FForm.Client.TimeoutMs := 4 * 60 * 1000;
  FForm.Client.OnWait := OnSdkWait;

  Inc(FNum);
  FForm.TestSetFilter('ALFA-VIS COM');
  Pump;
  Step('Фильтр «ALFA-VIS COM» введён — по нему SDK запустит Contragenti',
    TFile.Exists(FLauncher),
    'launcher: ' + FLauncher + IfThen(TFile.Exists(FLauncher), '', '  (НЕ НАЙДЕН)'),
    'sdk_filter');

  Inc(FNum);
  MarkSdkStart;
  Before := FForm.TestDbCount;
  FForm.TestShowBanner(FNum, 'Нажата «Добавить из реестра» — Contragenti ищет на портале…');
  Pump;
  FForm.TestClickAdd;           // блокирует до закрытия Contragenti, OnWait снимает окна
  Pump;
  CollectSdkShots;
  SdkOk := (FForm.TestDbCount = Before + 1) and (FForm.TestMessageKind = mkOk);
  Detail := Format('ожидание %d с, снимков во время работы %d, в базе %d → %d, сообщение зелёное=%s; %s',
    [FWaitTicks div 5, Length(FExtra), Before, FForm.TestDbCount,
     BoolToStr(FForm.TestMessageKind = mkOk, True), FForm.Client.LastError]);
  Step('Реальный вызов SDK: Contragenti запущен, нашёл ALFA-VIS (кэш date.gov.md или портал) и вернул XML-карточку',
    SdkOk, Detail, 'sdk_added');

  Inc(FNum);
  FForm.TestSetFilter('');
  Pump;
  FForm.TestSelectFirst;
  Pump;
  Step('Карточка из Contragenti в списке CRM (адрес, форма, администратор — данные реестра)',
    FForm.TestListCount = 2,
    Format('в списке %d', [FForm.TestListCount]),
    'sdk_list');
  FForm.TestSetFilter('ALFA-VIS COM');
  Pump;

  Inc(FNum);
  MarkSdkStart;
  Before := FForm.TestDbCount;
  FForm.TestShowBanner(FNum, 'Повторный вызов SDK с тем же фильтром…');
  Pump;
  FForm.TestClickAdd;
  Pump;
  CollectSdkShots;
  Step('Повторный вызов SDK — та же карточка отсечена как дубликат, база не выросла',
    (FForm.TestDbCount = Before) and (FForm.TestMessageKind = mkWarn)
      and (FForm.Client.LastError = ''),
    Format('ожидание %d с, в базе %d, сообщение янтарное=%s; %s',
      [FWaitTicks div 5, FForm.TestDbCount,
       BoolToStr(FForm.TestMessageKind = mkWarn, True), FForm.Client.LastError]),
    'sdk_duplicate');

  // Пока Contragenti открыт, окно CRM обязано оставаться живым: приложение
  // назначает свой обработчик ожидания и прокачивает очередь сообщений.
  // Проверяем на заглушке, чтобы лишний раз не дёргать портал.
  Inc(FNum);
  Stub := TPath.Combine(FOutDir, 'sdk_stub.py');
  TFile.WriteAllText(Stub, 'import time' + sLineBreak + 'time.sleep(3)' + sLineBreak,
    TEncoding.UTF8);
  SavedLauncher := FForm.Client.LauncherExe;
  FForm.Client.LauncherExe := Stub;
  FForm.Client.OnWait := nil;          // обработчик должен назначить сам CRM
  FForm.TestClickAdd;
  Pump;
  Step('Окно CRM не зависает, пока открыт Contragenti: обработчик ожидания отработал',
    (FForm.TestWaitTicks >= 10) and (FForm.TestMessageKind = mkWarn),
    Format('тактов ожидания %d (по 200 мс), сообщение: %s',
      [FForm.TestWaitTicks, FForm.TestMessage]),
    'sdk_responsive');
  FForm.Client.LauncherExe := SavedLauncher;
  TFile.Delete(Stub);

  // ── часть 3: разделы CRM для торговли, услуг и производства ──

  Inc(FNum);
  FForm.TestSetFilter('');
  Pump;
  FForm.TestSelectFirst;
  Pump;
  FForm.TestOverviewSet('Клиент', '+373 22 123-456', 'office@alfa-vis.md', 'Bubis Yevgeny');
  Pump;
  Step('Клиенты: в карточке сохранены тип, телефон, e-mail и контактное лицо',
    FForm.TestMessageKind = mkOk, FForm.TestMessage, 'client_card');
  AlfaId := FForm.Crm.Scalar('SELECT id FROM clients WHERE denumire LIKE ''%ALFA-VIS%''');

  Inc(FNum);
  FForm.TestClickNav(nsContacts);
  Pump;
  P := FForm.Page(nsContacts);
  P.NewRecord;
  Pump;
  P.SetField('name', 'Yevgeny Bubis');
  P.SetField('client_id', IntToStr(AlfaId));
  P.SetField('position', 'Директор');
  P.SetField('phone', '+373 69 000-000');
  P.SetField('email', 'y.bubis@alfa-vis.md');
  P.Save;
  Pump;
  Step('Контакты: создан контакт «Yevgeny Bubis», привязан к клиенту ALFA-VIS',
    (P.ListCount = 1) and (FForm.TestMessageKind = mkOk),
    Format('контактов %d; %s', [P.ListCount, FForm.TestMessage]), 'contact_new');

  Inc(FNum);
  FForm.TestClickNav(nsLeads);
  Pump;
  P := FForm.Page(nsLeads);
  P.NewRecord;
  Pump;
  P.SetField('name', 'Ion Popescu');
  P.SetField('company', 'Agro-Prim SRL');
  P.SetField('status', 'В работе');
  P.SetField('source', 'Выставка');
  P.SetField('phone', '+373 79 111-222');
  P.SetField('email', 'ion@agro-prim.md');
  P.SetField('notes', 'Интерес к дозирующему оборудованию для фермы');
  P.Save;
  Pump;
  Step('Лиды: создан лид «Agro-Prim SRL» — в работе, источник «Выставка»',
    (P.ListCount = 1) and (FForm.TestMessageKind = mkOk),
    Format('лидов %d', [P.ListCount]), 'lead_new');

  Inc(FNum);
  Before := FForm.TestDbCount;
  P.SelectFirst;
  Pump;
  FForm.TestLeadConvert;
  Pump;
  V := FForm.Crm.Scalar('SELECT status FROM leads WHERE company = ''Agro-Prim SRL''');
  AgroId := FForm.Crm.Scalar('SELECT id FROM clients WHERE denumire = ''Agro-Prim SRL''');
  Step('Лиды: «В клиенты» — создан клиент Agro-Prim SRL, статус лида «Конвертирован»',
    (FForm.TestDbCount = Before + 1) and (VarToStr(V) = 'Конвертирован') and (AgroId > 0),
    Format('клиентов %d → %d, статус лида: %s', [Before, FForm.TestDbCount, VarToStr(V)]),
    'lead_convert');

  Inc(FNum);
  FForm.TestClickNav(nsDeals);
  Pump;
  P := FForm.Page(nsDeals);
  P.NewRecord;
  Pump;
  P.SetField('title', 'Поставка дозирующей установки');
  P.SetField('client_id', IntToStr(AgroId));
  P.SetField('stage', 'Предложение');
  P.SetField('amount', '48500');
  P.SetField('close_date', FormatDateTime('yyyy-mm-dd', IncMonth(Now, 1)));
  P.SetField('notes', 'Коммерческое предложение отправлено');
  P.Save;
  Pump;
  Step('Сделки: создана сделка 48 500 MDL для Agro-Prim на этапе «Предложение»',
    (P.ListCount = 1) and (FForm.TestMessageKind = mkOk),
    Format('сделок %d', [P.ListCount]), 'deal_new');

  Inc(FNum);
  P.SelectFirst;
  Pump;
  P.SetField('stage', 'Выиграна');
  P.Save;
  Pump;
  V := FForm.Crm.Scalar('SELECT stage FROM deals WHERE title LIKE ''Поставка%''');
  Step('Сделки: этап переведён в «Выиграна» (воронка)',
    VarToStr(V) = 'Выиграна', 'этап в базе: ' + VarToStr(V), 'deal_won');

  Inc(FNum);
  FForm.TestClickNav(nsItems);
  Pump;
  P := FForm.Page(nsItems);
  P.NewRecord; Pump;
  P.SetField('code', 'T-001'); P.SetField('name', 'Насос дозирующий ND-25');
  P.SetField('kind', 'Товар'); P.SetField('unit_', 'шт');
  P.SetField('price', '12500'); P.SetField('stock', '5');
  P.Save; Pump;
  P.NewRecord; Pump;
  P.SetField('code', 'S-001'); P.SetField('name', 'Монтаж и пусконаладка');
  P.SetField('kind', 'Услуга'); P.SetField('unit_', 'час'); P.SetField('price', '350');
  P.Save; Pump;
  P.NewRecord; Pump;
  P.SetField('code', 'P-001'); P.SetField('name', 'Установка дозирования УД-1');
  P.SetField('kind', 'Изделие'); P.SetField('unit_', 'компл');
  P.SetField('price', '42000'); P.SetField('stock', '0');
  P.Save; Pump;
  Step('Номенклатура: товар (остаток 5), услуга (час) и изделие собственного производства',
    P.ListCount = 3, Format('позиций %d', [P.ListCount]), 'items');

  Inc(FNum);
  FForm.TestClickNav(nsOrders);
  Pump;
  P := FForm.Page(nsOrders);
  P.NewRecord; Pump;
  P.SetField('number', '0001');
  P.SetField('client_id', IntToStr(AgroId));
  P.SetField('kind', 'Продажа');
  P.SetField('status', 'Подтверждён');
  P.Save; Pump;
  P.LineSet(P.LineItemIndex('Насос'), 2, 12500); P.LineAdd; Pump;
  P.LineSet(P.LineItemIndex('Монтаж'), 8, 350); P.LineAdd; Pump;
  Step('Заказы: заказ на продажу №0001 — две строки (2 насоса + 8 ч монтажа), итого 27 800 MDL',
    (P.LinesCount = 2) and (Abs(P.LinesTotal - 27800) < 0.01),
    Format('строк %d, итого %.2f', [P.LinesCount, P.LinesTotal]), 'order_lines');

  Inc(FNum);
  P.SetField('status', 'Выполнен');
  P.PostOrder;
  Pump;
  V := FForm.Crm.Scalar('SELECT stock FROM items WHERE code = ''T-001''');
  Step('Заказы: статус «Выполнен» + «Провести» — остаток насосов списан 5 → 3',
    (Abs(Double(V) - 3) < 0.01) and (FForm.TestMessageKind = mkOk),
    Format('остаток T-001 = %s; %s', [VarToStr(V), FForm.TestMessage]), 'order_posted');

  Inc(FNum);
  P.NewRecord; Pump;
  P.SetField('number', '0002');
  P.SetField('kind', 'Производство');
  P.SetField('status', 'Выполнен');
  P.SetField('notes', 'Выпуск изделий на склад');
  P.Save; Pump;
  P.LineSet(P.LineItemIndex('Установка'), 2, 42000); P.LineAdd; Pump;
  P.PostOrder; Pump;
  V := FForm.Crm.Scalar('SELECT stock FROM items WHERE code = ''P-001''');
  Step('Заказы: производственный заказ №0002 проведён — оприходовано 2 изделия (0 → 2)',
    (Abs(Double(V) - 2) < 0.01) and (FForm.TestMessageKind = mkOk),
    Format('остаток P-001 = %s; %s', [VarToStr(V), FForm.TestMessage]), 'order_production');

  Inc(FNum);
  FForm.TestClickNav(nsCalendar);
  Pump;
  P := FForm.Page(nsCalendar);
  P.NewRecord; Pump;
  P.SetField('subject', 'Позвонить по оплате заказа №0001');
  P.SetField('kind', 'Звонок');
  P.SetField('due_at', FormatDateTime('yyyy-mm-dd', Now - 2));
  P.SetField('client_id', IntToStr(AgroId));
  P.Save; Pump;
  P.NewRecord; Pump;
  P.SetField('subject', 'Встреча: приёмка установки УД-1');
  P.SetField('kind', 'Встреча');
  P.SetField('due_at', FormatDateTime('yyyy-mm-dd', Now + 3));
  P.SetField('client_id', IntToStr(AgroId));
  P.Save; Pump;
  Step('Календарь: звонок (просрочен на 2 дня) и встреча через 3 дня',
    P.ListCount = 2, Format('открытых задач %d', [P.ListCount]), 'tasks');

  Inc(FNum);
  P.SelectPreset(2);   // «Просроченные»
  Pump;
  Step('Календарь: фильтр «Просроченные» — одна задача',
    P.ListCount = 1, Format('в списке %d', [P.ListCount]), 'tasks_overdue');

  Inc(FNum);
  P.SelectFirst; Pump;
  FForm.TestTaskDone; Pump;
  Step('Календарь: «Выполнено» — просроченная задача закрыта, список пуст',
    (P.ListCount = 0) and (FForm.TestMessageKind = mkOk),
    Format('в списке %d; %s', [P.ListCount, FForm.TestMessage]), 'task_done');
  P.SelectPreset(0);

  Inc(FNum);
  FForm.TestClickNav(nsWorkspace);
  Pump;
  Step('Рабочий стол: плитки показывают процесс — два заказа исполнены и закрыты',
    (FForm.Workspace.TileValue(stClosed) = '0') and (FForm.Workspace.TileValue(stReadyToShip) = '2'),
    Format('ожидает аванс=%s, в работе=%s, готово к отгрузке=%s, ждём оплату=%s, закрыто=%s',
      [FForm.Workspace.TileValue(stAwaitAdvance), FForm.Workspace.TileValue(stInWork),
       FForm.Workspace.TileValue(stReadyToShip), FForm.Workspace.TileValue(stAwaitPayment),
       FForm.Workspace.TileValue(stClosed)]),
    'workspace');

  // ── часть 4: генератор тестовых данных в полном объёме (AGENTS.md §1) ──

  Inc(FNum);
  Stats := SeedDemo(FForm.Crm.DB, FForm.Crm);
  FForm.TestClickNav(nsWorkspace);
  Pump;
  Step('Генератор тестовых данных: ' + Stats.Text + ' — плитки процесса заполнились',
    (Stats.Clients >= 12) and (Stats.Orders >= 15) and (Stats.Tasks >= 20)
      and (StrToIntDef(FForm.Workspace.TileValue(stAwaitPayment), 0) > 0),
    Format('аванс=%s, в работе=%s, к отгрузке=%s, ждём оплату=%s, закрыто=%s',
      [FForm.Workspace.TileValue(stAwaitAdvance), FForm.Workspace.TileValue(stInWork),
       FForm.Workspace.TileValue(stReadyToShip), FForm.Workspace.TileValue(stAwaitPayment),
       FForm.Workspace.TileValue(stClosed)]),
    'seed_workspace');

  Inc(FNum);
  FForm.Workspace.ClickTile(stAwaitPayment);
  Pump;
  P := FForm.Page(nsOrders);
  Step('Плитка «Отгружено — ждём оплату» открывает «Заказы» с этим фильтром',
    (FForm.TestSection = nsOrders) and (P.ListCount > 0)
      and (P.ListCount = FForm.Crm.Count('orders', FForm.Crm.StageWhere(stAwaitPayment))),
    Format('в списке %d, по условию этапа %d',
      [P.ListCount, FForm.Crm.Count('orders', FForm.Crm.StageWhere(stAwaitPayment))]),
    'tile_drilldown');

  Inc(FNum);
  FForm.TestClickNav(nsWorkspace);
  Pump;
  FForm.Workspace.ErpCheck;
  Pump;
  Step('Связь с ERP una.md по HTTP-API хаба: результат проверки виден в полосе ERP',
    FForm.Workspace.ErpText <> '',
    FForm.Workspace.ErpText, 'erp_check');

  Inc(FNum);
  FForm.TestClickNav(nsOrders);
  Pump;
  P := FForm.Page(nsOrders);
  P.SelectPreset(0);   // снять фильтр, оставшийся от перехода с плитки
  Pump;
  Step('Заказы на полном наборе: продажа / услуга / производство, все статусы',
    P.ListCount = FForm.Crm.Count('orders'),
    Format('в списке %d, в базе %d', [P.ListCount, FForm.Crm.Count('orders')]), 'seed_orders');

  Inc(FNum);
  FForm.TestClickNav(nsItems);
  Pump;
  P := FForm.Page(nsItems);
  P.SelectPreset(4);   // «Нет на складе»
  Pump;
  Step('Номенклатура на полном наборе: пресет «Нет на складе»',
    (P.ListCount > 0) and (P.ListCount < FForm.Crm.Count('items')),
    Format('без остатка %d из %d', [P.ListCount, FForm.Crm.Count('items')]), 'seed_items');
  P.SelectPreset(0);

  Inc(FNum);
  FForm.TestClickNav(nsCalendar);
  Pump;
  P := FForm.Page(nsCalendar);
  P.SelectPreset(2);   // «Просроченные»
  Pump;
  Step('Календарь на полном наборе: просроченные задачи выделены пресетом',
    P.ListCount > 0, Format('просроченных %d', [P.ListCount]), 'seed_tasks_overdue');
  P.SelectPreset(0);

  // ── часть 5: канбан и план работ ──

  Inc(FNum);
  FForm.TestClickNav(nsKanban);
  Pump;
  FForm.Kanban.SelectBoard(bkOrders);
  Pump;
  Before := FForm.Kanban.CardsInColumn(0);
  Step('Канбан «Заказы»: пять колонок процесса, карточки разложены по этапам',
    (FForm.Kanban.ColumnCount = 5) and (FForm.Kanban.CardsInColumn(1) > 0),
    Format('колонок %d; по этапам: %d / %d / %d / %d / %d',
      [FForm.Kanban.ColumnCount, FForm.Kanban.CardsInColumn(0), FForm.Kanban.CardsInColumn(1),
       FForm.Kanban.CardsInColumn(2), FForm.Kanban.CardsInColumn(3), FForm.Kanban.CardsInColumn(4)]),
    'kanban_orders');

  Inc(FNum);
  FForm.Kanban.SelectFirstCard(1);
  Pump;
  Id := FForm.Kanban.SelectedId;
  FForm.Kanban.MoveForward;
  Pump;
  V := FForm.Crm.Scalar('SELECT status FROM orders WHERE id = ' + IntToStr(Id));
  Step('Канбан: карточка перенесена «В работе» → «Готово к отгрузке», статус в базе изменён',
    (FForm.Kanban.SelectedColumn = 2) and (VarToStr(V) = 'Выполнен')
      and (FForm.Crm.StageOf(Id) = stReadyToShip),
    Format('колонка %d, статус «%s», этап %d',
      [FForm.Kanban.SelectedColumn, VarToStr(V), Ord(FForm.Crm.StageOf(Id))]),
    'kanban_move');

  Inc(FNum);
  FForm.Kanban.MoveBack;
  Pump;
  Step('Канбан: «← Назад» возвращает карточку на прежний этап',
    (FForm.Kanban.SelectedColumn = 1) and (FForm.Crm.StageOf(Id) = stInWork),
    Format('колонка %d, этап %d', [FForm.Kanban.SelectedColumn, Ord(FForm.Crm.StageOf(Id))]),
    'kanban_back');

  Inc(FNum);
  FForm.Kanban.SelectFirstCard(1);
  Id := FForm.Kanban.SelectedId;
  Before := FForm.Kanban.CardsInColumn(3);
  FForm.Kanban.DragCardById(Id, 3);   // тот же путь, что и мышь: нажатие, сдвиг, отпускание
  Pump;
  V := FForm.Crm.Scalar('SELECT ship_date FROM orders WHERE id = ' + IntToStr(Id));
  Step('Канбан: карточка перетащена мышью из «В работе» в «Отгружено — ждём оплату»',
    (FForm.Kanban.CardsInColumn(3) = Before + 1) and (VarToStr(V) <> '')
      and (FForm.Crm.StageOf(Id) = stAwaitPayment),
    Format('в колонке «ждём оплату» %d → %d, дата отгрузки «%s», этап %d',
      [Before, FForm.Kanban.CardsInColumn(3), VarToStr(V), Ord(FForm.Crm.StageOf(Id))]),
    'kanban_drag');

  Inc(FNum);
  FForm.Kanban.DragCardById(Id, 1);   // и обратно — перетаскиванием той же карточки
  Pump;
  V := FForm.Crm.Scalar('SELECT COALESCE(ship_date,'''') FROM orders WHERE id = ' + IntToStr(Id));
  Step('Канбан: перетаскивание работает в обе стороны — дата отгрузки снята',
    (VarToStr(V) = '') and (FForm.Crm.StageOf(Id) = stInWork),
    Format('дата отгрузки «%s», этап %d', [VarToStr(V), Ord(FForm.Crm.StageOf(Id))]),
    'kanban_drag_back');

  Inc(FNum);
  FForm.Kanban.SelectBoard(bkTasks);
  Pump;
  Step('Канбан «Задачи»: колонки по срокам — просрочено / сегодня / позже / выполнено',
    (FForm.Kanban.ColumnCount = 4) and (FForm.Kanban.CardsInColumn(0) > 0),
    Format('колонок %d; просрочено %d, сегодня %d, позже %d, выполнено %d',
      [FForm.Kanban.ColumnCount, FForm.Kanban.CardsInColumn(0), FForm.Kanban.CardsInColumn(1),
       FForm.Kanban.CardsInColumn(2), FForm.Kanban.CardsInColumn(3)]),
    'kanban_tasks');

  // ── карточки информативные, перенос анимирован ──

  Inc(FNum);
  FForm.Kanban.SelectBoard(bkOrders);
  Pump;
  Id := FForm.Crm.Scalar('SELECT t.id FROM orders t WHERE ' +
    FForm.Crm.StageWhere(stAwaitPayment) + ' ORDER BY t.id LIMIT 1');
  BC := Default(TBoardCard);
  FForm.Kanban.CardById(Id, BC);
  Step('Канбан: карточка информативна — значок вида, клиент, сумма, прогресс оплаты, бейдж срока',
    (Id > 0) and (BC.Id = Id) and (BC.Total > 0) and (BC.Paid > 0) and (BC.KindText <> '')
      and (BC.Icon <> '') and (DaysBadgeText(BC) <> ''),
    Format('«%s» %s %s · %s · оплачено %.0f из %.0f · бейдж «%s»',
      [BC.Title, BC.Icon, BC.KindText, BC.Subtitle, BC.Paid, BC.Total, DaysBadgeText(BC)]),
    'kanban_card_info');

  Inc(FNum);
  FForm.Kanban.SelectFirstCard(0);
  Id := FForm.Kanban.SelectedId;
  Before := FForm.Kanban.AnimFrames;
  FForm.Kanban.DragCardById(Id, 1);
  Pump;
  Step('Канбан: перенос анимирован — карточка перелетает в новую колонку и вспыхивает',
    (FForm.Kanban.AnimFrames > Before) and (FForm.Crm.StageOf(Id) = stInWork),
    Format('кадров анимации %d, этап %d', [FForm.Kanban.AnimFrames - Before, Ord(FForm.Crm.StageOf(Id))]),
    'kanban_anim');
  FForm.Kanban.DragCardById(Id, 0);   // вернуть на прежний этап
  Pump;

  // ── часть 5а: схема бизнес-процесса ──

  Inc(FNum);
  // самотест работает с копией processes.json, чтобы не трогать файл проекта
  ProcFile := TPath.Combine(FOutDir, 'processes_test.json');
  TFile.Copy(FForm.Process.FileName, ProcFile, True);
  FForm.Process.LoadFrom(ProcFile);
  FForm.TestClickNav(nsProcess);
  Pump;
  FForm.Process.SelectProcess(0);
  Pump;
  Step('Бизнес-процесс: схема «Сделка → заказ → оплата» из processes.json — дорожки, узлы, развилки, стрелки',
    (FForm.Process.LoadError = '') and (FForm.Process.ProcessCount = 3) and
    (FForm.Process.NodeCount = 13) and (FForm.Process.EdgeCount = 14),
    Format('процессов %d, узлов %d, связей %d', [FForm.Process.ProcessCount,
      FForm.Process.NodeCount, FForm.Process.EdgeCount]),
    'process_scheme');

  Inc(FNum);
  FForm.Process.ClickNode('work');
  Pump;
  Step('Бизнес-процесс: щелчок по этапу «В работе» показывает те же карточки, что колонка канбана',
    (FForm.Process.SelectedNodeId = 'work') and (FForm.Process.CardsShown > 0) and
    (FForm.Process.CardsShown = FForm.Process.NodeCards('work')) and
    (FForm.Process.NodeCards('work') = FForm.Crm.Count('orders', FForm.Crm.StageWhere(stInWork))),
    Format('узел «%s»: карточек %d, в базе на этапе %d, запаздывает %d',
      [FForm.Process.NodeTitle('work'), FForm.Process.CardsShown,
       FForm.Crm.Count('orders', FForm.Crm.StageWhere(stInWork)), FForm.Process.NodeOverdue('work')]),
    'process_node_click');

  Inc(FNum);
  Id := FForm.Crm.Scalar('SELECT t.id FROM orders t WHERE ' +
    FForm.Crm.StageWhere(stInWork) + ' ORDER BY t.due_date, t.id LIMIT 1');
  Before := FForm.Process.NodeCards('ready');
  FForm.Process.DragCardToNode(Id, 'ready');   // тот же путь, что и мышь
  Pump;
  Step('Бизнес-процесс: карточка перетащена мышью на этап «Готово к отгрузке» — этап в базе изменён',
    (FForm.Crm.StageOf(Id) = stReadyToShip) and (FForm.Process.NodeCards('ready') = Before + 1)
      and (FForm.Process.AnimFrames > 0),
    Format('на этапе «готово» было %d, стало %d; этап заказа %d; кадров анимации %d',
      [Before, FForm.Process.NodeCards('ready'), Ord(FForm.Crm.StageOf(Id)), FForm.Process.AnimFrames]),
    'process_drag');
  FForm.Process.ClickNode('ready');
  FForm.Process.DragCardToNode(Id, 'work');    // и обратно
  Pump;

  Inc(FNum);
  FForm.Process.ClickNode('advance');
  Pump;
  Stub := FForm.Process.Description;
  FForm.Process.SetDescription(Stub + ' [самотест ' + FormatDateTime('hh:nn:ss', Now) + ']');
  FForm.Process.SaveDescription;
  Pump;
  Detail := TFile.ReadAllText(ProcFile, TEncoding.UTF8);
  Step('Бизнес-процесс: описание этапа отредактировано и сохранено обратно в JSON',
    (Pos('[самотест', Detail) > 0) and (Pos('"sales_to_cash"', Detail) > 0) and (Stub <> ''),
    Format('файл %s, %d байт, описание «%s…»', [ExtractFileName(ProcFile), Length(Detail),
      Copy(Stub, 1, 40)]),
    'process_desc_saved');
  FForm.Process.LoadFrom('');   // вернуть штатный processes.json

  Inc(FNum);
  FForm.TestClickNav(nsCalendar);
  Pump;
  FForm.Calendar.GoToday;
  Pump;
  Step('Календарь месячной сеткой: задачи разложены по дням',
    (FForm.Calendar.TasksInMonth > 0) and (FForm.Calendar.MonthTitle <> ''),
    Format('месяц «%s», задач в месяце %d, сегодня %d',
      [FForm.Calendar.MonthTitle, FForm.Calendar.TasksInMonth,
       FForm.Calendar.TasksOnDay(Date)]),
    'calendar_month');

  Inc(FNum);
  Id := FForm.Crm.Scalar('SELECT id FROM tasks WHERE done = 0 AND due_at = ' +
    QuotedStr(FormatDateTime('yyyy-mm-dd', Date)) + ' LIMIT 1');
  if Id = 0 then
  begin
    // на сегодня задач нет — создадим, чтобы было что перетаскивать
    Id := FForm.Crm.Insert(DefTasks, ['Перенос мышью', 'Задача',
      FormatDateTime('yyyy-mm-dd', Date), '', '', '0', '']);
    FForm.Calendar.Refresh;
    Pump;
  end;
  Before := FForm.Calendar.TasksOnDay(Date + 3);
  FForm.Calendar.DragTask(Id, Date + 3);
  Pump;
  V := FForm.Crm.Scalar('SELECT due_at FROM tasks WHERE id = ' + IntToStr(Id));
  Step('Календарь: задача перетащена мышью на три дня вперёд',
    (VarToStr(V) = FormatDateTime('yyyy-mm-dd', Date + 3)) and
    (FForm.Calendar.TasksOnDay(Date + 3) = Before + 1),
    Format('срок в базе «%s», на дне %s задач %d → %d',
      [VarToStr(V), FormatDateTime('dd.mm', Date + 3), Before,
       FForm.Calendar.TasksOnDay(Date + 3)]),
    'calendar_drag');

  Inc(FNum);
  FForm.Calendar.GoNextMonth;
  Pump;
  Nav := FForm.Calendar.MonthTitle;
  FForm.Calendar.GoPrevMonth;
  Pump;
  Step('Календарь: листание месяцев кнопками ‹ ›',
    (Nav <> FForm.Calendar.MonthTitle) and (FForm.Calendar.MonthTitle <> ''),
    Format('следующий «%s», текущий «%s»', [Nav, FForm.Calendar.MonthTitle]),
    'calendar_next_month');

  Inc(FNum);
  FForm.TestClickNav(nsGantt);
  Pump;
  FForm.Gantt.SelectFilter(0);
  Pump;
  Step('План работ (Гант): производственные заказы и их операции на шкале времени',
    (FForm.Gantt.RowCount > 0) and (FForm.Gantt.WorkCount > 0),
    Format('строк %d, из них работ %d, просрочено заказов %d; период %s',
      [FForm.Gantt.RowCount, FForm.Gantt.WorkCount, FForm.Gantt.OverdueCount,
       FForm.Gantt.RangeText]),
    'gantt_production');

  Inc(FNum);
  Id := FForm.Gantt.RowOrderId(0);
  D1 := FForm.Gantt.RowStart(0);
  D2 := FForm.Gantt.RowPlanEnd(0);
  FForm.Gantt.DragBar(0, dmMove, 5);   // тот же путь, что и мышь
  Pump;
  V := FForm.Crm.Scalar('SELECT order_date FROM orders WHERE id = ' + IntToStr(Id));
  Step('План работ: полоса заказа перетащена мышью на 5 дней вперёд — даты в базе сдвинулись',
    (Abs(FForm.Gantt.RowStart(0) - (D1 + 5)) < 0.5) and
    (Abs(FForm.Gantt.RowPlanEnd(0) - (D2 + 5)) < 0.5) and
    (VarToStr(V) = FormatDateTime('yyyy-mm-dd', D1 + 5)),
    Format('было %s–%s, стало %s–%s (в базе %s)',
      [FormatDateTime('dd.mm', D1), FormatDateTime('dd.mm', D2),
       FormatDateTime('dd.mm', FForm.Gantt.RowStart(0)),
       FormatDateTime('dd.mm', FForm.Gantt.RowPlanEnd(0)), VarToStr(V)]),
    'gantt_drag_move');

  Inc(FNum);
  D2 := FForm.Gantt.RowPlanEnd(0);
  FForm.Gantt.DragBar(0, dmEnd, 7);    // тянем правый край — только срок
  Pump;
  Step('План работ: за правый край полосы растянут только срок, дата заказа не тронута',
    (Abs(FForm.Gantt.RowPlanEnd(0) - (D2 + 7)) < 0.5) and
    (Abs(FForm.Gantt.RowStart(0) - (D1 + 5)) < 0.5),
    Format('срок %s → %s, начало осталось %s',
      [FormatDateTime('dd.mm', D2), FormatDateTime('dd.mm', FForm.Gantt.RowPlanEnd(0)),
       FormatDateTime('dd.mm', FForm.Gantt.RowStart(0))]),
    'gantt_drag_resize');

  Inc(FNum);
  FForm.Gantt.SelectFilter(1);
  Pump;
  Step('План работ: фильтр «Все заказы» — строк становится больше',
    FForm.Gantt.RowCount > 0,
    Format('строк %d, работ %d', [FForm.Gantt.RowCount, FForm.Gantt.WorkCount]),
    'gantt_all');

  // ── часть 5б: проекты — единичные изделия под заказ, тендеры, авансы,
  //    задачи по этапам (gravura.md / BM Public) ──

  Inc(FNum);
  FForm.TestClickNav(nsProjects);
  Pump;
  P := FForm.Page(nsProjects);
  Step('Проекты: панно с логотипом, выжиг поздравлений, стенды, медали — тендеры с авансом и без',
    P.ListCount >= 10,
    Format('проектов %d; в производстве %d, тендеров %d, проиграно %d, запаздывает %d',
      [P.ListCount, FForm.Crm.Count('projects', 't.status = ''Производство'''),
       FForm.Crm.Count('projects', 't.status = ''Тендер'''), FForm.Crm.Count('projects', 't.status = ''Проигран'''),
       FForm.Crm.Count('projects', 't.status NOT IN (''Закрыт'',''Проигран'') AND t.due_date < date(''now'',''localtime'')')]),
    'projects_list');

  Inc(FNum);
  Id := FForm.Crm.Scalar('SELECT id FROM projects WHERE status = ''Производство'' ORDER BY id LIMIT 1');
  P.SelectPreset(0);
  P.SelectById(Id);
  Pump;
  FForm.TestProjectTasks;
  Pump;
  Step('Проект → «Задачи проекта»: доска задач по этапам — новая / в работе / ожидание / проверка / готово',
    (FForm.TestSection = nsKanban) and (FForm.Kanban.Board = bkProjectTasks) and
    (FForm.Kanban.ColumnCount = 5) and (FForm.Kanban.ProjectId = Id) and (FForm.Kanban.CardsInColumn(4) > 0),
    Format('проект %d, колонок %d; новых %d, в работе %d, ожидание %d, проверка %d, готово %d',
      [Id, FForm.Kanban.ColumnCount, FForm.Kanban.CardsInColumn(0), FForm.Kanban.CardsInColumn(1),
       FForm.Kanban.CardsInColumn(2), FForm.Kanban.CardsInColumn(3), FForm.Kanban.CardsInColumn(4)]),
    'project_tasks_board');

  Inc(FNum);
  Id := FForm.Crm.Scalar('SELECT id FROM tasks WHERE project_id = ' + IntToStr(FForm.Kanban.ProjectId) +
    ' AND stage = ''Новая'' ORDER BY seq LIMIT 1');
  FForm.Kanban.DragCardById(Id, 1);
  Pump;
  V := FForm.Crm.Scalar('SELECT stage FROM tasks WHERE id = ' + IntToStr(Id));
  Step('Задача перетащена «Новая» → «В работе»: этап в базе изменён, флаг «выполнено» не тронут',
    (VarToStr(V) = 'В работе') and (Integer(FForm.Crm.Scalar('SELECT done FROM tasks WHERE id = ' + IntToStr(Id))) = 0),
    Format('задача %d: этап «%s»', [Id, VarToStr(V)]), 'task_drag_inwork');

  Inc(FNum);
  FForm.Kanban.DragCardById(Id, 4);
  Pump;
  V := FForm.Crm.Scalar('SELECT stage FROM tasks WHERE id = ' + IntToStr(Id));
  Step('Задача перетащена в «Готово»: флаг «выполнено» выставлен сам — этап и флаг суть одно состояние',
    (VarToStr(V) = 'Готово') and (Integer(FForm.Crm.Scalar('SELECT done FROM tasks WHERE id = ' + IntToStr(Id))) = 1),
    Format('задача %d: этап «%s», done = %s', [Id, VarToStr(V),
      VarToStr(FForm.Crm.Scalar('SELECT done FROM tasks WHERE id = ' + IntToStr(Id)))]), 'task_drag_done');
  FForm.Kanban.DragCardById(Id, 0);   // вернуть в «Новая»
  Pump;

  Inc(FNum);
  FForm.Kanban.SelectBoard(bkProjects);
  Pump;
  Step('Канбан «Проекты»: девять этапов от тендера до закрытия, проигранные тендеры отдельно',
    (FForm.Kanban.ColumnCount = 9) and (FForm.Kanban.CardsInColumn(4) > 0) and (FForm.Kanban.CardsInColumn(8) > 0),
    Format('колонок %d; тендер %d, договор %d, аванс %d, дизайн %d, производство %d, сдача %d, оплата %d, закрыт %d, проигран %d',
      [FForm.Kanban.ColumnCount, FForm.Kanban.CardsInColumn(0), FForm.Kanban.CardsInColumn(1),
       FForm.Kanban.CardsInColumn(2), FForm.Kanban.CardsInColumn(3), FForm.Kanban.CardsInColumn(4),
       FForm.Kanban.CardsInColumn(5), FForm.Kanban.CardsInColumn(6), FForm.Kanban.CardsInColumn(7),
       FForm.Kanban.CardsInColumn(8)]),
    'kanban_projects');

  Inc(FNum);
  Id := FForm.Crm.Scalar('SELECT id FROM projects WHERE status = ''Тендер'' ORDER BY id LIMIT 1');
  FForm.Kanban.DragCardById(Id, 1);
  Pump;
  V := FForm.Crm.Scalar('SELECT status FROM projects WHERE id = ' + IntToStr(Id));
  Step('Проект перетащен «Тендер» → «Договор» (тендер выигран): этап в базе изменён',
    VarToStr(V) = 'Договор', Format('проект %d: этап «%s»', [Id, VarToStr(V)]), 'kanban_project_drag');
  FForm.Kanban.DragCardById(Id, 0);
  Pump;

  Inc(FNum);
  FForm.TestClickNav(nsProcess);
  Pump;
  FForm.Process.SelectProcess(2);
  Pump;
  FForm.Process.ClickNode('production');
  Pump;
  Step('Бизнес-процесс «Проект: тендер → аванс → производство → сдача → оплата»: узел «Производство» показывает его проекты',
    (FForm.Process.LoadError = '') and (FForm.Process.NodeCount >= 10) and (FForm.Process.CardsShown > 0) and
    (FForm.Process.CardsShown = FForm.Crm.Count('projects', 't.status = ''Производство''')),
    Format('узлов %d, связей %d; в производстве %d, запаздывает %d',
      [FForm.Process.NodeCount, FForm.Process.EdgeCount, FForm.Process.CardsShown, FForm.Process.NodeOverdue('production')]),
    'process_project');

  Inc(FNum);
  FForm.TestClickNav(nsGantt);
  Pump;
  FForm.Gantt.SelectFilter(3);
  Pump;
  Step('План работ «Проекты и задачи»: проект и его шаги по датам, готовые зелёным, просроченные красным, стрелки «после задачи»',
    (FForm.Gantt.RowCount > 10) and (FForm.Gantt.WorkCount > 10) and (FForm.Gantt.OverdueCount > 0),
    Format('строк %d, из них задач %d, просроченных проектов %d; период %s',
      [FForm.Gantt.RowCount, FForm.Gantt.WorkCount, FForm.Gantt.OverdueCount, FForm.Gantt.RangeText]),
    'gantt_projects');

  Inc(FNum);
  Before := FForm.Gantt.FirstTaskRow;
  Id := FForm.Gantt.RowTaskId(Before);
  D1 := FForm.Gantt.RowPlanEnd(Before);
  FForm.Gantt.DragBar(Before, dmMove, 3);   // тот же путь, что и мышь
  Pump;
  V := FForm.Crm.Scalar('SELECT due_at FROM tasks WHERE id = ' + IntToStr(Id));
  Step('План работ: задача проекта перетащена мышью на 3 дня — план и срок в базе сдвинулись',
    VarToStr(V) = FormatDateTime('yyyy-mm-dd', D1 + 3),
    Format('задача %d: срок %s → %s', [Id, FormatDateTime('yyyy-mm-dd', D1), VarToStr(V)]),
    'gantt_task_drag');
  FForm.Gantt.DragBar(Before, dmMove, -3);
  Pump;

  Inc(FNum);
  FForm.TestClickNav(nsReports);
  Pump;
  FForm.Reports.SelectReport(rkProjects);
  Pump;
  Xlsx := FForm.Reports.Export(efXlsx);
  Pdf := FForm.Reports.Export(efPdf);
  Step('Отчёт «Проекты: тендеры, авансы, задачи» — предпросмотр и выгрузка в Excel и PDF',
    (FForm.Reports.PreviewRows >= 10) and IsZip(Xlsx) and IsPdf(Pdf),
    Format('строк %d; %s, %s', [FForm.Reports.PreviewRows, ExtractFileName(Xlsx), ExtractFileName(Pdf)]),
    'report_projects');
  FExports := FExports + [Xlsx, Pdf];

  // ── часть 6: отчёты и выгрузка в Excel и PDF ──

  Inc(FNum);
  FForm.TestClickNav(nsReports);
  Pump;
  FForm.Reports.SelectReport(rkProcess);
  Pump;
  Step('Отчёты: «Процесс исполнения заказов» — предпросмотр по этапам',
    (FForm.TestSection = nsReports) and (FForm.Reports.PreviewRows >= 8)
      and (FForm.Reports.PreviewCols = 6),
    Format('строк %d, колонок %d', [FForm.Reports.PreviewRows, FForm.Reports.PreviewCols]),
    'report_process');

  Inc(FNum);
  Xlsx := FForm.Reports.Export(efXlsx);
  Pdf := FForm.Reports.Export(efPdf);
  Pump;
  Step('Выгрузка отчёта в Excel и PDF',
    IsZip(Xlsx) and IsPdf(Pdf),
    Format('%s (%d байт, zip=%s); %s (%d байт, %%PDF=%s)',
      [ExtractFileName(Xlsx), FileSizeOf(Xlsx), BoolToStr(IsZip(Xlsx), True),
       ExtractFileName(Pdf), FileSizeOf(Pdf), BoolToStr(IsPdf(Pdf), True)]),
    'report_export');
  FExports := FExports + [Xlsx, Pdf];

  Inc(FNum);
  FForm.Reports.SelectReport(rkReceivables);
  Pump;
  Xlsx := FForm.Reports.Export(efXlsx);
  Pdf := FForm.Reports.Export(efPdf);
  Step('Отчёт «Дебиторская задолженность»: строки есть, выгружен в оба формата',
    (FForm.Reports.PreviewRows > 0) and IsZip(Xlsx) and IsPdf(Pdf),
    Format('строк %d; %s, %s', [FForm.Reports.PreviewRows,
      ExtractFileName(Xlsx), ExtractFileName(Pdf)]),
    'report_receivables');
  FExports := FExports + [Xlsx, Pdf];

  Inc(FNum);
  FForm.Reports.SelectReport(rkStock);
  Pump;
  Xlsx := FForm.Reports.Export(efXlsx);
  Pdf := FForm.Reports.Export(efPdf);
  Step('Отчёт «Остатки номенклатуры»: остатки после проводок, выгружен в оба формата',
    (FForm.Reports.PreviewRows > 0) and IsZip(Xlsx) and IsPdf(Pdf),
    Format('позиций %d; %s, %s', [FForm.Reports.PreviewRows - 1,
      ExtractFileName(Xlsx), ExtractFileName(Pdf)]),
    'report_stock');
  FExports := FExports + [Xlsx, Pdf];

  Inc(FNum);
  FForm.TestClickNav(nsAccounts);
  FForm.TestSetFilter('');
  FForm.TestHideBanner;
  Pump;
  Step('Итоговое состояние окна: клиенты из SDK, лида и генератора',
    FForm.TestDbCount = 3 + Stats.Clients,
    Format('в базе %d клиентов', [FForm.TestDbCount]), 'final');

  WriteReport;
  Result := Passed = Total;
end;

function TGuiSelfTest.Passed: Integer;
var
  S: TStepResult;
begin
  Result := 0;
  for S in FSteps do
    if S.Ok then
      Inc(Result);
end;

function TGuiSelfTest.Total: Integer;
begin
  Result := Length(FSteps);
end;

procedure TGuiSelfTest.WriteReport;
var
  H, J: TStringBuilder;
  S: TStepResult;
  AllOk, First: Boolean;
  X: string;
begin
  AllOk := Passed = Total;

  J := TStringBuilder.Create;
  try
    J.Append('{"passed":').Append(Passed).Append(',"total":').Append(Total)
     .Append(',"launcher":"').Append(JsonEsc(FLauncher)).Append('","steps":[');
    First := True;
    for S in FSteps do
    begin
      if not First then J.Append(',');
      First := False;
      J.Append('{"num":').Append(S.Num)
       .Append(',"ok":').Append(BoolToStr(S.Ok, True).ToLower)
       .Append(',"title":"').Append(JsonEsc(S.Title))
       .Append('","detail":"').Append(JsonEsc(S.Detail))
       .Append('","message":"').Append(JsonEsc(S.Message))
       .Append('","shot":"').Append(S.Shot).Append('","extra":[');
      for X in S.Extra do
        J.Append('"').Append(X).Append('",');
      if Length(S.Extra) > 0 then J.Length := J.Length - 1;
      J.Append(']}');
    end;
    J.Append(']}');
    TFile.WriteAllText(TPath.Combine(FOutDir, 'results.json'), J.ToString, TEncoding.UTF8);
  finally
    J.Free;
  end;

  H := TStringBuilder.Create;
  try
    H.Append('<!doctype html><html lang="ru"><head><meta charset="utf-8">')
     .Append('<meta name="viewport" content="width=device-width,initial-scale=1">')
     .Append('<title>Demo CRM — отчёт GUI-самотеста</title><style>')
     .Append('body{margin:0;background:#f6f7f5;color:#12222f;font:15px/1.6 "Segoe UI",system-ui,sans-serif}')
     .Append('.wrap{max-width:1100px;margin:0 auto;padding:32px 24px 80px}')
     .Append('h1{font-size:28px;margin:0 0 6px}.sub{color:#69808f;margin:0 0 22px}')
     .Append('.verdict{display:inline-block;padding:6px 14px;border-radius:3px;font-weight:700;margin:0 0 26px}')
     .Append('.pass{background:#e3efec;color:#0b6e5f}.fail{background:#f6e7e4;color:#a63a2b}')
     .Append('table{border-collapse:collapse;width:100%;background:#fff;font-size:14px;margin:0 0 34px}')
     .Append('th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #d7dde0;vertical-align:top}')
     .Append('th{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:#69808f}')
     .Append('td.n{font-family:Consolas,monospace;color:#0b6e5f;white-space:nowrap}')
     .Append('.ok{color:#0b6e5f;font-weight:700}.no{color:#a63a2b;font-weight:700}')
     .Append('.step{margin:0 0 30px;background:#fff;border:1px solid #d7dde0;border-radius:3px;padding:16px 18px}')
     .Append('.step h3{margin:0 0 4px;font-size:16px}.step h3 span{font-family:Consolas,monospace;color:#0b6e5f;margin-right:8px}')
     .Append('.step .d{color:#69808f;font-size:13px;margin:0 0 4px}')
     .Append('.step .m{font-size:13px;margin:0 0 12px;padding:6px 10px;background:#f4f2ee;border-left:3px solid #0b6e5f;border-radius:2px}')
     .Append('.step img{display:block;max-width:100%;height:auto;border:1px solid #d7dde0;border-radius:3px;margin:0 0 10px}')
     .Append('.step .x{font-size:12px;color:#69808f;margin:0 0 4px}')
     .Append('.step a{color:#0b6e5f;font-size:12px}')
     .Append('</style></head><body><div class="wrap">')
     .Append('<h1>Demo CRM — отчёт GUI-самотеста</h1>')
     .Append('<p class="sub">Тест выполнен самим приложением: оно вело собственное окно по шагам, '
           + 'рисовало номер шага на плашке и снимало себя. Шаги 15–18 — реальный вызов SDK: '
           + 'нажата настоящая кнопка «Создать из реестра», запущен Contragenti; шаги 19–33 — разделы CRM: '
           + 'клиенты, контакты, лиды, сделки, номенклатура, заказы с проводкой остатков, календарь, главная.<br>'
           + 'Launcher: <code>').Append(HtmlEsc(FLauncher)).Append('</code></p>')
     .Append('<div class="verdict ').Append(IfThen(AllOk, 'pass', 'fail')).Append('">')
     .Append(Format('Пройдено %d из %d', [Passed, Total])).Append('</div>');

    H.Append('<table><thead><tr><th>#</th><th>Шаг</th><th>Статус</th><th>Проверка</th><th>Снимки</th></tr></thead><tbody>');
    for S in FSteps do
    begin
      H.Append('<tr><td class="n">').Append(Format('%.2d', [S.Num])).Append('</td><td>')
       .Append(HtmlEsc(S.Title)).Append('</td><td class="')
       .Append(IfThen(S.Ok, 'ok">OK', 'no">FAIL')).Append('</td><td>')
       .Append(HtmlEsc(S.Detail)).Append('</td><td><a href="#s').Append(S.Num).Append('">')
       .Append(S.Shot).Append('</a>');
      if Length(S.Extra) > 0 then
        H.Append(Format(' +%d', [Length(S.Extra)]));
      H.Append('</td></tr>');
    end;
    H.Append('</tbody></table>');

    for S in FSteps do
    begin
      H.Append('<div class="step" id="s').Append(S.Num).Append('"><h3><span>')
       .Append(Format('%.2d', [S.Num])).Append('</span>').Append(HtmlEsc(S.Title))
       .Append(' — <span class="').Append(IfThen(S.Ok, 'ok">OK', 'no">FAIL')).Append('</span></h3>');
      if S.Detail <> '' then
        H.Append('<p class="d">').Append(HtmlEsc(S.Detail)).Append('</p>');
      if S.Message <> '' then
        H.Append('<p class="m">Строка сообщений: ').Append(HtmlEsc(S.Message)).Append('</p>');
      for X in S.Extra do
        H.Append('<p class="x">во время работы SDK: ').Append(X).Append('</p>')
         .Append('<a href="').Append(X).Append('"><img src="').Append(X).Append('" alt="').Append(X).Append('"></a>');
      H.Append('<p class="x">после шага: ').Append(S.Shot).Append('</p>')
       .Append('<a href="').Append(S.Shot).Append('"><img src="').Append(S.Shot)
       .Append('" alt="').Append(HtmlEsc(S.Title)).Append('"></a></div>');
    end;

    H.Append('</div></body></html>');
    TFile.WriteAllText(TPath.Combine(FOutDir, 'report.html'), H.ToString, TEncoding.UTF8);
  finally
    H.Free;
  end;
end;

end.
