unit uCalendarView;
{
  Календарь месячной сеткой: 7 столбцов × 6 недель, в ячейке — задачи дня.

  Задачу можно перетащить мышью на другой день — меняется срок (due_at).
  Двойной клик открывает задачу в списке. Кнопки ← / → листают месяцы,
  «Сегодня» возвращает к текущему.

  Тот же принцип, что и на канбане: перенос идёт через один метод
  MoveTaskTo, поэтому мышь и кнопки дают одинаковый результат.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  uCrmData, uEspoTheme, uI18n;

type
  TTaskOpenEvent = procedure(TaskId: Integer) of object;
  TDayActionEvent = procedure(const ADate: TDateTime) of object;

  TCalCell = record
    Panel: TPanel;
    DayLabel: TLabel;
    Date: TDateTime;
    InMonth: Boolean;
  end;

  TCalTask = record
    Id: Integer;
    Subject, Kind: string;
    Due: TDateTime;
    Done, Overdue: Boolean;
  end;

  TCalendarPage = class(TPanel)
  private
    FData: TCrmData;
    FOnSay: TSayProc;
    FOnOpenTask: TTaskOpenEvent;
    FOnNewTask: TDayActionEvent;
    FOnShowList: TNotifyEvent;
    FMonth: TDateTime;          // первое число показываемого месяца
    FSelected: TDateTime;
    FTitle: TLabel;
    FGrid: TPanel;
    FCells: array[0..41] of TCalCell;
    FTaskLabels: TArray<TLabel>;
    FTasks: TArray<TCalTask>;
    FDayPanel: TPanel;
    FDayTitle, FDayList: TLabel;
    // перетаскивание задачи
    FDragId: Integer;
    FDragActive: Boolean;
    FDragOrigin: TPoint;
    FGhost: TPanel;
    FGhostText: TLabel;
    FHoverCell: Integer;
    procedure Say(Kind: TMsgKind; const Msg: string);
    procedure BuildUI;
    procedure LayoutCells;
    procedure GridResize(Sender: TObject);
    procedure LoadMonth;
    procedure FillDayPanel;
    function  CellAtScreen(const P: TPoint): Integer;
    procedure ShowGhost(const P: TPoint);
    procedure HideGhost;
    procedure HighlightCell(Index: Integer);
    procedure TaskMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure TaskMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure TaskMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure TaskDblClick(Sender: TObject);
    procedure CellClick(Sender: TObject);
    procedure OnPrevClick(Sender: TObject);
    procedure OnNextClick(Sender: TObject);
    procedure OnTodayClick(Sender: TObject);
    procedure OnNewClick(Sender: TObject);
    procedure OnListClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent; AParent: TWinControl; AData: TCrmData;
      ASay: TSayProc); reintroduce;
    procedure Refresh;
    procedure MoveTaskTo(TaskId: Integer; const NewDate: TDateTime);

    // хуки самотеста
    function  MonthTitle: string;
    function  TasksInMonth: Integer;
    function  TasksOnDay(const ADate: TDateTime): Integer;
    function  CellIndexOf(const ADate: TDateTime): Integer;
    procedure GoPrevMonth;
    procedure GoNextMonth;
    procedure GoToday;
    procedure SelectDay(const ADate: TDateTime);
    function  SelectedDay: TDateTime;
    { Тянет задачу мышью на другой день: нажатие, сдвиг, отпускание над ячейкой. }
    function  DragTask(TaskId: Integer; const ToDate: TDateTime): Boolean;

    property OnOpenTask: TTaskOpenEvent read FOnOpenTask write FOnOpenTask;
    property OnNewTask: TDayActionEvent read FOnNewTask write FOnNewTask;
    property OnShowList: TNotifyEvent read FOnShowList write FOnShowList;
  end;

implementation

uses
  System.StrUtils, System.Math, System.DateUtils, FireDAC.Comp.Client;

