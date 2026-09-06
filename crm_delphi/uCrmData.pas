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
    fkLookupClient, fkLookupDeal, fkLookupItem, fkLookupProject, fkBool, fkReadOnly);

  TFieldDef = record
    Name: string;        // колонка в таблице
    Caption: string;
    Kind: TFieldKind;
    Enum: string;        // канонические значения через ';' — они лежат в базе
    EnumName: string;    // имя списка в lang.json для показа перевода
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

  { Этап процесса «от контракта до денег» — по нему строятся плитки
    рабочего стола. Условия взаимоисключающие, см. StageWhere. }
  TStage = (stDealOffer, stDealTalks, stDealWon,
    stAwaitAdvance, stInWork, stReadyToShip, stAwaitPayment, stClosed);

  TStageInfo = record
    Stage: TStage;
    Title: string;      // «Ожидает аванс»
    Hint: string;       // пояснение процесса
    Table: string;      // deals | orders
    Count: Integer;
    Sum: Double;
    Overdue: Integer;   // сколько из них запаздывает
    OverdueSum: Double;
  end;

  TCrmData = class
  private
    FDB: TClientsDB;
    function Conn: TFDConnection;
    function LookupTable(Kind: TFieldKind; out DispCol: string): string;
    procedure AddColumn(const Table, Col, Decl: string);
  public
    constructor Create(ADB: TClientsDB);
    procedure EnsureSchema;

    { ── процесс работы: этапы, суммы, просрочка ── }
    function StageWhere(Stage: TStage): string;
    function OverdueWhere(Stage: TStage): string;
    function StageInfo(Stage: TStage): TStageInfo;
    function StageOf(OrderId: Integer): TStage;

    // универсальный CRUD по метаданным
    function List(const Def: TEntityDef; const Filter: string;
      const ExtraWhere: string = ''): TArray<TRow>;
    function Get(const Def: TEntityDef; Id: Integer; out Row: TRow): Boolean;
    function Insert(const Def: TEntityDef; const Values: TArray<string>): Integer;
    procedure Update(const Def: TEntityDef; Id: Integer; const Values: TArray<string>);
    procedure Delete(const Def: TEntityDef; Id: Integer);
    function Count(const Table: string; const Where: string = ''): Integer;
    function Scalar(const SQL: string): Variant;
    { Открытый запрос для отчётов; освобождает вызывающий код. }
    function OpenQuery(const SQL: string): TFDQuery;

    { ── пользователи и вход ── }
    procedure EnsureAdmin;
    function CheckLogin(const User, Password: string): Boolean;
    function SetPassword(const User, Password: string): Boolean;
    function UserCount: Integer;

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

    { ── задачи и проекты ── }
    { Этап и флаг «выполнено» — одно состояние с двух сторон: «Готово» ⇔ done.
      Все переключения идут через эти два метода (кнопка, канбан, схема). }
    procedure SetTaskDone(TaskId: Integer; Done: Boolean);
    procedure SetTaskStage(TaskId: Integer; const Stage: string);
    { Сводка по проекту: задач всего / готово / просрочено, часы план / факт. }
    procedure ProjectSummary(ProjectId: Integer; out Total, Done, Overdue: Integer;
      out HoursPlan, HoursFact: Double);
    { Процент готовности проекта по задачам (0..100). }
    function ProjectProgress(ProjectId: Integer): Integer;

    property DB: TClientsDB read FDB;
  end;

function FieldDef(const Name, Caption: string; Kind: TFieldKind;
  ListWidth: Integer = 0; Required: Boolean = False; const Enum: string = '';
  const Default: string = ''; const EnumName: string = ''): TFieldDef;
{ Значение по умолчанию «today» / «today+N» превращает в дату; остальное
  возвращает как есть. Используется и редактором, и генератором данных. }
function ResolveDefault(const S: string): string;
{ Перевод значения перечисления для показа: в базе остаётся каноническое. }
function EnumDisplay(const EnumName, Canonical, CanonicalList: string): string;
function EnumDisplayList(const EnumName, CanonicalList: string): TArray<string>;

var
  // ── описания сущностей ──
  DefContacts, DefLeads, DefDeals, DefItems, DefOrders, DefTasks, DefProjects: TEntityDef;

