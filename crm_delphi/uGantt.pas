unit uGantt;
{
  Диаграмма Ганта: последовательность работ по заказам во времени.

  Строка — заказ. Светлая полоса — план (от даты заказа до срока), поверх
  неё тёмная — факт (до отгрузки, а если не отгружен — до сегодня). Красным
  показан выход за срок, зелёным — закрытые заказы. Вертикальная линия —
  сегодняшний день.

  Под каждым производственным заказом раскрываются его строки — это и есть
  последовательность работ: они распределены по плановому окну заказа
  друг за другом, чтобы было видно, какая операция когда должна идти.

  Рисуется на TPaintBox, поэтому попадает в снимок формы вместе с окном.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  uCrmData, uEspoTheme;

type
  TGanttRow = record
    IsWork: Boolean;        // строка заказа (операция) или задача проекта, а не сам заказ/проект
    OrderId: Integer;
    ProjectId: Integer;     // режим «Проекты и задачи»
    TaskId: Integer;        // > 0 — задача проекта (её можно тянуть)
    DependsOn: Integer;     // задача, после которой идёт эта (стрелка на схеме)
    Caption: string;
    Sub: string;
    Start, PlanEnd, FactEnd: TDateTime;
    Overdue, Closed: Boolean;
  end;

  { Что делает перетаскивание: двигает весь заказ или тянет одну из границ. }
  TDragMode = (dmNone, dmMove, dmStart, dmEnd);

  TOpenOrderEvent = procedure(OrderId: Integer) of object;
  TOpenIdEvent = procedure(Id: Integer) of object;

  TGanttPage = class(TPanel)
  private
    FData: TCrmData;
    FOnSay: TSayProc;
    FFilter: TComboBox;
    FCanvas: TPaintBox;
    FScroll: TScrollBox;
    FInfo: TLabel;
    FRows: TArray<TGanttRow>;
    FMin, FMax: TDateTime;
    FChartW: Integer;
    FOnOpenOrder: TOpenOrderEvent;
    FOnOpenProject, FOnOpenTask: TOpenIdEvent;
    // перетаскивание полосы мышью
    FDragRow: Integer;
    FDragMode: TDragMode;
    FDragX0: Integer;
    FDragDays: Integer;
    procedure Say(Kind: TMsgKind; const Msg: string);
    function  XOfDate(D: TDateTime): Integer;
    function  DaysPerPixel: Double;
    function  HitTest(X, Y: Integer; out Row: Integer): TDragMode;
    procedure CanvasMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure CanvasMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure CanvasMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure CanvasDblClick(Sender: TObject);
    procedure CommitDrag;
    procedure BuildUI;
    procedure LoadRows;
    procedure LoadProjectRows;
    procedure FinishRows;
    procedure PaintChart(Sender: TObject);
    procedure OnFilterChange(Sender: TObject);
    procedure OnRefreshClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent; AParent: TWinControl; AData: TCrmData;
      ASay: TSayProc); reintroduce;
    procedure Refresh;

    // хуки самотеста
    function RowCount: Integer;
    function WorkCount: Integer;
    function OverdueCount: Integer;
    function RangeText: string;
    procedure SelectFilter(Index: Integer);
    { Тянет полосу тем же путём, что и мышь: нажатие на полосе, сдвиг на
      Days дней и отпускание. Mode задаёт, что именно тянем. }
    function DragBar(Row: Integer; Mode: TDragMode; Days: Integer): Boolean;
    function RowStart(Row: Integer): TDateTime;
    function RowPlanEnd(Row: Integer): TDateTime;
    function RowOrderId(Row: Integer): Integer;
    function RowTaskId(Row: Integer): Integer;
    function RowProjectId(Row: Integer): Integer;
    function FirstTaskRow: Integer;
    property OnOpenOrder: TOpenOrderEvent read FOnOpenOrder write FOnOpenOrder;
    property OnOpenProject: TOpenIdEvent read FOnOpenProject write FOnOpenProject;
    property OnOpenTask: TOpenIdEvent read FOnOpenTask write FOnOpenTask;
  end;

implementation

uses
  System.StrUtils, System.Math, System.DateUtils, FireDAC.Comp.Client;

const
  LEFT_W = 300;       // колонка подписей
  ROW_H = 22;
  HEAD_H = 34;

