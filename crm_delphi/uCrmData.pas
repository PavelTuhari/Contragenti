unit uCrmData;
{
  Слой данных CRM: описание сущностей (метаданные полей) и универсальный
  CRUD поверх той же SQLite-базы, что и клиенты (uClientsDB).

  Одна таблица — одно описание TEntityDef; страницы интерфейса (uEntityPage)
  строятся из этих описаний автоматически, поэтому добавление раздела —
  это новая запись в EntityDefs, а не новая форма.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  FireDAC.Comp.Client, Data.DB, uClientsDB;

type
  TFieldKind = (fkText, fkMemo, fkNumber, fkMoney, fkDate, fkEnum,
    fkLookupClient, fkLookupDeal, fkLookupItem, fkBool, fkReadOnly);

  TFieldDef = record
    Name: string;        // колонка в таблице
    Caption: string;
    Kind: TFieldKind;
    Enum: string;        // значения через ';' для fkEnum
    ListWidth: Integer;  // ширина колонки в списке, 0 — не показывать
    Required: Boolean;
    Default: string;
  end;

  TEntityDef = record
    Table: string;
    Title: string;       // «Сделки»
    TitleOne: string;    // «сделку»
    Fields: TArray<TFieldDef>;
    OrderBy: string;
    SearchCols: string;  // колонки для фильтра через ','
  end;

  TRow = record
    Id: Integer;
    Values: TArray<string>;   // по порядку Fields
    Display: TArray<string>;  // то же, но lookup/enum раскрыты для показа
  end;

  TOrderLine = record
    Id, ItemId: Integer;
    ItemName, Unit_: string;
    Qty, Price, Sum: Double;
  end;

  TCrmData = class
  private
    FDB: TClientsDB;
    function Conn: TFDConnection;
    function LookupTable(Kind: TFieldKind; out DispCol: string): string;
  public
    constructor Create(ADB: TClientsDB);
    procedure EnsureSchema;

    // универсальный CRUD по метаданным
    function List(const Def: TEntityDef; const Filter: string;
      const ExtraWhere: string = ''): TArray<TRow>;
    function Get(const Def: TEntityDef; Id: Integer; out Row: TRow): Boolean;
    function Insert(const Def: TEntityDef; const Values: TArray<string>): Integer;
    procedure Update(const Def: TEntityDef; Id: Integer; const Values: TArray<string>);
    procedure Delete(const Def: TEntityDef; Id: Integer);
    function Count(const Table: string; const Where: string = ''): Integer;
    function Scalar(const SQL: string): Variant;

    // справочники для выпадающих списков: пары id / название
    function LookupPairs(Kind: TFieldKind): TArray<TPair<Integer, string>>;

    // строки заказа
    function OrderLines(OrderId: Integer): TArray<TOrderLine>;
    procedure AddOrderLine(OrderId, ItemId: Integer; Qty, Price: Double);
    procedure DeleteOrderLine(LineId: Integer);
    function RecalcOrderTotal(OrderId: Integer): Double;
    { Проводка заказа: продажа списывает остаток номенклатуры,
      производство — приходует изделия. Возвращает описание для строки сообщений. }
    function PostOrder(OrderId: Integer): string;

    // лид → клиент
    function ConvertLead(LeadId: Integer; out ClientId: Integer): string;

    property DB: TClientsDB read FDB;
  end;

function FieldDef(const Name, Caption: string; Kind: TFieldKind;
  ListWidth: Integer = 0; Required: Boolean = False; const Enum: string = '';
  const Default: string = ''): TFieldDef;

var
  // ── описания сущностей ──
  DefContacts, DefLeads, DefDeals, DefItems, DefOrders, DefTasks: TEntityDef;

const
  ENUM_CLIENT_TYPE = 'Клиент;Поставщик;Партнёр';
  ENUM_LEAD_STATUS = 'Новый;В работе;Конвертирован;Отказ';
  ENUM_LEAD_SOURCE = 'Сайт;Звонок;Рекомендация;Выставка;Реклама;Другое';
  ENUM_DEAL_STAGE  = 'Новая;Предложение;Переговоры;Выиграна;Проиграна';
  ENUM_ITEM_KIND   = 'Товар;Услуга;Изделие';
  ENUM_UNIT        = 'шт;час;кг;м;м2;л;компл;услуга';
  ENUM_ORDER_KIND  = 'Продажа;Услуга;Производство';
  ENUM_ORDER_STATUS = 'Черновик;Подтверждён;В работе;Выполнен;Оплачен;Отменён';
  ENUM_TASK_KIND   = 'Задача;Звонок;Встреча';

implementation

uses
  System.Variants, System.StrUtils, System.DateUtils;

function FieldDef(const Name, Caption: string; Kind: TFieldKind;
  ListWidth: Integer; Required: Boolean; const Enum, Default: string): TFieldDef;
begin
  Result.Name := Name;
  Result.Caption := Caption;
  Result.Kind := Kind;
  Result.Enum := Enum;
  Result.ListWidth := ListWidth;
  Result.Required := Required;
  Result.Default := Default;
end;

procedure InitDefs;
begin
  DefContacts.Table := 'contacts';
  DefContacts.Title := 'Контакты';
  DefContacts.TitleOne := 'контакт';
  DefContacts.OrderBy := 'name';
  DefContacts.SearchCols := 'name,phone,email,position';
  DefContacts.Fields := [
    FieldDef('name', 'Имя', fkText, 220, True),
    FieldDef('client_id', 'Клиент', fkLookupClient, 240),
    FieldDef('position', 'Должность', fkText, 140),
    FieldDef('phone', 'Телефон', fkText, 120),
    FieldDef('email', 'E-mail', fkText, 160),
    FieldDef('notes', 'Заметки', fkMemo)];

  DefLeads.Table := 'leads';
  DefLeads.Title := 'Лиды';
  DefLeads.TitleOne := 'лид';
  DefLeads.OrderBy := 'id DESC';
  DefLeads.SearchCols := 'name,company,phone,email';
  DefLeads.Fields := [
    FieldDef('name', 'Имя', fkText, 180, True),
    FieldDef('company', 'Компания', fkText, 200),
    FieldDef('status', 'Статус', fkEnum, 110, True, ENUM_LEAD_STATUS, 'Новый'),
    FieldDef('source', 'Источник', fkEnum, 110, False, ENUM_LEAD_SOURCE, 'Сайт'),
    FieldDef('phone', 'Телефон', fkText, 120),
    FieldDef('email', 'E-mail', fkText, 150),
    FieldDef('notes', 'Заметки', fkMemo)];

  DefDeals.Table := 'deals';
  DefDeals.Title := 'Сделки';
  DefDeals.TitleOne := 'сделку';
  DefDeals.OrderBy := 'id DESC';
  DefDeals.SearchCols := 'title';
  DefDeals.Fields := [
    FieldDef('title', 'Название', fkText, 240, True),
    FieldDef('client_id', 'Клиент', fkLookupClient, 220),
    FieldDef('stage', 'Этап', fkEnum, 110, True, ENUM_DEAL_STAGE, 'Новая'),
    FieldDef('amount', 'Сумма, MDL', fkMoney, 110),
    FieldDef('close_date', 'Закрытие', fkDate, 100),
    FieldDef('notes', 'Заметки', fkMemo)];

  DefItems.Table := 'items';
  DefItems.Title := 'Номенклатура';
  DefItems.TitleOne := 'позицию';
  DefItems.OrderBy := 'name';
  DefItems.SearchCols := 'code,name';
  DefItems.Fields := [
    FieldDef('code', 'Код', fkText, 80),
    FieldDef('name', 'Наименование', fkText, 260, True),
    FieldDef('kind', 'Вид', fkEnum, 90, True, ENUM_ITEM_KIND, 'Товар'),
    FieldDef('unit_', 'Ед.', fkEnum, 60, True, ENUM_UNIT, 'шт'),
    FieldDef('price', 'Цена, MDL', fkMoney, 100),
    FieldDef('vat', 'НДС, %', fkNumber, 70, False, '', '20'),
    FieldDef('stock', 'Остаток', fkNumber, 80, False, '', '0'),
    FieldDef('notes', 'Описание', fkMemo)];

  DefOrders.Table := 'orders';
  DefOrders.Title := 'Заказы';
  DefOrders.TitleOne := 'заказ';
  DefOrders.OrderBy := 'id DESC';
  DefOrders.SearchCols := 'number';
  DefOrders.Fields := [
    FieldDef('number', '№', fkText, 70, True),
    FieldDef('order_date', 'Дата', fkDate, 90, True),
    FieldDef('client_id', 'Клиент', fkLookupClient, 220),
    FieldDef('kind', 'Вид', fkEnum, 110, True, ENUM_ORDER_KIND, 'Продажа'),
    FieldDef('status', 'Статус', fkEnum, 110, True, ENUM_ORDER_STATUS, 'Черновик'),
    FieldDef('total', 'Итого, MDL', fkReadOnly, 100),
    FieldDef('notes', 'Примечание', fkMemo)];

  DefTasks.Table := 'tasks';
  DefTasks.Title := 'Календарь';
  DefTasks.TitleOne := 'задачу';
  DefTasks.OrderBy := 'done, due_at';
  DefTasks.SearchCols := 'subject';
  DefTasks.Fields := [
    FieldDef('subject', 'Тема', fkText, 240, True),
    FieldDef('kind', 'Вид', fkEnum, 90, True, ENUM_TASK_KIND, 'Задача'),
    FieldDef('due_at', 'Срок', fkDate, 100, True),
    FieldDef('client_id', 'Клиент', fkLookupClient, 200),
    FieldDef('deal_id', 'Сделка', fkLookupDeal, 160),
    FieldDef('done', 'Выполнено', fkBool, 90),
    FieldDef('notes', 'Заметки', fkMemo)];
end;

{ TCrmData }

constructor TCrmData.Create(ADB: TClientsDB);
begin
  inherited Create;
  FDB := ADB;
end;

function TCrmData.Conn: TFDConnection;
begin
  Result := FDB.Connection;
end;

procedure TCrmData.EnsureSchema;
const
  DDL: array[0..7] of string = (
    // расширение клиентов — колонки добавляются, если их ещё нет (см. ниже)
    '',
    'CREATE TABLE IF NOT EXISTS contacts (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' name TEXT NOT NULL, client_id INTEGER, position TEXT, phone TEXT, email TEXT, notes TEXT)',
    'CREATE TABLE IF NOT EXISTS leads (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' name TEXT NOT NULL, company TEXT, status TEXT, source TEXT, phone TEXT, email TEXT,' +
    ' notes TEXT, client_id INTEGER, created_at TEXT DEFAULT (datetime(''now'',''localtime'')))',
    'CREATE TABLE IF NOT EXISTS deals (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' title TEXT NOT NULL, client_id INTEGER, stage TEXT, amount REAL DEFAULT 0,' +
    ' close_date TEXT, notes TEXT, created_at TEXT DEFAULT (datetime(''now'',''localtime'')))',
    'CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' code TEXT, name TEXT NOT NULL, kind TEXT, unit_ TEXT, price REAL DEFAULT 0,' +
    ' vat REAL DEFAULT 20, stock REAL DEFAULT 0, notes TEXT)',
    'CREATE TABLE IF NOT EXISTS orders (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' number TEXT NOT NULL, order_date TEXT, client_id INTEGER, kind TEXT, status TEXT,' +
    ' total REAL DEFAULT 0, notes TEXT, posted INTEGER DEFAULT 0,' +
    ' created_at TEXT DEFAULT (datetime(''now'',''localtime'')))',
    'CREATE TABLE IF NOT EXISTS order_lines (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' order_id INTEGER NOT NULL, item_id INTEGER NOT NULL, qty REAL DEFAULT 1,' +
    ' price REAL DEFAULT 0, sum REAL DEFAULT 0)',
    'CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' subject TEXT NOT NULL, kind TEXT, due_at TEXT, client_id INTEGER, deal_id INTEGER,' +
    ' done INTEGER DEFAULT 0, notes TEXT, created_at TEXT DEFAULT (datetime(''now'',''localtime'')))');
  ClientCols: array[0..4] of string = ('client_type', 'phone', 'email', 'notes', 'contact_person');