const
  HEAD_H = 78;      // шапка страницы
  WEEK_H = 24;      // строка с днями недели
  DAY_PAD = 3;

{ TCalendarPage }

constructor TCalendarPage.Create(AOwner: TComponent; AParent: TWinControl;
  AData: TCrmData; ASay: TSayProc);
begin
  inherited Create(AOwner);
  Parent := AParent;
  Align := alClient;
  Visible := False;
  FData := AData;
  FOnSay := ASay;
  FMonth := EncodeDate(YearOf(Date), MonthOf(Date), 1);
  FSelected := Date;
  FDragId := -1;
  FHoverCell := -1;
  BevelOuter := bvNone;
  Color := ESPO_BODY;
  ParentBackground := False;
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;
  BuildUI;
end;

procedure TCalendarPage.Say(Kind: TMsgKind; const Msg: string);
begin
  if Assigned(FOnSay) then FOnSay(Kind, Msg);
end;

procedure TCalendarPage.BuildUI;
var
  Hdr, Week: TPanel;
  L: TLabel;
  Btn: TPanel;
  Days: TArray<string>;
  I: Integer;
begin
  Hdr := TPanel.Create(Self);
  Hdr.Parent := Self;
  Hdr.Align := alTop;
  Hdr.Height := HEAD_H;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_BODY;
  Hdr.ParentBackground := False;

  L := TLabel.Create(Self);
  L.Parent := Hdr;
  L.SetBounds(15, 10, 200, 30);
  L.Caption := T.S('calendar.title');
  L.Font.Size := 16;

  Btn := MakeButton(Self, Hdr, '‹', False, OnPrevClick, 40);
  Btn.SetBounds(160, 10, 40, 32);
  Btn := MakeButton(Self, Hdr, '›', False, OnNextClick, 40);
  Btn.SetBounds(204, 10, 40, 32);
  Btn := MakeButton(Self, Hdr, T.S('calendar.today'), False, OnTodayClick, 110);
  Btn.SetBounds(248, 10, 110, 32);

  FTitle := MakeLabel(Self, Hdr, '', 370, 16, 300, ESPO_TEXT, 13);
  FTitle.Font.Style := [fsBold];

  Btn := MakeButton(Self, Hdr, T.S('btn.create'), True, OnNewClick, 150);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 165, 10, 150, 34);
  Btn := MakeButton(Self, Hdr, T.S('reports.preview'), False, OnListClick, 130);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 165 - 8 - 130, 10, 130, 34);
  Btn.Caption := 'Список';

  MakeLabel(Self, Hdr, T.S('calendar.hint'), 15, 52, 720, ESPO_MUTED, 9);

  // строка с днями недели
  Week := TPanel.Create(Self);
  Week.Parent := Self;
  Week.Align := alTop;
  Week.Top := HEAD_H + 1;
  Week.Height := WEEK_H;
  Week.BevelOuter := bvNone;
  Week.Color := ESPO_BODY;
  Week.ParentBackground := False;
  Days := T.S('calendar.week_days').Split([';']);
  for I := 0 to 6 do
    if I <= High(Days) then
      MakeLabel(Self, Week, Days[I], 15 + I * 100, 4, 96, ESPO_MUTED, 9).Name :=
        'wd' + IntToStr(I);

  // панель задач выбранного дня
  FDayPanel := MakePanelBox(Self, Self, '');
  FDayPanel.Align := alBottom;
  FDayPanel.Height := 96;
  FDayTitle := MakeLabel(Self, FDayPanel, '', 14, 8, 500, ESPO_SOFT, 11);
  FDayTitle.Font.Style := [fsBold];
  FDayList := MakeLabel(Self, FDayPanel, '', 14, 30, 1000, ESPO_TEXT, 9);
  FDayList.Height := 60;
  FDayList.WordWrap := True;

  FGrid := TPanel.Create(Self);
  FGrid.Parent := Self;
  FGrid.Align := alClient;
  FGrid.BevelOuter := bvNone;
  FGrid.Color := ESPO_BODY;
  FGrid.ParentBackground := False;
  FGrid.OnResize := GridResize;

  for I := 0 to 41 do
  begin
    FCells[I].Panel := TPanel.Create(Self);
    FCells[I].Panel.Parent := FGrid;
    FCells[I].Panel.BevelOuter := bvNone;
    FCells[I].Panel.BevelKind := bkFlat;
    FCells[I].Panel.Color := ESPO_WHITE;
    FCells[I].Panel.ParentBackground := False;
    FCells[I].Panel.Tag := I;
    FCells[I].Panel.OnClick := CellClick;
    FCells[I].DayLabel := MakeLabel(Self, FCells[I].Panel, '', 6, 4, 40, ESPO_TEXT, 10);
    FCells[I].DayLabel.Tag := I;
    FCells[I].DayLabel.OnClick := CellClick;
  end;
  LayoutCells;
