unit uKanban;
{
  Канбан-доска: информативные карточки по колонкам-этапам, перенос мышью
  с анимацией и кнопками «← Назад» / «Вперёд →».

  Три доски в одном экране (переключатель вверху):
    Заказы  — исполнение: аванс → работа → отгрузка → оплата → закрыто;
    Сделки  — продажи по этапам воронки;
    Задачи  — работы по срокам: просрочено / сегодня / позже / выполнено.

  Карточка: цветная полоса и значок по виду записи, клиент, сумма, прогресс
  оплаты, бейдж срока («−3 д», «сегодня», «5 д», «✔»). Данные карточек и
  единственная точка смены этапа — в uBoardCards, общем с схемой
  бизнес-процесса (uProcess), поэтому обе страницы показывают одно и то же.

  Анимация: при перетаскивании под курсором едет копия карточки, целевая
  колонка подсвечивается и показывает слот для вставки; после переноса
  (мышью или кнопкой) карточка «перелетает» на новое место и коротко
  вспыхивает. Кадры анимации считаются (AnimFrames) — самотест проверяет,
  что она действительно отработала.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  uCrmData, uEspoTheme, uBoardCards;

type
  { Двойной клик по карточке открывает запись в её разделе. }
  TOpenRecordEvent = procedure(Board: TBoardKind; Id: Integer) of object;

  TKanbanPage = class(TPanel)
  private
    FData: TCrmData;
    FOnSay: TSayProc;
    FBoard: TComboBox;
    FProject: TComboBox;          // проект для доски задач проекта
    FProjectIds: TArray<Integer>;
    FBody: TScrollBox;             // колонок может быть больше, чем влезает — горизонтальная прокрутка
    FColW: Integer;
    FCols: TArray<TPanel>;
    FColBodies: TArray<TScrollBox>;
    FColHeads: TArray<TLabel>;
    FColCounts: TArray<TLabel>;
    FColLate: TArray<TLabel>;
    FCards: TBoardCards;
    FCardPanels: TArray<TPanel>;
    FSelected: Integer;      // индекс в FCards, -1 — ничего не выбрано
    FKind: TBoardKind;
    FOnOpenRecord: TOpenRecordEvent;
    FTitle, FHint: TLabel;
    // перетаскивание карточки мышью
    FDragIdx: Integer;
    FDragActive: Boolean;
    FDragOrigin: TPoint;
    FDragOffset: TPoint;
    FGhost: TPanel;
    FSlot: TPanel;
    FHoverCol: Integer;
    FAnimFrames: Integer;
    FAnimEnabled: Boolean;
    procedure Say(Kind: TMsgKind; const Msg: string);
    procedure BuildUI;
    procedure RebuildColumns;
    procedure LoadCards;
    procedure OnBoardChange(Sender: TObject);
    procedure OnProjectChange(Sender: TObject);
    procedure FillProjects;
    procedure OnCardClick(Sender: TObject);
    procedure OnCardDblClick(Sender: TObject);
    procedure CardMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure CardMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure CardMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure HookMouse(Ctrl: TControl; CardIndex: Integer);
    function  ColumnAtScreen(const P: TPoint): Integer;
    function  PageRect(Ctrl: TControl): TRect;
    procedure ShowGhost(const P: TPoint);
    procedure HideGhost;
    procedure HighlightColumn(Col: Integer);
    procedure PaintCard(Index: Integer);
    procedure AnimateMove(const FromR, ToR: TRect; const C: TBoardCard);
    procedure Pulse(P: TPanel; const Base: TColor);
    procedure MoveCardTo(Index, NewCol: Integer; const FromR: TRect);
    procedure OnBackClick(Sender: TObject);
    procedure OnForwardClick(Sender: TObject);
    procedure OnRefreshClick(Sender: TObject);
    procedure MoveSelected(Delta: Integer);
  public
    constructor Create(AOwner: TComponent; AParent: TWinControl; AData: TCrmData;
      ASay: TSayProc); reintroduce;
    procedure Refresh;

    // хуки самотеста
    procedure SelectBoard(Kind: TBoardKind);
    { Доска задач проекта: выбрать проект (0 — все задачи с проектом). }
    procedure SelectProject(ProjectId: Integer);
    function  ProjectId: Integer;
    function  ColumnCount: Integer;
    function  CardsInColumn(Col: Integer): Integer;
    function  SelectFirstCard(Col: Integer): Boolean;
    function  SelectedColumn: Integer;
    function  SelectedId: Integer;
    function  CardById(Id: Integer; out C: TBoardCard): Boolean;
    procedure MoveForward;
    procedure MoveBack;
    { Проводит карточку тем же путём, что и мышь: нажатие, перемещение и
      отпускание над колонкой (координаты берутся из реальных позиций
      контролов). Возвращает False, если в колонке нет карточек. }
    function  DragCard(FromCol, ToCol: Integer): Boolean;
    function  DragCardById(Id, ToCol: Integer): Boolean;
    function  DragCardIndex(Index, ToCol: Integer): Boolean;
    property Board: TBoardKind read FKind;
    property AnimFrames: Integer read FAnimFrames;
    property AnimEnabled: Boolean read FAnimEnabled write FAnimEnabled;
    property OnOpenRecord: TOpenRecordEvent read FOnOpenRecord write FOnOpenRecord;
  end;

implementation

uses
  System.StrUtils, System.Math, System.Generics.Collections, uI18n;

const
  COL_W = 202;
  COL_GAP = 8;
  CARD_GAP = 6;

{ TKanbanPage }

constructor TKanbanPage.Create(AOwner: TComponent; AParent: TWinControl;
  AData: TCrmData; ASay: TSayProc);
begin
  inherited Create(AOwner);
  Parent := AParent;
  Align := alClient;
  Visible := False;
  FData := AData;
  FOnSay := ASay;
  FKind := bkOrders;
  FSelected := -1;
  FDragIdx := -1;
  FHoverCol := -1;
  FAnimEnabled := True;
  BevelOuter := bvNone;
  Color := ESPO_BODY;
  ParentBackground := False;
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;
  BuildUI;
end;

procedure TKanbanPage.Say(Kind: TMsgKind; const Msg: string);
begin
  if Assigned(FOnSay) then FOnSay(Kind, Msg);
end;

procedure TKanbanPage.BuildUI;
var
  Hdr: TPanel;
  Btn: TPanel;
  X: Integer;

  procedure Legend(const Glyph, Text: string; Color: TColor);
  var
    L: TLabel;
  begin
    L := MakeLabel(Self, Hdr, Glyph, X, 50, 16, Color, 10);
    L.Font.Style := [fsBold];
    L.Anchors := [akTop, akRight];
    L := MakeLabel(Self, Hdr, Text, X + 16, 51, 90, ESPO_MUTED, 8);
    L.Anchors := [akTop, akRight];
    Inc(X, 16 + Canvas.TextWidth(Text) + 14);
  end;

begin
  Hdr := TPanel.Create(Self);
  Hdr.Parent := Self;
  Hdr.Align := alTop;
  Hdr.Height := 72;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_BODY;
  Hdr.ParentBackground := False;

  FTitle := MakeLabel(Self, Hdr, T.S('kanban.title'), 15, 10, 110, ESPO_TEXT, 16);
  FTitle.Height := 30;

  FBoard := TComboBox.Create(Self);
  FBoard.Parent := Hdr;
  FBoard.Style := csDropDownList;
  FBoard.SetBounds(125, 14, 260, 28);
  FBoard.Items.Add(T.S('kanban.board_orders'));
  FBoard.Items.Add(T.S('kanban.board_deals'));
  FBoard.Items.Add(T.S('kanban.board_tasks'));
  FBoard.Items.Add(T.S('kanban.board_projects'));
  FBoard.Items.Add(T.S('kanban.board_project_tasks'));
  FBoard.ItemIndex := 0;
  FBoard.OnChange := OnBoardChange;

  // выбор проекта — только для доски задач проекта
  FProject := TComboBox.Create(Self);
  FProject.Parent := Hdr;
  FProject.Style := csDropDownList;
  FProject.SetBounds(395, 14, 250, 28);
  FProject.Visible := False;
  FProject.OnChange := OnProjectChange;

  Btn := MakeButton(Self, Hdr, T.S('btn.forward'), True, OnForwardClick, 130);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 145, 10, 130, 36);
  Btn := MakeButton(Self, Hdr, T.S('btn.back'), False, OnBackClick, 120);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 145 - 8 - 120, 10, 120, 36);
  Btn := MakeButton(Self, Hdr, T.S('btn.refresh'), False, OnRefreshClick, 110);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 145 - 8 - 120 - 8 - 110, 10, 110, 36);

  // подсказка отдельной строкой — иначе наезжает на кнопки
  FHint := MakeLabel(Self, Hdr, T.S('kanban.hint'), 15, 50, 560, ESPO_MUTED, 9);

  // легенда цветов справа
  Canvas.Font.Name := 'Segoe UI';
  Canvas.Font.Size := 8;
  X := Hdr.Width - 15 - 4 * 100;
  Legend('■', T.EnumAt('order_kind', 0), $00CA8955);
  Legend('■', T.EnumAt('order_kind', 1), $00A28F2B);
  Legend('■', T.EnumAt('order_kind', 2), $002E9BE0);
  Legend('■', T.S('kanban.overdue'), ST_DANGER_FG);
  Legend('■', T.S('kanban.done_badge'), ST_SUCCESS_FG);

  FBody := TScrollBox.Create(Self);
  FBody.Parent := Self;
  FBody.Align := alClient;
  FBody.BorderStyle := bsNone;
  FBody.Color := ESPO_BODY;
  FBody.ParentBackground := False;
  FBody.ParentColor := False;
  FBody.VertScrollBar.Visible := False;
  FBody.HorzScrollBar.Tracking := True;

  RebuildColumns;