var
  S, C: string;
  Q: TFDQuery;
  Have: Boolean;
begin
  for S in DDL do
    if S <> '' then
      Conn.ExecSQL(S);

  // clients: добавить колонки CRM, если базу создала старая версия
  for C in ClientCols do
  begin
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := Conn;
      Q.Open('PRAGMA table_info(clients)');
      Have := False;
      while not Q.Eof do
      begin
        if SameText(Q.FieldByName('name').AsString, C) then Have := True;
        Q.Next;
      end;
    finally
      Q.Free;
    end;
    if not Have then
      Conn.ExecSQL(Format('ALTER TABLE clients ADD COLUMN %s TEXT', [C]));
  end;
end;

function TCrmData.LookupTable(Kind: TFieldKind; out DispCol: string): string;
begin
  case Kind of
    fkLookupClient: begin Result := 'clients'; DispCol := 'denumire'; end;
    fkLookupDeal:   begin Result := 'deals';   DispCol := 'title'; end;
    fkLookupItem:   begin Result := 'items';   DispCol := 'name'; end;
  else
    Result := ''; DispCol := '';
  end;
end;

function TCrmData.List(const Def: TEntityDef; const Filter, ExtraWhere: string): TArray<TRow>;
var
  Q: TFDQuery;
  SQL, Cols, Where, LT, LD, C: string;
  I: Integer;
  Row: TRow;
  L: TList<TRow>;
  Parts: TArray<string>;
