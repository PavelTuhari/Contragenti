unit uReports;
{
  Отчёты CRM и их выгрузка в Excel (.xlsx) и PDF.

  Каждый отчёт — SQL-запрос → TReportTable (uReportTable), а дальше один и
  тот же объект отдаётся в uXlsx или uPdf. Добавить отчёт = добавить ветку
  в BuildReport и запись в REPORTS.
}

interface

uses
  System.SysUtils, System.Classes, uCrmData, uReportTable;

type
  TReportKind = (rkProcess, rkReceivables, rkSalesByClient, rkFunnel, rkStock, rkProjects);

  TReportInfo = record
    Kind: TReportKind;
    Title: string;
    Hint: string;
  end;

  TExportFormat = (efXlsx, efPdf);

const
  REPORTS: array[TReportKind] of TReportInfo = (
    (Kind: rkProcess;      Title: 'Процесс исполнения заказов';
     Hint: 'Этапы от аванса до оплаты, суммы и просрочка'),
    (Kind: rkReceivables;  Title: 'Дебиторская задолженность';
     Hint: 'Отгружено, но не оплачено — по клиентам и срокам'),
    (Kind: rkSalesByClient; Title: 'Продажи по клиентам';
     Hint: 'Заказы, выручка, оплата и долг по каждому клиенту'),
    (Kind: rkFunnel;       Title: 'Воронка продаж';
     Hint: 'Сделки по этапам: количество, сумма, средний чек'),
    (Kind: rkStock;        Title: 'Остатки номенклатуры';
     Hint: 'Товары и изделия: остаток и его стоимость'),
    (Kind: rkProjects;     Title: 'Проекты: тендеры, авансы, задачи';
     Hint: 'Каждый проект: этап, бюджет, аванс и оплата, долг, задачи и просрочка'));

function BuildReport(Data: TCrmData; Kind: TReportKind): TReportTable;
{ Сохраняет отчёт в каталог и возвращает полный путь к файлу. }
function ExportReport(Data: TCrmData; Kind: TReportKind; Fmt: TExportFormat;
  const Dir: string): string;

implementation

uses
  System.IOUtils, System.StrUtils, System.Variants, System.DateUtils, System.Math,
  FireDAC.Comp.Client, uXlsx, uPdf;

function M(V: Double): string;
begin
  Result := FormatFloat('#,##0.00', V);
end;

function N(V: Integer): string;
begin
  Result := IntToStr(V);
end;

function Today: string;
begin
  Result := FormatDateTime('yyyy-mm-dd', Now);
end;

{ ── отчёты ── }

function ReportProcess(Data: TCrmData): TReportTable;
var
  T: TReportTable;
  S: TStage;
  Info: TStageInfo;
  TotalCnt, TotalOver: Integer;
  TotalSum: Double;
begin
  T := TReportTable.Create;
  T.Title := REPORTS[rkProcess].Title;
  T.Subtitle := 'Состояние на ' + Today + '. Просрочка — срок исполнения в прошлом, этап не закрыт.';
  T.AddCol('Этап процесса', ckText, 190);
  T.AddCol('Что означает', ckText, 210);
  T.AddCol('Кол-во', ckNumber, 60);
  T.AddCol('Сумма, MDL', ckMoney, 100);
  T.AddCol('Запаздывает', ckNumber, 80);
  T.AddCol('Сумма просрочки, MDL', ckMoney, 120);
  TotalCnt := 0; TotalOver := 0; TotalSum := 0;
  for S := Low(TStage) to High(TStage) do
  begin
    Info := Data.StageInfo(S);
    T.AddRow([Info.Title, Info.Hint, N(Info.Count), M(Info.Sum),
      IfThen(Info.Overdue > 0, N(Info.Overdue), ''), IfThen(Info.Overdue > 0, M(Info.OverdueSum), '')]);
    if Info.Table = 'orders' then
    begin
      Inc(TotalCnt, Info.Count);
      Inc(TotalOver, Info.Overdue);
      TotalSum := TotalSum + Info.Sum;
    end;
  end;
  T.SetTotals(['Итого по заказам', '', N(TotalCnt), M(TotalSum), N(TotalOver), '']);
  Result := T;
end;

function ReportReceivables(Data: TCrmData): TReportTable;
var
  T: TReportTable;
  Q: TFDQuery;
  Debt, Sum: Double;
  Days: Integer;