end;

procedure TKanbanPage.RebuildColumns;
var
  Titles: TArray<string>;
  I, X: Integer;
  P, Stripe: TPanel;
  SB: TScrollBox;
begin
  HideGhost;
  for I := 0 to High(FCols) do
    FCols[I].Free;
  FCols := nil; FColBodies := nil; FColHeads := nil; FColCounts := nil; FColLate := nil;
  FCardPanels := nil; FCards := nil; FSelected := -1; FHoverCol := -1;

  Titles := BoardColumnTitles(FKind);
  // до пяти колонок — широкие; больше — уже и с горизонтальной прокруткой
  if Length(Titles) <= 5 then FColW := COL_W else FColW := 176;
  X := 15;
  for I := 0 to High(Titles) do
  begin
    P := TPanel.Create(Self);
    P.Parent := FBody;
    P.SetBounds(X, 12, FColW, FBody.ClientHeight - 24 - IfThen(Length(Titles) > 5, 18, 0));
    P.Anchors := [akLeft, akTop, akBottom];
    P.BevelOuter := bvNone;
    P.BevelKind := bkFlat;
    P.Color := ESPO_WHITE;
    P.ParentBackground := False;
    FCols := FCols + [P];

    // цветная кромка колонки — тот же цвет, что у узла схемы процесса
    Stripe := TPanel.Create(Self);
    Stripe.Parent := P;
    Stripe.SetBounds(0, 0, FColW - 4, 4);
    Stripe.Anchors := [akLeft, akTop, akRight];
    Stripe.BevelOuter := bvNone;
    Stripe.Color := BoardColumnColor(FKind, I);
    Stripe.ParentBackground := False;

    FColHeads := FColHeads + [MakeLabel(Self, P, Titles[I], 10, 12, FColW - 20, ESPO_SOFT, 9)];
    FColHeads[I].Font.Style := [fsBold];
    FColCounts := FColCounts + [MakeLabel(Self, P, '', 10, 30, FColW - 20, ESPO_MUTED, 8)];
    FColLate := FColLate + [MakeLabel(Self, P, '', 10, 44, FColW - 20, ST_DANGER_FG, 8)];

    SB := TScrollBox.Create(Self);
    SB.Parent := P;
    SB.SetBounds(6, 62, FColW - 12, P.Height - 70);
    SB.Anchors := [akLeft, akTop, akRight, akBottom];
    SB.BorderStyle := bsNone;
    SB.Color := ESPO_WHITE;
    SB.ParentBackground := False;
    SB.ParentColor := False;
    SB.VertScrollBar.Tracking := True;
    FColBodies := FColBodies + [SB];

    Inc(X, FColW + COL_GAP);
  end;
