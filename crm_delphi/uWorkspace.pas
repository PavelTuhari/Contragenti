unit uWorkspace;
{
  Рабочий стол — главный экран, где видно, что происходит в фирме:
  большие плитки этапов «от контракта до денег». Каждая плитка — счётчик,
  сумма и маркер просрочки; нажатие открывает соответствующий раздел с уже
  выставленным фильтром.

  Здесь же полоса связи с ERP una.md (uErpApi): проверка связи и отправка
  данных в справочник.

  Второй класс — страница отчётов: предпросмотр и выгрузка в Excel и PDF.
}

interface

uses
  Winapi.Windows, Winapi.ShellAPI, System.SysUtils, System.Classes,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  uCrmData, uEspoTheme, uErpApi, uReports, uReportTable;

type
  TStageClickEvent = procedure(Stage: TStage) of object;

  TTile = record
    Stage: TStage;
    Panel: TPanel;
    LblValue, LblTitle, LblHint, LblSum, LblOver: TLabel;
  end;

  TWorkspacePage = class(TPanel)
  private
    FData: TCrmData;
    FErp: TErpClient;
    FOnSay: TSayProc;
    FOnStageClick: TStageClickEvent;
    FTiles: array[TStage] of TTile;
    FErpLabel: TLabel;
    FErpPanel: TPanel;
    FSummary: TLabel;
    FLastOrders, FNextTasks: TLabel;
    procedure Say(Kind: TMsgKind; const Msg: string);
    function MakeTile(Stage: TStage; AParent: TWinControl; X, Y, W, H: Integer): TTile;
    procedure BuildUI;
    function ListLastOrders: string;
    function ListNextTasks: string;
    procedure OnTileClick(Sender: TObject);
    procedure OnRefreshClick(Sender: TObject);
    procedure OnErpCheckClick(Sender: TObject);
    procedure OnErpSendClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent; AParent: TWinControl; AData: TCrmData;
      AErp: TErpClient; ASay: TSayProc); reintroduce;
    procedure Refresh;

    // хуки самотеста
    procedure ClickTile(Stage: TStage);
    function TileValue(Stage: TStage): string;
    function TileOverdue(Stage: TStage): string;
    function TileVisible(Stage: TStage): Boolean;
    function ErpText: string;
    procedure ErpCheck;
    procedure ErpSend(const DbPath: string);

    property OnStageClick: TStageClickEvent read FOnStageClick write FOnStageClick;
  end;

  TReportsPage = class(TPanel)
  private
    FData: TCrmData;
    FOnSay: TSayProc;
    FList: TListView;
    FPreview: TListView;
    FPreviewTitle: TLabel;
    FPreviewHead: TPanel;   // свои заголовки колонок: штатные не попадают в снимок
    FCurrent: TReportKind;
    FExportDir: string;
    procedure Say(Kind: TMsgKind; const Msg: string);
    procedure BuildUI;
    procedure OnListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure OnXlsxClick(Sender: TObject);
    procedure OnPdfClick(Sender: TObject);
    procedure OnOpenDirClick(Sender: TObject);
    procedure ShowPreview(Kind: TReportKind);
  public
    constructor Create(AOwner: TComponent; AParent: TWinControl; AData: TCrmData;
      ASay: TSayProc; const AExportDir: string); reintroduce;
    procedure Refresh;

    // хуки самотеста
    procedure SelectReport(Kind: TReportKind);
    function Export(Fmt: TExportFormat): string;
    function PreviewRows: Integer;
    function PreviewCols: Integer;
    property ExportDir: string read FExportDir;
    property Current: TReportKind read FCurrent;
  end;

implementation

uses
  System.StrUtils, System.IOUtils, System.Math, FireDAC.Comp.Client;

const
  // пять плиток ряда должны помещаться при ширине окна 1280 (232 — навигация)
  TILE_W = 190;
  TILE_H = 124;
  TILE_GAP = 10;

{ ── TWorkspacePage ── }

constructor TWorkspacePage.Create(AOwner: TComponent; AParent: TWinControl;
  AData: TCrmData; AErp: TErpClient; ASay: TSayProc);