begin
  Cols := 't.id';
  for I := 0 to High(Def.Fields) do
  begin
    Cols := Cols + ', t.' + Def.Fields[I].Name;
    LT := LookupTable(Def.Fields[I].Kind, LD);
    if LT <> '' then
      Cols := Cols + Format(', (SELECT %s FROM %s x WHERE x.id = t.%s) AS %s__disp',
        [LD, LT, Def.Fields[I].Name, Def.Fields[I].Name]);
  end;
  Where := '';
  if (Filter <> '') and (Def.SearchCols <> '') then
  begin
    Parts := Def.SearchCols.Split([',']);
    for C in Parts do
      Where := Where + IfThen(Where = '', '', ' OR ') + 't.' + Trim(C) + ' LIKE :f';
    Where := '(' + Where + ')';
  end;
  if ExtraWhere <> '' then
    Where := IfThen(Where = '', ExtraWhere, Where + ' AND (' + ExtraWhere + ')');
  SQL := 'SELECT ' + Cols + ' FROM ' + Def.Table + ' t';
  if Where <> '' then SQL := SQL + ' WHERE ' + Where;
  if Def.OrderBy <> '' then SQL := SQL + ' ORDER BY ' + Def.OrderBy;

  L := TList<TRow>.Create;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.SQL.Text := SQL;
    if Pos(':f', SQL) > 0 then
      Q.ParamByName('f').AsString := '%' + Filter + '%';
    Q.Open;
    while not Q.Eof do
    begin
      Row.Id := Q.FieldByName('id').AsInteger;
      SetLength(Row.Values, Length(Def.Fields));
      SetLength(Row.Display, Length(Def.Fields));
      for I := 0 to High(Def.Fields) do
      begin
        Row.Values[I] := Q.FieldByName(Def.Fields[I].Name).AsString;
        case Def.Fields[I].Kind of
          fkLookupClient, fkLookupDeal, fkLookupItem:
            Row.Display[I] := Q.FieldByName(Def.Fields[I].Name + '__disp').AsString;
          fkBool:
            Row.Display[I] := IfThen(Row.Values[I] = '1', 'Да', '');
          fkMoney, fkReadOnly:
            Row.Display[I] := FormatFloat('#,##0.00', StrToFloatDef(Row.Values[I], 0));
        else
          Row.Display[I] := Row.Values[I];
        end;
      end;
      L.Add(Row);
      Q.Next;
    end;
    Result := L.ToArray;
  finally
    Q.Free;
    L.Free;
  end;
