unit uBoardCards;
{
  Общие данные досок: карточки заказов / сделок / задач / проектов по
  колонкам-этапам.

  Одни и те же карточки показывают канбан (uKanban) и схема бизнес-процесса
  (uProcess): здесь — загрузка карточек колонки, единственная точка смены
  этапа (MoveBoardCard) и фабрика информативной карточки VCL с цветной
  полосой, значком, суммой, прогрессом оплаты и бейджем срока.

  Доски:
    bkOrders       — заказы по этапам исполнения (аванс → … → закрыто);
    bkDeals        — сделки по воронке;
    bkTasks        — задачи по срокам (просрочено / сегодня / позже / выполнено);
    bkProjects     — проекты по этапам (тендер → договор → аванс → дизайн →
                     производство → сдача → оплата → закрыт | проигран);
    bkProjectTasks — задачи одного проекта по этапам работы (новая → в работе →
                     ожидание → проверка → готово); проект задаёт
                     BoardProjectFilter (0 — все задачи с проектом).

  Смена этапа выставляет те же поля, по которым считаются этапы на рабочем
  столе и в отчётах, поэтому канбан, схема процесса, Гант и плитки всегда
  показывают одно и то же.
}

interface

uses
  System.SysUtils, System.Classes, Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls,
  Vcl.Graphics, uCrmData, uEspoTheme;

type
  TBoardKind = (bkOrders, bkDeals, bkTasks, bkProjects, bkProjectTasks);

  TBoardCard = record
    Id: Integer;
    Col: Integer;
    Title, Subtitle, Amount, Due: string;
    KindValue: string;      // вид заказа / этап сделки / вид задачи (канонический)
    KindText: string;       // то же в переводе (+ исполнитель, приоритет)
    Total, Paid: Double;    // прогресс оплаты (заказы, проекты)
    Overdue, Done: Boolean;
    DaysLeft: Integer;      // до срока; MaxInt — срока нет
    Icon: string;
    Stripe: TColor;
  end;
  TBoardCards = TArray<TBoardCard>;

  THookProc = reference to procedure(Ctrl: TControl);

const
  CARD_H = 96;

var
  { Фильтр доски задач проекта: id проекта (0 — все задачи, у которых есть проект). }
  BoardProjectFilter: Integer = 0;

function BoardTable(Kind: TBoardKind): string;
function BoardColumnTitles(Kind: TBoardKind): TArray<string>;
function BoardColumnWhere(Data: TCrmData; Kind: TBoardKind; Col: Integer): string;
function BoardColumnColor(Kind: TBoardKind; Col: Integer): TColor;
function BoardTitle(Kind: TBoardKind): string;
function LoadBoardCards(Data: TCrmData; Kind: TBoardKind; Col: Integer): TBoardCards;
function BoardColumnSum(const Cards: TBoardCards): Double;
function BoardColumnOverdue(const Cards: TBoardCards): Integer;
{ Единственное место, где карточка меняет этап. False — колонка вне доски. }
function MoveBoardCard(Data: TCrmData; Kind: TBoardKind; Id, NewCol: Integer): Boolean;
{ Информативная карточка. Все дочерние контролы получают AHook (мышь, Tag). }
function MakeBoardCard(AOwner: TComponent; AParent: TWinControl; const C: TBoardCard;
  X, Y, W: Integer; AHook: THookProc): TPanel;
function CardBaseColor(const C: TBoardCard): TColor;
function DaysBadgeText(const C: TBoardCard): string;

implementation

uses
  System.StrUtils, System.Math, System.DateUtils, FireDAC.Comp.Client, uI18n;