end;

procedure TKanbanPage.LoadCards;
var
  Col, Y, I, Idx, Late: Integer;
  Cards: TBoardCards;
  C: TBoardCard;
  P: TPanel;
  Titles: TArray<string>;
  Sum: Double;
begin
  HideGhost;
  for I := 0 to High(FCardPanels) do
    FCardPanels[I].Free;
  FCardPanels := nil;
  FCards := nil;
  FSelected := -1;
  Titles := BoardColumnTitles(FKind);

  for Col := 0 to High(Titles) do
  begin
    Y := 4;
    Cards := LoadBoardCards(FData, FKind, Col);
    for C in Cards do
    begin
      Idx := Length(FCards);
      P := MakeBoardCard(Self, FColBodies[Col], C, 4, Y, FColW - 34,
        procedure(Ctrl: TControl) begin HookMouse(Ctrl, Idx); end);
      FCards := FCards + [C];
      FCardPanels := FCardPanels + [P];
      Inc(Y, CARD_H + CARD_GAP);
    end;

    // подпись под заголовком колонки: количество, сумма, просрочка
    Sum := BoardColumnSum(Cards);
    Late := BoardColumnOverdue(Cards);
    FColCounts[Col].Caption :=
      IfThen(Sum > 0, Format('%d  ·  %s MDL', [Length(Cards), FormatFloat('#,##0', Sum)]),
                      Format('%d', [Length(Cards)]));
    FColLate[Col].Caption := IfThen(Late > 0, T.F('kanban.col_late', [Late]), '');
  end;