const
  ENUM_CLIENT_TYPE = 'Клиент;Поставщик;Партнёр';
  // проект — единичное изделие/услуга под заказ (тендер → сдача → оплата)
  ENUM_PROJECT_KIND   = 'Реклама;Гравировка;Сувениры;Монтаж;Другое';
  ENUM_PROJECT_STATUS = 'Тендер;Договор;Аванс;Дизайн;Производство;Сдача;Оплата;Закрыт;Проигран';
  // этап задачи — колонки доски задач проекта; «Готово» ⇔ done = 1
  ENUM_TASK_STAGE    = 'Новая;В работе;Ожидание;Проверка;Готово';
  ENUM_TASK_PRIORITY = 'Низкий;Обычный;Высокий;Срочно';
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
  System.Variants, System.StrUtils, System.DateUtils, System.Hash, System.Math, uI18n;

var
  // числа в базу пишутся с точкой независимо от локали Windows
  FloatFS: TFormatSettings;

function FieldDef(const Name, Caption: string; Kind: TFieldKind;
  ListWidth: Integer; Required: Boolean; const Enum, Default, EnumName: string): TFieldDef;
begin
  Result.Name := Name;
  Result.Caption := Caption;
  Result.Kind := Kind;
  Result.Enum := Enum;
  Result.EnumName := EnumName;
  Result.ListWidth := ListWidth;
  Result.Required := Required;
  Result.Default := Default;
end;

function EnumDisplayList(const EnumName, CanonicalList: string): TArray<string>;
begin
  Result := T.EnumList(EnumName);
  // перевода нет или он неполный — показываем канонические значения
  if Length(Result) <> Length(CanonicalList.Split([';'])) then
    Result := CanonicalList.Split([';']);
end;

function EnumDisplay(const EnumName, Canonical, CanonicalList: string): string;
var
  Canon, Disp: TArray<string>;
  I: Integer;
begin
  Result := Canonical;
  Canon := CanonicalList.Split([';']);
  Disp := EnumDisplayList(EnumName, CanonicalList);
  for I := 0 to High(Canon) do
    if Canon[I] = Canonical then
      Exit(Disp[I]);
end;

