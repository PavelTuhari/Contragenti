program ContragentiCRM;
{
  Demo CRM (Delphi 10.2 Tokyo, VCL + FireDAC/SQLite).

  Показывает, как внешняя система заводит клиентов из государственного
  реестра date.gov.md через приложение Contragenti: CRM вызывает Contragenti
  в режиме одноразового выбора, получает XML карточки контрагента и сохраняет
  его в свою личную базу SQLite.

  Режимы:
    ContragentiCRM.exe                       графический интерфейс (по умолчанию)
    ContragentiCRM.exe --import file.xml     импорт карточки из XML (без GUI)
    ContragentiCRM.exe --selftest            проверка базы и разбора XML
    ContragentiCRM.exe --gui-test [каталог]  встроенный GUI-самотест со снимками
}

{$APPTYPE GUI}

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  Vcl.Forms,
  uContragenti in 'uContragenti.pas',
  uClientsDB in 'uClientsDB.pas',
  uEspoTheme in 'uEspoTheme.pas',
  uCrmData in 'uCrmData.pas',
  uEntityPage in 'uEntityPage.pas',
  uMainForm in 'uMainForm.pas',
  uGuiSelfTest in 'uGuiSelfTest.pas';

{$R *.res}

function AppDir: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

procedure WriteConsole(const S: string);
var
  Written: Cardinal;
  H: THandle;
  Bytes: TBytes;
begin
  H := GetStdHandle(STD_OUTPUT_HANDLE);
  if H <> INVALID_HANDLE_VALUE then
  begin
    Bytes := TEncoding.UTF8.GetBytes(S + sLineBreak);
    WriteFile(H, Bytes[0], Length(Bytes), Written, nil);
  end;
end;

{ Импорт карточки из XML в личную базу — без запуска интерфейса. }
function RunImport(const XmlFile: string): Integer;
var
  Cli: TContragentiClient;
  DB: TClientsDB;
  Card: TCounterpartyCard;
  NewId: Integer;
begin
  if not TFile.Exists(XmlFile) then
  begin
    WriteConsole('Файл не найден: ' + XmlFile);
    Exit(2);
  end;
  Cli := TContragentiClient.Create;
  DB := TClientsDB.Create(TPath.Combine(AppDir, 'clients.db'));
  try
    DB.Open;
    if not Cli.ParseCardFile(XmlFile, Card) then
    begin
      WriteConsole('Разбор не удался: ' + Cli.LastError);
      Exit(3);
    end;
    case DB.AddFromCard(Card, NewId) of
      arAdded:
        begin
          WriteConsole(Format('OK: добавлен клиент #%d — %s (IDNO %s)',
            [NewId, Card.Denumire, Card.Idno]));
          Result := 0;
        end;
      arDuplicate:
        begin
          WriteConsole(Format('DUP: уже в базе — %s (IDNO %s)', [Card.Denumire, Card.Idno]));
          Result := 0;
        end;
    else
      WriteConsole('ERROR: не удалось сохранить.');
      Result := 4;
    end;
    WriteConsole('Всего в базе: ' + IntToStr(DB.Count));
  finally
    DB.Free;
    Cli.Free;
  end;
end;

function RunSelfTest: Integer;
var
  DB: TClientsDB;
  Cli: TContragentiClient;
  Card: TCounterpartyCard;
  Ok: Boolean;
  TmpDb: string;
  Id1, Id2: Integer;
  R1, R2: TAddResult;
const
  SampleXml =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<counterparty source="date.gov.md" idno="1234567890123">' +
    '<idno>1234567890123</idno><denumire>SELFTEST SRL</denumire>' +
    '<forma_juridica>SRL</forma_juridica><adresa>Chisinau</adresa>' +
    '<administratori>ION [Administrator]</administratori>' +
    '<founders><founder name="ION" share="100"/></founders>' +
    '<debts currency="MDL"><debt nr="1" type="stat" sum="0,00"/></debts>' +
    '</counterparty>';
