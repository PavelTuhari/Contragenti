unit uProcess;
{
  Схема бизнес-процесса: те же этапы и те же карточки, что на канбане, но
  в виде дорожек и узлов со стрелками (start → шаги → развилки → end).

  Описание процессов — внешний processes.json рядом с программой: узлы,
  связи, ответственные, нормативы (sla_days) и текст описания на трёх
  языках. Узел с board/col привязан к колонке канбана и показывает её
  карточки (uBoardCards): щелчок по узлу — список карточек этапа и его
  описание; двойной щелчок по узлу — раздел с этим фильтром; двойной
  щелчок по карточке — запись; карточку можно перетащить мышью на другой
  узел того же процесса — этап меняется через MoveBoardCard, как на канбане.

  Описание этапа редактируется прямо здесь и сохраняется обратно в
  processes.json (для текущего языка).
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types, System.JSON,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  uCrmData, uEspoTheme, uBoardCards;

type
  TNodeKind = (nkStart, nkStep, nkGate, nkEnd);

  TProcNode = record
    Id: string;
    Kind: TNodeKind;
    HasBoard: Boolean;
    Board: TBoardKind;
    Col: Integer;
    X, Y: Integer;          // слот и дорожка
    Title, Owner, Desc: string;
    SlaDays: Integer;
    Json: TJSONObject;      // узел в файле — для сохранения описания
    R: TRect;               // прямоугольник на схеме (после Layout)
    Cards: TBoardCards;
    Count, Overdue: Integer;
    Sum: Double;
  end;

  TProcEdge = record
    FromIdx, ToIdx: Integer;
    Label_: string;
  end;

  TOpenColumnEvent = procedure(Board: TBoardKind; Col: Integer) of object;
  TOpenBoardRecordEvent = procedure(Board: TBoardKind; Id: Integer) of object;

  TProcessPage = class(TPanel)
  private
    FData: TCrmData;
    FOnSay: TSayProc;
    FRoot: TJSONObject;
    FFile: string;
    FProcs: TJSONArray;
    FProcIdx: Integer;
    FNodes: TArray<TProcNode>;
    FEdges: TArray<TProcEdge>;
    FLanes: TArray<string>;
    FSelected: Integer;
    FHoverNode: Integer;
    FPulseNode: Integer;
    FCombo: TComboBox;
    FBox: TPaintBox;
    FBottom: TPanel;
    FDescTitle, FOwnerLbl, FSlaLbl, FCardsTitle: TLabel;
    FDesc: TMemo;
    FCardsBox: TScrollBox;
    FCards: TBoardCards;
    FCardPanels: TArray<TPanel>;
    FOnOpenColumn: TOpenColumnEvent;
    FOnOpenRecord: TOpenBoardRecordEvent;
    // перетаскивание карточки на узел
    FDragIdx: Integer;
    FDragActive: Boolean;
    FDragOrigin, FDragOffset: TPoint;
    FGhost: TPanel;
    FAnimFrames: Integer;
    FAnimEnabled: Boolean;
    FError: string;
    procedure Say(Kind: TMsgKind; const Msg: string);
    procedure BuildUI;
    function  LoadFile(const APath: string = ''): Boolean;
    procedure LoadProcess(Index: Integer);
    procedure LoadNodeData;
    procedure Layout;
    function  NodeIndex(const Id: string): Integer;
    function  NodeAt(const P: TPoint): Integer;
    procedure OnPaint(Sender: TObject);
    procedure OnBoxMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure OnBoxDblClick(Sender: TObject);
    procedure OnComboChange(Sender: TObject);
    procedure OnSaveDesc(Sender: TObject);
    procedure OnRefreshClick(Sender: TObject);
    procedure SelectNode(Index: Integer);
    procedure ShowCards;
    procedure HookMouse(Ctrl: TControl; CardIndex: Integer);
    procedure CardMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure CardMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure CardMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure OnCardDblClick(Sender: TObject);
    procedure ShowGhost(const P: TPoint);
    procedure HideGhost;
    procedure AnimateTo(const FromR, ToR: TRect; const C: TBoardCard);
    procedure PulseNode(Index: Integer);
    procedure MoveCardToNode(CardIdx, NodeIdx: Integer; const FromR: TRect);
    procedure DrawArrow(C: TCanvas; const Pts: TArray<TPoint>; const Text: string);
    function  Fmt(const Key: string; const Args: array of const): string;
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent; AParent: TWinControl; AData: TCrmData;
      ASay: TSayProc); reintroduce;
    destructor Destroy; override;
    procedure Refresh;

    // хуки самотеста
    function  ProcessCount: Integer;
    procedure SelectProcess(Index: Integer);
    function  NodeCount: Integer;
    function  NodeTitle(const Id: string): string;
    function  NodeCards(const Id: string): Integer;
    function  NodeOverdue(const Id: string): Integer;
    function  ClickNode(const Id: string): Boolean;    // тот же путь, что и мышь
    function  SelectedNodeId: string;
    function  CardsShown: Integer;
    function  DragCardToNode(CardId: Integer; const NodeId: string): Boolean;
    function  Description: string;
    procedure SetDescription(const Text: string);
    procedure SaveDescription;
    function  EdgeCount: Integer;
    { Загрузить описание процессов из другого файла (самотест работает с копией). }
    function  LoadFrom(const APath: string): Boolean;
    property AnimFrames: Integer read FAnimFrames;
    property AnimEnabled: Boolean read FAnimEnabled write FAnimEnabled;
    property LoadError: string read FError;
    property FileName: string read FFile;
    property OnOpenColumn: TOpenColumnEvent read FOnOpenColumn write FOnOpenColumn;
    property OnOpenRecord: TOpenBoardRecordEvent read FOnOpenRecord write FOnOpenRecord;
  end;