end;

procedure TKanbanPage.Refresh;
begin
  LoadCards;
end;

procedure TKanbanPage.OnBoardChange(Sender: TObject);
begin
  FKind := TBoardKind(FBoard.ItemIndex);
  FProject.Visible := FKind = bkProjectTasks;
  if FKind = bkProjectTasks then
  begin
    FillProjects;
    BoardProjectFilter := ProjectId;
  end;
  RebuildColumns;
  LoadCards;
  Say(mkInfo, T.F('kanban.board', [FBoard.Text]));
end;

{ Список проектов для доски задач: первый пункт — все задачи с проектом. }
procedure TKanbanPage.FillProjects;
var
  Pairs: TArray<TPair<Integer, string>>;
  I, Keep: Integer;
begin
  Keep := ProjectId;
  FProject.Items.Clear;
  FProject.Items.Add(T.S('kanban.all_projects'));
  FProjectIds := [0];
  Pairs := FData.LookupPairs(fkLookupProject);
  for I := 0 to High(Pairs) do
  begin
    FProject.Items.Add(Pairs[I].Value);
    FProjectIds := FProjectIds + [Pairs[I].Key];
  end;
  FProject.ItemIndex := 0;
  for I := 0 to High(FProjectIds) do
    if FProjectIds[I] = Keep then FProject.ItemIndex := I;
end;