function ResolveDefault(const S: string): string;
begin
  if StartsText('today', S) then
    Result := FormatDateTime('yyyy-mm-dd', Now + StrToIntDef(Copy(S, 6, MaxInt), 0))
  else
    Result := S;
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
    FieldDef('status', 'Статус', fkEnum, 110, True, ENUM_LEAD_STATUS, 'Новый', 'lead_status'),
    FieldDef('source', 'Источник', fkEnum, 110, False, ENUM_LEAD_SOURCE, 'Сайт', 'lead_source'),
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
    FieldDef('stage', 'Этап', fkEnum, 110, True, ENUM_DEAL_STAGE, 'Новая', 'deal_stage'),
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
    FieldDef('kind', 'Вид', fkEnum, 90, True, ENUM_ITEM_KIND, 'Товар', 'item_kind'),
    FieldDef('unit_', 'Ед.', fkEnum, 60, True, ENUM_UNIT, 'шт', 'unit'),
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
    FieldDef('number', '№', fkText, 60, True),
    FieldDef('order_date', 'Дата', fkDate, 85, True, '', 'today'),
    FieldDef('client_id', 'Клиент', fkLookupClient, 190),
    FieldDef('project_id', 'Проект', fkLookupProject, 150),
    FieldDef('kind', 'Вид', fkEnum, 100, True, ENUM_ORDER_KIND, 'Продажа', 'order_kind'),
    FieldDef('status', 'Статус', fkEnum, 100, True, ENUM_ORDER_STATUS, 'Черновик', 'order_status'),
    FieldDef('total', 'Итого, MDL', fkReadOnly, 90),
    FieldDef('advance', 'Аванс', fkMoney, 80),
    FieldDef('paid', 'Оплачено', fkMoney, 85),
    FieldDef('due_date', 'Срок', fkDate, 85, False, '', 'today+14'),
    FieldDef('ship_date', 'Отгружен', fkDate, 85),
    FieldDef('notes', 'Примечание', fkMemo)];

  // Задача — единица работы по проекту: этап (колонка доски), приоритет,
  // исполнитель, план начала и срок, часы план/факт, зависимость от другой
  // задачи (№) и порядковый номер в проекте.
  DefTasks.Table := 'tasks';
  DefTasks.Title := 'Календарь';
  DefTasks.TitleOne := 'задачу';
  DefTasks.OrderBy := 'done, due_at, seq';
  DefTasks.SearchCols := 'subject,assignee';
  DefTasks.Fields := [
    FieldDef('subject', 'Тема', fkText, 220, True),
    FieldDef('project_id', 'Проект', fkLookupProject, 170),
    FieldDef('stage', 'Этап', fkEnum, 90, True, ENUM_TASK_STAGE, 'Новая', 'task_stage'),
    FieldDef('priority', 'Приоритет', fkEnum, 80, True, ENUM_TASK_PRIORITY, 'Обычный', 'task_priority'),
    FieldDef('assignee', 'Исполнитель', fkText, 120),
    FieldDef('kind', 'Вид', fkEnum, 80, True, ENUM_TASK_KIND, 'Задача', 'task_kind'),
    FieldDef('plan_start', 'Начало', fkDate, 85, False, '', 'today'),
    FieldDef('due_at', 'Срок', fkDate, 85, True, '', 'today'),
    FieldDef('hours_plan', 'Часы план', fkNumber, 70),
    FieldDef('hours_fact', 'Часы факт', fkNumber, 70),
    FieldDef('seq', '№ в проекте', fkNumber, 60),
    FieldDef('depends_on', 'После задачи №', fkNumber, 0),
    FieldDef('client_id', 'Клиент', fkLookupClient, 160),
    FieldDef('deal_id', 'Сделка', fkLookupDeal, 0),
    FieldDef('done', 'Выполнено', fkBool, 80),
    FieldDef('notes', 'Заметки', fkMemo)];

  // Проект — единичное изделие или услуга под заказ: панно с логотипом,
  // выжиг поздравлений на дереве, стенд… Путь: тендер → договор → аванс →
  // дизайн → производство → сдача → оплата → закрыт (или проигран).
  DefProjects.Table := 'projects';
  DefProjects.Title := 'Проекты';
  DefProjects.TitleOne := 'проект';
  DefProjects.OrderBy := 'id DESC';
  DefProjects.SearchCols := 'name,tender_no,manager';
  DefProjects.Fields := [
    FieldDef('name', 'Проект', fkText, 260, True),
    FieldDef('client_id', 'Клиент', fkLookupClient, 170),
    FieldDef('kind', 'Вид', fkEnum, 90, True, ENUM_PROJECT_KIND, 'Реклама', 'project_kind'),
    FieldDef('status', 'Этап', fkEnum, 100, True, ENUM_PROJECT_STATUS, 'Тендер', 'project_status'),
    FieldDef('tender_no', 'Тендер №', fkText, 90),
    FieldDef('tender_deadline', 'Срок тендера', fkDate, 0),
    FieldDef('budget', 'Бюджет, MDL', fkMoney, 100),
    FieldDef('prepay_pct', 'Аванс, %', fkNumber, 60, False, '', '0'),
    FieldDef('prepaid', 'Аванс получен', fkMoney, 95),
    FieldDef('paid', 'Оплачено', fkMoney, 90),
    FieldDef('start_date', 'Начало', fkDate, 85, False, '', 'today'),
    FieldDef('due_date', 'Сдача', fkDate, 85, True, '', 'today+30'),
    FieldDef('manager', 'Менеджер', fkText, 110),
    FieldDef('notes', 'Описание', fkMemo)];
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
  DDL: array[0..8] of string = (
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
    ' total REAL DEFAULT 0, advance REAL DEFAULT 0, paid REAL DEFAULT 0,' +
    ' due_date TEXT, ship_date TEXT, notes TEXT, posted INTEGER DEFAULT 0,' +
    ' erp_batch TEXT, erp_sent_at TEXT,' +
    ' created_at TEXT DEFAULT (datetime(''now'',''localtime'')))',
    'CREATE TABLE IF NOT EXISTS order_lines (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' order_id INTEGER NOT NULL, item_id INTEGER NOT NULL, qty REAL DEFAULT 1,' +
    ' price REAL DEFAULT 0, sum REAL DEFAULT 0)',
    'CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' login TEXT UNIQUE NOT NULL, pass_hash TEXT NOT NULL, full_name TEXT,' +
    ' created_at TEXT DEFAULT (datetime(''now'',''localtime'')))',
    'CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' subject TEXT NOT NULL, kind TEXT, due_at TEXT, client_id INTEGER, deal_id INTEGER,' +
    ' done INTEGER DEFAULT 0, notes TEXT, created_at TEXT DEFAULT (datetime(''now'',''localtime'')))');
  PROJECTS_DDL =
    'CREATE TABLE IF NOT EXISTS projects (id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    ' name TEXT NOT NULL, client_id INTEGER, kind TEXT, status TEXT, tender_no TEXT,' +
    ' tender_deadline TEXT, budget REAL DEFAULT 0, prepay_pct REAL DEFAULT 0,' +
    ' prepaid REAL DEFAULT 0, paid REAL DEFAULT 0, start_date TEXT, due_date TEXT,' +
    ' manager TEXT, notes TEXT, created_at TEXT DEFAULT (datetime(''now'',''localtime'')))';
  ClientCols: array[0..4] of string = ('client_type', 'phone', 'email', 'notes', 'contact_person');
  // колонки процесса исполнения заказа, добавленные позже создания таблицы
  OrderCols: array[0..6] of string = ('advance REAL DEFAULT 0', 'paid REAL DEFAULT 0',
    'due_date TEXT', 'ship_date TEXT', 'erp_batch TEXT', 'erp_sent_at TEXT', 'project_id INTEGER');
  // проектные поля задач (этап, приоритет, исполнитель, план, часы, зависимость)
  TaskCols: array[0..8] of string = ('project_id INTEGER', 'stage TEXT', 'priority TEXT',
    'assignee TEXT', 'plan_start TEXT', 'hours_plan REAL', 'hours_fact REAL',
    'depends_on INTEGER', 'seq INTEGER');
