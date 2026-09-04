unit uContragenti;
{
  SDK-модуль интеграции с приложением Contragenti (date.gov.md).

  Contragenti умеет работать в режиме одноразового выбора: запускается с
  фильтром, показывает поиск контрагентов, а после выбора возвращает XML
  полной карточки и закрывается. Этот модуль оборачивает такой вызов в
  удобный класс: CRM просит выбрать контрагента и получает готовую запись.

    var
      Client: TContragentiClient;
      Card: TCounterpartyCard;
    begin
      Client := TContragentiClient.Create;
      try
        Client.LauncherExe := 'Contragenti.exe';
        if Client.Pick('UNISIM', Card) then
          // Card.Idno, Card.Denumire, Card.Adresa ...
      finally
        Client.Free;
      end;
    end;

  Модуль не зависит от VCL и может использоваться в консольных утилитах.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TFounder = record
    Name: string;
    Share: string;
  end;

  TDebt = record
    Nr: string;
    DebtType: string;
    Sum: string;
  end;

  { Карточка контрагента, полученная из Contragenti. }
  TCounterpartyCard = record
    Idno: string;
    Denumire: string;
    Inregistrare: string;
    FormaJuridica: string;
    Lichidata: string;
    Adresa: string;
    Administratori: string;
    DetailsText: string;
    Founders: TArray<TFounder>;
    Debts: TArray<TDebt>;
    procedure Clear;
    function IsEmpty: Boolean;
  end;

  EContragentiError = class(Exception);

  TContragentiClient = class
  private
    FLauncherExe: string;
    FExtraArgs: string;
    FLang: string;
    FTimeoutMs: Cardinal;
    FLastError: string;
    FOnWait: TProc;
    function BuildArgs(const Filter, OutFile: string): string;
    function RunAndWait(const Cmd: string): Boolean;
  public
    constructor Create;
    { Запускает Contragenti в режиме выбора, ждёт закрытия и разбирает XML.
      Возвращает True, если пользователь выбрал контрагента. }
    function Pick(const Filter: string; out Card: TCounterpartyCard): Boolean;
    { Разбирает XML-карточку из файла (для тестов и повторного импорта). }
    function ParseCardFile(const FileName: string; out Card: TCounterpartyCard): Boolean;
    { Разбирает XML-карточку из строки. }
    function ParseCardXml(const Xml: string; out Card: TCounterpartyCard): Boolean;

    property LauncherExe: string read FLauncherExe write FLauncherExe;
    property ExtraArgs: string read FExtraArgs write FExtraArgs;
    property Lang: string read FLang write FLang;
    property TimeoutMs: Cardinal read FTimeoutMs write FTimeoutMs;
    property LastError: string read FLastError;
    { Вызывается каждые ~200 мс, пока Contragenti открыт: GUI-приложение
      может прокачивать очередь сообщений, показывать прогресс, снимать окна. }
    property OnWait: TProc read FOnWait write FOnWait;
  end;

implementation

uses
  Winapi.Windows, Xml.XMLDoc, Xml.XMLIntf, System.IOUtils, System.Variants;

{ TCounterpartyCard }

procedure TCounterpartyCard.Clear;
begin
  Self := Default(TCounterpartyCard);
end;

function TCounterpartyCard.IsEmpty: Boolean;
begin
  Result := (Idno = '') and (Denumire = '');
end;

{ TContragentiClient }

constructor TContragentiClient.Create;
begin
  inherited Create;
  FLauncherExe := 'Contragenti.exe';
  FExtraArgs := '--no-server --no-tray';
  FLang := 'ru';
  FTimeoutMs := 5 * 60 * 1000;  // 5 минут на выбор пользователем
end;

function TContragentiClient.BuildArgs(const Filter, OutFile: string): string;
begin
  // --pick: одноразовый выбор; --out: файл для XML; --q: начальный фильтр
  Result := Format('--pick --out "%s" --lang %s', [OutFile, FLang]);
  if Filter <> '' then
    Result := Result + Format(' --q "%s"', [Filter]);
  if FExtraArgs <> '' then
    Result := Result + ' ' + FExtraArgs;
end;

function TContragentiClient.RunAndWait(const Cmd: string): Boolean;
var
  SI: TStartupInfo;
  PI: TProcessInformation;
  CmdLine: string;
  WaitRes: DWORD;
  Elapsed: Cardinal;
begin
  Result := False;
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_SHOWNORMAL;
  FillChar(PI, SizeOf(PI), 0);

  CmdLine := Cmd;  // CreateProcessW может модифицировать буфер
  UniqueString(CmdLine);

  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False,
    CREATE_UNICODE_ENVIRONMENT, nil, nil, SI, PI) then
  begin
    FLastError := Format('Не удалось запустить Contragenti (код %d). Проверьте путь: %s',
      [GetLastError, FLauncherExe]);
    Exit;
  end;
  try
    // ждём ломтиками по 200 мс, между ними отдаём управление вызывающему
    Elapsed := 0;
    repeat
      WaitRes := WaitForSingleObject(PI.hProcess, 200);
      if WaitRes = WAIT_TIMEOUT then
      begin
        Inc(Elapsed, 200);
        if Assigned(FOnWait) then
          FOnWait();
        if Elapsed >= FTimeoutMs then
          Break;
      end;
    until WaitRes <> WAIT_TIMEOUT;
    if WaitRes = WAIT_TIMEOUT then
    begin
      FLastError := 'Истекло время ожидания выбора контрагента.';
      TerminateProcess(PI.hProcess, 1);
      Exit;
    end;
    Result := True;
  finally
    CloseHandle(PI.hThread);
    CloseHandle(PI.hProcess);
  end;