end;

procedure TCalendarPage.GridResize(Sender: TObject);
begin
  LayoutCells;
end;

procedure TCalendarPage.LayoutCells;
var
  I, CW, CH, X, Y: Integer;
  WD: TComponent;
begin
  if FGrid = nil then Exit;
  CW := Max(60, (FGrid.ClientWidth - 30) div 7);
  CH := Max(50, (FGrid.ClientHeight - 12) div 6);
  for I := 0 to 41 do
  begin
    X := 15 + (I mod 7) * CW;
    Y := 4 + (I div 7) * CH;
    FCells[I].Panel.SetBounds(X, Y, CW - 3, CH - 3);
  end;
  // подписи дней недели держим над колонками
  for I := 0 to 6 do
  begin
    WD := FindComponent('wd' + IntToStr(I));
    if WD is TLabel then
      TLabel(WD).SetBounds(15 + I * CW + 4, 4, CW - 8, 18);
  end;
end;

procedure TCalendarPage.LoadMonth;
var
  Q: TFDQuery;
  First, D: TDateTime;
  Shift, I, K, Shown: Integer;
  Task: TCalTask;
  Months: TArray<string>;
  Lbl: TLabel;
  Cnt: array[0..41] of Integer;
begin
  for I := 0 to High(FTaskLabels) do
    FTaskLabels[I].Free;
  FTaskLabels := nil;
  FTasks := nil;
  FillChar(Cnt, SizeOf(Cnt), 0);

  Months := T.S('calendar.months').Split([';']);
  if MonthOf(FMonth) - 1 <= High(Months) then
    FTitle.Caption := Months[MonthOf(FMonth) - 1] + ' ' + IntToStr(YearOf(FMonth))
  else
    FTitle.Caption := FormatDateTime('mmmm yyyy', FMonth);

  // сетка начинается с понедельника недели, в которую попало 1-е число
  First := EncodeDate(YearOf(FMonth), MonthOf(FMonth), 1);
  Shift := (DayOfTheWeek(First) + 6) mod 7;   // Пн = 0
  for I := 0 to 41 do
  begin
    D := First - Shift + I;
    FCells[I].Date := D;
    FCells[I].InMonth := MonthOf(D) = MonthOf(FMonth);
    FCells[I].DayLabel.Caption := IntToStr(DayOf(D));
    if not FCells[I].InMonth then
      FCells[I].DayLabel.Font.Color := ESPO_PANEL_BRD
    else if D = Date then
      FCells[I].DayLabel.Font.Color := ST_DANGER_FG
    else
      FCells[I].DayLabel.Font.Color := ESPO_TEXT;
    if D = Date then
      FCells[I].DayLabel.Font.Style := [fsBold]
    else
      FCells[I].DayLabel.Font.Style := [];
    if D = FSelected then
      FCells[I].Panel.Color := ST_PRIMARY_BG
    else if not FCells[I].InMonth then
      FCells[I].Panel.Color := $00FAFAF8
    else
      FCells[I].Panel.Color := ESPO_WHITE;
  end;

  // задачи всего показываемого окна одним запросом
  Q := FData.OpenQuery(Format(
    'SELECT id, subject, kind, due_at, done FROM tasks ' +
    'WHERE due_at >= %s AND due_at <= %s ORDER BY due_at, id',
    [QuotedStr(FormatDateTime('yyyy-mm-dd', First - Shift)),
     QuotedStr(FormatDateTime('yyyy-mm-dd', First - Shift + 41))]));
  try
    while not Q.Eof do
    begin
      Task.Id := Q.FieldByName('id').AsInteger;
      Task.Subject := Q.FieldByName('subject').AsString;
      Task.Kind := Q.FieldByName('kind').AsString;
      // разбор ISO-даты без зависимости от локали Windows
      Task.Due := EncodeDate(
        StrToIntDef(Copy(Q.FieldByName('due_at').AsString, 1, 4), 1900),
        StrToIntDef(Copy(Q.FieldByName('due_at').AsString, 6, 2), 1),
        StrToIntDef(Copy(Q.FieldByName('due_at').AsString, 9, 2), 1));
      Task.Done := Q.FieldByName('done').AsInteger = 1;
      Task.Overdue := (not Task.Done) and (Task.Due < Date);
      FTasks := FTasks + [Task];
      Q.Next;
    end;
  finally
    Q.Free;
  end;

  // раскладываем задачи по ячейкам, максимум 3 подписи в ячейке
  for K := 0 to High(FTasks) do
  begin
    I := CellIndexOf(FTasks[K].Due);
    if I < 0 then Continue;
    Inc(Cnt[I]);
    if Cnt[I] > 3 then Continue;
    Lbl := MakeLabel(Self, FCells[I].Panel, '', 6, 20 + (Cnt[I] - 1) * 15,
      FCells[I].Panel.Width - 12,
      IfThen(FTasks[K].Done, ESPO_MUTED,
        IfThen(FTasks[K].Overdue, ST_DANGER_FG, ESPO_TEXT)), 8);
    Lbl.Caption := IfThen(FTasks[K].Done, '✓ ', '') + FTasks[K].Subject;
    Lbl.Tag := FTasks[K].Id;
    Lbl.Cursor := crHandPoint;
    Lbl.OnMouseDown := TaskMouseDown;
    Lbl.OnMouseMove := TaskMouseMove;
    Lbl.OnMouseUp := TaskMouseUp;
    Lbl.OnDblClick := TaskDblClick;
    FTaskLabels := FTaskLabels + [Lbl];
  end;
  for I := 0 to 41 do
    if Cnt[I] > 3 then
    begin
      Shown := Cnt[I] - 3;
      Lbl := MakeLabel(Self, FCells[I].Panel, Format('+ %d', [Shown]),
        6, 65, 60, ESPO_MUTED, 8);
      FTaskLabels := FTaskLabels + [Lbl];
    end;

  FillDayPanel;