begin
  inherited Create(AOwner);
  Parent := AParent;
  Align := alClient;
  Visible := False;
  FData := AData;
  FErp := AErp;
  FOnSay := ASay;
  BevelOuter := bvNone;
  Color := ESPO_BODY;
  ParentBackground := False;
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;
  BuildUI;
end;

procedure TWorkspacePage.Say(Kind: TMsgKind; const Msg: string);
begin
  if Assigned(FOnSay) then FOnSay(Kind, Msg);
end;

function TWorkspacePage.MakeTile(Stage: TStage; AParent: TWinControl;
  X, Y, W, H: Integer): TTile;
var
  P: TPanel;
begin
  P := TPanel.Create(Self);
  P.Parent := AParent;
  P.SetBounds(X, Y, W, H);
  P.BevelOuter := bvNone;
  P.BevelKind := bkFlat;
  P.Color := ESPO_WHITE;
  P.ParentBackground := False;
  P.Cursor := crHandPoint;
  P.Tag := Ord(Stage);
  P.OnClick := OnTileClick;

  Result.Stage := Stage;
  Result.Panel := P;
  Result.LblTitle := MakeLabel(Self, P, '', 14, 10, W - 28, ESPO_SOFT, 10);
  Result.LblTitle.Font.Style := [fsBold];
  Result.LblTitle.Tag := Ord(Stage);
  Result.LblTitle.OnClick := OnTileClick;
  Result.LblTitle.Cursor := crHandPoint;

  Result.LblValue := MakeLabel(Self, P, '0', 14, 30, 90, ESPO_PRIMARY, 24);
  Result.LblValue.Height := 34;
  Result.LblValue.Font.Style := [fsBold];
  Result.LblValue.Tag := Ord(Stage);
  Result.LblValue.OnClick := OnTileClick;
  Result.LblValue.Cursor := crHandPoint;

  Result.LblSum := MakeLabel(Self, P, '', 14, 66, W - 28, ESPO_TEXT, 10);
  Result.LblOver := MakeLabel(Self, P, '', 14, 86, W - 28, ST_DANGER_FG, 9);
  Result.LblOver.Font.Style := [fsBold];
  Result.LblHint := MakeLabel(Self, P, '', 14, 104, W - 28, ESPO_MUTED, 8);
end;

procedure TWorkspacePage.BuildUI;
var
  Hdr, Line: TPanel;
  L: TLabel;
  Btn: TPanel;
  S: TStage;
  X, Y: Integer;
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
  L.SetBounds(15, 14, 400, 30);
  L.Caption := 'Рабочий стол';
  L.Font.Size := 16;

  Btn := MakeButton(Self, Hdr, 'Обновить', False, OnRefreshClick, 110);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 125, 12, 110, 36);

  FSummary := MakeLabel(Self, Hdr, '', 210, 22, 820, ESPO_MUTED, 10);

  // полоса ERP
  FErpPanel := TPanel.Create(Self);
  FErpPanel.Parent := Self;
  FErpPanel.Align := alTop;
  FErpPanel.Top := 60;
  FErpPanel.Height := 52;
  FErpPanel.BevelOuter := bvNone;
  FErpPanel.Color := ST_PRIMARY_BG;
  FErpPanel.ParentBackground := False;

  FErpLabel := MakeLabel(Self, FErpPanel, 'ERP una.md: связь не проверена',
    15, 17, 700, ST_PRIMARY_FG, 10);
  Btn := MakeButton(Self, FErpPanel, 'Проверить связь', False, OnErpCheckClick, 150);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(FErpPanel.Width - 320, 8, 150, 36);
  Btn := MakeButton(Self, FErpPanel, 'Отправить в ERP', True, OnErpSendClick, 160);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(FErpPanel.Width - 160, 8, 160, 36);

  // раздел «Контракт с клиентом»
  Line := TPanel.Create(Self);
  Line.Parent := Self;
  Line.Align := alClient;
  Line.BevelOuter := bvNone;
  Line.Color := ESPO_BODY;
  Line.ParentBackground := False;

  MakeLabel(Self, Line, 'КОНТРАКТ С КЛИЕНТОМ', 15, 12, 400, ESPO_MUTED, 8);
  X := 15; Y := 32;
  for S := stDealOffer to stDealWon do
  begin
    FTiles[S] := MakeTile(S, Line, X, Y, TILE_W, TILE_H);
    Inc(X, TILE_W + TILE_GAP);
  end;

  MakeLabel(Self, Line, 'ИСПОЛНЕНИЕ ЗАКАЗОВ: ПРОИЗВОДСТВО, ОПЛАТА, ОТГРУЗКА',
    15, Y + TILE_H + 18, 700, ESPO_MUTED, 8);
  X := 15; Y := Y + TILE_H + 38;
  for S := stAwaitAdvance to stClosed do
  begin
    FTiles[S] := MakeTile(S, Line, X, Y, TILE_W, TILE_H);
    Inc(X, TILE_W + TILE_GAP);
  end;

  // две сводки под плитками
  Inc(Y, TILE_H + 18);
  Btn := MakePanelBox(Self, Line, 'Последние заказы');
  Btn.SetBounds(15, Y, 505, 190);
  FLastOrders := MakeLabel(Self, Btn, '', 14, 34, 478, ESPO_TEXT, 9);
  FLastOrders.Height := 148;
  FLastOrders.WordWrap := True;

  Btn := MakePanelBox(Self, Line, 'Ближайшие задачи');
  Btn.SetBounds(530, Y, 505, 190);
  FNextTasks := MakeLabel(Self, Btn, '', 14, 34, 478, ESPO_TEXT, 9);
  FNextTasks.Height := 148;
  FNextTasks.WordWrap := True;