{ TGanttPage }

constructor TGanttPage.Create(AOwner: TComponent; AParent: TWinControl;
  AData: TCrmData; ASay: TSayProc);
begin
  inherited Create(AOwner);
  Parent := AParent;
  Align := alClient;
  Visible := False;
  FData := AData;
  FOnSay := ASay;
  BevelOuter := bvNone;
  Color := ESPO_BODY;
  ParentBackground := False;
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;
  BuildUI;
end;

procedure TGanttPage.Say(Kind: TMsgKind; const Msg: string);
begin
  if Assigned(FOnSay) then FOnSay(Kind, Msg);
end;

procedure TGanttPage.BuildUI;
var
  Hdr: TPanel;
  L: TLabel;
  Btn: TPanel;
begin
  Hdr := TPanel.Create(Self);
  Hdr.Parent := Self;
  Hdr.Align := alTop;
  Hdr.Height := 56;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_BODY;
  Hdr.ParentBackground := False;

  L := TLabel.Create(Self);
  L.Parent := Hdr;
  L.SetBounds(15, 14, 260, 30);
  L.Caption := 'План работ (Гант)';
  L.Font.Size := 16;

  FFilter := TComboBox.Create(Self);
  FFilter.Parent := Hdr;
  FFilter.Style := csDropDownList;
  FFilter.SetBounds(210, 18, 240, 28);
  FFilter.Items.Add('Производство');
  FFilter.Items.Add('Все заказы');
  FFilter.Items.Add('Только незакрытые');
  FFilter.Items.Add('Проекты и задачи');
  FFilter.ItemIndex := 0;
  FFilter.OnChange := OnFilterChange;

  Hdr.Height := 72;
  FInfo := MakeLabel(Self, Hdr, '', 465, 20, 560, ESPO_MUTED, 9);
  MakeLabel(Self, Hdr, 'тяните полосу мышью — сдвиг заказа, за края — срок  ·  двойной клик открывает заказ',
    15, 50, 700, ESPO_MUTED, 9);

  Btn := MakeButton(Self, Hdr, 'Обновить', False, OnRefreshClick, 110);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 125, 12, 110, 36);

  FScroll := TScrollBox.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alClient;
  FScroll.BorderStyle := bsNone;
  FScroll.Color := ESPO_WHITE;
  FScroll.ParentBackground := False;
  FScroll.ParentColor := False;

  FCanvas := TPaintBox.Create(Self);
  FCanvas.Parent := FScroll;
  FCanvas.Align := alClient;
  FCanvas.OnPaint := PaintChart;
  FCanvas.OnMouseDown := CanvasMouseDown;
  FCanvas.OnMouseMove := CanvasMouseMove;
  FCanvas.OnMouseUp := CanvasMouseUp;
  FCanvas.OnDblClick := CanvasDblClick;
  FDragRow := -1;
  FDragMode := dmNone;
end;

{ ── перетаскивание полос мышью ── }

function TGanttPage.XOfDate(D: TDateTime): Integer;
begin
  if FMax - FMin <= 0 then Exit(LEFT_W);
  Result := LEFT_W + Round((D - FMin) / (FMax - FMin) * FChartW);
end;

function TGanttPage.DaysPerPixel: Double;
begin
  if FChartW <= 0 then Exit(0);
  Result := (FMax - FMin) / FChartW;
end;

{ Что под курсором: край полосы (растянуть) или её середина (сдвинуть).
  Операции не тянем — их даты вычисляются из заказа. }
function TGanttPage.HitTest(X, Y: Integer; out Row: Integer): TDragMode;
var
  X1, X2: Integer;
begin
  Result := dmNone;
  Row := (Y - HEAD_H) div ROW_H;
  if (Row < 0) or (Row > High(FRows)) or (FRows[Row].IsWork and (FRows[Row].TaskId = 0)) then
  begin
    Row := -1;
    Exit;
  end;
  X1 := XOfDate(FRows[Row].Start);
  X2 := XOfDate(FRows[Row].PlanEnd);
  // короткая полоса (день-два) — только сдвиг: у неё нет «краёв», за которые
  // можно тянуть, иначе клик по середине попадал бы в растяжение
  if (X2 - X1 < 14) then
  begin
    if (X >= X1 - 4) and (X <= X2 + 4) then Result := dmMove else Row := -1;
  end
  else if Abs(X - X1) <= 4 then Result := dmStart
  else if Abs(X - X2) <= 4 then Result := dmEnd
  else if (X > X1) and (X < X2) then Result := dmMove
  else Row := -1;