{ Читаемая запись JSON (System.JSON экранирует кириллицу как \uXXXX). }
function JsonPretty(V: TJSONValue; Indent: Integer = 0): string;

implementation

uses
  System.StrUtils, System.Math, System.IOUtils, uI18n;

const
  MARGIN = 20;
  LANE_H = 140;
  NODE_H = 92;
  LANE_TITLE_H = 22;
  CARD_W_MIN = 250;

{ ── JSON helpers ── }

function JsonEscape(const S: string): string;
var
  Ch: Char;
begin
  Result := '';
  for Ch in S do
    case Ch of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if Ord(Ch) < 32 then
        Result := Result + '\u' + IntToHex(Ord(Ch), 4)
      else
        Result := Result + Ch;
    end;
end;

function JsonPretty(V: TJSONValue; Indent: Integer): string;
var
  Pad, Inner: string;
  I: Integer;
  O: TJSONObject;
  A: TJSONArray;
  Simple: Boolean;
begin
  Pad := StringOfChar(' ', Indent);
  Inner := StringOfChar(' ', Indent + 2);
  if V is TJSONObject then
  begin
    O := TJSONObject(V);
    if O.Count = 0 then Exit('{}');
    // короткие объекты из строк (переводы) — в одну строку
    Simple := O.Count <= 3;
    for I := 0 to O.Count - 1 do
      if not (O.Pairs[I].JsonValue is TJSONString) then Simple := False;
    if Simple then
    begin
      Result := '{ ';
      for I := 0 to O.Count - 1 do
      begin
        if I > 0 then Result := Result + ', ';
        Result := Result + '"' + JsonEscape(O.Pairs[I].JsonString.Value) + '": ' +
          JsonPretty(O.Pairs[I].JsonValue, 0);
      end;
      Exit(Result + ' }');
    end;
    Result := '{' + sLineBreak;
    for I := 0 to O.Count - 1 do
    begin
      Result := Result + Inner + '"' + JsonEscape(O.Pairs[I].JsonString.Value) + '": ' +
        JsonPretty(O.Pairs[I].JsonValue, Indent + 2);
      if I < O.Count - 1 then Result := Result + ',';
      Result := Result + sLineBreak;
    end;
    Result := Result + Pad + '}';
  end
  else if V is TJSONArray then
  begin
    A := TJSONArray(V);
    if A.Count = 0 then Exit('[]');
    Result := '[' + sLineBreak;
    for I := 0 to A.Count - 1 do
    begin
      Result := Result + Inner + JsonPretty(A.Items[I], Indent + 2);
      if I < A.Count - 1 then Result := Result + ',';
      Result := Result + sLineBreak;
    end;
    Result := Result + Pad + ']';
  end
  else if V is TJSONString then
    Result := '"' + JsonEscape(TJSONString(V).Value) + '"'
  else if V is TJSONNumber then
    Result := TJSONNumber(V).ToString
  else if V is TJSONTrue then Result := 'true'
  else if V is TJSONFalse then Result := 'false'
  else Result := 'null';
end;

{ Текст по языку: значение — либо строка, либо объект с ключами ro/en/ru. }
function LText(O: TJSONObject; const Name: string): string;
var
  V: TJSONValue;
  L: TJSONObject;
begin
  Result := '';
  if O = nil then Exit;
  V := O.GetValue(Name);
  if V = nil then Exit;
  if V is TJSONObject then
  begin
    L := TJSONObject(V);
    if L.GetValue(T.Lang) <> nil then Result := L.GetValue(T.Lang).Value
    else if L.GetValue('ru') <> nil then Result := L.GetValue('ru').Value
    else if L.Count > 0 then Result := L.Pairs[0].JsonValue.Value;
  end
  else
    Result := V.Value;
end;

function LInt(O: TJSONObject; const Name: string; Default: Integer): Integer;
var
  V: TJSONValue;
begin
  Result := Default;
  V := O.GetValue(Name);
  if V is TJSONNumber then Result := TJSONNumber(V).AsInt;
end;

{ ── TProcessPage ── }

constructor TProcessPage.Create(AOwner: TComponent; AParent: TWinControl;
  AData: TCrmData; ASay: TSayProc);
begin
  inherited Create(AOwner);
  Parent := AParent;
  Align := alClient;
  Visible := False;
  FData := AData;
  FOnSay := ASay;
  FSelected := -1;
  FHoverNode := -1;
  FPulseNode := -1;
  FDragIdx := -1;
  FProcIdx := -1;
  FAnimEnabled := True;
  BevelOuter := bvNone;
  Color := ESPO_BODY;
  ParentBackground := False;
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;
  BuildUI;
  LoadFile;
end;

destructor TProcessPage.Destroy;
begin
  FRoot.Free;
  inherited;
end;

procedure TProcessPage.Say(Kind: TMsgKind; const Msg: string);
begin
  if Assigned(FOnSay) then FOnSay(Kind, Msg);
end;

function TProcessPage.Fmt(const Key: string; const Args: array of const): string;
begin
  Result := T.F(Key, Args);
end;

procedure TProcessPage.BuildUI;
var
  Hdr, Left, Right, Btn: TPanel;
  L: TLabel;