end;

procedure TCalendarPage.FillDayPanel;
var
  S: string;
  K: Integer;
begin
  FDayTitle.Caption := T.S('calendar.day_tasks') + '  ·  ' +
    FormatDateTime('dd.mm.yyyy', FSelected);
  S := '';
  for K := 0 to High(FTasks) do
    if FTasks[K].Due = FSelected then
      S := S + Format('• %s — %s%s', [FTasks[K].Kind, FTasks[K].Subject,
        IfThen(FTasks[K].Done, '  ✓', IfThen(FTasks[K].Overdue, '  ← ' + T.S('kanban.overdue'), ''))])
        + sLineBreak;
  FDayList.Caption := IfThen(S = '', T.S('calendar.no_tasks'), S);
end;

procedure TCalendarPage.Refresh;
begin
  LoadMonth;
end;

function TCalendarPage.CellIndexOf(const ADate: TDateTime): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to 41 do
    if Trunc(FCells[I].Date) = Trunc(ADate) then
      Exit(I);
end;

function TCalendarPage.CellAtScreen(const P: TPoint): Integer;
var
  L: TPoint;
  I: Integer;
  R: TRect;
begin
  Result := -1;
  L := FGrid.ScreenToClient(P);
  for I := 0 to 41 do
  begin
    R := FCells[I].Panel.BoundsRect;
    if (L.X >= R.Left) and (L.X <= R.Right) and (L.Y >= R.Top) and (L.Y <= R.Bottom) then
      Exit(I);
  end;
