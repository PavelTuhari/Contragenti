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
    IsWork: Boolean;        // строка заказа (операция), а не сам заказ
    Caption: string;
    Sub: string;
    Start, PlanEnd, FactEnd: TDateTime;
    Overdue, Closed: Boolean;
  end;

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
    procedure Say(Kind: TMsgKind; const Msg: string);
    procedure BuildUI;
    procedure LoadRows;
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
  FFilter.ItemIndex := 0;
  FFilter.OnChange := OnFilterChange;

  FInfo := MakeLabel(Self, Hdr, '', 465, 24, 480, ESPO_MUTED, 9);

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

  // диапазон времени по всем строкам
  FMin := Today; FMax := Today + 7;
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
  W, ChartW, X, Y, I, BarY: Integer;
  D: TDateTime;
  Total: Double;
  R: TGanttRow;

  function XOf(ADate: TDateTime): Integer;
  begin
    if Total <= 0 then Exit(LEFT_W);
    Result := LEFT_W + Round((ADate - FMin) / Total * ChartW);
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