end;

procedure TWorkspacePage.Refresh;
var
  S: TStage;
  Info: TStageInfo;
  Orders, Overdue: Integer;
  Money: Double;
begin
  Orders := 0; Overdue := 0; Money := 0;
  for S := Low(TStage) to High(TStage) do
  begin
    Info := FData.StageInfo(S);
    FTiles[S].LblTitle.Caption := Info.Title;
    FTiles[S].LblHint.Caption := Info.Hint;
    FTiles[S].LblValue.Caption := IntToStr(Info.Count);
    FTiles[S].LblSum.Caption := FormatFloat('#,##0', Info.Sum) + ' MDL';
    if Info.Overdue > 0 then
    begin
      FTiles[S].LblOver.Caption := Format('запаздывает %d  ·  %s MDL',
        [Info.Overdue, FormatFloat('#,##0', Info.OverdueSum)]);
      FTiles[S].LblValue.Font.Color := ST_DANGER_FG;
    end
    else
    begin
      if Info.Count > 0 then
        FTiles[S].LblOver.Caption := 'всё в срок'
      else
        FTiles[S].LblOver.Caption := '';
      if S = stClosed then
        FTiles[S].LblValue.Font.Color := ST_SUCCESS_FG
      else
        FTiles[S].LblValue.Font.Color := ESPO_PRIMARY;
    end;
    FTiles[S].LblOver.Font.Color := IfThen(Info.Overdue > 0, ST_DANGER_FG, ST_SUCCESS_FG);
    if Info.Table = 'orders' then
    begin
      Inc(Orders, Info.Count);
      Inc(Overdue, Info.Overdue);
      if S <> stClosed then Money := Money + Info.Sum;
    end;
  end;
  FSummary.Caption := Format('заказов в работе и закрытых: %d   ·   не закрыто на %s MDL   ·   запаздывает: %d',
    [Orders, FormatFloat('#,##0', Money), Overdue]);
  FLastOrders.Caption := ListLastOrders;
  FNextTasks.Caption := ListNextTasks;
end;

function TWorkspacePage.ListLastOrders: string;
var
  Q: TFDQuery;
  N: Integer;