end;

procedure TGanttPage.CanvasMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Row: Integer;
begin
  if Button <> mbLeft then Exit;
  FDragMode := HitTest(X, Y, Row);
  FDragRow := Row;
  FDragX0 := X;
  FDragDays := 0;
end;

procedure TGanttPage.CanvasMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  Row: Integer;
  Mode: TDragMode;
begin
  if (FDragMode <> dmNone) and (ssLeft in Shift) then
  begin
    FDragDays := Round((X - FDragX0) * DaysPerPixel);
    FCanvas.Invalidate;
    Exit;
  end;
  // подсказка курсором: у краёв — растянуть, в середине — двигать
  Mode := HitTest(X, Y, Row);
  case Mode of
    dmStart, dmEnd: FCanvas.Cursor := crSizeWE;
    dmMove: FCanvas.Cursor := crHandPoint;
  else FCanvas.Cursor := crDefault;
  end;
end;

procedure TGanttPage.CanvasMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if (FDragMode <> dmNone) and (FDragRow >= 0) and (FDragDays <> 0) then
    CommitDrag
  else if FDragMode <> dmNone then
    Say(mkInfo, 'Перетаскивание отменено: даты не изменились.');
  FDragMode := dmNone;
  FDragRow := -1;
  FDragDays := 0;
  FCanvas.Invalidate;
end;

procedure TGanttPage.CommitDrag;
var
  R: TGanttRow;
  NewStart, NewEnd: TDateTime;
  What: string;
begin
  R := FRows[FDragRow];
  NewStart := R.Start;
  NewEnd := R.PlanEnd;
  case FDragMode of
    dmMove:  begin NewStart := R.Start + FDragDays; NewEnd := R.PlanEnd + FDragDays; What := 'сдвинут'; end;
    dmStart: begin NewStart := R.Start + FDragDays; What := 'смещено начало'; end;
    dmEnd:   begin NewEnd := R.PlanEnd + FDragDays; What := 'изменён срок'; end;
  end;
  if NewEnd < NewStart then
  begin
    Say(mkWarn, 'Срок не может быть раньше даты заказа — изменение отменено.');
    Exit;
  end;
  if R.TaskId > 0 then
    FData.DB.Connection.ExecSQL(
      'UPDATE tasks SET plan_start = :d1, due_at = :d2 WHERE id = :i',
      [FormatDateTime('yyyy-mm-dd', NewStart), FormatDateTime('yyyy-mm-dd', NewEnd), R.TaskId])
  else if R.ProjectId > 0 then
    FData.DB.Connection.ExecSQL(
      'UPDATE projects SET start_date = :d1, due_date = :d2 WHERE id = :i',
      [FormatDateTime('yyyy-mm-dd', NewStart), FormatDateTime('yyyy-mm-dd', NewEnd), R.ProjectId])
  else
    FData.DB.Connection.ExecSQL(
      'UPDATE orders SET order_date = :d1, due_date = :d2 WHERE id = :i',
      [FormatDateTime('yyyy-mm-dd', NewStart), FormatDateTime('yyyy-mm-dd', NewEnd), R.OrderId]);
  LoadRows;
  // «%+d» Delphi не поддерживает — знак ставим сами
  Say(mkOk, Format('%s: %s — %s → %s (%s%d дн.)',
    [R.Caption, What, FormatDateTime('dd.mm', R.Start) + '–' + FormatDateTime('dd.mm', R.PlanEnd),
     FormatDateTime('dd.mm', NewStart) + '–' + FormatDateTime('dd.mm', NewEnd),
     IfThen(FDragDays > 0, '+', ''), FDragDays]));
end;

procedure TGanttPage.CanvasDblClick(Sender: TObject);
var
  P: TPoint;
  Row: Integer;
begin
  P := FCanvas.ScreenToClient(Mouse.CursorPos);
  Row := (P.Y - HEAD_H) div ROW_H;
  if (Row < 0) or (Row > High(FRows)) then Exit;
  if FRows[Row].TaskId > 0 then
  begin
    if Assigned(FOnOpenTask) then FOnOpenTask(FRows[Row].TaskId);
  end
  else if FRows[Row].ProjectId > 0 then
  begin
    if Assigned(FOnOpenProject) then FOnOpenProject(FRows[Row].ProjectId);
  end
  else if Assigned(FOnOpenOrder) then
    FOnOpenOrder(FRows[Row].OrderId);