begin
  Hdr := TPanel.Create(Self);
  Hdr.Parent := Self;
  Hdr.Align := alTop;
  Hdr.Height := 72;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_BODY;
  Hdr.ParentBackground := False;

  L := MakeLabel(Self, Hdr, T.S('process.title'), 15, 10, 200, ESPO_TEXT, 16);
  L.Height := 30;

  FCombo := TComboBox.Create(Self);
  FCombo.Parent := Hdr;
  FCombo.Style := csDropDownList;
  FCombo.SetBounds(225, 14, 320, 28);
  FCombo.OnChange := OnComboChange;

  Btn := MakeButton(Self, Hdr, T.S('btn.refresh'), False, OnRefreshClick, 110);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 125, 10, 110, 36);

  MakeLabel(Self, Hdr, T.S('process.hint'), 15, 50, 900, ESPO_MUTED, 9);

  // низ: описание этапа (слева) и карточки этапа (справа)
  FBottom := TPanel.Create(Self);
  FBottom.Parent := Self;
  FBottom.Align := alBottom;
  FBottom.Height := 250;
  FBottom.BevelOuter := bvNone;
  FBottom.Color := ESPO_BODY;
  FBottom.ParentBackground := False;

  Right := MakePanelBox(Self, FBottom, '');
  Right.Align := alRight;
  Right.Width := 330;
  FCardsTitle := MakeLabel(Self, Right, T.S('process.cards'), 14, 8, 300, ESPO_SOFT, 11);
  FCardsTitle.Font.Style := [fsBold];
  FCardsBox := TScrollBox.Create(Self);
  FCardsBox.Parent := Right;
  FCardsBox.SetBounds(8, 34, Right.Width - 16, Right.Height - 42);
  FCardsBox.Anchors := [akLeft, akTop, akRight, akBottom];
  FCardsBox.BorderStyle := bsNone;
  FCardsBox.Color := ESPO_WHITE;
  FCardsBox.ParentBackground := False;
  FCardsBox.ParentColor := False;
  FCardsBox.VertScrollBar.Tracking := True;

  Left := MakePanelBox(Self, FBottom, '');
  Left.Align := alClient;
  FDescTitle := MakeLabel(Self, Left, T.S('process.desc'), 14, 8, 500, ESPO_SOFT, 11);
  FDescTitle.Font.Style := [fsBold];
  FOwnerLbl := MakeLabel(Self, Left, '', 14, 32, 400, ESPO_MUTED, 9);
  FSlaLbl := MakeLabel(Self, Left, '', 14, 50, 400, ESPO_MUTED, 9);
  FDesc := TMemo.Create(Self);
  FDesc.Parent := Left;
  FDesc.SetBounds(14, 72, Left.Width - 28, Left.Height - 72 - 50);
  FDesc.Anchors := [akLeft, akTop, akRight, akBottom];
  FDesc.BorderStyle := bsNone;
  FDesc.Color := ESPO_HEAD_BG;
  FDesc.Font.Name := 'Segoe UI';
  FDesc.Font.Size := 10;
  FDesc.ScrollBars := ssVertical;
  FDesc.WordWrap := True;
  Btn := MakeButton(Self, Left, T.S('process.save'), True, OnSaveDesc, 190);
  Btn.Anchors := [akLeft, akBottom];
  Btn.SetBounds(14, Left.Height - 44, 190, 36);

  // схема
  FBox := TPaintBox.Create(Self);
  FBox.Parent := Self;
  FBox.Align := alClient;
  FBox.OnPaint := OnPaint;
  FBox.OnMouseDown := OnBoxMouseDown;
  FBox.OnDblClick := OnBoxDblClick;
  FBox.Font.Name := 'Segoe UI';
end;

function TProcessPage.LoadFile(const APath: string): Boolean;
var
  Path, Text: string;
  I: Integer;
  P: TJSONObject;
begin
  Result := False;
  FError := '';
  Path := APath;
  if Path = '' then
    Path := TPath.Combine(ExtractFilePath(ParamStr(0)), 'processes.json');
  if (APath = '') and not TFile.Exists(Path) then
    Path := TPath.Combine(TPath.GetFullPath(TPath.Combine(
      ExtractFilePath(ParamStr(0)), '..\crm_delphi')), 'processes.json');
  FFile := Path;
  FreeAndNil(FRoot);
  FProcs := nil;
  FCombo.Items.Clear;
  if not TFile.Exists(Path) then
  begin
    FError := Fmt('process.missing', [Path]);
    Exit;
  end;
  try
    Text := TFile.ReadAllText(Path, TEncoding.UTF8);
    FRoot := TJSONObject.ParseJSONValue(Text) as TJSONObject;
    if FRoot = nil then
    begin
      FError := 'processes.json: JSON';
      Exit;
    end;
    FProcs := FRoot.GetValue('processes') as TJSONArray;
    if FProcs = nil then
    begin
      FError := 'processes.json: no "processes"';
      Exit;
    end;
    for I := 0 to FProcs.Count - 1 do
    begin
      P := FProcs.Items[I] as TJSONObject;
      FCombo.Items.Add(LText(P, 'title'));
    end;
    if FCombo.Items.Count > 0 then
    begin
      FCombo.ItemIndex := 0;
      LoadProcess(0);
    end;
    Result := True;
  except
    on E: Exception do
      FError := 'processes.json: ' + E.Message;
  end;
end;

procedure TProcessPage.LoadProcess(Index: Integer);
var
  P, N, Lane: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Node: TProcNode;
  Edge: TProcEdge;
  Kind, Board: string;