procedure TKanbanPage.OnProjectChange(Sender: TObject);
begin
  BoardProjectFilter := ProjectId;
  LoadCards;
  Say(mkInfo, T.F('kanban.project', [FProject.Text]));
end;

function TKanbanPage.ProjectId: Integer;
begin
  if (FProject.ItemIndex >= 0) and (FProject.ItemIndex <= High(FProjectIds)) then
    Result := FProjectIds[FProject.ItemIndex]
  else
    Result := 0;
end;

procedure TKanbanPage.SelectProject(ProjectId: Integer);
var
  I: Integer;
begin
  if FKind <> bkProjectTasks then SelectBoard(bkProjectTasks);
  FillProjects;
  for I := 0 to High(FProjectIds) do
    if FProjectIds[I] = ProjectId then FProject.ItemIndex := I;
  OnProjectChange(FProject);
end;

procedure TKanbanPage.SelectBoard(Kind: TBoardKind);
begin
  FBoard.ItemIndex := Ord(Kind);
  OnBoardChange(FBoard);
end;

{ Мышь вешаем и на панель карточки, и на её подписи: иначе нажатие по тексту
  до панели не доходит и карточку нельзя ни выбрать, ни потащить. }
procedure TKanbanPage.HookMouse(Ctrl: TControl; CardIndex: Integer);
begin
  Ctrl.Tag := CardIndex;
  Ctrl.Cursor := crHandPoint;
  if Ctrl is TPanel then
  begin
    TPanel(Ctrl).OnMouseDown := CardMouseDown;
    TPanel(Ctrl).OnMouseMove := CardMouseMove;
    TPanel(Ctrl).OnMouseUp := CardMouseUp;
    TPanel(Ctrl).OnDblClick := OnCardDblClick;
  end
  else if Ctrl is TLabel then
  begin
    TLabel(Ctrl).OnMouseDown := CardMouseDown;
    TLabel(Ctrl).OnMouseMove := CardMouseMove;
    TLabel(Ctrl).OnMouseUp := CardMouseUp;
    TLabel(Ctrl).OnDblClick := OnCardDblClick;
  end;
end;

function TKanbanPage.ColumnAtScreen(const P: TPoint): Integer;
var
  L: TPoint;
  I: Integer;
begin
  Result := -1;
  L := FBody.ScreenToClient(P);
  for I := 0 to High(FCols) do
    if (L.X >= FCols[I].Left) and (L.X <= FCols[I].Left + FCols[I].Width) then
      Exit(I);
end;

{ Прямоугольник контрола в координатах страницы — для анимации перелёта. }
function TKanbanPage.PageRect(Ctrl: TControl): TRect;
var
  TL: TPoint;
begin
  if Ctrl = nil then Exit(TRect.Empty);
  TL := ScreenToClient(Ctrl.ClientToScreen(Point(0, 0)));
  Result := Rect(TL.X, TL.Y, TL.X + Ctrl.Width, TL.Y + Ctrl.Height);
end;

{ Под курсором едет копия карточки; оригинал остаётся на месте приглушённым. }
procedure TKanbanPage.ShowGhost(const P: TPoint);
var
  L: TPoint;
begin
  if (FDragIdx < 0) or (FDragIdx > High(FCards)) then Exit;
  if FGhost = nil then
  begin
    FGhost := MakeBoardCard(Self, Self, FCards[FDragIdx], 0, 0, FColW - 34, nil);
    FGhost.Color := ST_PRIMARY_BG;
    FGhost.BevelKind := bkFlat;
    FGhost.BevelOuter := bvRaised;
    FCardPanels[FDragIdx].Color := ESPO_BODY;
  end;
  L := ScreenToClient(P);
  FGhost.SetBounds(L.X - FDragOffset.X, L.Y - FDragOffset.Y, FGhost.Width, FGhost.Height);
  FGhost.Visible := True;
  FGhost.BringToFront;
end;