var
  S, C: string;
begin
  for S in DDL do
    if S <> '' then
      Conn.ExecSQL(S);
  Conn.ExecSQL(PROJECTS_DDL);

  for C in ClientCols do
    AddColumn('clients', C, 'TEXT');
  for C in OrderCols do
    AddColumn('orders', Copy(C, 1, Pos(' ', C + ' ') - 1), Copy(C, Pos(' ', C + ' ') + 1, MaxInt));
  for C in TaskCols do
    AddColumn('tasks', Copy(C, 1, Pos(' ', C + ' ') - 1), Copy(C, Pos(' ', C + ' ') + 1, MaxInt));
  // задачи старой базы: этап из флага «выполнено», приоритет обычный
  Conn.ExecSQL('UPDATE tasks SET stage = CASE WHEN COALESCE(done,0) = 1 THEN ''Готово'' ELSE ''Новая'' END ' +
    'WHERE COALESCE(stage,'''') = ''''');
  Conn.ExecSQL('UPDATE tasks SET priority = ''Обычный'' WHERE COALESCE(priority,'''') = ''''');
  Conn.ExecSQL('UPDATE tasks SET plan_start = due_at WHERE COALESCE(plan_start,'''') = ''''');
end;

{ ── задачи и проекты ── }

procedure TCrmData.SetTaskDone(TaskId: Integer; Done: Boolean);
begin
  if Done then
    Conn.ExecSQL('UPDATE tasks SET done = 1, stage = ''Готово'' WHERE id = :i', [TaskId])
  else
    Conn.ExecSQL('UPDATE tasks SET done = 0, stage = CASE WHEN stage = ''Готово'' THEN ''В работе'' ELSE stage END ' +
      'WHERE id = :i', [TaskId]);
end;

procedure TCrmData.SetTaskStage(TaskId: Integer; const Stage: string);
begin
  Conn.ExecSQL('UPDATE tasks SET stage = :s, done = :d WHERE id = :i',
    [Stage, IfThen(Stage = 'Готово', 1, 0), TaskId]);
end;

procedure TCrmData.ProjectSummary(ProjectId: Integer; out Total, Done, Overdue: Integer;
  out HoursPlan, HoursFact: Double);
var
  Q: TFDQuery;
begin
  Q := OpenQuery(Format(
    'SELECT COUNT(*) AS n, SUM(CASE WHEN done = 1 THEN 1 ELSE 0 END) AS d, ' +
    ' SUM(CASE WHEN done = 0 AND COALESCE(due_at,'''') <> '''' AND due_at < date(''now'',''localtime'') THEN 1 ELSE 0 END) AS o, ' +
    ' COALESCE(SUM(hours_plan),0) AS hp, COALESCE(SUM(hours_fact),0) AS hf ' +
    'FROM tasks WHERE project_id = %d', [ProjectId]));
  try
    Total := Q.FieldByName('n').AsInteger;
    Done := Q.FieldByName('d').AsInteger;
    Overdue := Q.FieldByName('o').AsInteger;
    HoursPlan := Q.FieldByName('hp').AsFloat;
    HoursFact := Q.FieldByName('hf').AsFloat;
  finally
    Q.Free;
  end;