begin
  FNodes := nil; FEdges := nil; FLanes := nil;
  FSelected := -1; FHoverNode := -1;
  FProcIdx := Index;
  if (FProcs = nil) or (Index < 0) or (Index >= FProcs.Count) then Exit;
  P := FProcs.Items[Index] as TJSONObject;

  Arr := P.GetValue('lanes') as TJSONArray;
  if Arr <> nil then
    for I := 0 to Arr.Count - 1 do
    begin
      Lane := Arr.Items[I] as TJSONObject;
      FLanes := FLanes + [LText(Lane, 'title')];
    end;

  Arr := P.GetValue('nodes') as TJSONArray;
  if Arr <> nil then
    for I := 0 to Arr.Count - 1 do
    begin
      N := Arr.Items[I] as TJSONObject;
      Node := Default(TProcNode);
      Node.Json := N;
      Node.Id := LText(N, 'id');
      Kind := LText(N, 'kind');
      if Kind = 'start' then Node.Kind := nkStart
      else if Kind = 'gate' then Node.Kind := nkGate
      else if Kind = 'end' then Node.Kind := nkEnd
      else Node.Kind := nkStep;
      Board := LText(N, 'board');
      Node.HasBoard := Board <> '';
      if Board = 'deals' then Node.Board := bkDeals
      else if Board = 'tasks' then Node.Board := bkTasks
      else if Board = 'projects' then Node.Board := bkProjects
      else if Board = 'project_tasks' then Node.Board := bkProjectTasks
      else Node.Board := bkOrders;
      Node.Col := LInt(N, 'col', 0);
      Node.X := LInt(N, 'x', I);
      Node.Y := LInt(N, 'y', 0);
      Node.Title := LText(N, 'title');
      Node.Owner := LText(N, 'owner');
      Node.Desc := LText(N, 'desc');
      Node.SlaDays := LInt(N, 'sla_days', -1);
      FNodes := FNodes + [Node];
    end;

  Arr := P.GetValue('edges') as TJSONArray;
  if Arr <> nil then
    for I := 0 to Arr.Count - 1 do
    begin
      N := Arr.Items[I] as TJSONObject;
      Edge.FromIdx := NodeIndex(LText(N, 'from'));
      Edge.ToIdx := NodeIndex(LText(N, 'to'));
      Edge.Label_ := LText(N, 'label');
      if (Edge.FromIdx >= 0) and (Edge.ToIdx >= 0) then
        FEdges := FEdges + [Edge];
    end;

  LoadNodeData;
  Layout;
  ShowCards;
  FBox.Invalidate;
end;

{ Карточки каждого узла — те же, что в колонке канбана. }
procedure TProcessPage.LoadNodeData;
var
  I: Integer;
begin
  for I := 0 to High(FNodes) do
  begin
    FNodes[I].Cards := nil;
    FNodes[I].Count := 0; FNodes[I].Overdue := 0; FNodes[I].Sum := 0;
    if FNodes[I].HasBoard then
    begin
      FNodes[I].Cards := LoadBoardCards(FData, FNodes[I].Board, FNodes[I].Col);
      FNodes[I].Count := Length(FNodes[I].Cards);
      FNodes[I].Overdue := BoardColumnOverdue(FNodes[I].Cards);
      FNodes[I].Sum := BoardColumnSum(FNodes[I].Cards);
    end;
  end;
end;

procedure TProcessPage.Layout;
var
  MaxX, MaxY, I, SlotW, NodeW, GateW: Integer;
begin
  MaxX := 0; MaxY := 0;
  for I := 0 to High(FNodes) do
  begin
    MaxX := Max(MaxX, FNodes[I].X);
    MaxY := Max(MaxY, FNodes[I].Y);
  end;
  SlotW := Max(96, (FBox.Width - 2 * MARGIN) div (MaxX + 1));
  NodeW := SlotW - 18;
  GateW := Min(NodeW, 104);
  for I := 0 to High(FNodes) do
    with FNodes[I] do
    begin
      if Kind = nkGate then
        R := Rect(MARGIN + X * SlotW + (SlotW - GateW) div 2,
                  MARGIN + LANE_TITLE_H + Y * LANE_H + (NODE_H - GateW) div 2 + 4,
                  MARGIN + X * SlotW + (SlotW - GateW) div 2 + GateW,
                  MARGIN + LANE_TITLE_H + Y * LANE_H + (NODE_H - GateW) div 2 + 4 + GateW)
      else
        R := Rect(MARGIN + X * SlotW, MARGIN + LANE_TITLE_H + Y * LANE_H,
                  MARGIN + X * SlotW + NodeW, MARGIN + LANE_TITLE_H + Y * LANE_H + NODE_H);
    end;
end;

function TProcessPage.NodeIndex(const Id: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FNodes) do
    if FNodes[I].Id = Id then Exit(I);
end;

function TProcessPage.NodeAt(const P: TPoint): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FNodes) do
    if FNodes[I].R.Contains(P) then Exit(I);
end;

procedure TProcessPage.DrawArrow(C: TCanvas; const Pts: TArray<TPoint>; const Text: string);
var
  I, N: Integer;
  A, B: TPoint;
  Dx, Dy: Integer;
  Tri: array[0..2] of TPoint;
  TW, TH, MX, MY, Best: Integer;
begin
  N := Length(Pts);
  if N < 2 then Exit;
  C.Pen.Color := ESPO_GRAY;
  C.Pen.Width := 2;
  C.MoveTo(Pts[0].X, Pts[0].Y);
  for I := 1 to N - 1 do
    C.LineTo(Pts[I].X, Pts[I].Y);
  // стрелка на последнем отрезке
  A := Pts[N - 2]; B := Pts[N - 1];
  Dx := Sign(B.X - A.X); Dy := Sign(B.Y - A.Y);
  Tri[0] := B;
  if Dx <> 0 then
  begin
    Tri[1] := Point(B.X - Dx * 9, B.Y - 5);
    Tri[2] := Point(B.X - Dx * 9, B.Y + 5);
  end
  else
  begin
    Tri[1] := Point(B.X - 5, B.Y - Dy * 9);
    Tri[2] := Point(B.X + 5, B.Y - Dy * 9);
  end;
  C.Brush.Color := ESPO_GRAY;
  C.Pen.Width := 1;
  C.Polygon(Tri);
  if Text <> '' then
  begin
    // подпись у середины самого длинного отрезка
    MX := (Pts[0].X + Pts[1].X) div 2; MY := (Pts[0].Y + Pts[1].Y) div 2;
    Best := Abs(Pts[1].X - Pts[0].X) + Abs(Pts[1].Y - Pts[0].Y);
    for I := 2 to N - 1 do
      if Abs(Pts[I].X - Pts[I - 1].X) + Abs(Pts[I].Y - Pts[I - 1].Y) > Best then
      begin
        Best := Abs(Pts[I].X - Pts[I - 1].X) + Abs(Pts[I].Y - Pts[I - 1].Y);
        MX := (Pts[I].X + Pts[I - 1].X) div 2; MY := (Pts[I].Y + Pts[I - 1].Y) div 2;
      end;
    C.Font.Size := 7;
    C.Font.Style := [];
    C.Font.Color := ESPO_GRAY;
    TW := C.TextWidth(Text); TH := C.TextHeight(Text);
    C.Brush.Color := ESPO_BODY;
    C.TextOut(MX - TW div 2, MY - TH - 2, Text);
  end;