begin
  Ok := True;
  Cli := TContragentiClient.Create;
  try
    if Cli.ParseCardXml(SampleXml, Card) then
      WriteConsole('[OK]   разбор XML: ' + Card.Denumire + ' / ' + Card.Idno +
        ' / учредителей ' + IntToStr(Length(Card.Founders)) +
        ' / долгов ' + IntToStr(Length(Card.Debts)))
    else
    begin
      WriteConsole('[FAIL] разбор XML: ' + Cli.LastError);
      Ok := False;
    end;
  finally
    Cli.Free;
  end;

  TmpDb := TPath.Combine(TPath.GetTempPath, 'crm_selftest_' + IntToStr(GetTickCount) + '.db');
  if TFile.Exists(TmpDb) then
    TFile.Delete(TmpDb);
  DB := TClientsDB.Create(TmpDb);
  try
    try
      DB.Open;
      R1 := DB.AddFromCard(Card, Id1);
      R2 := DB.AddFromCard(Card, Id2);
      if (R1 = arAdded) and (R2 = arDuplicate) and (DB.Count = 1) then
        WriteConsole('[OK]   SQLite: добавление и дедупликация по IDNO')
      else
      begin
        WriteConsole(Format('[FAIL] SQLite: r1=%d r2=%d count=%d', [Ord(R1), Ord(R2), DB.Count]));
        Ok := False;
      end;
    except
      on E: Exception do
      begin
        WriteConsole('[FAIL] SQLite: ' + E.ClassName + ': ' + E.Message);
        Ok := False;
      end;
    end;
  finally
    DB.Free;
    if TFile.Exists(TmpDb) then
      TFile.Delete(TmpDb);
  end;

  WriteConsole('');
  WriteConsole('CRM self-test: ' + BoolToStr(Ok, True));
  if Ok then Result := 0 else Result := 1;
end;

{ Встроенный GUI-самотест: форма ведёт себя сама, снимает себя и пишет отчёт. }
function RunGuiTest(const OutDir, LauncherArg: string): Integer;
var
  Form: TMainForm;
  Test: TGuiSelfTest;
  Ok: Boolean;
  Dir, DbPath, Launcher: string;
begin
  Dir := OutDir;
  if Dir = '' then
    Dir := TPath.Combine(AppDir, 'gui_test');
  TDirectory.CreateDirectory(Dir);

  // чем запускать Contragenti: явный аргумент, иначе исходник рядом с репо
  // (python company_search.py), иначе frozen-сборка
  Launcher := LauncherArg;
  if Launcher = '' then
    Launcher := TPath.GetFullPath(TPath.Combine(AppDir, '..\company_search.py'));
  if not TFile.Exists(Launcher) then
    Launcher := TPath.GetFullPath(TPath.Combine(AppDir, '..\build\exe.win-amd64-3.12\Contragenti.exe'));

  // тест работает в собственной базе, рабочая clients.db не затрагивается
  DbPath := TPath.Combine(Dir, 'test_clients.db');
  if TFile.Exists(DbPath) then
    TFile.Delete(DbPath);
  GDBPathOverride := DbPath;

  Application.Initialize;
  Ok := False;
  try
    Form := TMainForm.CreateNew(Application);
    try
      Form.Show;
      Application.ProcessMessages;
      Test := TGuiSelfTest.Create(Form, Dir, Launcher);
      try
        Ok := Test.Run;
        WriteConsole(Format('GUI self-test: %d/%d — %s',
          [Test.Passed, Test.Total, BoolToStr(Ok, True)]));
        WriteConsole('Отчёт: ' + TPath.Combine(Dir, 'report.html'));
      finally
        Test.Free;
      end;
    finally
      Form.Free;
    end;
  except
    // в тестовом режиме никаких модальных диалогов: причина — в лог и код 2
    on E: Exception do
    begin
      WriteConsole('GUI self-test EXCEPTION: ' + E.ClassName + ': ' + E.Message);
      Exit(2);
    end;
  end;
  if Ok then Result := 0 else Result := 1;
end;

var
  Arg: string;
  Form: TMainForm;
begin
  if ParamCount >= 1 then
  begin
    Arg := LowerCase(ParamStr(1));
    if Arg = '--selftest' then
    begin
      ExitCode := RunSelfTest;
      Exit;
    end;
    if (Arg = '--import') and (ParamCount >= 2) then
    begin
      ExitCode := RunImport(ParamStr(2));
      Exit;
    end;
    if Arg = '--gui-test' then
    begin
      ExitCode := RunGuiTest(ParamStr(2), ParamStr(3));
      Exit;
    end;
  end;

  Application.Initialize;
  Application.Title := 'Demo CRM';
  Form := TMainForm.CreateNew(Application);
  Form.Show;
  // Форма создана в коде и не зарегистрирована как MainForm, поэтому
  // Application.Run не запустил бы цикл — крутим его сами до закрытия окна.
  repeat
    Application.HandleMessage;
  until Application.Terminated;
end.