end;

function TCrmData.ProjectProgress(ProjectId: Integer): Integer;
var
  T, D, O: Integer;
  HP, HF: Double;
begin
  ProjectSummary(ProjectId, T, D, O, HP, HF);
  if T = 0 then Result := 0 else Result := Round(D * 100 / T);
end;

{ ── пользователи ── }

{ Пароль хранится только как SHA-256 с солью из логина: в базе нет текста
  пароля, а одинаковые пароли разных пользователей дают разные хеши. }
function PassHash(const User, Password: string): string;
begin
  Result := THashSHA2.GetHashString('crm:' + LowerCase(User) + ':' + Password);
end;

procedure TCrmData.EnsureAdmin;
begin
  if UserCount = 0 then
    Conn.ExecSQL('INSERT INTO users (login, pass_hash, full_name) VALUES (:l, :h, :n)',
      ['admin', PassHash('admin', 'admin'), 'Administrator']);
end;

function TCrmData.UserCount: Integer;
begin
  Result := Scalar('SELECT COUNT(*) FROM users');
end;

function TCrmData.CheckLogin(const User, Password: string): Boolean;
var
  Q: TFDQuery;
begin
  Result := False;
  if Trim(User) = '' then Exit;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.Open('SELECT pass_hash FROM users WHERE login = :l COLLATE NOCASE', [Trim(User)]);
    Result := (not Q.IsEmpty) and
              (Q.FieldByName('pass_hash').AsString = PassHash(Trim(User), Password));
  finally
    Q.Free;
  end;
end;

function TCrmData.SetPassword(const User, Password: string): Boolean;
begin
  Result := Trim(Password) <> '';
  if not Result then Exit;
  Conn.ExecSQL('UPDATE users SET pass_hash = :h WHERE login = :l COLLATE NOCASE',
    [PassHash(Trim(User), Password), Trim(User)]);
end;

{ Добавляет колонку, если её ещё нет — база могла быть создана старой версией. }
procedure TCrmData.AddColumn(const Table, Col, Decl: string);
var
  Q: TFDQuery;
  Have: Boolean;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.Open('PRAGMA table_info(' + Table + ')');
    Have := False;
    while not Q.Eof do
    begin
      if SameText(Q.FieldByName('name').AsString, Col) then Have := True;
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  if not Have then
    Conn.ExecSQL(Format('ALTER TABLE %s ADD COLUMN %s %s', [Table, Col, Decl]));
end;

{ ── этапы процесса ── }

const
  STAGE_TITLES: array[TStage] of string = (
    'Предложение', 'Переговоры', 'Готово к заказу',
    'Ожидает аванс', 'В работе / производство', 'Готово к отгрузке',
    'Отгружено — ждём оплату', 'Закрыто');
  STAGE_HINTS: array[TStage] of string = (
    'КП отправлено клиенту', 'Согласование условий', 'Сделка выиграна — оформить заказ',
    'Заказ подтверждён, аванс не поступил', 'Аванс есть, идёт исполнение',
    'Исполнен, отгрузка не оформлена', 'Отгружен, оплата не закрыта',
    'Отгружен и полностью оплачен');
  STAGE_TABLES: array[TStage] of string = (
    'deals', 'deals', 'deals', 'orders', 'orders', 'orders', 'orders', 'orders');

function TCrmData.StageWhere(Stage: TStage): string;
const
  NOT_CANCELLED = 't.status <> ''Отменён'' AND ';