end;

function TCrmData.Get(const Def: TEntityDef; Id: Integer; out Row: TRow): Boolean;
var
  Rows: TArray<TRow>;
begin
  Rows := List(Def, '', 't.id = ' + IntToStr(Id));
  Result := Length(Rows) = 1;
  if Result then Row := Rows[0];
end;

function TCrmData.Insert(const Def: TEntityDef; const Values: TArray<string>): Integer;
var
  Q: TFDQuery;
  Cols, Pars: string;
  I: Integer;
begin
  Cols := ''; Pars := '';
  for I := 0 to High(Def.Fields) do
  begin
    if Def.Fields[I].Kind = fkReadOnly then Continue;
    Cols := Cols + IfThen(Cols = '', '', ', ') + Def.Fields[I].Name;
    Pars := Pars + IfThen(Pars = '', '', ', ') + ':p' + IntToStr(I);
  end;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.SQL.Text := Format('INSERT INTO %s (%s) VALUES (%s)', [Def.Table, Cols, Pars]);
    for I := 0 to High(Def.Fields) do
      if Def.Fields[I].Kind <> fkReadOnly then
        if (Values[I] = '') and (Def.Fields[I].Kind in [fkLookupClient, fkLookupDeal, fkLookupItem]) then
          begin
            // NULL для пустой ссылки: FireDAC требует тип параметра до Clear
            Q.ParamByName('p' + IntToStr(I)).DataType := ftInteger;
            Q.ParamByName('p' + IntToStr(I)).Clear;
          end
        else
          Q.ParamByName('p' + IntToStr(I)).AsString := Values[I];
    Q.ExecSQL;
    Result := Conn.GetLastAutoGenValue('');
  finally
    Q.Free;
  end;