end;

function TContragentiClient.Pick(const Filter: string;
  out Card: TCounterpartyCard): Boolean;
var
  OutFile, CmdLine, PyExe: string;
begin
  Result := False;
  Card.Clear;
  FLastError := '';

  OutFile := TPath.Combine(TPath.GetTempPath,
    Format('contragenti_%d.xml', [GetTickCount]));
  if TFile.Exists(OutFile) then
    TFile.Delete(OutFile);

  // Разработчику удобно указывать сам скрипт company_search.py —
  // тогда запускаем его через python из PATH; в проде это Contragenti.exe.
  if SameText(ExtractFileExt(FLauncherExe), '.py') then
  begin
    // предпочитаем виртуальное окружение рядом со скриптом (.venv / venv)
    PyExe := TPath.Combine(ExtractFilePath(FLauncherExe), '.venv\Scripts\python.exe');
    if not TFile.Exists(PyExe) then
      PyExe := TPath.Combine(ExtractFilePath(FLauncherExe), 'venv\Scripts\python.exe');
    if not TFile.Exists(PyExe) then
      PyExe := 'python.exe';
    CmdLine := Format('"%s" "%s" %s', [PyExe, FLauncherExe, BuildArgs(Filter, OutFile)]);
  end
  else
    CmdLine := Format('"%s" %s', [FLauncherExe, BuildArgs(Filter, OutFile)]);
  if not RunAndWait(CmdLine) then
    Exit;

  // Пользователь мог закрыть окно без выбора — файла не будет.
  if not TFile.Exists(OutFile) then
  begin
    FLastError := 'Контрагент не выбран.';
    Exit;
  end;
  try
    Result := ParseCardFile(OutFile, Card);
  finally
    if TFile.Exists(OutFile) then
      TFile.Delete(OutFile);
  end;
end;

function TContragentiClient.ParseCardFile(const FileName: string;
  out Card: TCounterpartyCard): Boolean;
begin
  Result := ParseCardXml(TFile.ReadAllText(FileName, TEncoding.UTF8), Card);
end;

function TContragentiClient.ParseCardXml(const Xml: string;
  out Card: TCounterpartyCard): Boolean;
var
  Doc: IXMLDocument;
  Root, Node, Child: IXMLNode;
  I: Integer;
  F: TFounder;
  D: TDebt;

  function Text(const Tag: string): string;
  var
    N: IXMLNode;
  begin
    N := Root.ChildNodes.FindNode(Tag);
    if Assigned(N) then
      Result := VarToStr(N.Text)
    else
      Result := '';
  end;

begin
  Result := False;
  Card.Clear;
  Doc := TXMLDocument.Create(nil);
  try
    Doc.LoadFromXML(Xml);
    Doc.Active := True;
    Root := Doc.DocumentElement;
    if not Assigned(Root) or (Root.NodeName <> 'counterparty') then
    begin
      FLastError := 'Неверный формат XML: ожидался <counterparty>.';
      Exit;
    end;

    Card.Idno := Text('idno');
    Card.Denumire := Text('denumire');
    Card.Inregistrare := Text('inregistrare');
    Card.FormaJuridica := Text('forma_juridica');
    Card.Lichidata := Text('lichidata');
    Card.Adresa := Text('adresa');
    Card.Administratori := Text('administratori');
    Card.DetailsText := Text('details_text');

    // атрибут idno на корне — запасной источник
    if (Card.Idno = '') and Root.HasAttribute('idno') then
      Card.Idno := VarToStr(Root.Attributes['idno']);

    Node := Root.ChildNodes.FindNode('founders');
    if Assigned(Node) then
      for I := 0 to Node.ChildNodes.Count - 1 do
      begin
        Child := Node.ChildNodes[I];
        if Child.NodeName = 'founder' then
        begin
          F.Name := VarToStr(Child.Attributes['name']);
          F.Share := VarToStr(Child.Attributes['share']);
          Card.Founders := Card.Founders + [F];
        end;
      end;

    Node := Root.ChildNodes.FindNode('debts');
    if Assigned(Node) then
      for I := 0 to Node.ChildNodes.Count - 1 do
      begin
        Child := Node.ChildNodes[I];
        if Child.NodeName = 'debt' then
        begin
          D.Nr := VarToStr(Child.Attributes['nr']);
          D.DebtType := VarToStr(Child.Attributes['type']);
          D.Sum := VarToStr(Child.Attributes['sum']);
          Card.Debts := Card.Debts + [D];
        end;
      end;

    Result := not Card.IsEmpty;
    if not Result then
      FLastError := 'Карточка пуста (нет IDNO и названия).';
  except
    on E: Exception do
    begin
      FLastError := 'Ошибка разбора XML: ' + E.Message;
      Result := False;
    end;
  end;
end;

end.