begin
  case Stage of
    stDealOffer:     Result := 't.stage = ''Предложение''';
    stDealTalks:     Result := 't.stage = ''Переговоры''';
    stDealWon:       Result := 't.stage = ''Выиграна''';
    stAwaitAdvance:  Result := NOT_CANCELLED + 't.status = ''Подтверждён'' AND COALESCE(t.advance,0) <= 0';
    stInWork:        Result := NOT_CANCELLED + 't.status IN (''Подтверждён'',''В работе'') AND COALESCE(t.advance,0) > 0';
    stReadyToShip:   Result := NOT_CANCELLED + 't.status IN (''Выполнен'',''Оплачен'') AND COALESCE(t.ship_date,'''') = ''''';
    stAwaitPayment:  Result := NOT_CANCELLED + 'COALESCE(t.ship_date,'''') <> '''' AND COALESCE(t.paid,0) < t.total';
    stClosed:        Result := NOT_CANCELLED + 'COALESCE(t.ship_date,'''') <> '''' AND COALESCE(t.paid,0) >= t.total';
  else Result := '1=1';
  end;
end;

{ Запаздывает: срок в прошлом, а этап ещё не закрыт. }
function TCrmData.OverdueWhere(Stage: TStage): string;
begin
  if Stage in [stDealOffer, stDealTalks, stDealWon] then
    Result := StageWhere(Stage) +
      ' AND COALESCE(t.close_date,'''') <> '''' AND t.close_date < date(''now'',''localtime'')'
  else if Stage = stClosed then
    Result := StageWhere(Stage) + ' AND 1=0'
  else
    Result := StageWhere(Stage) +
      ' AND COALESCE(t.due_date,'''') <> '''' AND t.due_date < date(''now'',''localtime'')';
end;

function TCrmData.StageInfo(Stage: TStage): TStageInfo;
var
  Tbl, SumCol: string;
begin
  Result.Stage := Stage;
  // названия этапов берём из lang.json; если перевода нет — из кода
  Result.Title := T.EnumAt('stage_title', Ord(Stage));
  if Result.Title = '' then Result.Title := STAGE_TITLES[Stage];
  Result.Hint := T.EnumAt('stage_hint', Ord(Stage));
  if Result.Hint = '' then Result.Hint := STAGE_HINTS[Stage];
  Tbl := STAGE_TABLES[Stage];
  Result.Table := Tbl;
  if Tbl = 'deals' then SumCol := 'amount' else SumCol := 'total';
  Result.Count := Scalar(Format('SELECT COUNT(*) FROM %s t WHERE %s', [Tbl, StageWhere(Stage)]));
  Result.Sum := Scalar(Format('SELECT COALESCE(SUM(t.%s),0) FROM %s t WHERE %s', [SumCol, Tbl, StageWhere(Stage)]));
  Result.Overdue := Scalar(Format('SELECT COUNT(*) FROM %s t WHERE %s', [Tbl, OverdueWhere(Stage)]));
  Result.OverdueSum := Scalar(Format('SELECT COALESCE(SUM(t.%s),0) FROM %s t WHERE %s', [SumCol, Tbl, OverdueWhere(Stage)]));
end;

function TCrmData.StageOf(OrderId: Integer): TStage;
var
  S: TStage;
begin
  Result := stAwaitAdvance;
  for S := stAwaitAdvance to stClosed do
    if Scalar(Format('SELECT COUNT(*) FROM orders t WHERE t.id = %d AND (%s)',
      [OrderId, StageWhere(S)])) > 0 then
      Exit(S);
end;