end;

procedure TCrmData.Update(const Def: TEntityDef; Id: Integer; const Values: TArray<string>);
var
  Q: TFDQuery;
  Sets: string;
  I: Integer;
begin
  Sets := '';
  for I := 0 to High(Def.Fields) do
  begin
    if Def.Fields[I].Kind = fkReadOnly then Continue;
    Sets := Sets + IfThen(Sets = '', '', ', ') + Def.Fields[I].Name + ' = :p' + IntToStr(I);
  end;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.SQL.Text := Format('UPDATE %s SET %s WHERE id = :id', [Def.Table, Sets]);
    for I := 0 to High(Def.Fields) do
      if Def.Fields[I].Kind <> fkReadOnly then
        if (Values[I] = '') and (Def.Fields[I].Kind in [fkLookupClient, fkLookupDeal, fkLookupItem]) then
          begin
            // NULL для пустой ссылки: FireDAC требует тип параметра до Clear
            Q.ParamByName('p' + IntToStr(I)).DataType := ftInteger;
            Q.ParamByName('p' + IntToStr(I)).Clear;
          end
        else
          Q.ParamByName('p' + IntToStr(I)).AsString := Values[I];
    Q.ParamByName('id').AsInteger := Id;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

procedure TCrmData.Delete(const Def: TEntityDef; Id: Integer);
begin
  if Def.Table = 'orders' then
    Conn.ExecSQL('DELETE FROM order_lines WHERE order_id = :o', [Id]);
  Conn.ExecSQL(Format('DELETE FROM %s WHERE id = :id', [Def.Table]), [Id]);
end;

function TCrmData.Count(const Table, Where: string): Integer;
begin
  Result := Scalar('SELECT COUNT(*) FROM ' + Table + IfThen(Where = '', '', ' WHERE ' + Where));
end;

function TCrmData.Scalar(const SQL: string): Variant;
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.Open(SQL);
    if Q.IsEmpty or Q.Fields[0].IsNull then
      Result := 0
    else
      Result := Q.Fields[0].Value;
  finally
    Q.Free;
  end;
end;

function TCrmData.LookupPairs(Kind: TFieldKind): TArray<TPair<Integer, string>>;
var
  Q: TFDQuery;
  LT, LD: string;
  L: TList<TPair<Integer, string>>;
begin
  LT := LookupTable(Kind, LD);
  L := TList<TPair<Integer, string>>.Create;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.Open(Format('SELECT id, %s AS d FROM %s ORDER BY %s', [LD, LT, LD]));
    while not Q.Eof do
    begin
      L.Add(TPair<Integer, string>.Create(Q.FieldByName('id').AsInteger, Q.FieldByName('d').AsString));
      Q.Next;
    end;
    Result := L.ToArray;
  finally
    Q.Free;
    L.Free;
  end;
end;

function TCrmData.OrderLines(OrderId: Integer): TArray<TOrderLine>;
var
  Q: TFDQuery;
  L: TList<TOrderLine>;
  R: TOrderLine;
begin
  L := TList<TOrderLine>.Create;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.Open('SELECT l.id, l.item_id, i.name, i.unit_, l.qty, l.price, l.sum ' +
           'FROM order_lines l LEFT JOIN items i ON i.id = l.item_id ' +
           'WHERE l.order_id = :o ORDER BY l.id', [OrderId]);
    while not Q.Eof do
    begin
      R.Id := Q.FieldByName('id').AsInteger;
      R.ItemId := Q.FieldByName('item_id').AsInteger;
      R.ItemName := Q.FieldByName('name').AsString;
      R.Unit_ := Q.FieldByName('unit_').AsString;
      R.Qty := Q.FieldByName('qty').AsFloat;
      R.Price := Q.FieldByName('price').AsFloat;
      R.Sum := Q.FieldByName('sum').AsFloat;
      L.Add(R);
      Q.Next;
    end;
    Result := L.ToArray;
  finally
    Q.Free;
    L.Free;
  end;