const
  // акценты колонок: продажа/сделка — синий, работа — янтарный, готово —
  // зелёный, ожидание оплаты — фиолетовый, закрыто — серый; просрочка — красный
  CLR_BLUE   = $00CA8955;  // #5589ca
  CLR_AMBER  = $002E9BE0;  // #e09b2e
  CLR_GREEN  = $004C9A2A;
  CLR_VIOLET = $00B0668A;  // #8a66b0
  CLR_GRAY   = $00969696;
  CLR_RED    = $004648AD;
  CLR_TEAL   = $00A28F2B;  // #2b8fa2
  ORDER_COLORS: array[0..4] of TColor = (CLR_AMBER, CLR_BLUE, CLR_GREEN, CLR_VIOLET, CLR_GRAY);
  DEAL_COLORS:  array[0..4] of TColor = (CLR_TEAL, CLR_BLUE, CLR_AMBER, CLR_GREEN, CLR_RED);
  TASK_COLORS:  array[0..3] of TColor = (CLR_RED, CLR_AMBER, CLR_BLUE, CLR_GREEN);
  // тендер, договор, аванс, дизайн, производство, сдача, оплата, закрыт, проигран
  PROJECT_COLORS: array[0..8] of TColor = (CLR_TEAL, CLR_BLUE, CLR_AMBER, CLR_VIOLET,
    CLR_AMBER, CLR_GREEN, CLR_VIOLET, CLR_GRAY, CLR_RED);
  // новая, в работе, ожидание, проверка, готово
  TSTAGE_COLORS: array[0..4] of TColor = (CLR_TEAL, CLR_BLUE, CLR_AMBER, CLR_VIOLET, CLR_GREEN);

function BoardTable(Kind: TBoardKind): string;
begin
  case Kind of
    bkDeals: Result := 'deals';
    bkTasks, bkProjectTasks: Result := 'tasks';
    bkProjects: Result := 'projects';
  else Result := 'orders';
  end;
end;

function BoardTitle(Kind: TBoardKind): string;
begin
  case Kind of
    bkDeals: Result := T.S('kanban.board_deals');
    bkTasks: Result := T.S('kanban.board_tasks');
    bkProjects: Result := T.S('kanban.board_projects');
    bkProjectTasks: Result := T.S('kanban.board_project_tasks');
  else Result := T.S('kanban.board_orders');
  end;
end;

function EnumTitles(const EnumName, Canonical: string): TArray<string>;
begin
  Result := T.EnumList(EnumName);
  if Length(Result) <> Length(Canonical.Split([';'])) then
    Result := Canonical.Split([';']);
end;

function BoardColumnTitles(Kind: TBoardKind): TArray<string>;
var
  I: Integer;
begin
  case Kind of
    bkOrders:
      begin
        SetLength(Result, 5);
        for I := 0 to 4 do
        begin
          Result[I] := T.EnumAt('stage_title', Ord(stAwaitAdvance) + I);
          if Result[I] = '' then Result[I] := 'stage ' + IntToStr(I);
        end;
      end;
    bkDeals: Result := EnumTitles('deal_stage', ENUM_DEAL_STAGE);
    bkProjects: Result := EnumTitles('project_status', ENUM_PROJECT_STATUS);
    bkProjectTasks: Result := EnumTitles('task_stage', ENUM_TASK_STAGE);
  else
    Result := T.S('kanban.task_cols').Split([';']);
    if Length(Result) <> 4 then
      Result := ['Просрочено', 'Сегодня', 'Позже', 'Выполнено'];
  end;
end;

function BoardColumnWhere(Data: TCrmData; Kind: TBoardKind; Col: Integer): string;
var
  Stages: TArray<string>;