end;

function TGanttPage.DragBar(Row: Integer; Mode: TDragMode; Days: Integer): Boolean;
var
  X0, Y0: Integer;
begin
  Result := (Row >= 0) and (Row <= High(FRows)) and (Mode <> dmNone) and
            (not FRows[Row].IsWork or (FRows[Row].TaskId > 0));
  if not Result then Exit;
  Y0 := HEAD_H + Row * ROW_H + ROW_H div 2;
  case Mode of
    dmStart: X0 := XOfDate(FRows[Row].Start);
    dmEnd:   X0 := XOfDate(FRows[Row].PlanEnd);
  else       X0 := (XOfDate(FRows[Row].Start) + XOfDate(FRows[Row].PlanEnd)) div 2;
  end;
  // тот же путь, что и у мыши: нажатие на полосе, сдвиг, отпускание
  CanvasMouseDown(FCanvas, mbLeft, [ssLeft], X0, Y0);
  CanvasMouseMove(FCanvas, [ssLeft], X0 + Round(Days / Max(DaysPerPixel, 1E-6)), Y0);
  CanvasMouseUp(FCanvas, mbLeft, [], X0 + Round(Days / Max(DaysPerPixel, 1E-6)), Y0);
end;

function TGanttPage.RowStart(Row: Integer): TDateTime;
begin
  if (Row >= 0) and (Row <= High(FRows)) then Result := FRows[Row].Start else Result := 0;
end;

function TGanttPage.RowPlanEnd(Row: Integer): TDateTime;
begin
  if (Row >= 0) and (Row <= High(FRows)) then Result := FRows[Row].PlanEnd else Result := 0;
end;

function TGanttPage.RowOrderId(Row: Integer): Integer;
begin
  if (Row >= 0) and (Row <= High(FRows)) then Result := FRows[Row].OrderId else Result := 0;
end;

function TGanttPage.RowTaskId(Row: Integer): Integer;
begin
  if (Row >= 0) and (Row <= High(FRows)) then Result := FRows[Row].TaskId else Result := 0;
end;

function TGanttPage.RowProjectId(Row: Integer): Integer;
begin
  if (Row >= 0) and (Row <= High(FRows)) then Result := FRows[Row].ProjectId else Result := 0;
end;

function TGanttPage.FirstTaskRow: Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FRows) do
    if FRows[I].TaskId > 0 then Exit(I);
end;

{ Режим «Проекты и задачи»: строка — проект (от начала до сдачи), под ним —
  его задачи в порядке выполнения (план начала → срок), готовые зелёным,
  просроченные красным. Задачи можно тянуть: меняются plan_start / due_at. }
procedure TGanttPage.LoadProjectRows;
var
  Q, QT: TFDQuery;
  R, W: TGanttRow;
  Today: TDateTime;
  Status: string;

  function AsDate(const S: string; Def: TDateTime): TDateTime;
  var
    Y, M, D: Integer;
  begin
    Result := Def;
    if Length(S) < 10 then Exit;
    Y := StrToIntDef(Copy(S, 1, 4), 0);
    M := StrToIntDef(Copy(S, 6, 2), 0);
    D := StrToIntDef(Copy(S, 9, 2), 0);
    if (Y > 1900) and (M >= 1) and (M <= 12) and (D >= 1) and (D <= 31) then
      Result := EncodeDate(Y, M, D);
  end;