begin
  T := TReportTable.Create;
  T.Title := REPORTS[rkReceivables].Title;
  T.Subtitle := 'Отгруженные заказы с непогашенной оплатой на ' + Today;
  T.AddCol('Заказ', ckText, 60);
  T.AddCol('Клиент', ckText, 220);
  T.AddCol('Отгружен', ckDate, 80);
  T.AddCol('Срок оплаты', ckDate, 80);
  T.AddCol('Итого, MDL', ckMoney, 95);
  T.AddCol('Оплачено, MDL', ckMoney, 95);
  T.AddCol('Долг, MDL', ckMoney, 95);
  T.AddCol('Просрочка, дн.', ckNumber, 85);
  Sum := 0;
  Q := Data.OpenQuery(
    'SELECT o.number, COALESCE(c.denumire, ''—'') AS client, o.ship_date, o.due_date, ' +
    ' o.total, COALESCE(o.paid,0) AS paid, ' +
    ' julianday(''now'',''localtime'') - julianday(o.due_date) AS overdue ' +
    'FROM orders o LEFT JOIN clients c ON c.id = o.client_id ' +
    'WHERE o.status <> ''Отменён'' AND COALESCE(o.ship_date,'''') <> '''' ' +
    '  AND COALESCE(o.paid,0) < o.total ' +
    'ORDER BY overdue DESC, o.total DESC');
  try
    while not Q.Eof do
    begin
      Debt := Q.FieldByName('total').AsFloat - Q.FieldByName('paid').AsFloat;
      Sum := Sum + Debt;
      if Q.FieldByName('due_date').AsString = '' then Days := 0
      else Days := Trunc(Q.FieldByName('overdue').AsFloat);
      T.AddRow([Q.FieldByName('number').AsString, Q.FieldByName('client').AsString,
        Q.FieldByName('ship_date').AsString, Q.FieldByName('due_date').AsString,
        M(Q.FieldByName('total').AsFloat), M(Q.FieldByName('paid').AsFloat), M(Debt),
        IfThen(Days > 0, N(Days), '')]);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  T.SetTotals(['Итого', Format('заказов: %d', [T.RowCount]), '', '', '', '', M(Sum), '']);
  Result := T;
end;

function ReportSalesByClient(Data: TCrmData): TReportTable;
var
  T: TReportTable;
  Q: TFDQuery;
  Sum, Paid: Double;
begin
  T := TReportTable.Create;
  T.Title := REPORTS[rkSalesByClient].Title;
  T.Subtitle := 'Все заказы, кроме отменённых, на ' + Today;
  T.AddCol('Клиент', ckText, 240);
  T.AddCol('IDNO', ckText, 100);
  T.AddCol('Заказов', ckNumber, 70);
  T.AddCol('Сумма, MDL', ckMoney, 110);
  T.AddCol('Оплачено, MDL', ckMoney, 110);
  T.AddCol('Долг, MDL', ckMoney, 110);
  T.AddCol('Последний заказ', ckDate, 100);
  Sum := 0; Paid := 0;
  Q := Data.OpenQuery(
    'SELECT COALESCE(c.denumire, ''(без клиента)'') AS client, COALESCE(c.idno,'''') AS idno, ' +
    ' COUNT(o.id) AS cnt, COALESCE(SUM(o.total),0) AS total, ' +
    ' COALESCE(SUM(o.paid),0) AS paid, MAX(o.order_date) AS last_date ' +
    'FROM orders o LEFT JOIN clients c ON c.id = o.client_id ' +
    'WHERE o.status <> ''Отменён'' ' +
    'GROUP BY o.client_id ORDER BY total DESC');
  try
    while not Q.Eof do
    begin
      Sum := Sum + Q.FieldByName('total').AsFloat;
      Paid := Paid + Q.FieldByName('paid').AsFloat;
      T.AddRow([Q.FieldByName('client').AsString, Q.FieldByName('idno').AsString,
        N(Q.FieldByName('cnt').AsInteger), M(Q.FieldByName('total').AsFloat),
        M(Q.FieldByName('paid').AsFloat),
        M(Q.FieldByName('total').AsFloat - Q.FieldByName('paid').AsFloat),
        Q.FieldByName('last_date').AsString]);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  T.SetTotals(['Итого', '', N(T.RowCount), M(Sum), M(Paid), M(Sum - Paid), '']);
  Result := T;
end;

function ReportFunnel(Data: TCrmData): TReportTable;
var
  T: TReportTable;
  Q: TFDQuery;
  Sum: Double;
  Cnt: Integer;
begin
  T := TReportTable.Create;
  T.Title := REPORTS[rkFunnel].Title;
  T.Subtitle := 'Сделки по этапам на ' + Today;
  T.AddCol('Этап', ckText, 160);
  T.AddCol('Сделок', ckNumber, 70);
  T.AddCol('Сумма, MDL', ckMoney, 120);
  T.AddCol('Средний чек, MDL', ckMoney, 130);
  T.AddCol('Ближайшее закрытие', ckDate, 130);
  Sum := 0; Cnt := 0;
  Q := Data.OpenQuery(
    'SELECT stage, COUNT(*) AS cnt, COALESCE(SUM(amount),0) AS total, ' +
    ' MIN(NULLIF(close_date,'''')) AS nearest FROM deals ' +
    'GROUP BY stage ORDER BY total DESC');
  try
    while not Q.Eof do
    begin
      Sum := Sum + Q.FieldByName('total').AsFloat;
      Inc(Cnt, Q.FieldByName('cnt').AsInteger);
      T.AddRow([Q.FieldByName('stage').AsString, N(Q.FieldByName('cnt').AsInteger),
        M(Q.FieldByName('total').AsFloat),
        M(Q.FieldByName('total').AsFloat / Max(1, Q.FieldByName('cnt').AsInteger)),
        Q.FieldByName('nearest').AsString]);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  T.SetTotals(['Итого', N(Cnt), M(Sum), M(Sum / Max(1, Cnt)), '']);
  Result := T;