begin
  case Kind of
    bkOrders:
      Result := Data.StageWhere(TStage(Ord(stAwaitAdvance) + Col));
    bkDeals:
      begin
        Stages := ENUM_DEAL_STAGE.Split([';']);
        Result := 't.stage = ''' + Stages[Col] + '''';
      end;
    bkProjects:
      begin
        Stages := ENUM_PROJECT_STATUS.Split([';']);
        Result := 't.status = ''' + Stages[Col] + '''';
      end;
    bkProjectTasks:
      begin
        Stages := ENUM_TASK_STAGE.Split([';']);
        Result := 't.stage = ''' + Stages[Col] + '''';
        if BoardProjectFilter > 0 then
          Result := Result + ' AND t.project_id = ' + IntToStr(BoardProjectFilter)
        else
          Result := Result + ' AND COALESCE(t.project_id,0) > 0';
      end;
  else
    case Col of
      0: Result := 't.done = 0 AND t.due_at < date(''now'',''localtime'')';
      1: Result := 't.done = 0 AND t.due_at = date(''now'',''localtime'')';
      2: Result := 't.done = 0 AND t.due_at > date(''now'',''localtime'')';
    else Result := 't.done = 1';
    end;
  end;
end;

function BoardColumnColor(Kind: TBoardKind; Col: Integer): TColor;
begin
  Result := CLR_GRAY;
  case Kind of
    bkOrders: if (Col >= 0) and (Col <= 4) then Result := ORDER_COLORS[Col];
    bkDeals:  if (Col >= 0) and (Col <= 4) then Result := DEAL_COLORS[Col];
    bkTasks:  if (Col >= 0) and (Col <= 3) then Result := TASK_COLORS[Col];
    bkProjects: if (Col >= 0) and (Col <= 8) then Result := PROJECT_COLORS[Col];
    bkProjectTasks: if (Col >= 0) and (Col <= 4) then Result := TSTAGE_COLORS[Col];
  end;
end;

function KindIndex(const List: string; const Value: string): Integer;
var
  Parts: TArray<string>;
  I: Integer;
begin
  Parts := List.Split([';']);
  for I := 0 to High(Parts) do
    if Parts[I] = Value then Exit(I);
  Result := -1;
end;

function LoadBoardCards(Data: TCrmData; Kind: TBoardKind; Col: Integer): TBoardCards;
var
  Q: TFDQuery;
  SQL, Today: string;
  C: TBoardCard;
  Titles: TArray<string>;
  LastCol, Idx: Integer;
  D: TDateTime;
begin
  Result := nil;
  Titles := BoardColumnTitles(Kind);
  LastCol := High(Titles);
  Today := FormatDateTime('yyyy-mm-dd', Now);
  case Kind of
    bkOrders:
      SQL := 'SELECT t.id, t.number AS a, COALESCE(c.denumire,'''') AS b, ' +
             ' COALESCE(t.total,0) AS amt, COALESCE(t.paid,0) AS paid, ' +
             ' COALESCE(t.due_date,'''') AS due, t.kind AS k, '''' AS extra ' +
             'FROM orders t LEFT JOIN clients c ON c.id = t.client_id WHERE ' +
             BoardColumnWhere(Data, Kind, Col) + ' ORDER BY t.due_date, t.id';
    bkDeals:
      SQL := 'SELECT t.id, t.title AS a, COALESCE(c.denumire,'''') AS b, ' +
             ' COALESCE(t.amount,0) AS amt, 0 AS paid, COALESCE(t.close_date,'''') AS due, ' +
             ' t.stage AS k, '''' AS extra ' +
             'FROM deals t LEFT JOIN clients c ON c.id = t.client_id WHERE ' +
             BoardColumnWhere(Data, Kind, Col) + ' ORDER BY t.close_date, t.id';
    bkProjects:
      SQL := 'SELECT t.id, t.name AS a, COALESCE(c.denumire,'''') AS b, ' +
             ' COALESCE(t.budget,0) AS amt, COALESCE(t.prepaid,0) + COALESCE(t.paid,0) AS paid, ' +
             ' COALESCE(t.due_date,'''') AS due, t.kind AS k, ' +
             ' (SELECT COUNT(*) FROM tasks x WHERE x.project_id = t.id) || ''/'' || ' +
             ' (SELECT COUNT(*) FROM tasks x WHERE x.project_id = t.id AND x.done = 1) AS extra ' +
             'FROM projects t LEFT JOIN clients c ON c.id = t.client_id WHERE ' +
             BoardColumnWhere(Data, Kind, Col) + ' ORDER BY t.due_date, t.id';
    bkProjectTasks:
      SQL := 'SELECT t.id, t.subject AS a, COALESCE(p.name,'''') AS b, 0 AS amt, 0 AS paid, ' +
             ' COALESCE(t.due_at,'''') AS due, COALESCE(t.priority,''Обычный'') AS k, ' +
             ' COALESCE(t.assignee,'''') AS extra ' +
             'FROM tasks t LEFT JOIN projects p ON p.id = t.project_id WHERE ' +
             BoardColumnWhere(Data, Kind, Col) + ' ORDER BY COALESCE(t.seq,0), t.due_at, t.id';
  else
    SQL := 'SELECT t.id, t.subject AS a, COALESCE(c.denumire,'''') AS b, 0 AS amt, 0 AS paid, ' +
           ' COALESCE(t.due_at,'''') AS due, t.kind AS k, COALESCE(t.assignee,'''') AS extra ' +
           'FROM tasks t LEFT JOIN clients c ON c.id = t.client_id WHERE ' +
           BoardColumnWhere(Data, Kind, Col) + ' ORDER BY t.due_at, t.id';
  end;

  Q := Data.OpenQuery(SQL);
  try
    while not Q.Eof do
    begin
      C := Default(TBoardCard);
      C.Id := Q.FieldByName('id').AsInteger;
      C.Col := Col;
      C.Title := Q.FieldByName('a').AsString;
      C.Subtitle := Q.FieldByName('b').AsString;
      if C.Subtitle = '' then C.Subtitle := T.S('kanban.no_client');
      C.KindValue := Q.FieldByName('k').AsString;
      C.Total := Q.FieldByName('amt').AsFloat;
      C.Paid := Q.FieldByName('paid').AsFloat;
      if C.Total > 0 then
        C.Amount := FormatFloat('#,##0.00', C.Total) + ' MDL';
      C.Due := Q.FieldByName('due').AsString;
      C.Done := Col = LastCol;
      C.DaysLeft := MaxInt;
      if (C.Due <> '') and TryISO8601ToDate(C.Due, D, False) then
        C.DaysLeft := DaysBetween(Trunc(D), Date) * IfThen(Trunc(D) < Date, -1, 1);

      case Kind of
        bkOrders:
          begin
            Idx := KindIndex(ENUM_ORDER_KIND, C.KindValue);
            C.KindText := T.EnumAt('order_kind', Idx);
            C.Title := '№' + C.Title;
            case Idx of
              0: begin C.Icon := '$'; C.Stripe := CLR_BLUE; end;      // продажа
              1: begin C.Icon := '✎'; C.Stripe := CLR_TEAL; end;      // услуга
              2: begin C.Icon := '⚒'; C.Stripe := CLR_AMBER; end;     // производство
            else begin C.Icon := '▣'; C.Stripe := CLR_GRAY; end;
            end;
          end;
        bkDeals:
          begin
            Idx := KindIndex(ENUM_DEAL_STAGE, C.KindValue);
            C.KindText := T.EnumAt('deal_stage', Idx);
            C.Icon := '◆';
            C.Stripe := BoardColumnColor(bkDeals, Col);
          end;
        bkProjects:
          begin
            Idx := KindIndex(ENUM_PROJECT_KIND, C.KindValue);
            C.KindText := T.EnumAt('project_kind', Idx);
            if C.KindText = '' then C.KindText := C.KindValue;
            // задач всего/готово — в строке суммы, чтобы не наезжать на «оплачено»
            C.Amount := C.Amount + '   ·   ' + T.F('kanban.tasks_of', [Q.FieldByName('extra').AsString]);
            case Idx of
              0: begin C.Icon := '▣'; C.Stripe := CLR_BLUE; end;      // реклама
              1: begin C.Icon := '✎'; C.Stripe := CLR_AMBER; end;     // гравировка
              2: begin C.Icon := '★'; C.Stripe := CLR_VIOLET; end;    // сувениры
              3: begin C.Icon := '⚒'; C.Stripe := CLR_TEAL; end;      // монтаж
            else begin C.Icon := '▤'; C.Stripe := CLR_GRAY; end;
            end;
            // проигранный тендер — закрыт, но не «сделано»
            C.Done := Col = 7;
            if Col = 8 then begin C.Icon := '✖'; C.Stripe := CLR_RED; end;
          end;
        bkProjectTasks:
          begin
            Idx := KindIndex(ENUM_TASK_PRIORITY, C.KindValue);
            C.KindText := T.EnumAt('task_priority', Idx);
            if C.KindText = '' then C.KindText := C.KindValue;
            if Q.FieldByName('extra').AsString <> '' then
              C.KindText := C.KindText + '  ·  ' + Q.FieldByName('extra').AsString;
            case Idx of
              2: begin C.Icon := '▲'; C.Stripe := CLR_AMBER; end;     // высокий
              3: begin C.Icon := '‼'; C.Stripe := CLR_RED; end;       // срочно
              0: begin C.Icon := '▽'; C.Stripe := CLR_GRAY; end;      // низкий
            else begin C.Icon := '☑'; C.Stripe := CLR_BLUE; end;
            end;
          end;
      else
        Idx := KindIndex(ENUM_TASK_KIND, C.KindValue);
        C.KindText := T.EnumAt('task_kind', Idx);
        if Q.FieldByName('extra').AsString <> '' then
          C.KindText := C.KindText + '  ·  ' + Q.FieldByName('extra').AsString;
        case Idx of
          1: begin C.Icon := '☎'; C.Stripe := CLR_TEAL; end;         // звонок
          2: begin C.Icon := '☺'; C.Stripe := CLR_VIOLET; end;       // встреча
        else begin C.Icon := '☑'; C.Stripe := CLR_BLUE; end;         // задача
        end;
      end;
      if C.KindText = '' then C.KindText := C.KindValue;
      C.Overdue := (C.Due <> '') and (C.Due < Today) and not C.Done and
                   not ((Kind = bkProjects) and (Col = 8));
      if C.Done then begin C.Icon := '✔'; C.Stripe := CLR_GREEN; end
      else if C.Overdue then C.Stripe := CLR_RED;

      Result := Result + [C];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function BoardColumnSum(const Cards: TBoardCards): Double;
var
  C: TBoardCard;
begin
  Result := 0;
  for C in Cards do Result := Result + C.Total;
end;

function BoardColumnOverdue(const Cards: TBoardCards): Integer;
var
  C: TBoardCard;
begin
  Result := 0;
  for C in Cards do if C.Overdue then Inc(Result);
end;

function MoveBoardCard(Data: TCrmData; Kind: TBoardKind; Id, NewCol: Integer): Boolean;
var
  Titles: TArray<string>;
  Total: Double;
begin
  Titles := BoardColumnTitles(Kind);
  Result := (NewCol >= 0) and (NewCol <= High(Titles));
  if not Result then Exit;

  case Kind of
    bkOrders:
      begin
        Total := Data.Scalar('SELECT COALESCE(total,0) FROM orders WHERE id = ' + IntToStr(Id));
        // выставляем те же поля, по которым считаются этапы процесса
        case NewCol of
          0: Data.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''Подтверждён'', advance = 0, paid = 0, ship_date = NULL WHERE id = :i', [Id]);
          1: Data.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''В работе'', advance = :a, paid = 0, ship_date = NULL WHERE id = :i',
               [Max(0.01, Round(Total * 0.3 * 100) / 100), Id]);
          2: Data.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''Выполнен'', advance = :a, ship_date = NULL WHERE id = :i',
               [Max(0.01, Round(Total * 0.3 * 100) / 100), Id]);
          3: Data.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''Выполнен'', ship_date = :s, paid = :p WHERE id = :i',
               [FormatDateTime('yyyy-mm-dd', Now), Round(Total * 0.3 * 100) / 100, Id]);
          4: Data.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''Оплачен'', paid = :p, ship_date = COALESCE(NULLIF(ship_date,''''), :s) WHERE id = :i',
               [Total, FormatDateTime('yyyy-mm-dd', Now), Id]);
        end;
      end;
    bkDeals:
      Data.DB.Connection.ExecSQL('UPDATE deals SET stage = :s WHERE id = :i',
        [ENUM_DEAL_STAGE.Split([';'])[NewCol], Id]);
    bkProjects:
      begin
        Data.DB.Connection.ExecSQL('UPDATE projects SET status = :s WHERE id = :i',
          [ENUM_PROJECT_STATUS.Split([';'])[NewCol], Id]);
        // деньги следуют за этапом: аванс получен — записан по проценту,
        // закрыт — оплачен полностью
        case NewCol of
          0, 1: Data.DB.Connection.ExecSQL('UPDATE projects SET prepaid = 0, paid = 0 WHERE id = :i', [Id]);
          2..5: Data.DB.Connection.ExecSQL(
                  'UPDATE projects SET prepaid = ROUND(COALESCE(budget,0) * COALESCE(prepay_pct,0) / 100, 2), paid = 0 WHERE id = :i', [Id]);
          7:    Data.DB.Connection.ExecSQL(
                  'UPDATE projects SET paid = COALESCE(budget,0) - COALESCE(prepaid,0) WHERE id = :i', [Id]);
        end;
      end;
    bkProjectTasks:
      Data.SetTaskStage(Id, ENUM_TASK_STAGE.Split([';'])[NewCol]);
  else
    if NewCol = High(Titles) then
      Data.SetTaskDone(Id, True)
    else
    begin
      Data.SetTaskDone(Id, False);
      Data.DB.Connection.ExecSQL('UPDATE tasks SET due_at = :d WHERE id = :i',
        [FormatDateTime('yyyy-mm-dd', Now + IfThen(NewCol = 0, -1, IfThen(NewCol = 1, 0, 7))), Id]);
    end;
  end;