procedure TKanbanPage.HideGhost;
begin
  if FGhost <> nil then
  begin
    FGhost.Free;
    FGhost := nil;
  end;
  if FSlot <> nil then
  begin
    FSlot.Free;
    FSlot := nil;
  end;
  if (FDragIdx >= 0) and (FDragIdx <= High(FCardPanels)) then
    PaintCard(FDragIdx);
end;

{ Целевая колонка подсвечивается и показывает слот, куда ляжет карточка. }
procedure TKanbanPage.HighlightColumn(Col: Integer);
var
  I, Y: Integer;
begin
  if Col = FHoverCol then Exit;
  FHoverCol := Col;
  for I := 0 to High(FCols) do
    FCols[I].Color := IfThen(I = Col, ST_PRIMARY_BG, ESPO_WHITE);
  if FSlot <> nil then
  begin
    FSlot.Free;
    FSlot := nil;
  end;
  if (Col >= 0) and (FDragIdx >= 0) and (Col <> FCards[FDragIdx].Col) then
  begin
    Y := 4;
    for I := 0 to High(FCards) do
      if FCards[I].Col = Col then Inc(Y, CARD_H + CARD_GAP);
    FSlot := TPanel.Create(Self);
    FSlot.Parent := FColBodies[Col];
    FSlot.SetBounds(4, Y, FColW - 34, CARD_H);
    FSlot.BevelOuter := bvNone;
    FSlot.BevelKind := bkFlat;
    FSlot.Color := ESPO_HEAD_BG;
    FSlot.ParentBackground := False;
    FSlot.Caption := '⇩';
    FSlot.Font.Size := 16;
    FSlot.Font.Color := ESPO_PRIMARY;
  end;
end;

procedure TKanbanPage.PaintCard(Index: Integer);
begin
  if (Index < 0) or (Index > High(FCardPanels)) then Exit;
  if Index = FSelected then
    FCardPanels[Index].Color := ST_PRIMARY_BG
  else
    FCardPanels[Index].Color := CardBaseColor(FCards[Index]);
end;

procedure TKanbanPage.CardMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Card: TPanel;
begin
  if Button <> mbLeft then Exit;
  FDragIdx := (Sender as TComponent).Tag;
  FDragActive := False;
  FDragOrigin := (Sender as TControl).ClientToScreen(Point(X, Y));
  if (FDragIdx >= 0) and (FDragIdx <= High(FCardPanels)) then
  begin
    Card := FCardPanels[FDragIdx];
    FDragOffset := Card.ScreenToClient(FDragOrigin);
    FDragOffset.X := Max(0, Min(FDragOffset.X, Card.Width));
    FDragOffset.Y := Max(0, Min(FDragOffset.Y, Card.Height));
  end;
  OnCardClick(Sender);
end;

procedure TKanbanPage.CardMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  P: TPoint;
begin
  if (FDragIdx < 0) or not (ssLeft in Shift) then Exit;
  P := (Sender as TControl).ClientToScreen(Point(X, Y));
  // старт перетаскивания только после заметного сдвига — чтобы обычный
  // клик по карточке не превращался в перенос
  if not FDragActive and (Abs(P.X - FDragOrigin.X) + Abs(P.Y - FDragOrigin.Y) < 8) then
    Exit;
  FDragActive := True;
  ShowGhost(P);
  HighlightColumn(ColumnAtScreen(P));
end;

procedure TKanbanPage.CardMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Col: Integer;
  FromR: TRect;
begin
  if FDragActive then
  begin
    Col := ColumnAtScreen((Sender as TControl).ClientToScreen(Point(X, Y)));
    FromR := PageRect(FGhost);
    HideGhost;
    HighlightColumn(-1);
    if (Col >= 0) and (FDragIdx >= 0) and (FDragIdx <= High(FCards)) and
       (Col <> FCards[FDragIdx].Col) then
      MoveCardTo(FDragIdx, Col, FromR)
    else
      Say(mkInfo, T.S('kanban.cancelled'));
  end;
  FDragActive := False;
  FDragIdx := -1;