end;

procedure TProcessPage.OnPaint(Sender: TObject);
var
  C: TCanvas;
  I, Y, TH: Integer;
  N: TProcNode;
  Pts: TArray<TPoint>;
  E: TProcEdge;
  A, B: TRect;
  Accent: TColor;
  Fill: TColor;
  Txt: string;
  Rc, TitleR: TRect;
  Dia: array[0..3] of TPoint;
  MidY: Integer;

  procedure TextIn(const S: string; X, Y, W: Integer; Size: Integer; Bold: Boolean; Color: TColor);
  var
    R: TRect;
  begin
    C.Font.Size := Size;
    if Bold then C.Font.Style := [fsBold] else C.Font.Style := [];
    C.Font.Color := Color;
    R := Rect(X, Y, X + W, Y + Size * 2 + 6);
    C.Brush.Style := bsClear;
    DrawText(C.Handle, PChar(S), Length(S), R, DT_LEFT or DT_END_ELLIPSIS or DT_SINGLELINE);
  end;

begin
  C := FBox.Canvas;
  C.Brush.Style := bsSolid;
  C.Brush.Color := ESPO_BODY;
  C.FillRect(FBox.ClientRect);
  if FError <> '' then
  begin
    TextIn(FError, MARGIN, MARGIN, FBox.Width - 2 * MARGIN, 10, False, ST_DANGER_FG);
    Exit;
  end;

  // дорожки
  for I := 0 to High(FLanes) do
  begin
    Y := MARGIN + I * LANE_H;
    C.Brush.Color := IfThen(Odd(I), ESPO_BODY, ESPO_WHITE);
    C.Pen.Color := ESPO_BORDER;
    C.Pen.Width := 1;
    C.Rectangle(MARGIN - 8, Y - 6, FBox.Width - MARGIN + 8, Y + LANE_H - 6);
    TextIn(FLanes[I], MARGIN, Y, 500, 8, True, ESPO_MUTED);
  end;

  // связи
  for E in FEdges do
  begin
    A := FNodes[E.FromIdx].R; B := FNodes[E.ToIdx].R;
    if FNodes[E.FromIdx].Y = FNodes[E.ToIdx].Y then
    begin
      if B.Left > A.Right then
        Pts := [Point(A.Right, A.CenterPoint.Y), Point(B.Left, B.CenterPoint.Y)]
      else
      begin
        // возврат назад — дугой под узлами
        MidY := Max(A.Bottom, B.Bottom) + 14;
        Pts := [Point(A.CenterPoint.X, A.Bottom), Point(A.CenterPoint.X, MidY),
                Point(B.CenterPoint.X, MidY), Point(B.CenterPoint.X, B.Bottom)];
      end;
    end
    else
    begin
      // на другую дорожку: вниз, вдоль зазора, вниз в узел
      MidY := MARGIN + (FNodes[E.FromIdx].Y + 1) * LANE_H - 12 + IfThen(FNodes[E.ToIdx].Y < FNodes[E.FromIdx].Y, -LANE_H + 8, 0);
      if FNodes[E.ToIdx].Y > FNodes[E.FromIdx].Y then
        Pts := [Point(A.CenterPoint.X, A.Bottom), Point(A.CenterPoint.X, MidY),
                Point(B.CenterPoint.X, MidY), Point(B.CenterPoint.X, B.Top)]
      else
        Pts := [Point(A.CenterPoint.X, A.Top), Point(A.CenterPoint.X, MidY),
                Point(B.CenterPoint.X, MidY), Point(B.CenterPoint.X, B.Bottom)];
    end;
    DrawArrow(C, Pts, E.Label_);
  end;

  // узлы
  for I := 0 to High(FNodes) do
  begin
    N := FNodes[I];
    Rc := N.R;
    if N.HasBoard then Accent := BoardColumnColor(N.Board, N.Col) else Accent := ESPO_GRAY;
    if N.Kind = nkGate then Accent := $002E9BE0;
    Fill := ESPO_WHITE;
    if I = FPulseNode then Fill := ST_SUCCESS_BG
    else if I = FSelected then Fill := ST_PRIMARY_BG
    else if I = FHoverNode then Fill := ESPO_HEAD_BG
    else if N.Overdue > 0 then Fill := $00F0F0FA;

    // тень
    C.Brush.Color := ESPO_BORDER;
    C.Pen.Color := ESPO_BORDER;
    C.Pen.Width := 1;
    case N.Kind of
      nkGate:
        begin
          Dia[0] := Point(Rc.CenterPoint.X + 3, Rc.Top + 3);
          Dia[1] := Point(Rc.Right + 3, Rc.CenterPoint.Y + 3);
          Dia[2] := Point(Rc.CenterPoint.X + 3, Rc.Bottom + 3);
          Dia[3] := Point(Rc.Left + 3, Rc.CenterPoint.Y + 3);
          C.Polygon(Dia);
        end;
      nkStart: C.RoundRect(Rc.Left + 3, Rc.Top + 3, Rc.Right + 3, Rc.Bottom + 3, NODE_H, NODE_H);
    else
      C.RoundRect(Rc.Left + 3, Rc.Top + 3, Rc.Right + 3, Rc.Bottom + 3, 10, 10);
    end;

    C.Brush.Color := Fill;
    C.Pen.Color := IfThen(I = FSelected, ESPO_PRIMARY, Accent);
    C.Pen.Width := IfThen(I = FSelected, 3, 2);
    case N.Kind of
      nkGate:
        begin
          Dia[0] := Point(Rc.CenterPoint.X, Rc.Top);
          Dia[1] := Point(Rc.Right, Rc.CenterPoint.Y);
          Dia[2] := Point(Rc.CenterPoint.X, Rc.Bottom);
          Dia[3] := Point(Rc.Left, Rc.CenterPoint.Y);
          C.Polygon(Dia);
          C.Font.Size := 7; C.Font.Style := [fsBold]; C.Font.Color := ESPO_TEXT;
          C.Brush.Style := bsClear;
          Rc.Inflate(-14, -14);
          DrawText(C.Handle, PChar(N.Title), Length(N.Title), Rc,
            DT_CENTER or DT_VCENTER or DT_WORDBREAK or DT_NOPREFIX);
          C.Brush.Style := bsSolid;
          Continue;
        end;
      nkStart: C.RoundRect(Rc.Left, Rc.Top, Rc.Right, Rc.Bottom, NODE_H, NODE_H);
      nkEnd:
        begin
          C.RoundRect(Rc.Left, Rc.Top, Rc.Right, Rc.Bottom, 10, 10);
          C.Brush.Style := bsClear;
          C.RoundRect(Rc.Left + 4, Rc.Top + 4, Rc.Right - 4, Rc.Bottom - 4, 8, 8);
          C.Brush.Style := bsSolid;
        end;
    else
      C.RoundRect(Rc.Left, Rc.Top, Rc.Right, Rc.Bottom, 10, 10);
      // цветная кромка — как у колонки канбана
      C.Brush.Color := Accent;
      C.Pen.Color := Accent;
      C.Rectangle(Rc.Left + 6, Rc.Top + 1, Rc.Right - 6, Rc.Top + 6);
    end;

    // текст узла
    if N.Kind = nkStart then TH := 16 else TH := 10;
    C.Font.Size := 9; C.Font.Style := [fsBold]; C.Font.Color := ESPO_TEXT;
    C.Brush.Style := bsClear;
    TitleR := Rect(Rc.Left + TH, Rc.Top + 9, Rc.Right - TH, Rc.Top + 41);
    DrawText(C.Handle, PChar(N.Title), Length(N.Title), TitleR,
      DT_LEFT or DT_WORDBREAK or DT_END_ELLIPSIS or DT_NOPREFIX or DT_EDITCONTROL);
    C.Brush.Style := bsSolid;
    if N.HasBoard then
    begin
      if N.Sum > 0 then
        Txt := Format('%d  ·  %s MDL', [N.Count, FormatFloat('#,##0', N.Sum)])
      else
        Txt := Fmt('process.count', [N.Count]);
      TextIn(Txt, Rc.Left + TH, Rc.Top + 44, Rc.Width - 2 * TH, 9, False, Accent);
      if N.Overdue > 0 then
        TextIn(Fmt('kanban.col_late', [N.Overdue]), Rc.Left + TH, Rc.Top + 61, Rc.Width - 2 * TH, 8, True, ST_DANGER_FG)
      else if (N.Count > 0) and (N.Kind <> nkEnd) then
        TextIn(T.S('workspace.on_time'), Rc.Left + TH, Rc.Top + 61, Rc.Width - 2 * TH, 8, False, ST_SUCCESS_FG);
    end;
    if N.Owner <> '' then
      TextIn('☺ ' + N.Owner, Rc.Left + TH, Rc.Bottom - 18, Rc.Width - 2 * TH, 7, False, ESPO_MUTED);
  end;