begin
  FRows := nil;
  Today := Date;
  Q := FData.OpenQuery(
    'SELECT p.id, p.name, p.status, p.kind, COALESCE(c.denumire,''(без клиента)'') AS client, ' +
    ' COALESCE(p.start_date,'''') AS d1, COALESCE(p.due_date,'''') AS d2 ' +
    'FROM projects p LEFT JOIN clients c ON c.id = p.client_id ' +
    'WHERE p.status NOT IN (''Проигран'') ORDER BY p.start_date, p.id');
  try
    while not Q.Eof do
    begin
      R := Default(TGanttRow);
      R.ProjectId := Q.FieldByName('id').AsInteger;
      Status := Q.FieldByName('status').AsString;
      R.Caption := Q.FieldByName('name').AsString;
      R.Sub := Q.FieldByName('client').AsString + '  ·  ' + Status;
      R.Start := AsDate(Q.FieldByName('d1').AsString, Today);
      R.PlanEnd := AsDate(Q.FieldByName('d2').AsString, R.Start + 30);
      if R.PlanEnd < R.Start then R.PlanEnd := R.Start + 1;
      R.Closed := Status = 'Закрыт';
      if R.Closed then R.FactEnd := R.PlanEnd else R.FactEnd := Today;
      R.Overdue := (not R.Closed) and (R.PlanEnd < Today);
      FRows := FRows + [R];

      QT := FData.OpenQuery(
        'SELECT t.id, t.subject, COALESCE(t.assignee,'''') AS who, COALESCE(t.stage,'''') AS stage, ' +
        ' COALESCE(t.done,0) AS done, COALESCE(t.plan_start,'''') AS d1, COALESCE(t.due_at,'''') AS d2, ' +
        ' COALESCE(t.depends_on,0) AS dep, COALESCE(t.hours_plan,0) AS hp ' +
        'FROM tasks t WHERE t.project_id = ' + IntToStr(R.ProjectId) +
        ' ORDER BY COALESCE(t.seq,0), t.plan_start, t.id');
      try
        while not QT.Eof do
        begin
          W := Default(TGanttRow);
          W.IsWork := True;
          W.ProjectId := R.ProjectId;
          W.TaskId := QT.FieldByName('id').AsInteger;
          W.DependsOn := QT.FieldByName('dep').AsInteger;
          W.Caption := '   ' + QT.FieldByName('subject').AsString;
          W.Sub := QT.FieldByName('who').AsString + '  ·  ' + QT.FieldByName('stage').AsString +
                   IfThen(QT.FieldByName('hp').AsFloat > 0, '  ·  ' + FormatFloat('0.#', QT.FieldByName('hp').AsFloat) + ' ч', '');
          W.PlanEnd := AsDate(QT.FieldByName('d2').AsString, R.PlanEnd);
          W.Start := AsDate(QT.FieldByName('d1').AsString, W.PlanEnd - 1);
          if W.PlanEnd < W.Start then W.PlanEnd := W.Start + 1;
          W.Closed := QT.FieldByName('done').AsInteger = 1;
          if W.Closed then W.FactEnd := W.PlanEnd else W.FactEnd := Min(Today, W.PlanEnd);
          if W.FactEnd < W.Start then W.FactEnd := W.Start;
          W.Overdue := (not W.Closed) and (W.PlanEnd < Today);
          FRows := FRows + [W];
          QT.Next;
        end;
      finally
        QT.Free;
      end;
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TGanttPage.LoadRows;
var
  Q, QL: TFDQuery;
  R, W: TGanttRow;
  Where: string;
  OrderId, I, N: Integer;
  Span: Double;
  Today: TDateTime;

  function AsDate(const S: string; Def: TDateTime): TDateTime;
  var
    Y, M, D: Integer;
  begin
    Result := Def;
    if Length(S) < 10 then Exit;
    Y := StrToIntDef(Copy(S, 1, 4), 0);
    M := StrToIntDef(Copy(S, 6, 2), 0);
    D := StrToIntDef(Copy(S, 9, 2), 0);
    if (Y > 1900) and (M >= 1) and (M <= 12) and (D >= 1) and (D <= 31) then
      Result := EncodeDate(Y, M, D);
  end;

