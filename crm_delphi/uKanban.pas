unit uKanban;
{
  Канбан-доска: карточки работ по колонкам-этапам и перенос карточки
  кнопками «← Назад» / «Вперёд →».

  Три доски в одном экране (переключатель вверху):
    Заказы  — исполнение: аванс → работа → отгрузка → оплата → закрыто;
    Сделки  — продажи по этапам воронки;
    Задачи  — работы по срокам: просрочено / сегодня / позже / выполнено.

  Перенос не просто меняет подпись, а выставляет те же поля, по которым
  считаются этапы на рабочем столе (аванс, статус, дата отгрузки, оплата),
  поэтому доска и плитки всегда показывают одно и то же.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Generics.Collections,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  uCrmData, uEspoTheme;

type
  TBoardKind = (bkOrders, bkDeals, bkTasks);

  { Двойной клик по карточке открывает запись в её разделе. }
  TOpenRecordEvent = procedure(Board: TBoardKind; Id: Integer) of object;

  TKanbanCard = record
    Id: Integer;
    Col: Integer;
    Title, Subtitle, Amount, Due: string;
    Overdue: Boolean;
  end;

  TKanbanPage = class(TPanel)
  private
    FData: TCrmData;
    FOnSay: TSayProc;
    FBoard: TComboBox;
    FBody: TPanel;
    FCols: TArray<TPanel>;
    FColBodies: TArray<TScrollBox>;
    FColHeads: TArray<TLabel>;
    FColCounts: TArray<TLabel>;
    FCards: TArray<TKanbanCard>;
    FCardPanels: TArray<TPanel>;
    FSelected: Integer;      // индекс в FCards, -1 — ничего не выбрано
    FKind: TBoardKind;
    FOnOpenRecord: TOpenRecordEvent;
    // перетаскивание карточки мышью
    FDragIdx: Integer;
    FDragActive: Boolean;
    FDragOrigin: TPoint;
    FGhost: TPanel;
    FGhostText: TLabel;
    FHoverCol: Integer;
    procedure Say(Kind: TMsgKind; const Msg: string);
    function  ColumnTitles: TArray<string>;
    function  ColumnWhere(Col: Integer): string;
    function  TableName: string;
    procedure BuildUI;
    procedure RebuildColumns;
    procedure LoadCards;
    procedure OnBoardChange(Sender: TObject);
    procedure OnCardClick(Sender: TObject);
    procedure OnCardDblClick(Sender: TObject);
    procedure CardMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure CardMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure CardMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure HookMouse(Ctrl: TControl; CardIndex: Integer);
    function  ColumnAtScreen(const P: TPoint): Integer;
    procedure ShowGhost(const P: TPoint);
    procedure HideGhost;
    procedure HighlightColumn(Col: Integer);
    procedure MoveCardTo(Index, NewCol: Integer);
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
    function  ColumnCount: Integer;
    function  CardsInColumn(Col: Integer): Integer;
    function  SelectFirstCard(Col: Integer): Boolean;
    function  SelectedColumn: Integer;
    function  SelectedId: Integer;
    procedure MoveForward;
    procedure MoveBack;
    { Проводит карточку тем же путём, что и мышь: нажатие, перемещение и
      отпускание над колонкой (координаты берутся из реальных позиций
      контролов). Возвращает False, если в колонке нет карточек. }
    function  DragCard(FromCol, ToCol: Integer): Boolean;
    function  DragCardById(Id, ToCol: Integer): Boolean;
    function  DragCardIndex(Index, ToCol: Integer): Boolean;
    property Board: TBoardKind read FKind;
    property OnOpenRecord: TOpenRecordEvent read FOnOpenRecord write FOnOpenRecord;
  end;

implementation

uses
  System.StrUtils, System.Math, System.DateUtils, System.Variants,
  FireDAC.Comp.Client;

const
  COL_W = 196;
  COL_GAP = 8;
  CARD_H = 74;

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

function TKanbanPage.TableName: string;
begin
  case FKind of
    bkDeals: Result := 'deals';
    bkTasks: Result := 'tasks';
  else Result := 'orders';
  end;
end;

function TKanbanPage.ColumnTitles: TArray<string>;
begin
  case FKind of
    bkOrders: Result := ['Ожидает аванс', 'В работе / производство', 'Готово к отгрузке',
                         'Отгружено — ждём оплату', 'Закрыто'];
    bkDeals:  Result := ENUM_DEAL_STAGE.Split([';']);
  else        Result := ['Просрочено', 'Сегодня', 'Позже', 'Выполнено'];
  end;
end;

function TKanbanPage.ColumnWhere(Col: Integer): string;
var
  Stages: TArray<string>;
begin
  case FKind of
    bkOrders:
      Result := FData.StageWhere(TStage(Ord(stAwaitAdvance) + Col));
    bkDeals:
      begin
        Stages := ENUM_DEAL_STAGE.Split([';']);
        Result := 't.stage = ''' + Stages[Col] + '''';
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

procedure TKanbanPage.BuildUI;
var
  Hdr: TPanel;
  L: TLabel;
  Btn: TPanel;
begin
  Hdr := TPanel.Create(Self);
  Hdr.Parent := Self;
  Hdr.Align := alTop;
  Hdr.Height := 72;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_BODY;
  Hdr.ParentBackground := False;

  L := TLabel.Create(Self);
  L.Parent := Hdr;
  L.SetBounds(15, 10, 200, 30);
  L.Caption := 'Канбан';
  L.Font.Size := 16;

  FBoard := TComboBox.Create(Self);
  FBoard.Parent := Hdr;
  FBoard.Style := csDropDownList;
  FBoard.SetBounds(125, 14, 260, 28);
  FBoard.Items.Add('Заказы — исполнение');
  FBoard.Items.Add('Сделки — продажи');
  FBoard.Items.Add('Задачи — работы');
  FBoard.ItemIndex := 0;
  FBoard.OnChange := OnBoardChange;

  Btn := MakeButton(Self, Hdr, 'Вперёд →', True, OnForwardClick, 130);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 145, 10, 130, 36);
  Btn := MakeButton(Self, Hdr, '← Назад', False, OnBackClick, 120);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 145 - 8 - 120, 10, 120, 36);
  Btn := MakeButton(Self, Hdr, 'Обновить', False, OnRefreshClick, 110);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 145 - 8 - 120 - 8 - 110, 10, 110, 36);

  // подсказка отдельной строкой — иначе наезжает на кнопки
  MakeLabel(Self, Hdr, 'тяните карточку мышью между колонками  ·  двойной клик по карточке открывает запись',
    15, 50, 700, ESPO_MUTED, 9);

  FBody := TPanel.Create(Self);
  FBody.Parent := Self;
  FBody.Align := alClient;
  FBody.BevelOuter := bvNone;
  FBody.Color := ESPO_BODY;
  FBody.ParentBackground := False;

  RebuildColumns;
end;

procedure TKanbanPage.RebuildColumns;
var
  Titles: TArray<string>;
  I, X: Integer;
  P: TPanel;
  SB: TScrollBox;
begin
  for I := 0 to High(FCols) do
    FCols[I].Free;
  FCols := nil; FColBodies := nil; FColHeads := nil; FColCounts := nil;
  FCardPanels := nil; FCards := nil; FSelected := -1;

  Titles := ColumnTitles;
  X := 15;
  for I := 0 to High(Titles) do
  begin
    P := TPanel.Create(Self);
    P.Parent := FBody;
    P.SetBounds(X, 12, COL_W, FBody.Height - 24);
    P.Anchors := [akLeft, akTop, akBottom];
    P.BevelOuter := bvNone;
    P.BevelKind := bkFlat;
    P.Color := ESPO_WHITE;
    P.ParentBackground := False;
    FCols := FCols + [P];

    FColHeads := FColHeads + [MakeLabel(Self, P, Titles[I], 10, 10, COL_W - 20, ESPO_SOFT, 9)];
    FColHeads[I].Font.Style := [fsBold];
    FColCounts := FColCounts + [MakeLabel(Self, P, '', 10, 28, COL_W - 20, ESPO_MUTED, 8)];

    SB := TScrollBox.Create(Self);
    SB.Parent := P;
    SB.SetBounds(6, 48, COL_W - 12, P.Height - 56);
    SB.Anchors := [akLeft, akTop, akRight, akBottom];
    SB.BorderStyle := bsNone;
    SB.Color := ESPO_WHITE;
    SB.ParentBackground := False;
    SB.ParentColor := False;
    SB.VertScrollBar.Tracking := True;
    FColBodies := FColBodies + [SB];

    Inc(X, COL_W + COL_GAP);
  end;
end;

procedure TKanbanPage.LoadCards;
var
  Q: TFDQuery;
  SQL: string;
  Col, Y, I: Integer;
  C: TKanbanCard;
  P: TPanel;
  Titles: TArray<string>;
  Sum: Double;
  Cnt: Integer;
begin
  for I := 0 to High(FCardPanels) do
    FCardPanels[I].Free;
  FCardPanels := nil;
  FCards := nil;
  FSelected := -1;
  Titles := ColumnTitles;

  for Col := 0 to High(Titles) do
  begin
    Y := 4;
    Sum := 0; Cnt := 0;
    case FKind of
      bkOrders:
        SQL := 'SELECT t.id, t.number AS a, COALESCE(c.denumire,''(без клиента)'') AS b, ' +
               ' COALESCE(t.total,0) AS amt, COALESCE(t.due_date,'''') AS due, t.kind AS k ' +
               'FROM orders t LEFT JOIN clients c ON c.id = t.client_id WHERE ' +
               ColumnWhere(Col) + ' ORDER BY t.due_date, t.id';
      bkDeals:
        SQL := 'SELECT t.id, t.title AS a, COALESCE(c.denumire,''(без клиента)'') AS b, ' +
               ' COALESCE(t.amount,0) AS amt, COALESCE(t.close_date,'''') AS due, '''' AS k ' +
               'FROM deals t LEFT JOIN clients c ON c.id = t.client_id WHERE ' +
               ColumnWhere(Col) + ' ORDER BY t.close_date, t.id';
    else
      SQL := 'SELECT t.id, t.subject AS a, COALESCE(c.denumire,'''') AS b, 0 AS amt, ' +
             ' COALESCE(t.due_at,'''') AS due, t.kind AS k ' +
             'FROM tasks t LEFT JOIN clients c ON c.id = t.client_id WHERE ' +
             ColumnWhere(Col) + ' ORDER BY t.due_at, t.id';
    end;

    Q := FData.OpenQuery(SQL);
    try
      while not Q.Eof do
      begin
        C.Id := Q.FieldByName('id').AsInteger;
        C.Col := Col;
        C.Title := Q.FieldByName('a').AsString;
        if FKind = bkOrders then
          C.Title := '№' + C.Title + '  ·  ' + Q.FieldByName('k').AsString;
        C.Subtitle := Q.FieldByName('b').AsString;
        if FKind = bkTasks then
          C.Subtitle := Trim(Q.FieldByName('k').AsString + '  ' + C.Subtitle);
        if Q.FieldByName('amt').AsFloat > 0 then
          C.Amount := FormatFloat('#,##0.00', Q.FieldByName('amt').AsFloat) + ' MDL'
        else
          C.Amount := '';
        C.Due := Q.FieldByName('due').AsString;
        C.Overdue := (C.Due <> '') and (C.Due < FormatDateTime('yyyy-mm-dd', Now))
                     and (Col < High(Titles));
        Sum := Sum + Q.FieldByName('amt').AsFloat;
        Inc(Cnt);

        P := TPanel.Create(Self);
        P.Parent := FColBodies[Col];
        P.SetBounds(4, Y, COL_W - 34, CARD_H);
        P.BevelOuter := bvNone;
        P.BevelKind := bkFlat;
        P.Color := IfThen(C.Overdue, ST_DANGER_BG, ESPO_HEAD_BG);
        P.ParentBackground := False;
        P.Cursor := crHandPoint;
        HookMouse(P, Length(FCards));

        HookMouse(MakeLabel(Self, P, C.Title, 8, 6, P.Width - 16, ESPO_TEXT, 9), Length(FCards));
        TLabel(P.Controls[0]).Font.Style := [fsBold];
        HookMouse(MakeLabel(Self, P, C.Subtitle, 8, 24, P.Width - 16, ESPO_MUTED, 8), Length(FCards));
        HookMouse(MakeLabel(Self, P, C.Amount, 8, 42, P.Width - 16, ESPO_TEXT, 9), Length(FCards));
        HookMouse(MakeLabel(Self, P, IfThen(C.Due = '', '', IfThen(C.Overdue, 'просрочен ', 'срок ') + C.Due),
          8, 56, P.Width - 16, IfThen(C.Overdue, ST_DANGER_FG, ESPO_MUTED), 8), Length(FCards));

        FCards := FCards + [C];
        FCardPanels := FCardPanels + [P];
        Inc(Y, CARD_H + 6);
        Q.Next;
      end;
    finally
      Q.Free;
    end;

    // подпись под заголовком колонки: количество и сумма
    FColCounts[Col].Caption :=
      IfThen(Sum > 0, Format('%d  ·  %s MDL', [Cnt, FormatFloat('#,##0', Sum)]),
                      Format('%d', [Cnt]));
  end;
end;

procedure TKanbanPage.Refresh;
begin
  LoadCards;
end;

procedure TKanbanPage.OnBoardChange(Sender: TObject);
begin
  FKind := TBoardKind(FBoard.ItemIndex);
  RebuildColumns;
  LoadCards;
  Say(mkInfo, 'Доска: ' + FBoard.Text);
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

procedure TKanbanPage.ShowGhost(const P: TPoint);
var
  L: TPoint;
begin
  if FGhost = nil then
  begin
    FGhost := TPanel.Create(Self);
    FGhost.Parent := Self;
    FGhost.BevelOuter := bvNone;
    FGhost.BevelKind := bkFlat;
    FGhost.Color := ST_PRIMARY_BG;
    FGhost.ParentBackground := False;
    FGhost.SetBounds(0, 0, 180, 30);
    FGhostText := MakeLabel(Self, FGhost, '', 8, 7, 164, ST_PRIMARY_FG, 9);
    FGhostText.Font.Style := [fsBold];
  end;
  FGhostText.Caption := FCards[FDragIdx].Title;
  L := ScreenToClient(P);
  FGhost.SetBounds(L.X + 12, L.Y + 8, 180, 30);
  FGhost.Visible := True;
  FGhost.BringToFront;
end;

procedure TKanbanPage.HideGhost;
begin
  if FGhost <> nil then
    FGhost.Visible := False;
end;

procedure TKanbanPage.HighlightColumn(Col: Integer);
var
  I: Integer;
begin
  if Col = FHoverCol then Exit;
  FHoverCol := Col;
  for I := 0 to High(FCols) do
    FCols[I].Color := IfThen(I = Col, ST_PRIMARY_BG, ESPO_WHITE);
end;

procedure TKanbanPage.CardMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  FDragIdx := (Sender as TComponent).Tag;
  FDragActive := False;
  FDragOrigin := Mouse.CursorPos;
  OnCardClick(Sender);
end;

procedure TKanbanPage.CardMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  P: TPoint;
begin
  if (FDragIdx < 0) or not (ssLeft in Shift) then Exit;
  P := Mouse.CursorPos;
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
begin
  if FDragActive then
  begin
    Col := ColumnAtScreen(Mouse.CursorPos);
    HideGhost;
    HighlightColumn(-1);
    if (Col >= 0) and (FDragIdx >= 0) and (FDragIdx <= High(FCards)) and
       (Col <> FCards[FDragIdx].Col) then
      MoveCardTo(FDragIdx, Col)
    else
      Say(mkInfo, 'Перенос отменён: карточка осталась на прежнем этапе.');
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
  for I := 0 to High(FCardPanels) do
    if I = FSelected then
      FCardPanels[I].Color := ST_PRIMARY_BG
    else
      FCardPanels[I].Color := IfThen(FCards[I].Overdue, ST_DANGER_BG, ESPO_HEAD_BG);
  Say(mkInfo, Format('Выбрано: %s  ·  колонка «%s»',
    [FCards[FSelected].Title, ColumnTitles[FCards[FSelected].Col]]));
end;

procedure TKanbanPage.MoveSelected(Delta: Integer);
begin
  if (FSelected < 0) or (FSelected > High(FCards)) then
  begin
    Say(mkWarn, 'Выберите карточку на доске.');
    Exit;
  end;
  MoveCardTo(FSelected, FCards[FSelected].Col + Delta);
end;

{ Единственное место, где карточка меняет этап: сюда приходят и кнопки
  «Назад» / «Вперёд», и перетаскивание мышью. }
procedure TKanbanPage.MoveCardTo(Index, NewCol: Integer);
var
  C: TKanbanCard;
  Titles: TArray<string>;
  Total: Double;
  Id, I: Integer;
begin
  if (Index < 0) or (Index > High(FCards)) then
  begin
    Say(mkWarn, 'Выберите карточку на доске.');
    Exit;
  end;
  C := FCards[Index];
  Titles := ColumnTitles;
  if (NewCol < 0) or (NewCol > High(Titles)) then
  begin
    Say(mkWarn, 'Дальше двигать некуда: «' + Titles[C.Col] + '» — крайний этап.');
    Exit;
  end;
  if NewCol = C.Col then Exit;
  Id := C.Id;

  case FKind of
    bkOrders:
      begin
        Total := FData.Scalar('SELECT COALESCE(total,0) FROM orders WHERE id = ' + IntToStr(Id));
        // выставляем те же поля, по которым считаются этапы процесса
        case NewCol of
          0: FData.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''Подтверждён'', advance = 0, paid = 0, ship_date = NULL WHERE id = :i', [Id]);
          1: FData.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''В работе'', advance = :a, paid = 0, ship_date = NULL WHERE id = :i',
               [Max(0.01, Round(Total * 0.3 * 100) / 100), Id]);
          2: FData.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''Выполнен'', advance = :a, ship_date = NULL WHERE id = :i',
               [Max(0.01, Round(Total * 0.3 * 100) / 100), Id]);
          3: FData.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''Выполнен'', ship_date = :s, paid = :p WHERE id = :i',
               [FormatDateTime('yyyy-mm-dd', Now), Round(Total * 0.3 * 100) / 100, Id]);
          4: FData.DB.Connection.ExecSQL(
               'UPDATE orders SET status = ''Оплачен'', paid = :p, ship_date = COALESCE(NULLIF(ship_date,''''), :s) WHERE id = :i',
               [Total, FormatDateTime('yyyy-mm-dd', Now), Id]);
        end;
      end;
    bkDeals:
      FData.DB.Connection.ExecSQL('UPDATE deals SET stage = :s WHERE id = :i',
        [Titles[NewCol], Id]);
  else
    if NewCol = High(Titles) then
      FData.DB.Connection.ExecSQL('UPDATE tasks SET done = 1 WHERE id = :i', [Id])
    else
      FData.DB.Connection.ExecSQL('UPDATE tasks SET done = 0, due_at = :d WHERE id = :i',
        [FormatDateTime('yyyy-mm-dd', Now + IfThen(NewCol = 0, -1, IfThen(NewCol = 1, 0, 7))), Id]);
  end;

  LoadCards;
  // вернуть выделение на ту же запись в новой колонке
  for I := 0 to High(FCards) do
    if FCards[I].Id = Id then
    begin
      FSelected := I;
      FCardPanels[I].Color := ST_PRIMARY_BG;
      Break;
    end;
  Say(mkOk, Format('«%s» → этап «%s»', [C.Title, Titles[NewCol]]));
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
  // тот же путь, что и у мыши: нажатие на карточке, сдвиг, отпускание
  // над серединой целевой колонки
  P := Src.ClientToScreen(Point(Src.Width div 2, Src.Height div 2));
  Mouse.CursorPos := P;
  CardMouseDown(Src, mbLeft, [ssLeft], 0, 0);
  P := FBody.ClientToScreen(Point(FCols[ToCol].Left + FCols[ToCol].Width div 2,
    FCols[ToCol].Top + 80));
  Mouse.CursorPos := P;
  CardMouseMove(Src, [ssLeft], 0, 0);
  CardMouseUp(Src, mbLeft, [], 0, 0);
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
  Say(mkInfo, 'Доска обновлена.');
end;

{ ── хуки самотеста ── }

function TKanbanPage.ColumnCount: Integer;
begin
  Result := Length(FCols);
end;

function TKanbanPage.CardsInColumn(Col: Integer): Integer;
var
  C: TKanbanCard;
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

procedure TKanbanPage.MoveForward;
begin
  MoveSelected(1);
end;

procedure TKanbanPage.MoveBack;
begin
  MoveSelected(-1);
end;

end.