end;

procedure TProcessPage.Resize;
begin
  inherited;
  if FBox <> nil then
  begin
    Layout;
    FBox.Invalidate;
  end;
end;

procedure TProcessPage.OnBoxMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  SelectNode(NodeAt(Point(X, Y)));
end;

procedure TProcessPage.OnBoxDblClick(Sender: TObject);
var
  I: Integer;
begin
  I := NodeAt(FBox.ScreenToClient(Mouse.CursorPos));
  if (I >= 0) and FNodes[I].HasBoard and Assigned(FOnOpenColumn) then
    FOnOpenColumn(FNodes[I].Board, FNodes[I].Col);
end;

procedure TProcessPage.SelectNode(Index: Integer);
begin
  FSelected := Index;
  FBox.Invalidate;
  if (Index < 0) or (Index > High(FNodes)) then
  begin
    FDescTitle.Caption := T.S('process.desc');
    FOwnerLbl.Caption := ''; FSlaLbl.Caption := '';
    FDesc.Text := '';
    ShowCards;
    Exit;
  end;
  with FNodes[Index] do
  begin
    FDescTitle.Caption := T.S('process.desc') + ': ' + Title;
    FOwnerLbl.Caption := IfThen(Owner <> '', Fmt('process.owner', [Owner]), '');
    if SlaDays >= 0 then FSlaLbl.Caption := Fmt('process.sla', [SlaDays]) else FSlaLbl.Caption := '';
    FDesc.Text := Desc;
    ShowCards;
    if HasBoard then
      Say(mkInfo, Fmt('process.node_info', [Title, Count, Overdue]))
    else
      Say(mkInfo, Title);
  end;
end;

procedure TProcessPage.ShowCards;
var
  I, Y, Idx, W: Integer;
  P: TPanel;
begin
  HideGhost;
  for I := 0 to High(FCardPanels) do FCardPanels[I].Free;
  FCardPanels := nil;
  FCards := nil;
  if (FSelected < 0) or not FNodes[FSelected].HasBoard then
  begin
    FCardsTitle.Caption := T.S('process.cards');
    Exit;
  end;
  FCards := FNodes[FSelected].Cards;
  FCardsTitle.Caption := Format('%s: %s (%d)', [T.S('process.cards'), FNodes[FSelected].Title, Length(FCards)]);
  W := Max(CARD_W_MIN, FCardsBox.Width - 26);
  Y := 4;
  for I := 0 to High(FCards) do
  begin
    Idx := I;
    P := MakeBoardCard(Self, FCardsBox, FCards[I], 4, Y, W,
      procedure(Ctrl: TControl) begin HookMouse(Ctrl, Idx); end);
    FCardPanels := FCardPanels + [P];
    Inc(Y, CARD_H + 6);
  end;
