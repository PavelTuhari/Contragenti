unit uClientsDB;
{
  Локальная база клиентов CRM на SQLite (через FireDAC).

  База — личная для каждой установки CRM: файл clients.db рядом с программой.
  FireDAC линкует SQLite статически, поэтому внешняя sqlite3.dll не нужна.

  Класс TClientsDB инкапсулирует подключение и операции: открыть/создать,
  перечислить, добавить из карточки Contragenti (с дедупликацией по IDNO),
  удалить.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.Stan.Async, FireDAC.DApt,
  FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef, FireDAC.Stan.ExprFuncs,
  FireDAC.Stan.Param, FireDAC.Comp.UI, FireDAC.ConsoleUI.Wait, Data.DB,
  uContragenti;

type
  TClientRow = record
    Id: Integer;
    Idno: string;
    Denumire: string;
    FormaJuridica: string;
    Adresa: string;
    Administrator: string;
    AddedAt: string;
  end;

  { Результат добавления клиента. }
  TAddResult = (arAdded, arDuplicate, arError);

  TClientsDB = class
  private
    FConn: TFDConnection;
    FDBPath: string;
    procedure EnsureSchema;
  public
    constructor Create(const ADBPath: string);
    destructor Destroy; override;
    procedure Open;

    function Count: Integer;
    function List(const Filter: string = ''): TArray<TClientRow>;
    function ExistsByIdno(const Idno: string): Boolean;
    function AddFromCard(const Card: TCounterpartyCard;
      out NewId: Integer): TAddResult;
    procedure Delete(Id: Integer);

    property DBPath: string read FDBPath;
    property Connection: TFDConnection read FConn;
  end;

implementation

uses
  System.IOUtils;

constructor TClientsDB.Create(const ADBPath: string);
begin
  inherited Create;
  FDBPath := ADBPath;
  FConn := TFDConnection.Create(nil);
  FConn.DriverName := 'SQLite';
  FConn.Params.Values['Database'] := FDBPath;
  // создавать файл, если его нет; ждать блокировки; UTF-8
  FConn.Params.Values['OpenMode'] := 'CreateUTF8';
  FConn.Params.Values['LockingMode'] := 'Normal';
  FConn.Params.Values['Synchronous'] := 'Full';
  FConn.LoginPrompt := False;
end;

destructor TClientsDB.Destroy;
begin
  FConn.Free;
  inherited;
end;

procedure TClientsDB.Open;
begin
  FConn.Connected := True;
  EnsureSchema;
end;

procedure TClientsDB.EnsureSchema;
begin
  FConn.ExecSQL(
    'CREATE TABLE IF NOT EXISTS clients (' +
    '  id            INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  idno          TEXT UNIQUE,' +
    '  denumire      TEXT NOT NULL,' +
    '  forma_juridica TEXT,' +
    '  inregistrare  TEXT,' +
    '  lichidata     TEXT,' +
    '  adresa        TEXT,' +
    '  administrator TEXT,' +
    '  details       TEXT,' +
    '  source        TEXT,' +
    '  added_at      TEXT DEFAULT (datetime(''now'',''localtime''))' +
    ')');
  FConn.ExecSQL(
    'CREATE INDEX IF NOT EXISTS ix_clients_denumire ON clients(denumire)');
end;

function TClientsDB.Count: Integer;
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT COUNT(*) AS n FROM clients');
    Result := Q.FieldByName('n').AsInteger;
  finally
    Q.Free;
  end;
end;

function TClientsDB.List(const Filter: string): TArray<TClientRow>;
var
  Q: TFDQuery;
  Row: TClientRow;
  List: TList<TClientRow>;
  Sql: string;
begin
  List := TList<TClientRow>.Create;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Sql := 'SELECT id, idno, denumire, forma_juridica, adresa, administrator, ' +
           'added_at FROM clients';
    if Filter <> '' then
      Sql := Sql + ' WHERE idno LIKE :f OR denumire LIKE :f OR ' +
             'administrator LIKE :f';
    Sql := Sql + ' ORDER BY added_at DESC, id DESC';
    // параметры существуют только после присвоения SQL
    Q.SQL.Text := Sql;
    if Filter <> '' then
      Q.ParamByName('f').AsString := '%' + Filter + '%';
    Q.Open;
    while not Q.Eof do
    begin
      Row.Id := Q.FieldByName('id').AsInteger;
      Row.Idno := Q.FieldByName('idno').AsString;
      Row.Denumire := Q.FieldByName('denumire').AsString;
      Row.FormaJuridica := Q.FieldByName('forma_juridica').AsString;
      Row.Adresa := Q.FieldByName('adresa').AsString;
      Row.Administrator := Q.FieldByName('administrator').AsString;
      Row.AddedAt := Q.FieldByName('added_at').AsString;
      List.Add(Row);
      Q.Next;
    end;
    Result := List.ToArray;
  finally
    Q.Free;
    List.Free;
  end;
end;

function TClientsDB.ExistsByIdno(const Idno: string): Boolean;
var
  Q: TFDQuery;
begin
  if Idno = '' then
    Exit(False);
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.Open('SELECT 1 FROM clients WHERE idno = :i', [Idno]);
    Result := not Q.IsEmpty;
  finally
    Q.Free;
  end;
end;

function TClientsDB.AddFromCard(const Card: TCounterpartyCard;
  out NewId: Integer): TAddResult;
var
  Q: TFDQuery;
begin
  NewId := 0;
  // Дедупликация по IDNO: тот же контрагент не заводится дважды.
  if (Card.Idno <> '') and ExistsByIdno(Card.Idno) then
    Exit(arDuplicate);

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    try
      Q.ExecSQL(
        'INSERT INTO clients (idno, denumire, forma_juridica, inregistrare, ' +
        'lichidata, adresa, administrator, details, source) ' +
        'VALUES (:idno, :den, :forma, :inreg, :lich, :adr, :adm, :det, :src)',
        [Card.Idno, Card.Denumire, Card.FormaJuridica, Card.Inregistrare,
         Card.Lichidata, Card.Adresa, Card.Administratori, Card.DetailsText,
         'date.gov.md']);
      NewId := FConn.GetLastAutoGenValue('');
      Result := arAdded;
    except
      // гонка: другой поток/копия успела вставить тот же IDNO
      on E: Exception do
        if ExistsByIdno(Card.Idno) then
          Result := arDuplicate
        else
          raise;
    end;
  finally
    Q.Free;
  end;
end;

procedure TClientsDB.Delete(Id: Integer);
begin
  FConn.ExecSQL('DELETE FROM clients WHERE id = :id', [Id]);
end;

var
  GWaitCursor: TFDGUIxWaitCursor = nil;

initialization
  // FireDAC требует зарегистрированный указатель ожидания. В приложении из
  // компонентов его роль играет TFDGUIxWaitCursor с палитры; в коде создаём
  // его сами и назначаем консольный провайдер — тогда ни один режим
  // (GUI и headless) не пытается показать модальный диалог и не зависает.
  GWaitCursor := TFDGUIxWaitCursor.Create(nil);
  GWaitCursor.Provider := 'Console';

finalization
  GWaitCursor.Free;

end.