end;

function ReportStock(Data: TCrmData): TReportTable;
var
  T: TReportTable;
  Q: TFDQuery;
  Sum: Double;
begin
  T := TReportTable.Create;
  T.Title := REPORTS[rkStock].Title;
  T.Subtitle := 'Товары и изделия (услуги не имеют остатка) на ' + Today;
  T.AddCol('Код', ckText, 70);
  T.AddCol('Наименование', ckText, 250);
  T.AddCol('Вид', ckText, 80);
  T.AddCol('Ед.', ckText, 50);
  T.AddCol('Цена, MDL', ckMoney, 95);
  T.AddCol('Остаток', ckNumber, 75);
  T.AddCol('Стоимость, MDL', ckMoney, 115);
  Sum := 0;
  Q := Data.OpenQuery(
    'SELECT code, name, kind, unit_, COALESCE(price,0) AS price, COALESCE(stock,0) AS stock, ' +
    ' COALESCE(price,0) * COALESCE(stock,0) AS value FROM items ' +
    'WHERE kind <> ''Услуга'' ORDER BY value DESC, name');
  try
    while not Q.Eof do
    begin
      Sum := Sum + Q.FieldByName('value').AsFloat;
      T.AddRow([Q.FieldByName('code').AsString, Q.FieldByName('name').AsString,
        Q.FieldByName('kind').AsString, Q.FieldByName('unit_').AsString,
        M(Q.FieldByName('price').AsFloat),
        FormatFloat('0.##', Q.FieldByName('stock').AsFloat),
        M(Q.FieldByName('value').AsFloat)]);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  T.SetTotals(['Итого', Format('позиций: %d', [T.RowCount]), '', '', '', '', M(Sum)]);
  Result := T;
end;

{ Проекты: по каждому — этап, тендер, деньги (бюджет, аванс по проценту и
  фактически, оплачено, долг) и задачи (всего / готово / просрочено). }
function ReportProjects(Data: TCrmData): TReportTable;
var
  T: TReportTable;
  Q: TFDQuery;
  Budget, Prepaid, Paid, Debt, SumBudget, SumPaid, SumDebt: Double;
  Total, Done, Over, Cnt, OverAll: Integer;
  HP, HF: Double;
  Status: string;