end;

procedure TProcessPage.HookMouse(Ctrl: TControl; CardIndex: Integer);
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

procedure TProcessPage.CardMouseDown(Sender: TObject; Button: TMouseButton;
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
end;

procedure TProcessPage.CardMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  P: TPoint;
  N: Integer;
begin
  if (FDragIdx < 0) or not (ssLeft in Shift) then Exit;
  P := (Sender as TControl).ClientToScreen(Point(X, Y));
  if not FDragActive and (Abs(P.X - FDragOrigin.X) + Abs(P.Y - FDragOrigin.Y) < 8) then
    Exit;
  FDragActive := True;
  ShowGhost(P);
  N := NodeAt(FBox.ScreenToClient(P));
  if (N >= 0) and not (FNodes[N].HasBoard and (FNodes[N].Board = FNodes[FSelected].Board)) then
    N := -1;
  if N <> FHoverNode then
  begin
    FHoverNode := N;
    FBox.Invalidate;
  end;
end;

procedure TProcessPage.CardMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  N: Integer;
  FromR: TRect;
begin
  if FDragActive then
  begin
    N := NodeAt(FBox.ScreenToClient((Sender as TControl).ClientToScreen(Point(X, Y))));
    FromR := TRect.Empty;
    if FGhost <> nil then
      FromR := Rect(FGhost.Left, FGhost.Top, FGhost.Left + FGhost.Width, FGhost.Top + FGhost.Height);
    HideGhost;
    FHoverNode := -1;
    if (N >= 0) and (FDragIdx >= 0) and (FDragIdx <= High(FCards)) and FNodes[N].HasBoard and
       (FNodes[N].Board = FNodes[FSelected].Board) and (FNodes[N].Col <> FCards[FDragIdx].Col) then
      MoveCardToNode(FDragIdx, N, FromR)
    else
    begin
      FBox.Invalidate;
      Say(mkInfo, T.S('kanban.cancelled'));
    end;
  end;
  FDragActive := False;
  FDragIdx := -1;
end;

procedure TProcessPage.OnCardDblClick(Sender: TObject);
var
  Idx: Integer;
begin
  Idx := (Sender as TComponent).Tag;
  if (Idx < 0) or (Idx > High(FCards)) or (FSelected < 0) then Exit;
  if Assigned(FOnOpenRecord) then
    FOnOpenRecord(FNodes[FSelected].Board, FCards[Idx].Id);
end;

procedure TProcessPage.ShowGhost(const P: TPoint);
var
  L: TPoint;
begin
  if (FDragIdx < 0) or (FDragIdx > High(FCards)) then Exit;
  if FGhost = nil then
  begin
    FGhost := MakeBoardCard(Self, Self, FCards[FDragIdx], 0, 0, CARD_W_MIN, nil);
    FGhost.Color := ST_PRIMARY_BG;
    FGhost.BevelOuter := bvRaised;
    FCardPanels[FDragIdx].Color := ESPO_BODY;
  end;
  L := ScreenToClient(P);
  FGhost.SetBounds(L.X - Min(FDragOffset.X, CARD_W_MIN - 10), L.Y - FDragOffset.Y, FGhost.Width, FGhost.Height);
  FGhost.Visible := True;
  FGhost.BringToFront;
end;

procedure TProcessPage.HideGhost;
begin
  if FGhost <> nil then
  begin
    FGhost.Free;
    FGhost := nil;
  end;
  if (FDragIdx >= 0) and (FDragIdx <= High(FCardPanels)) then
    FCardPanels[FDragIdx].Color := CardBaseColor(FCards[FDragIdx]);
end;

procedure TProcessPage.AnimateTo(const FromR, ToR: TRect; const C: TBoardCard);
const
  FRAMES = 14;
var
  Fly: TPanel;
  I: Integer;
  K: Double;
  W, H: Integer;
begin
  if not FAnimEnabled or FromR.IsEmpty or ToR.IsEmpty then Exit;
  Fly := MakeBoardCard(Self, Self, C, FromR.Left, FromR.Top, FromR.Width, nil);
  try
    Fly.Color := ST_PRIMARY_BG;
    Fly.BringToFront;
    for I := 1 to FRAMES do
    begin
      K := I / FRAMES;
      K := 1 - Sqr(1 - K);
      // карточка летит к узлу и уменьшается до его размера
      W := Round(FromR.Width + (ToR.Width - FromR.Width) * K);
      H := Round(FromR.Height + (ToR.Height - FromR.Height) * K);
      Fly.SetBounds(Round(FromR.Left + (ToR.Left - FromR.Left) * K),
                    Round(FromR.Top + (ToR.Top - FromR.Top) * K), W, H);
      Fly.Update;
      Application.ProcessMessages;
      Sleep(12);
      Inc(FAnimFrames);
    end;
  finally
    Fly.Free;
  end;
end;

procedure TProcessPage.PulseNode(Index: Integer);
var
  I: Integer;
begin
  if not FAnimEnabled then Exit;
  for I := 1 to 3 do
  begin
    FPulseNode := IfThen(Odd(I), Index, -1);
    FBox.Repaint;
    Application.ProcessMessages;
    Sleep(50);
    Inc(FAnimFrames);
  end;
  FPulseNode := -1;
  FBox.Invalidate;
end;

{ Смена этапа через ту же точку, что и канбан. }
procedure TProcessPage.MoveCardToNode(CardIdx, NodeIdx: Integer; const FromR: TRect);
var
  C: TBoardCard;
  ToR: TRect;
  TL: TPoint;
  Keep: Integer;
begin
  C := FCards[CardIdx];
  if not MoveBoardCard(FData, FNodes[NodeIdx].Board, C.Id, FNodes[NodeIdx].Col) then Exit;
  TL := ScreenToClient(FBox.ClientToScreen(FNodes[NodeIdx].R.TopLeft));
  ToR := Rect(TL.X, TL.Y, TL.X + FNodes[NodeIdx].R.Width, TL.Y + FNodes[NodeIdx].R.Height);
  AnimateTo(FromR, ToR, C);
  Keep := FSelected;
  LoadNodeData;
  FSelected := Keep;
  ShowCards;
  PulseNode(NodeIdx);
  Say(mkOk, Fmt('kanban.moved', [C.Title, FNodes[NodeIdx].Title]));
end;

procedure TProcessPage.OnComboChange(Sender: TObject);
begin
  LoadProcess(FCombo.ItemIndex);
  SelectNode(-1);
end;

procedure TProcessPage.OnSaveDesc(Sender: TObject);
begin
  SaveDescription;
end;

procedure TProcessPage.OnRefreshClick(Sender: TObject);
begin
  Refresh;
  Say(mkInfo, T.S('kanban.refreshed'));
end;

procedure TProcessPage.Refresh;
var
  Keep: Integer;
begin
  if FRoot = nil then
  begin
    LoadFile;
    Exit;
  end;
  Keep := FSelected;
  LoadNodeData;
  Layout;
  FSelected := Keep;
  ShowCards;
  FBox.Invalidate;
end;

{ ── хуки самотеста ── }

function TProcessPage.LoadFrom(const APath: string): Boolean;
begin
  Result := LoadFile(APath);
  SelectNode(-1);
  FBox.Invalidate;
end;

function TProcessPage.ProcessCount: Integer;
begin
  Result := FCombo.Items.Count;
end;

procedure TProcessPage.SelectProcess(Index: Integer);
begin
  if (Index < 0) or (Index >= FCombo.Items.Count) then Exit;
  FCombo.ItemIndex := Index;
  OnComboChange(FCombo);
end;

function TProcessPage.NodeCount: Integer;
begin
  Result := Length(FNodes);
end;

function TProcessPage.EdgeCount: Integer;
begin
  Result := Length(FEdges);
end;

function TProcessPage.NodeTitle(const Id: string): string;
var
  I: Integer;
begin
  I := NodeIndex(Id);
  if I >= 0 then Result := FNodes[I].Title else Result := '';
end;

function TProcessPage.NodeCards(const Id: string): Integer;
var
  I: Integer;
begin
  I := NodeIndex(Id);
  if I >= 0 then Result := FNodes[I].Count else Result := -1;
end;

function TProcessPage.NodeOverdue(const Id: string): Integer;
var
  I: Integer;
begin
  I := NodeIndex(Id);
  if I >= 0 then Result := FNodes[I].Overdue else Result := -1;
end;

function TProcessPage.ClickNode(const Id: string): Boolean;
var
  I: Integer;
  P: TPoint;
begin
  I := NodeIndex(Id);
  Result := I >= 0;
  if not Result then Exit;
  P := FNodes[I].R.CenterPoint;
  OnBoxMouseDown(FBox, mbLeft, [ssLeft], P.X, P.Y);
end;

function TProcessPage.SelectedNodeId: string;
begin
  if (FSelected >= 0) and (FSelected <= High(FNodes)) then
    Result := FNodes[FSelected].Id
  else
    Result := '';
end;

function TProcessPage.CardsShown: Integer;
begin
  Result := Length(FCardPanels);
end;

function TProcessPage.DragCardToNode(CardId: Integer; const NodeId: string): Boolean;
var
  I, N: Integer;
  Src: TPanel;
  P: TPoint;
begin
  Result := False;
  N := NodeIndex(NodeId);
  if N < 0 then Exit;
  for I := 0 to High(FCards) do
    if FCards[I].Id = CardId then
    begin
      Src := FCardPanels[I];
      // координаты относительно карточки — как у реальной мыши
      CardMouseDown(Src, mbLeft, [ssLeft], Src.Width div 2, Src.Height div 2);
      P := Src.ScreenToClient(FBox.ClientToScreen(FNodes[N].R.CenterPoint));
      CardMouseMove(Src, [ssLeft], P.X, P.Y);
      Application.ProcessMessages;
      CardMouseUp(Src, mbLeft, [], P.X, P.Y);
      Exit(True);
    end;
end;

function TProcessPage.Description: string;
begin
  Result := FDesc.Text;
end;

procedure TProcessPage.SetDescription(const Text: string);
begin
  FDesc.Text := Text;
end;

procedure TProcessPage.SaveDescription;
var
  N, D: TJSONObject;
begin
  if (FSelected < 0) or (FSelected > High(FNodes)) or (FRoot = nil) then
  begin
    Say(mkWarn, T.S('process.select_node'));
    Exit;
  end;
  N := FNodes[FSelected].Json;
  D := N.GetValue('desc') as TJSONObject;
  if D = nil then
  begin
    N.RemovePair('desc').Free;
    D := TJSONObject.Create;
    N.AddPair('desc', D);
  end;
  D.RemovePair(T.Lang).Free;
  D.AddPair(T.Lang, TJSONString.Create(Trim(FDesc.Text)));
  FNodes[FSelected].Desc := Trim(FDesc.Text);
  try
    TFile.WriteAllText(FFile, JsonPretty(FRoot) + sLineBreak, TEncoding.UTF8);
    Say(mkOk, Fmt('process.saved', [FNodes[FSelected].Title, ExtractFileName(FFile)]));
  except
    on E: Exception do
      Say(mkErr, E.Message);
  end;
end;

end.