end;

procedure TCalendarPage.ShowGhost(const P: TPoint);
var
  L: TPoint;
  I: Integer;
begin
  if FGhost = nil then
  begin
    FGhost := TPanel.Create(Self);
    FGhost.Parent := Self;
    FGhost.BevelOuter := bvNone;
    FGhost.BevelKind := bkFlat;
    FGhost.Color := ST_PRIMARY_BG;
    FGhost.ParentBackground := False;
    FGhost.SetBounds(0, 0, 200, 26);
    FGhostText := MakeLabel(Self, FGhost, '', 8, 5, 184, ST_PRIMARY_FG, 9);
  end;
  for I := 0 to High(FTasks) do
    if FTasks[I].Id = FDragId then
      FGhostText.Caption := FTasks[I].Subject;
  L := ScreenToClient(P);
  FGhost.SetBounds(L.X + 12, L.Y + 8, 200, 26);
  FGhost.Visible := True;
  FGhost.BringToFront;
end;

procedure TCalendarPage.HideGhost;
begin
  if FGhost <> nil then
    FGhost.Visible := False;
end;

procedure TCalendarPage.HighlightCell(Index: Integer);
begin
  if Index = FHoverCell then Exit;
  if (FHoverCell >= 0) and (FHoverCell <= 41) then
    FCells[FHoverCell].Panel.Color :=
      IfThen(Trunc(FCells[FHoverCell].Date) = Trunc(FSelected), ST_PRIMARY_BG,
        IfThen(FCells[FHoverCell].InMonth, ESPO_WHITE, $00FAFAF8));
  FHoverCell := Index;
  if (Index >= 0) and (Index <= 41) then
    FCells[Index].Panel.Color := ST_SUCCESS_BG;
end;

procedure TCalendarPage.TaskMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  FDragId := (Sender as TComponent).Tag;
  FDragActive := False;
  FDragOrigin := (Sender as TControl).ClientToScreen(Point(X, Y));
end;

procedure TCalendarPage.TaskMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  P: TPoint;
begin
  if (FDragId < 0) or not (ssLeft in Shift) then Exit;
  P := (Sender as TControl).ClientToScreen(Point(X, Y));
  if not FDragActive and (Abs(P.X - FDragOrigin.X) + Abs(P.Y - FDragOrigin.Y) < 8) then
    Exit;
  FDragActive := True;
  ShowGhost(P);
  HighlightCell(CellAtScreen(P));
end;

procedure TCalendarPage.TaskMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Cell: Integer;
begin
  if FDragActive then
  begin
    Cell := CellAtScreen((Sender as TControl).ClientToScreen(Point(X, Y)));
    HideGhost;
    HighlightCell(-1);
    if (Cell >= 0) and (FDragId >= 0) then
      MoveTaskTo(FDragId, FCells[Cell].Date);
  end;
  FDragActive := False;
  FDragId := -1;
end;

procedure TCalendarPage.TaskDblClick(Sender: TObject);
begin
  if Assigned(FOnOpenTask) then
    FOnOpenTask((Sender as TComponent).Tag);
end;

procedure TCalendarPage.MoveTaskTo(TaskId: Integer; const NewDate: TDateTime);
var
  I: Integer;
  Subject: string;