end;

procedure TKanbanPage.OnCardDblClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := (Sender as TComponent).Tag;
  if (Idx < 0) or (Idx > High(FCards)) then Exit;
  if Assigned(FOnOpenRecord) then
    FOnOpenRecord(FKind, FCards[Idx].Id);
end;

procedure TKanbanPage.OnCardClick(Sender: TObject);
var
  I: Integer;
begin
  FSelected := (Sender as TComponent).Tag;
  if (FSelected < 0) or (FSelected > High(FCards)) then Exit;
  for I := 0 to High(FCardPanels) do
    PaintCard(I);
  Say(mkInfo, T.F('kanban.selected',
    [FCards[FSelected].Title, BoardColumnTitles(FKind)[FCards[FSelected].Col]]));
end;

procedure TKanbanPage.MoveSelected(Delta: Integer);
begin
  if (FSelected < 0) or (FSelected > High(FCards)) then
  begin
    Say(mkWarn, T.S('kanban.select_card'));
    Exit;
  end;
  MoveCardTo(FSelected, FCards[FSelected].Col + Delta, PageRect(FCardPanels[FSelected]));
end;

{ Перелёт копии карточки из FromR в ToR с замедлением в конце. }
procedure TKanbanPage.AnimateMove(const FromR, ToR: TRect; const C: TBoardCard);
const
  FRAMES = 14;
var
  Fly: TPanel;
  I: Integer;
  K: Double;
begin
  if not FAnimEnabled or FromR.IsEmpty or ToR.IsEmpty then Exit;
  Fly := MakeBoardCard(Self, Self, C, FromR.Left, FromR.Top, FromR.Width, nil);
  try
    Fly.Color := ST_PRIMARY_BG;
    Fly.BringToFront;
    for I := 1 to FRAMES do
    begin
      K := I / FRAMES;
      K := 1 - Sqr(1 - K);   // ease-out
      Fly.SetBounds(Round(FromR.Left + (ToR.Left - FromR.Left) * K),
                    Round(FromR.Top + (ToR.Top - FromR.Top) * K),
                    FromR.Width, FromR.Height);
      Fly.Update;
      Application.ProcessMessages;
      Sleep(12);
      Inc(FAnimFrames);
    end;
  finally
    Fly.Free;
  end;
end;

{ Короткая вспышка приземлившейся карточки. }
procedure TKanbanPage.Pulse(P: TPanel; const Base: TColor);
const
  STEPS: array[0..2] of TColor = (ST_SUCCESS_BG, ST_PRIMARY_BG, ST_SUCCESS_BG);
var
  I: Integer;
begin
  if not FAnimEnabled or (P = nil) then Exit;
  for I := 0 to High(STEPS) do
  begin
    P.Color := STEPS[I];
    P.Update;
    Application.ProcessMessages;
    Sleep(45);
    Inc(FAnimFrames);
  end;
  P.Color := Base;
end;

{ Единственное место на доске, где карточка меняет этап: сюда приходят и
  кнопки «Назад» / «Вперёд», и перетаскивание мышью. Сама запись в базу —
  MoveBoardCard, общая со схемой бизнес-процесса. }
procedure TKanbanPage.MoveCardTo(Index, NewCol: Integer; const FromR: TRect);
var
  C: TBoardCard;
  Titles: TArray<string>;
  Id, I: Integer;