begin
  if FFilter.ItemIndex = 3 then
  begin
    LoadProjectRows;
    FinishRows;
    Exit;
  end;
  FRows := nil;
  Today := Date;
  case FFilter.ItemIndex of
    0: Where := 't.kind = ''Производство'' AND t.status <> ''Отменён''';
    2: Where := 't.status NOT IN (''Отменён'') AND NOT (COALESCE(t.ship_date,'''') <> '''' AND COALESCE(t.paid,0) >= t.total)';
  else Where := 't.status <> ''Отменён''';
  end;

  Q := FData.OpenQuery(
    'SELECT t.id, t.number, t.kind, t.status, COALESCE(c.denumire,''(без клиента)'') AS client, ' +
    ' COALESCE(t.order_date,'''') AS d1, COALESCE(t.due_date,'''') AS d2, ' +
    ' COALESCE(t.ship_date,'''') AS d3, COALESCE(t.total,0) AS total, COALESCE(t.paid,0) AS paid ' +
    'FROM orders t LEFT JOIN clients c ON c.id = t.client_id ' +
    'WHERE ' + Where + ' ORDER BY t.order_date, t.id');
  try
    while not Q.Eof do
    begin
      R.IsWork := False;
      R.OrderId := Q.FieldByName('id').AsInteger;
      R.Caption := '№' + Q.FieldByName('number').AsString + '  ' + Q.FieldByName('kind').AsString;
      R.Sub := Q.FieldByName('client').AsString + '  ·  ' + Q.FieldByName('status').AsString;
      R.Start := AsDate(Q.FieldByName('d1').AsString, Today);
      R.PlanEnd := AsDate(Q.FieldByName('d2').AsString, R.Start + 14);
      if R.PlanEnd < R.Start then R.PlanEnd := R.Start + 1;
      if Q.FieldByName('d3').AsString <> '' then
        R.FactEnd := AsDate(Q.FieldByName('d3').AsString, R.PlanEnd)
      else
        R.FactEnd := Today;
      R.Closed := (Q.FieldByName('d3').AsString <> '') and
                  (Q.FieldByName('paid').AsFloat >= Q.FieldByName('total').AsFloat);
      R.Overdue := (not R.Closed) and (R.PlanEnd < Today);
      FRows := FRows + [R];

      // операции: строки заказа, распределённые по плановому окну
      OrderId := Q.FieldByName('id').AsInteger;
      QL := FData.OpenQuery(
        'SELECT i.name, i.unit_, l.qty FROM order_lines l ' +
        'LEFT JOIN items i ON i.id = l.item_id WHERE l.order_id = ' + IntToStr(OrderId) +
        ' ORDER BY l.id');
      try
        N := QL.RecordCount;
        if N > 0 then
        begin
          Span := Max(1, R.PlanEnd - R.Start) / N;
          I := 0;
          while not QL.Eof do
          begin
            W.IsWork := True;
            W.OrderId := OrderId;
            W.Caption := '   ' + QL.FieldByName('name').AsString;
            W.Sub := FormatFloat('0.##', QL.FieldByName('qty').AsFloat) + ' ' +
                     QL.FieldByName('unit_').AsString;
            W.Start := R.Start + I * Span;
            W.PlanEnd := R.Start + (I + 1) * Span;
            W.FactEnd := Min(W.PlanEnd, Max(W.Start, R.FactEnd));
            W.Closed := R.Closed;
            // Факта по отдельным операциям нет, поэтому просрочку операция
            // наследует от своего заказа — иначе получился бы домысел.
            W.Overdue := R.Overdue;
            FRows := FRows + [W];
            Inc(I);
            QL.Next;
          end;
        end;
      finally
        QL.Free;
      end;
      Q.Next;
    end;
  finally
    Q.Free;
  end;

  FinishRows;
end;

{ Диапазон времени по всем строкам, высота холста, строка сведений. }
procedure TGanttPage.FinishRows;
var
  I: Integer;
begin
  FMin := Date; FMax := Date + 7;
  for I := 0 to High(FRows) do
  begin
    if FRows[I].Start < FMin then FMin := FRows[I].Start;
    if FRows[I].PlanEnd > FMax then FMax := FRows[I].PlanEnd;
    if FRows[I].FactEnd > FMax then FMax := FRows[I].FactEnd;
  end;
  FMin := FMin - 2;
  FMax := FMax + 2;

  FCanvas.Height := Max(FScroll.ClientHeight, HEAD_H + Length(FRows) * ROW_H + 40);
  FInfo.Caption := Format('строк: %d (работ: %d), просрочено: %d   ·   %s',
    [Length(FRows), WorkCount, OverdueCount, RangeText]);
  FCanvas.Invalidate;
end;

procedure TGanttPage.PaintChart(Sender: TObject);
var
  C: TCanvas;
  W, ChartW, X, Y, I, J, X2, Y2, BarY: Integer;
  D: TDateTime;
  Total: Double;
  R: TGanttRow;

  function XOf(ADate: TDateTime): Integer;
  begin
    if Total <= 0 then Exit(LEFT_W);
    Result := LEFT_W + Round((ADate - FMin) / Total * ChartW);
  end;

  { Предпросмотр во время перетаскивания: строка рисуется уже сдвинутой,
    в базу изменение уходит только при отпускании кнопки. }
  procedure ApplyDrag(var Row: TGanttRow; Index: Integer);
  begin
    if (FDragMode = dmNone) or (FDragRow < 0) or (FDragDays = 0) then Exit;
    if FRows[FDragRow].TaskId > 0 then
    begin
      if Index <> FDragRow then Exit;      // задача двигается одна
    end
    else if (Row.OrderId <> FRows[FDragRow].OrderId) or (Row.ProjectId <> FRows[FDragRow].ProjectId) then
      Exit;
    case FDragMode of
      dmMove:  begin Row.Start := Row.Start + FDragDays; Row.PlanEnd := Row.PlanEnd + FDragDays; end;
      dmStart: if Index = FDragRow then Row.Start := Row.Start + FDragDays;
      dmEnd:   if Index = FDragRow then Row.PlanEnd := Row.PlanEnd + FDragDays;
    end;
  end;

  procedure Bar(X1, X2, AY, H: Integer; Col: TColor);
  begin
    if X2 < X1 + 2 then X2 := X1 + 2;
    C.Brush.Color := Col;
    C.FillRect(Rect(X1, AY, X2, AY + H));
  end;

begin
  C := FCanvas.Canvas;
  W := FCanvas.Width;
  ChartW := Max(50, W - LEFT_W - 16);
  FChartW := ChartW;         // нужен обработчикам мыши для перевода пикселей в дни
  Total := FMax - FMin;

  C.Brush.Color := ESPO_WHITE;
  C.FillRect(Rect(0, 0, W, FCanvas.Height));
  C.Font.Name := 'Segoe UI';

  // шкала времени: месяцы и недели
  C.Font.Size := 8;
  C.Font.Color := ESPO_MUTED;
  C.Brush.Style := bsClear;
  D := FMin;
  while D <= FMax do
  begin
    X := XOf(D);
    C.Pen.Color := IfThen(DayOfTheWeek(D) = 1, ESPO_BORDER, ESPO_PANEL_BRD);
    C.MoveTo(X, HEAD_H - 6);
    C.LineTo(X, FCanvas.Height - 20);
    C.TextOut(X + 3, 6, FormatDateTime('dd.mm', D));
    D := D + 7;
  end;

  // сегодня
  X := XOf(Date);
  C.Pen.Color := ST_DANGER_FG;
  C.Pen.Width := 2;
  C.MoveTo(X, HEAD_H - 10);
  C.LineTo(X, FCanvas.Height - 20);
  C.Pen.Width := 1;
  C.Font.Color := ST_DANGER_FG;
  C.TextOut(X + 3, HEAD_H - 24, 'сегодня');

  // строки
  for I := 0 to High(FRows) do
  begin
    R := FRows[I];
    ApplyDrag(R, I);
    Y := HEAD_H + I * ROW_H;
    if I mod 2 = 1 then
    begin
      C.Brush.Style := bsSolid;
      C.Brush.Color := $00FAFAF8;
      C.FillRect(Rect(0, Y, W, Y + ROW_H));
    end;
    C.Brush.Style := bsClear;
    C.Font.Color := IfThen(R.IsWork, ESPO_MUTED, ESPO_TEXT);
    C.Font.Size := IfThen(R.IsWork, 8, 9);
    if R.IsWork then C.Font.Style := [] else C.Font.Style := [fsBold];
    C.TextRect(Rect(10, Y, LEFT_W - 124, Y + ROW_H), 10, Y + 3, R.Caption);
    C.Font.Style := [];
    C.Font.Color := ESPO_MUTED;
    C.Font.Size := 8;
    // подписи обрезаются по границе левой колонки, а не по числу символов
    C.TextRect(Rect(LEFT_W - 120, Y, LEFT_W - 6, Y + ROW_H), LEFT_W - 120, Y + 5, R.Sub);

    BarY := Y + IfThen(R.IsWork, 7, 4);
    // план
    Bar(XOf(R.Start), XOf(R.PlanEnd), BarY, IfThen(R.IsWork, 8, 14), $00E8DFD2);
    // факт
    if R.Closed then
      Bar(XOf(R.Start), XOf(R.FactEnd), BarY, IfThen(R.IsWork, 8, 14), ST_SUCCESS_FG)
    else if R.Overdue then
      Bar(XOf(R.PlanEnd), XOf(Max(R.FactEnd, Date)), BarY, IfThen(R.IsWork, 8, 14), ST_DANGER_FG)
    else
      Bar(XOf(R.Start), XOf(R.FactEnd), BarY, IfThen(R.IsWork, 8, 14), ESPO_PRIMARY);
  end;

  // стрелки зависимостей задач: конец предшественника → начало задачи
  C.Pen.Color := ESPO_GRAY;
  C.Pen.Width := 1;
  for I := 0 to High(FRows) do
    if (FRows[I].TaskId > 0) and (FRows[I].DependsOn > 0) then
      for J := 0 to High(FRows) do
        if FRows[J].TaskId = FRows[I].DependsOn then
        begin
          R := FRows[J]; ApplyDrag(R, J);
          X := XOf(R.PlanEnd);
          Y := HEAD_H + J * ROW_H + 11;
          R := FRows[I]; ApplyDrag(R, I);
          X2 := XOf(R.Start);
          Y2 := HEAD_H + I * ROW_H + 11;
          C.MoveTo(X, Y); C.LineTo(X + 4, Y); C.LineTo(X + 4, Y2); C.LineTo(X2, Y2);
          C.Brush.Style := bsSolid; C.Brush.Color := ESPO_GRAY;
          C.Polygon([Point(X2, Y2), Point(X2 - 5, Y2 - 3), Point(X2 - 5, Y2 + 3)]);
          C.Brush.Style := bsClear;
          Break;
        end;

  // легенда
  Y := HEAD_H + Length(FRows) * ROW_H + 8;
  C.Brush.Style := bsSolid;
  Bar(10, 30, Y, 10, $00E8DFD2);   C.Brush.Style := bsClear;
  C.Font.Color := ESPO_MUTED; C.TextOut(36, Y - 2, 'план');
  C.Brush.Style := bsSolid;
  Bar(90, 110, Y, 10, ESPO_PRIMARY); C.Brush.Style := bsClear;
  C.TextOut(116, Y - 2, 'идёт');
  C.Brush.Style := bsSolid;
  Bar(170, 190, Y, 10, ST_DANGER_FG); C.Brush.Style := bsClear;
  C.TextOut(196, Y - 2, 'просрочка');
  C.Brush.Style := bsSolid;
  Bar(280, 300, Y, 10, ST_SUCCESS_FG); C.Brush.Style := bsClear;
  C.TextOut(306, Y - 2, 'закрыт');
  if FFilter.ItemIndex = 3 then
    C.TextOut(380, Y - 2, 'отступом показаны задачи проекта в порядке выполнения; стрелка — «после задачи»; задачи можно тянуть')
  else
    C.TextOut(380, Y - 2, 'отступом показаны работы заказа — строки в порядке исполнения');
end;

procedure TGanttPage.Refresh;
begin
  LoadRows;
end;

procedure TGanttPage.OnFilterChange(Sender: TObject);
begin
  LoadRows;
  Say(mkInfo, 'План работ: ' + FFilter.Text + '   ·   ' + FInfo.Caption);
end;

procedure TGanttPage.OnRefreshClick(Sender: TObject);
begin
  LoadRows;
  Say(mkInfo, 'План работ обновлён: ' + FInfo.Caption);
end;

procedure TGanttPage.SelectFilter(Index: Integer);
begin
  FFilter.ItemIndex := Index;
  OnFilterChange(FFilter);
end;

function TGanttPage.RowCount: Integer;
begin
  Result := Length(FRows);
end;

function TGanttPage.WorkCount: Integer;
var
  R: TGanttRow;
begin
  Result := 0;
  for R in FRows do
    if R.IsWork then Inc(Result);
end;

function TGanttPage.OverdueCount: Integer;
var
  R: TGanttRow;
begin
  Result := 0;
  for R in FRows do
    if R.Overdue and not R.IsWork then Inc(Result);
end;

function TGanttPage.RangeText: string;
begin
  Result := Format('%s — %s', [FormatDateTime('dd.mm.yyyy', FMin),
    FormatDateTime('dd.mm.yyyy', FMax)]);
end;

end.