begin
  Subject := '';
  for I := 0 to High(FTasks) do
    if FTasks[I].Id = TaskId then
    begin
      if Trunc(FTasks[I].Due) = Trunc(NewDate) then Exit;
      Subject := FTasks[I].Subject;
    end;
  FData.DB.Connection.ExecSQL('UPDATE tasks SET due_at = :d WHERE id = :i',
    [FormatDateTime('yyyy-mm-dd', NewDate), TaskId]);
  FSelected := Trunc(NewDate);
  LoadMonth;
  Say(mkOk, T.F('calendar.moved', [Subject, FormatDateTime('dd.mm.yyyy', NewDate)]));
end;

procedure TCalendarPage.CellClick(Sender: TObject);
var
  I: Integer;
begin
  I := (Sender as TComponent).Tag;
  if (I < 0) or (I > 41) then Exit;
  FSelected := FCells[I].Date;
  LoadMonth;
end;

procedure TCalendarPage.OnPrevClick(Sender: TObject);
begin
  GoPrevMonth;
end;

procedure TCalendarPage.OnNextClick(Sender: TObject);
begin
  GoNextMonth;
end;

procedure TCalendarPage.OnTodayClick(Sender: TObject);
begin
  GoToday;
end;

procedure TCalendarPage.OnNewClick(Sender: TObject);
begin
  if Assigned(FOnNewTask) then
    FOnNewTask(FSelected);
end;

procedure TCalendarPage.OnListClick(Sender: TObject);
begin
  if Assigned(FOnShowList) then
    FOnShowList(Self);
end;

procedure TCalendarPage.GoPrevMonth;
begin
  FMonth := IncMonth(FMonth, -1);
  LoadMonth;
end;

procedure TCalendarPage.GoNextMonth;
begin
  FMonth := IncMonth(FMonth, 1);
  LoadMonth;
end;

procedure TCalendarPage.GoToday;
begin
  FMonth := EncodeDate(YearOf(Date), MonthOf(Date), 1);
  FSelected := Date;
  LoadMonth;
end;

procedure TCalendarPage.SelectDay(const ADate: TDateTime);
begin
  FSelected := Trunc(ADate);
  FMonth := EncodeDate(YearOf(ADate), MonthOf(ADate), 1);
  LoadMonth;
end;

function TCalendarPage.SelectedDay: TDateTime;
begin
  Result := FSelected;
end;

function TCalendarPage.MonthTitle: string;
begin
  Result := FTitle.Caption;
end;

function TCalendarPage.TasksInMonth: Integer;
var
  Task: TCalTask;
begin
  Result := 0;
  for Task in FTasks do
    if MonthOf(Task.Due) = MonthOf(FMonth) then Inc(Result);
end;

function TCalendarPage.TasksOnDay(const ADate: TDateTime): Integer;
var
  Task: TCalTask;
begin
  Result := 0;
  for Task in FTasks do
    if Trunc(Task.Due) = Trunc(ADate) then Inc(Result);
end;

function TCalendarPage.DragTask(TaskId: Integer; const ToDate: TDateTime): Boolean;
var
  I, Cell: Integer;
  Src: TLabel;
  P: TPoint;
begin
  Result := False;
  Cell := CellIndexOf(ToDate);
  if Cell < 0 then Exit;
  for I := 0 to High(FTaskLabels) do
    if FTaskLabels[I].Tag = TaskId then
    begin
      Src := FTaskLabels[I];
      // тот же путь, что и у мыши; координаты относительно подписи задачи
      TaskMouseDown(Src, mbLeft, [ssLeft], Src.Width div 2, Src.Height div 2);
      P := Src.ScreenToClient(FGrid.ClientToScreen(Point(
        FCells[Cell].Panel.Left + FCells[Cell].Panel.Width div 2,
        FCells[Cell].Panel.Top + FCells[Cell].Panel.Height div 2)));
      TaskMouseMove(Src, [ssLeft], P.X, P.Y);
      TaskMouseUp(Src, mbLeft, [], P.X, P.Y);
      Exit(True);
    end;
end;

end.