begin
  T := TReportTable.Create;
  T.Title := REPORTS[rkProjects].Title;
  T.Subtitle := 'Состояние на ' + Today + '. Долг = бюджет − аванс − оплата (для незакрытых и не проигранных).';
  T.AddCol('Проект', ckText, 200);
  T.AddCol('Клиент', ckText, 150);
  T.AddCol('Этап', ckText, 80);
  T.AddCol('Тендер', ckText, 70);
  T.AddCol('Бюджет, MDL', ckMoney, 90);
  T.AddCol('Аванс, %', ckNumber, 55);
  T.AddCol('Аванс, MDL', ckMoney, 85);
  T.AddCol('Оплачено, MDL', ckMoney, 90);
  T.AddCol('Долг, MDL', ckMoney, 85);
  T.AddCol('Задач', ckNumber, 50);
  T.AddCol('Готово', ckNumber, 55);
  T.AddCol('Просрочено', ckNumber, 70);
  T.AddCol('Сдача', ckDate, 80);
  SumBudget := 0; SumPaid := 0; SumDebt := 0; Cnt := 0; OverAll := 0;
  Q := Data.OpenQuery(
    'SELECT p.id, p.name, COALESCE(c.denumire, ''—'') AS client, p.status, ' +
    ' COALESCE(p.tender_no,'''') AS tender, COALESCE(p.budget,0) AS budget, ' +
    ' COALESCE(p.prepay_pct,0) AS pct, COALESCE(p.prepaid,0) AS prepaid, COALESCE(p.paid,0) AS paid, ' +
    ' COALESCE(p.due_date,'''') AS due ' +
    'FROM projects p LEFT JOIN clients c ON c.id = p.client_id ' +
    'ORDER BY CASE p.status WHEN ''Закрыт'' THEN 2 WHEN ''Проигран'' THEN 3 ELSE 1 END, p.due_date');
  try
    while not Q.Eof do
    begin
      Status := Q.FieldByName('status').AsString;
      Budget := Q.FieldByName('budget').AsFloat;
      Prepaid := Q.FieldByName('prepaid').AsFloat;
      Paid := Q.FieldByName('paid').AsFloat;
      if (Status = 'Закрыт') or (Status = 'Проигран') then Debt := 0
      else Debt := Max(0, Budget - Prepaid - Paid);
      Data.ProjectSummary(Q.FieldByName('id').AsInteger, Total, Done, Over, HP, HF);
      T.AddRow([Q.FieldByName('name').AsString, Q.FieldByName('client').AsString, Status,
        Q.FieldByName('tender').AsString, M(Budget), N(Round(Q.FieldByName('pct').AsFloat)),
        M(Prepaid), M(Paid), IfThen(Debt > 0, M(Debt), ''), N(Total), N(Done),
        IfThen(Over > 0, N(Over), ''), Q.FieldByName('due').AsString]);
      if Status <> 'Проигран' then
      begin
        SumBudget := SumBudget + Budget;
        SumPaid := SumPaid + Prepaid + Paid;
        SumDebt := SumDebt + Debt;
      end;
      Inc(Cnt);
      Inc(OverAll, Over);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  T.SetTotals(['Итого', Format('проектов: %d', [Cnt]), '', '', M(SumBudget), '', '',
    M(SumPaid), M(SumDebt), '', '', N(OverAll), '']);
  Result := T;
end;

function BuildReport(Data: TCrmData; Kind: TReportKind): TReportTable;
begin
  case Kind of
    rkProcess:       Result := ReportProcess(Data);
    rkReceivables:   Result := ReportReceivables(Data);
    rkSalesByClient: Result := ReportSalesByClient(Data);
    rkFunnel:        Result := ReportFunnel(Data);
    rkStock:         Result := ReportStock(Data);
    rkProjects:      Result := ReportProjects(Data);
  else
    raise Exception.Create('Неизвестный отчёт');
  end;
end;

function SafeName(const S: string): string;
var
  C: Char;
begin
  Result := '';
  for C in S do
    if CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', ' ', '-', '_']) then
      Result := Result + C
    else if C = ' ' then
      Result := Result + '_';
  Result := Trim(Result);
end;

function ExportReport(Data: TCrmData; Kind: TReportKind; Fmt: TExportFormat;
  const Dir: string): string;
const
  FILES: array[TReportKind] of string = (
    'process', 'receivables', 'sales_by_client', 'funnel', 'stock', 'projects');
var
  T: TReportTable;
  Ext: string;
begin
  if Fmt = efXlsx then Ext := '.xlsx' else Ext := '.pdf';
  TDirectory.CreateDirectory(Dir);
  Result := TPath.Combine(Dir, Format('%s_%s%s',
    [FILES[Kind], FormatDateTime('yyyy-mm-dd', Now), Ext]));
  T := BuildReport(Data, Kind);
  try
    if Fmt = efXlsx then
      SaveTableToXlsx(T, Result)
    else
      SaveTableToPdf(T, Result);
  finally
    T.Free;
  end;
end;

end.