end;

function CardBaseColor(const C: TBoardCard): TColor;
begin
  if C.Done then Result := ST_SUCCESS_BG
  else if C.Overdue then Result := ST_DANGER_BG
  else Result := ESPO_WHITE;
end;

function DaysBadgeText(const C: TBoardCard): string;
begin
  if C.Done then Result := '✔'
  else if C.DaysLeft = MaxInt then Result := ''
  else if C.DaysLeft < 0 then Result := T.F('kanban.days_late', [-C.DaysLeft])
  else if C.DaysLeft = 0 then Result := T.S('kanban.today')
  else Result := T.F('kanban.days_left', [C.DaysLeft]);
end;

function MakeBoardCard(AOwner: TComponent; AParent: TWinControl; const C: TBoardCard;
  X, Y, W: Integer; AHook: THookProc): TPanel;
var
  Stripe, Badge, BarBg, BarFill: TPanel;
  L: TLabel;
  Pct: Integer;
  BadgeText: string;
begin
  Result := TPanel.Create(AOwner);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, CARD_H);
  Result.BevelOuter := bvNone;
  Result.BevelKind := bkFlat;
  Result.Color := CardBaseColor(C);
  Result.ParentBackground := False;
  Result.Cursor := crHandPoint;
  Result.Font.Name := 'Segoe UI';
  if Assigned(AHook) then AHook(Result);

  // цветная полоса слева — вид записи (или просрочка / выполнено)
  Stripe := TPanel.Create(AOwner);
  Stripe.Parent := Result;
  Stripe.SetBounds(0, 0, 5, CARD_H);
  Stripe.BevelOuter := bvNone;
  Stripe.Color := C.Stripe;
  Stripe.ParentBackground := False;
  if Assigned(AHook) then AHook(Stripe);

  // значок и заголовок
  L := MakeLabel(AOwner, Result, C.Icon, 11, 5, 18, C.Stripe, 11);
  L.Font.Style := [fsBold]; L.Transparent := True;
  if Assigned(AHook) then AHook(L);
  L := MakeLabel(AOwner, Result, C.Title, 30, 6, W - 36 - 52, ESPO_TEXT, 9);
  L.Font.Style := [fsBold]; L.Transparent := True;
  if Assigned(AHook) then AHook(L);

  // бейдж срока: «−3 д» красный, «сегодня» янтарный, «5 д» серый, «✔» зелёный
  BadgeText := DaysBadgeText(C);
  if BadgeText <> '' then
  begin
    Badge := TPanel.Create(AOwner);
    Badge.Parent := Result;
    Badge.SetBounds(W - 56, 6, 48, 18);
    Badge.BevelOuter := bvNone;
    Badge.ParentBackground := False;
    Badge.Caption := BadgeText;
    Badge.Font.Name := 'Segoe UI';
    Badge.Font.Size := 8;
    Badge.Font.Style := [fsBold];
    if C.Done then begin Badge.Color := ST_SUCCESS_FG; Badge.Font.Color := clWhite; end
    else if C.DaysLeft < 0 then begin Badge.Color := ST_DANGER_FG; Badge.Font.Color := clWhite; end
    else if C.DaysLeft = 0 then begin Badge.Color := CLR_AMBER; Badge.Font.Color := clWhite; end
    else begin Badge.Color := ESPO_BORDER; Badge.Font.Color := ESPO_GRAY; end;
    if Assigned(AHook) then AHook(Badge);
  end;

  // клиент и вид
  L := MakeLabel(AOwner, Result, '☺ ' + C.Subtitle, 11, 26, W - 18, ESPO_MUTED, 8);
  L.Transparent := True;
  if Assigned(AHook) then AHook(L);
  L := MakeLabel(AOwner, Result, C.KindText, 11, 43, W - 18 - 70, C.Stripe, 8);
  L.Font.Style := [fsBold]; L.Transparent := True;
  if Assigned(AHook) then AHook(L);

  // сумма
  L := MakeLabel(AOwner, Result, C.Amount, 11, 59, W - 18, ESPO_TEXT, 9);
  L.Font.Style := [fsBold]; L.Transparent := True;
  if Assigned(AHook) then AHook(L);

  // прогресс оплаты (только записи с суммой)
  if (C.Total > 0) and (C.Paid >= 0) and (C.Icon <> '◆') then
  begin
    Pct := Min(100, Round(C.Paid / C.Total * 100));
    BarBg := TPanel.Create(AOwner);
    BarBg.Parent := Result;
    BarBg.SetBounds(11, 78, W - 22, 6);
    BarBg.BevelOuter := bvNone;
    BarBg.Color := ESPO_BORDER;
    BarBg.ParentBackground := False;
    if Assigned(AHook) then AHook(BarBg);
    BarFill := TPanel.Create(AOwner);
    BarFill.Parent := BarBg;
    BarFill.SetBounds(0, 0, Max(0, (W - 22) * Pct div 100), 6);
    BarFill.BevelOuter := bvNone;
    BarFill.Color := IfThen(Pct >= 100, ST_SUCCESS_FG, CLR_BLUE);
    BarFill.ParentBackground := False;
    if Assigned(AHook) then AHook(BarFill);
    L := MakeLabel(AOwner, Result, T.F('kanban.paid_pct', [Pct]), W - 80, 43, 70, ESPO_MUTED, 8);
    L.Alignment := taRightJustify; L.Transparent := True;
    if Assigned(AHook) then AHook(L);
  end
  else if C.Due <> '' then
  begin
    L := MakeLabel(AOwner, Result, IfThen(C.Overdue, T.S('kanban.overdue'), T.S('kanban.due')) + ' ' + C.Due,
      11, 76, W - 18, IfThen(C.Overdue, ST_DANGER_FG, ESPO_MUTED), 8);
    L.Transparent := True;
    if Assigned(AHook) then AHook(L);
  end;
end;

end.