function TCrmData.LookupTable(Kind: TFieldKind; out DispCol: string): string;
begin
  case Kind of
    fkLookupClient: begin Result := 'clients'; DispCol := 'denumire'; end;
    fkLookupDeal:   begin Result := 'deals';   DispCol := 'title'; end;
    fkLookupItem:   begin Result := 'items';   DispCol := 'name'; end;
    fkLookupProject: begin Result := 'projects'; DispCol := 'name'; end;
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
          fkLookupClient, fkLookupDeal, fkLookupItem, fkLookupProject:
            Row.Display[I] := Q.FieldByName(Def.Fields[I].Name + '__disp').AsString;
          fkEnum:
            Row.Display[I] := EnumDisplay(Def.Fields[I].EnumName, Row.Values[I],
              Def.Fields[I].Enum);
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
        if (Values[I] = '') and (Def.Fields[I].Kind in [fkLookupClient, fkLookupDeal, fkLookupItem, fkLookupProject]) then
          begin
            // NULL для пустой ссылки: FireDAC требует тип параметра до Clear
            Q.ParamByName('p' + IntToStr(I)).DataType := ftInteger;
            Q.ParamByName('p' + IntToStr(I)).Clear;
          end
        else if (Values[I] = '') and (Def.Fields[I].Kind in [fkMoney, fkNumber]) then
          begin
            // Пустое число — NULL, а не пустая строка: SQLite типизирует
            // значения по факту, и текст '' ломал бы сравнения COALESCE(...)>0.
            Q.ParamByName('p' + IntToStr(I)).DataType := ftFloat;
            Q.ParamByName('p' + IntToStr(I)).Clear;
          end
        else if (Values[I] <> '') and (Def.Fields[I].Kind in [fkMoney, fkNumber]) then
          Q.ParamByName('p' + IntToStr(I)).AsFloat :=
            StrToFloatDef(StringReplace(Values[I], ',', '.', [rfReplaceAll]), 0, FloatFS)
        else
          Q.ParamByName('p' + IntToStr(I)).AsString := Values[I];
    Q.ExecSQL;
    Result := Conn.GetLastAutoGenValue('');
  finally
    Q.Free;
  end;
  if Def.Table = 'tasks' then
    Conn.ExecSQL('UPDATE tasks SET done = CASE WHEN stage = ''Готово'' THEN 1 ELSE COALESCE(done,0) END, ' +
      'stage = CASE WHEN COALESCE(done,0) = 1 AND COALESCE(stage,'''') <> ''Готово'' THEN ''Готово'' ELSE stage END ' +
      'WHERE id = :i', [Result]);
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
        if (Values[I] = '') and (Def.Fields[I].Kind in [fkLookupClient, fkLookupDeal, fkLookupItem, fkLookupProject]) then
          begin
            // NULL для пустой ссылки: FireDAC требует тип параметра до Clear
            Q.ParamByName('p' + IntToStr(I)).DataType := ftInteger;
            Q.ParamByName('p' + IntToStr(I)).Clear;
          end
        else if (Values[I] = '') and (Def.Fields[I].Kind in [fkMoney, fkNumber]) then
          begin
            // Пустое число — NULL, а не пустая строка: SQLite типизирует
            // значения по факту, и текст '' ломал бы сравнения COALESCE(...)>0.
            Q.ParamByName('p' + IntToStr(I)).DataType := ftFloat;
            Q.ParamByName('p' + IntToStr(I)).Clear;
          end
        else if (Values[I] <> '') and (Def.Fields[I].Kind in [fkMoney, fkNumber]) then
          Q.ParamByName('p' + IntToStr(I)).AsFloat :=
            StrToFloatDef(StringReplace(Values[I], ',', '.', [rfReplaceAll]), 0, FloatFS)
        else
          Q.ParamByName('p' + IntToStr(I)).AsString := Values[I];
    Q.ParamByName('id').AsInteger := Id;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
  // задача: этап и флаг «выполнено» — одно состояние; редактор мог поменять
  // любое из двух полей, приводим их к согласию по этапу
  if Def.Table = 'tasks' then
    Conn.ExecSQL('UPDATE tasks SET done = CASE WHEN stage = ''Готово'' THEN 1 ELSE 0 END WHERE id = :i', [Id]);
end;

procedure TCrmData.Delete(const Def: TEntityDef; Id: Integer);
begin
  if Def.Table = 'orders' then
    Conn.ExecSQL('DELETE FROM order_lines WHERE order_id = :o', [Id]);
  if Def.Table = 'projects' then
  begin
    // задачи проекта уходят вместе с ним; заказы остаются, ссылка снимается
    Conn.ExecSQL('DELETE FROM tasks WHERE project_id = :p', [Id]);
    Conn.ExecSQL('UPDATE orders SET project_id = NULL WHERE project_id = :p', [Id]);
  end;
  Conn.ExecSQL(Format('DELETE FROM %s WHERE id = :id', [Def.Table]), [Id]);
end;

function TCrmData.Count(const Table, Where: string): Integer;
begin
  // псевдоним t обязателен: условия этапов и пресетов написаны через «t.»
  Result := Scalar('SELECT COUNT(*) FROM ' + Table + ' t' +
    IfThen(Where = '', '', ' WHERE ' + Where));
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

function TCrmData.OpenQuery(const SQL: string): TFDQuery;
begin
  Result := TFDQuery.Create(nil);
  try
    Result.Connection := Conn;
    Result.Open(SQL);
  except
    Result.Free;
    raise;
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
  FloatFS := TFormatSettings.Create;
  FloatFS.DecimalSeparator := '.';
  InitDefs;

end.
