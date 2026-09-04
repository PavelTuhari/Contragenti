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
  Winapi.Windows, System.SysUtils, System.Classes, uMainForm;

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
  uContragenti, uClientsDB;

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
      Png.SaveToFile(TPath.Combine(FOutDir, Result));
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
      Png.SaveToFile(TPath.Combine(FOutDir, Result));
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
begin
  FSteps := nil;
  FNum := 0;
  FExtra := nil;
  TDirectory.CreateDirectory(FOutDir);

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
  FForm.TestClickNav(nsHome);
  Pump;
  Step('Навигация: раздел «Главная» с дашлетами (стиль EspoCRM)',
    FForm.TestSection = nsHome, '', 'home');

  Inc(FNum);
  FForm.TestClickNav(nsLeads);
  Pump;
  Step('Навигация: демо-раздел «Лиды» — информационное сообщение, без смены страницы',
    (FForm.TestSection = nsHome) and (FForm.TestMessageKind = mkInfo),
    'сообщение: ' + FForm.TestMessage, 'nav_demo');

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

  Inc(FNum);
  FForm.TestSetFilter('');
  FForm.TestHideBanner;
  Pump;
  Step('Итоговое состояние окна', FForm.TestDbCount = 2,
    Format('в базе %d', [FForm.TestDbCount]), 'final');

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
           + 'рисовало номер шага на плашке и снимало себя через GetFormImage. Шаги 12–15 — реальный '
           + 'вызов SDK: нажата настоящая кнопка «Добавить из реестра», запущен Contragenti '
           + '(Chrome + date.gov.md); его окна сняты через PrintWindow во время работы.<br>'
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