begin
  Result := '';
  N := 0;
  Q := FData.OpenQuery(
    'SELECT o.number, o.order_date, o.kind, o.status, o.total, ' +
    ' COALESCE(c.denumire, ''(без клиента)'') AS client ' +
    'FROM orders o LEFT JOIN clients c ON c.id = o.client_id ' +
    'ORDER BY o.id DESC LIMIT 7');
  try
    while not Q.Eof do
    begin
      Result := Result + Format('• №%s от %s — %s, %s, %s MDL  [%s]',
        [Q.FieldByName('number').AsString, Q.FieldByName('order_date').AsString,
         Q.FieldByName('client').AsString, Q.FieldByName('kind').AsString,
         FormatFloat('#,##0.00', Q.FieldByName('total').AsFloat),
         Q.FieldByName('status').AsString]) + sLineBreak;
      Inc(N);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  if N = 0 then
    Result := 'Заказов пока нет — создайте первый в разделе «Заказы».';
end;

function TWorkspacePage.ListNextTasks: string;
var
  Q: TFDQuery;
  N: Integer;
begin
  Result := '';
  N := 0;
  Q := FData.OpenQuery(
    'SELECT t.due_at, t.kind, t.subject, COALESCE(c.denumire,'''') AS client, ' +
    ' CASE WHEN t.due_at < date(''now'',''localtime'') THEN 1 ELSE 0 END AS late ' +
    'FROM tasks t LEFT JOIN clients c ON c.id = t.client_id ' +
    'WHERE t.done = 0 ORDER BY t.due_at LIMIT 7');
  try
    while not Q.Eof do
    begin
      Result := Result + Format('• %s  %s — %s%s%s',
        [Q.FieldByName('due_at').AsString, Q.FieldByName('kind').AsString,
         Q.FieldByName('subject').AsString,
         IfThen(Q.FieldByName('client').AsString = '', '', ' (' + Q.FieldByName('client').AsString + ')'),
         IfThen(Q.FieldByName('late').AsInteger = 1, '  ← просрочено', '')]) + sLineBreak;
      Inc(N);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  if N = 0 then
    Result := 'Открытых задач нет.';
end;

procedure TWorkspacePage.OnTileClick(Sender: TObject);
begin
  if Assigned(FOnStageClick) then
    FOnStageClick(TStage((Sender as TComponent).Tag));
end;

procedure TWorkspacePage.OnRefreshClick(Sender: TObject);
begin
  Refresh;
  Say(mkInfo, 'Рабочий стол обновлён.');
end;

procedure TWorkspacePage.OnErpCheckClick(Sender: TObject);
begin
  ErpCheck;
end;

procedure TWorkspacePage.OnErpSendClick(Sender: TObject);
begin
  ErpSend(FData.DB.DBPath);
end;

procedure TWorkspacePage.ClickTile(Stage: TStage);
begin
  OnTileClick(FTiles[Stage].Panel);
end;

function TWorkspacePage.TileValue(Stage: TStage): string;
begin
  Result := FTiles[Stage].LblValue.Caption;
end;

function TWorkspacePage.TileOverdue(Stage: TStage): string;
begin
  Result := FTiles[Stage].LblOver.Caption;
end;

function TWorkspacePage.TileVisible(Stage: TStage): Boolean;
begin
  Result := (FTiles[Stage].Panel <> nil) and FTiles[Stage].Panel.Visible;
end;

function TWorkspacePage.ErpText: string;
begin
  Result := FErpLabel.Caption;
end;

procedure TWorkspacePage.ErpCheck;
var
  St: TErpStatus;
begin
  if FErp.Health(St) then
  begin
    FErpLabel.Caption := St.Message;
    FErpLabel.Font.Color := ST_SUCCESS_FG;
    FErpPanel.Color := ST_SUCCESS_BG;
    Say(mkOk, St.Message);
  end
  else
  begin
    FErpLabel.Caption := St.Message;
    FErpLabel.Font.Color := ST_WARNING_FG;
    FErpPanel.Color := ST_WARNING_BG;
    Say(mkWarn, St.Message);
  end;
end;

procedure TWorkspacePage.ErpSend(const DbPath: string);
var
  BatchId, Msg: string;
begin
  if FErp.SendDatabase(DbPath, BatchId) then
  begin
    Msg := Format('Данные отправлены в ERP: пакет %s (%s)', [BatchId, FErp.LastError]);
    FErpLabel.Caption := Msg;
    FErpLabel.Font.Color := ST_SUCCESS_FG;
    FErpPanel.Color := ST_SUCCESS_BG;
    FData.DB.Connection.ExecSQL(
      'UPDATE orders SET erp_batch = :b, erp_sent_at = datetime(''now'',''localtime'') ' +
      'WHERE COALESCE(erp_batch,'''') = ''''', [BatchId]);
    Say(mkOk, Msg);
  end
  else
  begin
    Msg := 'Не удалось отправить в ERP: ' + FErp.LastError;
    FErpLabel.Caption := Msg;
    FErpLabel.Font.Color := ST_WARNING_FG;
    FErpPanel.Color := ST_WARNING_BG;
    Say(mkWarn, Msg);
  end;
end;

{ ── TReportsPage ── }

constructor TReportsPage.Create(AOwner: TComponent; AParent: TWinControl;
  AData: TCrmData; ASay: TSayProc; const AExportDir: string);
begin
  inherited Create(AOwner);
  Parent := AParent;
  Align := alClient;
  Visible := False;
  FData := AData;
  FOnSay := ASay;
  FExportDir := AExportDir;
  FCurrent := rkProcess;
  BevelOuter := bvNone;
  Color := ESPO_BODY;
  ParentBackground := False;
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;
  BuildUI;
end;

procedure TReportsPage.Say(Kind: TMsgKind; const Msg: string);
begin
  if Assigned(FOnSay) then FOnSay(Kind, Msg);
end;

procedure TReportsPage.BuildUI;
var
  Hdr: TPanel;
  L: TLabel;
  Btn: TPanel;
  Col: TListColumn;
  K: TReportKind;
  Item: TListItem;
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
  L.SetBounds(15, 14, 400, 30);
  L.Caption := 'Отчёты';
  L.Font.Size := 16;

  Btn := MakeButton(Self, Hdr, 'Выгрузить в Excel', True, OnXlsxClick, 175);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 190, 12, 175, 36);
  Btn := MakeButton(Self, Hdr, 'Выгрузить в PDF', False, OnPdfClick, 155);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 190 - 8 - 155, 12, 155, 36);
  Btn := MakeButton(Self, Hdr, 'Папка выгрузки', False, OnOpenDirClick, 150);
  Btn.Anchors := [akTop, akRight];
  Btn.SetBounds(Hdr.Width - 190 - 8 - 155 - 8 - 150, 12, 150, 36);

  // список отчётов слева
  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alLeft;
  FList.Width := 380;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.HideSelection := False;
  FList.BorderStyle := bsNone;
  FList.Color := ESPO_WHITE;
  FList.OnSelectItem := OnListSelect;
  Col := FList.Columns.Add; Col.Caption := 'Отчёт'; Col.Width := 190;
  Col := FList.Columns.Add; Col.Caption := 'Что показывает'; Col.Width := 185;
  for K := Low(TReportKind) to High(TReportKind) do
  begin
    Item := FList.Items.Add;
    Item.Caption := REPORTS[K].Title;
    Item.Data := Pointer(Ord(K));
    Item.SubItems.Add(REPORTS[K].Hint);
  end;

  FPreviewTitle := TLabel.Create(Self);
  FPreviewTitle.Parent := Self;
  FPreviewTitle.Top := 1000;   // ниже шапки в стопке alTop
  FPreviewTitle.Align := alTop;
  FPreviewTitle.Height := 26;
  FPreviewTitle.Layout := tlCenter;
  FPreviewTitle.Font.Size := 11;
  FPreviewTitle.Font.Style := [fsBold];
  FPreviewTitle.Font.Color := ESPO_SOFT;
  FPreviewTitle.Caption := '   Предпросмотр';

  FPreviewHead := TPanel.Create(Self);
  FPreviewHead.Parent := Self;
  FPreviewHead.Top := 1001;
  FPreviewHead.Align := alTop;
  FPreviewHead.Height := 26;
  FPreviewHead.BevelOuter := bvNone;
  FPreviewHead.Color := ESPO_WHITE;
  FPreviewHead.ParentBackground := False;
  with TPanel.Create(Self) do
  begin
    Parent := FPreviewHead; Align := alBottom; Height := 1;
    BevelOuter := bvNone; Color := ESPO_BORDER; ParentBackground := False;
  end;

  FPreview := TListView.Create(Self);
  FPreview.Parent := Self;
  FPreview.Align := alClient;
  FPreview.ShowColumnHeaders := False;
  FPreview.ViewStyle := vsReport;
  FPreview.ReadOnly := True;
  FPreview.RowSelect := True;
  FPreview.GridLines := True;
  FPreview.BorderStyle := bsNone;
  FPreview.Color := ESPO_WHITE;
end;

procedure TReportsPage.Refresh;
begin
  ShowPreview(FCurrent);
end;

procedure TReportsPage.ShowPreview(Kind: TReportKind);
var
  T: TReportTable;
  Col: TListColumn;
  Item: TListItem;
  R, C, X: Integer;
begin
  FCurrent := Kind;
  T := BuildReport(FData, Kind);
  try
    FPreviewTitle.Caption := '   ' + T.Title + ' — ' + T.Subtitle;
    while FPreviewHead.ControlCount > 1 do
      FPreviewHead.Controls[FPreviewHead.ControlCount - 1].Free;
    X := 6;
    FPreview.Items.BeginUpdate;
    try
      FPreview.Items.Clear;
      FPreview.Columns.Clear;
      for C := 0 to T.ColCount - 1 do
      begin
        Col := FPreview.Columns.Add;
        Col.Caption := T.Cols[C].Title;
        Col.Width := Max(60, Round(T.Cols[C].Width * 0.9));
        if T.Cols[C].Kind in [ckMoney, ckNumber, ckRight] then
          Col.Alignment := taRightJustify;
        MakeLabel(Self, FPreviewHead, UpperCase(T.Cols[C].Title), X + 4, 6,
          Col.Width - 8, ESPO_MUTED, 8);
        Inc(X, Col.Width);
      end;
      for R := 0 to T.RowCount - 1 do
      begin
        Item := FPreview.Items.Add;
        Item.Caption := T.Cell(R, 0);
        for C := 1 to T.ColCount - 1 do
          Item.SubItems.Add(T.Cell(R, C));
      end;
      if Length(T.Totals) > 0 then
      begin
        Item := FPreview.Items.Add;
        Item.Caption := T.Totals[0];
        for C := 1 to T.ColCount - 1 do
          if C <= High(T.Totals) then
            Item.SubItems.Add(T.Totals[C])
          else
            Item.SubItems.Add('');
      end;
    finally
      FPreview.Items.EndUpdate;
    end;
  finally
    T.Free;
  end;
end;

procedure TReportsPage.OnListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if Selected then
    ShowPreview(TReportKind(Integer(Item.Data)));
end;

procedure TReportsPage.SelectReport(Kind: TReportKind);
var
  I: Integer;
begin
  for I := 0 to FList.Items.Count - 1 do
    if Integer(FList.Items[I].Data) = Ord(Kind) then
    begin
      FList.Items[I].Selected := True;
      FList.Selected := FList.Items[I];
    end;
  ShowPreview(Kind);
end;

function TReportsPage.Export(Fmt: TExportFormat): string;
begin
  Result := ExportReport(FData, FCurrent, Fmt, FExportDir);
  Say(mkOk, Format('Отчёт «%s» выгружен: %s', [REPORTS[FCurrent].Title, Result]));
end;

function TReportsPage.PreviewRows: Integer;
begin
  Result := FPreview.Items.Count;
end;

function TReportsPage.PreviewCols: Integer;
begin
  Result := FPreview.Columns.Count;
end;

procedure TReportsPage.OnXlsxClick(Sender: TObject);
begin
  Export(efXlsx);
end;

procedure TReportsPage.OnPdfClick(Sender: TObject);
begin
  Export(efPdf);
end;

procedure TReportsPage.OnOpenDirClick(Sender: TObject);
begin
  TDirectory.CreateDirectory(FExportDir);
  ShellExecute(0, 'open', PChar(FExportDir), nil, nil, SW_SHOWNORMAL);
  Say(mkInfo, 'Папка выгрузки: ' + FExportDir);
end;

end.