end;

procedure TCrmData.AddOrderLine(OrderId, ItemId: Integer; Qty, Price: Double);
begin
  Conn.ExecSQL('INSERT INTO order_lines (order_id, item_id, qty, price, sum) ' +
    'VALUES (:o, :i, :q, :p, :s)', [OrderId, ItemId, Qty, Price, Qty * Price]);
  RecalcOrderTotal(OrderId);
end;

procedure TCrmData.DeleteOrderLine(LineId: Integer);
var
  OrderId: Integer;
begin
  OrderId := Scalar('SELECT order_id FROM order_lines WHERE id = ' + IntToStr(LineId));
  Conn.ExecSQL('DELETE FROM order_lines WHERE id = :id', [LineId]);
  if OrderId > 0 then RecalcOrderTotal(OrderId);
end;

function TCrmData.RecalcOrderTotal(OrderId: Integer): Double;
begin
  Result := Scalar('SELECT COALESCE(SUM(sum), 0) FROM order_lines WHERE order_id = ' + IntToStr(OrderId));
  Conn.ExecSQL('UPDATE orders SET total = :t WHERE id = :id', [Result, OrderId]);
end;

function TCrmData.PostOrder(OrderId: Integer): string;
var
  Kind, Status: string;
  Posted: Integer;
  Lines: TArray<TOrderLine>;
  L: TOrderLine;
  Sign: Integer;
begin
  Result := '';
  Kind := VarToStr(Scalar('SELECT kind FROM orders WHERE id = ' + IntToStr(OrderId)));
  Status := VarToStr(Scalar('SELECT status FROM orders WHERE id = ' + IntToStr(OrderId)));
  Posted := Scalar('SELECT posted FROM orders WHERE id = ' + IntToStr(OrderId));
  if Posted = 1 then Exit('уже проведён');
  if not ((Status = 'Выполнен') or (Status = 'Оплачен')) then
    Exit('проводится только со статусом «Выполнен» или «Оплачен»');
  if Kind = 'Продажа' then Sign := -1
  else if Kind = 'Производство' then Sign := 1
  else Sign := 0;   // услуги остаток не меняют
  Lines := OrderLines(OrderId);
  if Length(Lines) = 0 then Exit('нет строк');
  for L in Lines do
    if Sign <> 0 then
      Conn.ExecSQL('UPDATE items SET stock = COALESCE(stock,0) + :d WHERE id = :i',
        [Sign * L.Qty, L.ItemId]);
  Conn.ExecSQL('UPDATE orders SET posted = 1 WHERE id = :id', [OrderId]);
  case Sign of
    -1: Result := Format('списано со склада по %d строкам', [Length(Lines)]);
     1: Result := Format('оприходовано изделий по %d строкам', [Length(Lines)]);
  else Result := 'услуги — остатки без изменений';
  end;
end;

function TCrmData.ConvertLead(LeadId: Integer; out ClientId: Integer): string;
var
  Row: TRow;
  Name, Company, Phone, Email: string;
begin
  ClientId := 0;
  if not Get(DefLeads, LeadId, Row) then Exit('лид не найден');
  Name := Row.Values[0]; Company := Row.Values[1];
  Phone := Row.Values[4]; Email := Row.Values[5];
  if Row.Values[2] = 'Конвертирован' then Exit('уже конвертирован');
  Conn.ExecSQL('INSERT INTO clients (denumire, contact_person, phone, email, client_type, source) ' +
    'VALUES (:n, :c, :p, :e, :t, :s)',
    [IfThen(Company = '', Name, Company), Name, Phone, Email, 'Клиент', 'lead']);
  ClientId := Conn.GetLastAutoGenValue('');
  Conn.ExecSQL('UPDATE leads SET status = :s, client_id = :c WHERE id = :id',
    ['Конвертирован', ClientId, LeadId]);
  Result := 'создан клиент «' + IfThen(Company = '', Name, Company) + '»';
end;

initialization
  InitDefs;

end.