begin
  if (Index < 0) or (Index > High(FCards)) then
  begin
    Say(mkWarn, T.S('kanban.select_card'));
    Exit;
  end;
  C := FCards[Index];
  Titles := BoardColumnTitles(FKind);
  if (NewCol < 0) or (NewCol > High(Titles)) then
  begin
    Say(mkWarn, T.F('kanban.edge', [Titles[C.Col]]));
    Exit;
  end;
  if NewCol = C.Col then Exit;
  Id := C.Id;

  MoveBoardCard(FData, FKind, Id, NewCol);
  LoadCards;

  // вернуть выделение на ту же запись в новой колонке и показать перелёт
  for I := 0 to High(FCards) do
    if FCards[I].Id = Id then
    begin
      FSelected := I;
      FCardPanels[I].Visible := False;
      AnimateMove(FromR, PageRect(FCardPanels[I]), FCards[I]);
      FCardPanels[I].Visible := True;
      Pulse(FCardPanels[I], ST_PRIMARY_BG);
      Break;
    end;
  Say(mkOk, T.F('kanban.moved', [C.Title, Titles[NewCol]]));
end;

function TKanbanPage.DragCardIndex(Index, ToCol: Integer): Boolean;
var
  P: TPoint;
  Src: TPanel;
begin
  Result := (Index >= 0) and (Index <= High(FCards)) and
            (ToCol >= 0) and (ToCol <= High(FCols));
  if not Result then Exit;
  Src := FCardPanels[Index];
  // тот же путь, что и у мыши: нажатие на карточке, сдвиг, отпускание над
  // серединой целевой колонки. Координаты передаются относительно карточки,
  // как их даёт VCL реальной мыши (SetCursorPos в заблокированном сеансе
  // не работает, поэтому на физический курсор не полагаемся).
  CardMouseDown(Src, mbLeft, [ssLeft], Src.Width div 2, Src.Height div 2);
  P := Src.ScreenToClient(FBody.ClientToScreen(Point(
    FCols[ToCol].Left + FCols[ToCol].Width div 2, FCols[ToCol].Top + 80)));
  CardMouseMove(Src, [ssLeft], P.X, P.Y);
  Application.ProcessMessages;
  CardMouseUp(Src, mbLeft, [], P.X, P.Y);
end;

function TKanbanPage.DragCard(FromCol, ToCol: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FCards) do
    if FCards[I].Col = FromCol then
      Exit(DragCardIndex(I, ToCol));
end;

function TKanbanPage.DragCardById(Id, ToCol: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FCards) do
    if FCards[I].Id = Id then
      Exit(DragCardIndex(I, ToCol));
end;

procedure TKanbanPage.OnBackClick(Sender: TObject);
begin
  MoveSelected(-1);
end;

procedure TKanbanPage.OnForwardClick(Sender: TObject);
begin
  MoveSelected(1);
end;

procedure TKanbanPage.OnRefreshClick(Sender: TObject);
begin
  LoadCards;
  Say(mkInfo, T.S('kanban.refreshed'));
end;

{ ── хуки самотеста ── }

function TKanbanPage.ColumnCount: Integer;
begin
  Result := Length(FCols);
end;

function TKanbanPage.CardsInColumn(Col: Integer): Integer;
var
  C: TBoardCard;
begin
  Result := 0;
  for C in FCards do
    if C.Col = Col then Inc(Result);
end;

function TKanbanPage.SelectFirstCard(Col: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FCards) do
    if FCards[I].Col = Col then
    begin
      OnCardClick(FCardPanels[I]);
      Exit(True);
    end;
end;

function TKanbanPage.SelectedColumn: Integer;
begin
  if (FSelected >= 0) and (FSelected <= High(FCards)) then
    Result := FCards[FSelected].Col
  else
    Result := -1;
end;

function TKanbanPage.SelectedId: Integer;
begin
  if (FSelected >= 0) and (FSelected <= High(FCards)) then
    Result := FCards[FSelected].Id
  else
    Result := 0;
end;

function TKanbanPage.CardById(Id: Integer; out C: TBoardCard): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FCards) do
    if FCards[I].Id = Id then
    begin
      C := FCards[I];
      Exit(True);
    end;
end;

procedure TKanbanPage.MoveForward;
begin
  MoveSelected(1);
end;

procedure TKanbanPage.MoveBack;
begin
  MoveSelected(-1);
end;

end.
