unit uMainForm;
{
  Главное окно CRM для небольшой фирмы (торговля, услуги, производство)
  в стиле EspoCRM (бесплатная редакция, тема «Espo»).

  Разделы: Главная (показатели), Клиенты (из реестра date.gov.md через
  Contragenti + карточка), Контакты, Лиды (→ клиент), Сделки (воронка),
  Номенклатура (товар/услуга/изделие, остатки), Заказы (продажа/услуга/
  производство, строки, проводка остатков), Календарь (задачи/звонки/
  встречи), Настройки.

  Интерфейс строится в коде (без .dfm) — проект собирается консольным dcc32.
  Никаких модальных окон: сообщения — в цветной строке внизу, редакторы —
  панели внутри страниц, удаление — подтверждением повторным нажатием.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  Vcl.Graphics,
  uClientsDB, uContragenti, uCrmData, uEntityPage, uEspoTheme, uErpApi,
  uWorkspace, uReports, uKanban, uGantt;

type
  TNavSection = (nsWorkspace, nsKanban, nsGantt, nsAccounts, nsContacts, nsLeads,
    nsDeals, nsItems, nsOrders, nsCalendar, nsReports, nsSettings);

  TMainForm = class(TForm)
  private
    FDB: TClientsDB;
    FCrm: TCrmData;
    FCli: TContragentiClient;
    FIniPath: string;
    FPendingDeleteId: Integer;
    FSection: TNavSection;
    FAdding: Boolean;      // защита от повторного входа, пока открыт Contragenti
    FWaitTicks: Integer;

    FTestBanner: TPanel;
    FSidebar: TPanel;
    FNavItems: array[TNavSection] of TPanel;
    FTopBar: TPanel;
    FGlobalSearch: TEdit;
    FContent: TPanel;
    FMsg: TPanel;

    // «Клиенты»
    FPageAccounts: TPanel;
    FBtnAdd, FBtnDelete, FBtnRefresh: TPanel;
    FPreset: TComboBox;
    FSearch: TEdit;
    FPager: TLabel;
    FList: TListView;
    FOverview: TPanel;
    FOvValues: array[0..5] of TLabel;
    FOvType: TComboBox;
    FOvPhone, FOvEmail, FOvContact: TEdit;

    // универсальные страницы
    FPages: array[TNavSection] of TEntityPage;

    // рабочий стол и отчёты
    FErp: TErpClient;
    FWorkspace: TWorkspacePage;
    FReportsPage: TReportsPage;
    FKanbanPage: TKanbanPage;
    FGanttPage: TGanttPage;

    FSettingsPanel: TPanel;
    FLauncherEdit, FErpUrlEdit, FErpKeyEdit: TEdit;

    procedure BuildUI;
    procedure BuildSidebar;
    procedure BuildTopBar;
    procedure BuildAccountsPage;
    procedure BuildEntityPages;
    procedure BuildWorkspacePages;
    procedure SetStagePresets;
    procedure BuildSettingsPanel;
    procedure AddNavItem(Section: TNavSection; const Glyph, Title: string);
    procedure SelectSection(Section: TNavSection);
    procedure LoadSettings;
    procedure SaveSettings;
    procedure RefreshList;
    procedure ShowOverview(Item: TListItem);
    procedure OnStageClick(Stage: TStage);
    procedure OnContragentiWait;
    function  ResolveLauncher: string;
    procedure Say(Kind: TMsgKind; const Msg: string);
    procedure OnNavClick(Sender: TObject);
    procedure OnAddClick(Sender: TObject);
    procedure OnDeleteClick(Sender: TObject);
    procedure OnRefreshClick(Sender: TObject);
    procedure OnSettingsSave(Sender: TObject);
    procedure OnSearchChange(Sender: TObject);
    procedure OnGlobalSearchChange(Sender: TObject);
    procedure OnPresetChange(Sender: TObject);
    procedure OnListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure OnOverviewSave(Sender: TObject);
    procedure OnLeadConvert(Sender: TObject);
    procedure OnTaskDone(Sender: TObject);
    procedure OnPageChanged(Sender: TObject);
    procedure OnFormClose(Sender: TObject; var Action: TCloseAction);
    procedure OnAppException(Sender: TObject; E: Exception);
    function SelectedId: Integer;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;

    { ── хуки для встроенного GUI-самотеста (uGuiSelfTest) ── }
    procedure TestShowBanner(Step: Integer; const Title: string);
    procedure TestHideBanner;
    procedure TestSetFilter(const Text: string);
    procedure TestClickAdd;
    procedure TestClickNav(Section: TNavSection);
    property Client: TContragentiClient read FCli;
    property Crm: TCrmData read FCrm;
    property Erp: TErpClient read FErp;
    property Workspace: TWorkspacePage read FWorkspace;
    property Reports: TReportsPage read FReportsPage;
    property Kanban: TKanbanPage read FKanbanPage;
    property Gantt: TGanttPage read FGanttPage;
    function  Page(Section: TNavSection): TEntityPage;
    function  TestImportXml(const Xml: string; out Card: TCounterpartyCard): TAddResult;
    function  TestSelectFirst: Boolean;
    procedure TestClickDelete;
    procedure TestClickSettings;
    procedure TestLeadConvert;
    procedure TestTaskDone;
    procedure TestOverviewSet(const AType, Phone, Email, Contact: string);
    function  TestListCount: Integer;
    function  TestDbCount: Integer;
    function  TestMessage: string;
    function  TestMessageKind: TMsgKind;
    function  TestSection: TNavSection;
    { Сколько раз сработал обработчик ожидания Contragenti — по нему видно,
      что окно продолжало обрабатывать сообщения, а не висело. }
    function  TestWaitTicks: Integer;
  end;

var
  GDBPathOverride: string = '';

implementation

uses
  System.IOUtils, System.IniFiles, System.StrUtils, System.DateUtils, System.Math,
  System.Variants;

const
  CLR_TEST_BG = $00D9E8FF;  CLR_TEST_FG = $00203A80;
  NAV_WIDTH = 232;
  NAV_ITEM_H = 40;
  TOPBAR_H = 32;
  OV_LABELS: array[0..5] of string =
    ('Название', 'IDNO', 'Форма', 'Адрес', 'Руководитель', 'Добавлен');
  COL_TITLES: array[0..5] of string =
    ('Название', 'IDNO', 'Форма', 'Адрес', 'Руководитель', 'Добавлен');
  COL_WIDTHS: array[0..5] of Integer = (300, 120, 90, 230, 150, 120);

function AppDir: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

{ TMainForm }

constructor TMainForm.CreateNew(AOwner: TComponent; Dummy: Integer);
var
  DbPath: string;
begin
  inherited CreateNew(AOwner, Dummy);
  FIniPath := TPath.Combine(AppDir, 'crm.ini');
  FPendingDeleteId := 0;

  if GDBPathOverride <> '' then
    DbPath := GDBPathOverride
  else
    DbPath := TPath.Combine(AppDir, 'clients.db');
  FDB := TClientsDB.Create(DbPath);
  FDB.Open;
  FCrm := TCrmData.Create(FDB);
  FCrm.EnsureSchema;

  FCli := TContragentiClient.Create;
  FErp := TErpClient.Create;
  LoadSettings;

  BuildUI;
  Application.OnException := OnAppException;
  RefreshList;
  SelectSection(nsWorkspace);
  Say(mkInfo, Format('База: %s   |   клиентов: %d', [FDB.DBPath, FDB.Count]));
end;

procedure TMainForm.OnAppException(Sender: TObject; E: Exception);
begin
  Say(mkErr, 'Ошибка: ' + E.Message);
end;

destructor TMainForm.Destroy;
begin
  FErp.Free;
  FCli.Free;
  FCrm.Free;
  FDB.Free;
  inherited;
end;

{ ── каркас ── }

procedure TMainForm.BuildUI;
begin
  Caption := 'Demo CRM · Клиенты';
  Width := 1280;
  Height := 800;
  Position := poScreenCenter;
  Color := ESPO_BODY;
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;
  OnClose := OnFormClose;

  FTestBanner := TPanel.Create(Self);
  FTestBanner.Parent := Self;
  FTestBanner.Align := alTop;
  FTestBanner.Height := 30;
  FTestBanner.BevelOuter := bvNone;
  FTestBanner.Color := CLR_TEST_BG;
  FTestBanner.ParentBackground := False;
  FTestBanner.Alignment := taLeftJustify;
  FTestBanner.Font.Color := CLR_TEST_FG;
  FTestBanner.Font.Style := [fsBold];
  FTestBanner.Visible := False;

  FMsg := TPanel.Create(Self);
  FMsg.Parent := Self;
  FMsg.Align := alBottom;
  FMsg.Height := 30;
  FMsg.BevelOuter := bvNone;
  FMsg.ParentBackground := False;
  FMsg.Alignment := taLeftJustify;
  FMsg.Font.Style := [fsBold];

  BuildSidebar;
  BuildTopBar;

  FContent := TPanel.Create(Self);
  FContent.Parent := Self;
  FContent.Align := alClient;
  FContent.BevelOuter := bvNone;
  FContent.Color := ESPO_BODY;
  FContent.ParentBackground := False;

  BuildSettingsPanel;
  BuildAccountsPage;
  BuildEntityPages;
  BuildWorkspacePages;
end;

procedure TMainForm.AddNavItem(Section: TNavSection; const Glyph, Title: string);
var
  P: TPanel;
  L, G: TLabel;
begin
  P := TPanel.Create(Self);
  P.Parent := FSidebar;
  P.Align := alTop;
  P.Height := NAV_ITEM_H;
  P.Top := 1000;
  P.BevelOuter := bvNone;
  P.Color := ESPO_BODY;
  P.ParentBackground := False;
  P.Cursor := crHandPoint;
  P.Tag := Ord(Section);
  P.OnClick := OnNavClick;

  G := TLabel.Create(Self);
  G.Parent := P;
  G.SetBounds(16, 9, 20, 22);
  G.Caption := Glyph;
  G.Font.Name := 'Segoe UI Symbol';
  G.Font.Size := 11;
  G.Font.Color := ESPO_GRAY;
  G.Tag := Ord(Section);
  G.OnClick := OnNavClick;
  G.Cursor := crHandPoint;

  L := TLabel.Create(Self);
  L.Parent := P;
  L.SetBounds(44, 10, 170, 22);
  L.Caption := Title;
  L.Font.Size := 10;
  L.Font.Color := ESPO_TEXT;
  L.Tag := Ord(Section);
  L.OnClick := OnNavClick;
  L.Cursor := crHandPoint;

  FNavItems[Section] := P;
end;

procedure TMainForm.BuildSidebar;
var
  Logo, Sub, Min: TLabel;
  Hdr, Sep, Line: TPanel;
begin
  FSidebar := TPanel.Create(Self);
  FSidebar.Parent := Self;
  FSidebar.Align := alLeft;
  FSidebar.Width := NAV_WIDTH;
  FSidebar.BevelOuter := bvNone;
  FSidebar.Color := ESPO_BODY;
  FSidebar.ParentBackground := False;

  Line := TPanel.Create(Self);
  Line.Parent := FSidebar;
  Line.Align := alRight;
  Line.Width := 1;
  Line.BevelOuter := bvNone;
  Line.Color := ESPO_BORDER;
  Line.ParentBackground := False;

  Hdr := TPanel.Create(Self);
  Hdr.Parent := FSidebar;
  Hdr.Align := alTop;
  Hdr.Height := 65;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_BODY;
  Hdr.ParentBackground := False;
  Logo := TLabel.Create(Self);
  Logo.Parent := Hdr;
  Logo.SetBounds(18, 14, 200, 26);
  Logo.Caption := 'Demo CRM';
  Logo.Font.Size := 14;
  Logo.Font.Style := [fsBold];
  Logo.Font.Color := ESPO_PRIMARY;
  Sub := TLabel.Create(Self);
  Sub.Parent := Hdr;
  Sub.SetBounds(19, 40, 200, 16);
  Sub.Caption := 'SDK Contragenti · date.gov.md';
  Sub.Font.Size := 8;
  Sub.Font.Color := ESPO_MUTED;

  AddNavItem(nsWorkspace, '⌂', 'Рабочий стол');
  AddNavItem(nsKanban,    '▦', 'Канбан');
  AddNavItem(nsGantt,     '▤', 'План работ');
  AddNavItem(nsAccounts,  '▣', 'Клиенты');
  AddNavItem(nsContacts,  '☺', 'Контакты');
  AddNavItem(nsLeads,     '✉', 'Лиды');
  AddNavItem(nsDeals,     '$', 'Сделки');
  AddNavItem(nsItems,     '▤', 'Номенклатура');
  AddNavItem(nsOrders,    '▥', 'Заказы');
  AddNavItem(nsCalendar,  '▦', 'Календарь');
  AddNavItem(nsReports,   '▤', 'Отчёты');

  Sep := TPanel.Create(Self);
  Sep.Parent := FSidebar;
  Sep.Align := alTop;
  Sep.Top := 1000;
  Sep.Height := 9;
  Sep.BevelOuter := bvNone;
  Sep.Color := ESPO_BODY;
  Sep.ParentBackground := False;
  with TPanel.Create(Self) do
  begin
    Parent := Sep; SetBounds(16, 4, NAV_WIDTH - 33, 1);
    BevelOuter := bvNone; Color := ESPO_BORDER; ParentBackground := False;
  end;

  AddNavItem(nsSettings, '⚙', 'Настройки');

  Min := TLabel.Create(Self);
  Min.Parent := FSidebar;
  Min.Align := alBottom;
  Min.Height := 28;
  Min.Alignment := taCenter;
  Min.Layout := tlCenter;
  Min.Caption := '‹';
  Min.Font.Size := 12;
  Min.Font.Color := ESPO_MUTED;
end;

procedure TMainForm.BuildTopBar;
var
  Plus, Bell, User: TLabel;
  Line: TPanel;
begin
  FTopBar := TPanel.Create(Self);
  FTopBar.Parent := Self;
  FTopBar.Align := alTop;
  FTopBar.Height := TOPBAR_H;
  FTopBar.Top := 100;
  FTopBar.BevelOuter := bvNone;
  FTopBar.Color := ESPO_BODY;
  FTopBar.ParentBackground := False;

  Line := TPanel.Create(Self);
  Line.Parent := FTopBar;
  Line.Align := alBottom;
  Line.Height := 1;
  Line.BevelOuter := bvNone;
  Line.Color := ESPO_BORDER;
  Line.ParentBackground := False;

  User := TLabel.Create(Self);
  User.Parent := FTopBar;
  User.Align := alRight;
  User.AutoSize := False;
  User.Width := 120;
  User.Layout := tlCenter;
  User.Alignment := taCenter;
  User.Caption := 'Оператор  ⋮';

  Bell := TLabel.Create(Self);
  Bell.Parent := FTopBar;
  Bell.Align := alRight;
  Bell.AutoSize := False;
  Bell.Width := 34;
  Bell.Layout := tlCenter;
  Bell.Alignment := taCenter;
  Bell.Caption := '🔔';
  Bell.Font.Name := 'Segoe UI Symbol';
  Bell.Font.Color := ESPO_GRAY;

  Plus := TLabel.Create(Self);
  Plus.Parent := FTopBar;
  Plus.Align := alRight;
  Plus.AutoSize := False;
  Plus.Width := 34;
  Plus.Layout := tlCenter;
  Plus.Alignment := taCenter;
  Plus.Caption := '+';
  Plus.Font.Size := 14;
  Plus.Font.Color := ESPO_GRAY;
  Plus.Cursor := crHandPoint;
  Plus.OnClick := OnAddClick;

  FGlobalSearch := TEdit.Create(Self);
  FGlobalSearch.Parent := FTopBar;
  FGlobalSearch.SetBounds(0, 4, 260, 24);
  FGlobalSearch.Anchors := [akTop, akRight];
  FGlobalSearch.TextHint := 'Поиск клиента…';
  FGlobalSearch.OnChange := OnGlobalSearchChange;
  FGlobalSearch.Left := FTopBar.Width - 260 - 34 - 34 - 120 - 12;
end;

procedure TMainForm.BuildAccountsPage;
var
  Col: TListColumn;
  Hdr, SearchRow, Line: TPanel;
  I, X: Integer;
  L: TLabel;
  Mag, Dots, Btn: TPanel;
begin
  FPageAccounts := TPanel.Create(Self);
  FPageAccounts.Parent := FContent;
  FPageAccounts.Align := alClient;
  FPageAccounts.BevelOuter := bvNone;
  FPageAccounts.Color := ESPO_BODY;
  FPageAccounts.ParentBackground := False;
  FPageAccounts.Padding.SetBounds(15, 12, 15, 12);

  Hdr := TPanel.Create(Self);
  Hdr.Parent := FPageAccounts;
  Hdr.Align := alTop;
  Hdr.Height := 48;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_BODY;
  Hdr.ParentBackground := False;

  L := TLabel.Create(Self);
  L.Parent := Hdr;
  L.SetBounds(0, 6, 400, 30);
  L.Caption := 'Клиенты';
  L.Font.Size := 16;

  FBtnAdd := MakeButton(Self, Hdr, 'Создать из реестра', True, OnAddClick, 180);
  FBtnAdd.Anchors := [akTop, akRight];
  FBtnAdd.SetBounds(Hdr.Width - 180, 4, 180, 36);
  Dots := MakeButton(Self, Hdr, '⋯', False, nil, 36);
  Dots.Anchors := [akTop, akRight];
  Dots.SetBounds(Hdr.Width - 180 - 8 - 36, 4, 36, 36);
  Dots.Font.Name := 'Segoe UI Symbol';
  FBtnRefresh := MakeButton(Self, Hdr, 'Обновить', False, OnRefreshClick, 100);
  FBtnRefresh.Anchors := [akTop, akRight];
  FBtnRefresh.SetBounds(Hdr.Width - 180 - 8 - 36 - 8 - 100, 4, 100, 36);
  FBtnDelete := MakeButton(Self, Hdr, 'Удалить', False, OnDeleteClick, 100);
  FBtnDelete.Anchors := [akTop, akRight];
  FBtnDelete.SetBounds(Hdr.Width - 180 - 8 - 36 - 8 - 100 - 8 - 100, 4, 100, 36);

  SearchRow := TPanel.Create(Self);
  SearchRow.Parent := FPageAccounts;
  SearchRow.Align := alTop;
  SearchRow.Top := 60;
  SearchRow.Height := 48;
  SearchRow.BevelOuter := bvNone;
  SearchRow.Color := ESPO_BODY;
  SearchRow.ParentBackground := False;

  FPreset := TComboBox.Create(Self);
  FPreset.Parent := SearchRow;
  FPreset.Style := csDropDownList;
  FPreset.SetBounds(0, 8, 190, 28);
  FPreset.Items.Add('Все');
  FPreset.Items.Add('Добавлены сегодня');
  FPreset.Items.Add('С юридическим адресом');
  FPreset.ItemIndex := 0;
  FPreset.OnChange := OnPresetChange;

  FSearch := TEdit.Create(Self);
  FSearch.Parent := SearchRow;
  FSearch.SetBounds(198, 8, 320, 28);
  FSearch.TextHint := 'Название, IDNO или руководитель…';
  FSearch.OnChange := OnSearchChange;

  Mag := MakeButton(Self, SearchRow, '🔍', False, OnRefreshClick, 36);
  Mag.SetBounds(524, 4, 36, 36);
  Mag.Font.Name := 'Segoe UI Symbol';

  FPager := TLabel.Create(Self);
  FPager.Parent := SearchRow;
  FPager.AutoSize := False;
  FPager.SetBounds(SearchRow.Width - 200, 12, 200, 22);
  FPager.Anchors := [akTop, akRight];
  FPager.Alignment := taRightJustify;
  FPager.Font.Color := ESPO_MUTED;

  // карточка клиента: реестровые поля (только чтение) + поля CRM (редактируемые)
  FOverview := MakePanelBox(Self, FPageAccounts, 'Карточка клиента');
  FOverview.Align := alBottom;
  FOverview.Height := 196;
  for I := 0 to 5 do
  begin
    MakeLabel(Self, FOverview, OV_LABELS[I], 14 + (I mod 3) * 340, 36 + (I div 3) * 40, 300);
    FOvValues[I] := MakeLabel(Self, FOverview, '—', 14 + (I mod 3) * 340, 52 + (I div 3) * 40, 330, ESPO_TEXT, 10);
  end;
  MakeLabel(Self, FOverview, 'Тип', 14, 118, 150);
  FOvType := TComboBox.Create(Self);
  FOvType.Parent := FOverview;
  FOvType.Style := csDropDownList;
  FOvType.SetBounds(14, 136, 150, 26);
  FOvType.Items.AddStrings(ENUM_CLIENT_TYPE.Split([';']));
  FOvType.ItemIndex := 0;
  MakeLabel(Self, FOverview, 'Телефон', 178, 118, 150);
  FOvPhone := TEdit.Create(Self); FOvPhone.Parent := FOverview; FOvPhone.SetBounds(178, 136, 150, 26);
  MakeLabel(Self, FOverview, 'E-mail', 342, 118, 200);
  FOvEmail := TEdit.Create(Self); FOvEmail.Parent := FOverview; FOvEmail.SetBounds(342, 136, 200, 26);
  MakeLabel(Self, FOverview, 'Контактное лицо', 556, 118, 220);
  FOvContact := TEdit.Create(Self); FOvContact.Parent := FOverview; FOvContact.SetBounds(556, 136, 220, 26);
  Btn := MakeButton(Self, FOverview, 'Сохранить', True, OnOverviewSave, 120);
  Btn.SetBounds(790, 131, 120, 36);

  Line := TPanel.Create(Self);
  Line.Parent := FPageAccounts;
  Line.Align := alBottom;
  Line.Height := 14;
  Line.BevelOuter := bvNone;
  Line.Color := ESPO_BODY;
  Line.ParentBackground := False;

  Hdr := TPanel.Create(Self);
  Hdr.Parent := FPageAccounts;
  Hdr.Align := alTop;
  Hdr.Top := 200;
  Hdr.Height := 30;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_WHITE;
  Hdr.ParentBackground := False;
  with TPanel.Create(Self) do
  begin
    Parent := Hdr; Align := alBottom; Height := 1;
    BevelOuter := bvNone; Color := ESPO_BORDER; ParentBackground := False;
  end;
  X := 24;
  for I := 0 to High(COL_TITLES) do
  begin
    MakeLabel(Self, Hdr, UpperCase(COL_TITLES[I]), X + 4, 8, COL_WIDTHS[I] - 8, ESPO_MUTED, 8);
    Inc(X, COL_WIDTHS[I]);
  end;

  FList := TListView.Create(Self);
  FList.Parent := FPageAccounts;
  FList.Align := alClient;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.Checkboxes := True;
  FList.GridLines := False;
  FList.HideSelection := False;
  FList.ShowColumnHeaders := False;
  FList.BorderStyle := bsNone;
  FList.Color := ESPO_WHITE;
  FList.Font.Color := ESPO_TEXT;
  FList.OnSelectItem := OnListSelect;
  for I := 0 to High(COL_TITLES) do
  begin
    Col := FList.Columns.Add;
    Col.Caption := COL_TITLES[I];
    Col.Width := COL_WIDTHS[I];
  end;
end;

procedure TMainForm.BuildEntityPages;
var
  P: TEntityPage;
begin
  FPages[nsContacts] := TEntityPage.Create(Self, FContent, FCrm, DefContacts, Say);
  FPages[nsLeads]    := TEntityPage.Create(Self, FContent, FCrm, DefLeads, Say);
  FPages[nsDeals]    := TEntityPage.Create(Self, FContent, FCrm, DefDeals, Say);
  FPages[nsItems]    := TEntityPage.Create(Self, FContent, FCrm, DefItems, Say);
  FPages[nsOrders]   := TEntityPage.Create(Self, FContent, FCrm, DefOrders, Say);
  FPages[nsCalendar] := TEntityPage.Create(Self, FContent, FCrm, DefTasks, Say);
  for P in FPages do
    if P <> nil then
      P.OnChanged := OnPageChanged;

  FPages[nsLeads].AddExtraButton('В клиенты', OnLeadConvert, False, 120);
  FPages[nsLeads].SetPresets(['Все', 'Новые', 'В работе', 'Конвертированные'],
    ['', 't.status = ''Новый''', 't.status = ''В работе''', 't.status = ''Конвертирован''']);

  FPages[nsDeals].SetPresets(['Все', 'Открытые', 'Выигранные', 'Проигранные'],
    ['', 't.stage NOT IN (''Выиграна'',''Проиграна'')', 't.stage = ''Выиграна''', 't.stage = ''Проиграна''']);

  FPages[nsItems].SetPresets(['Все', 'Товары', 'Услуги', 'Изделия', 'Нет на складе'],
    ['', 't.kind = ''Товар''', 't.kind = ''Услуга''', 't.kind = ''Изделие''',
     't.kind <> ''Услуга'' AND COALESCE(t.stock,0) <= 0']);

  FPages[nsOrders].SetPresets(['Все', 'Открытые', 'Не проведённые', 'Продажи', 'Услуги', 'Производство'],
    ['', 't.status NOT IN (''Выполнен'',''Оплачен'',''Отменён'')', 't.posted = 0',
     't.kind = ''Продажа''', 't.kind = ''Услуга''', 't.kind = ''Производство''']);

  FPages[nsCalendar].AddExtraButton('Выполнено', OnTaskDone, False, 120);
  FPages[nsCalendar].SetPresets(['Открытые', 'Сегодня', 'Просроченные', 'Все'],
    ['t.done = 0', 't.done = 0 AND t.due_at = date(''now'',''localtime'')',
     't.done = 0 AND t.due_at < date(''now'',''localtime'')', '']);
end;

{ Пресеты разделов совпадают с плитками рабочего стола, поэтому нажатие на
  плитку открывает раздел уже отфильтрованным. }
procedure TMainForm.SetStagePresets;
begin
  FPages[nsDeals].SetPresets(
    ['Все', 'Предложение', 'Переговоры', 'Выиграна', 'Проиграна', 'Открытые'],
    ['', FCrm.StageWhere(stDealOffer), FCrm.StageWhere(stDealTalks),
     FCrm.StageWhere(stDealWon), 't.stage = ''Проиграна''',
     't.stage NOT IN (''Выиграна'',''Проиграна'')']);
  FPages[nsOrders].SetPresets(
    ['Все', 'Ожидает аванс', 'В работе / производство', 'Готово к отгрузке',
     'Отгружено — ждём оплату', 'Закрыто', 'Запаздывает'],
    ['', FCrm.StageWhere(stAwaitAdvance), FCrm.StageWhere(stInWork),
     FCrm.StageWhere(stReadyToShip), FCrm.StageWhere(stAwaitPayment),
     FCrm.StageWhere(stClosed),
     't.status <> ''Отменён'' AND COALESCE(t.due_date,'''') <> '''' ' +
     'AND t.due_date < date(''now'',''localtime'') ' +
     'AND NOT (COALESCE(t.ship_date,'''') <> '''' AND COALESCE(t.paid,0) >= t.total)']);
end;

procedure TMainForm.BuildWorkspacePages;
begin
  FWorkspace := TWorkspacePage.Create(Self, FContent, FCrm, FErp, Say);
  FWorkspace.OnStageClick := OnStageClick;
  FReportsPage := TReportsPage.Create(Self, FContent, FCrm, Say,
    TPath.Combine(AppDir, 'reports'));
  FKanbanPage := TKanbanPage.Create(Self, FContent, FCrm, Say);
  FGanttPage := TGanttPage.Create(Self, FContent, FCrm, Say);
  SetStagePresets;
end;

{ Нажатие на плитку: открыть раздел с соответствующим фильтром. }
procedure TMainForm.OnStageClick(Stage: TStage);
const
  DEAL_PRESET: array[stDealOffer..stDealWon] of Integer = (1, 2, 3);
  ORDER_PRESET: array[stAwaitAdvance..stClosed] of Integer = (1, 2, 3, 4, 5);
begin
  if Stage in [stDealOffer, stDealTalks, stDealWon] then
  begin
    SelectSection(nsDeals);
    FPages[nsDeals].SelectPreset(DEAL_PRESET[Stage]);
    Say(mkInfo, Format('Сделки, этап «%s»: %d',
      [FCrm.StageInfo(Stage).Title, FPages[nsDeals].ListCount]));
  end
  else
  begin
    SelectSection(nsOrders);
    FPages[nsOrders].SelectPreset(ORDER_PRESET[Stage]);
    Say(mkInfo, Format('Заказы, этап «%s»: %d',
      [FCrm.StageInfo(Stage).Title, FPages[nsOrders].ListCount]));
  end;
end;


procedure TMainForm.BuildSettingsPanel;
var
  Btn: TPanel;
begin
  FSettingsPanel := TPanel.Create(Self);
  FSettingsPanel.Parent := FContent;
  FSettingsPanel.Align := alTop;
  FSettingsPanel.Height := 56;
  FSettingsPanel.BevelOuter := bvNone;
  FSettingsPanel.Color := ST_PRIMARY_BG;
  FSettingsPanel.ParentBackground := False;
  FSettingsPanel.Visible := False;
  FSettingsPanel.Height := 92;
  MakeLabel(Self, FSettingsPanel, 'Путь к Contragenti (exe/py):', 15, 14, 190, ST_PRIMARY_FG, 10);
  FLauncherEdit := TEdit.Create(Self);
  FLauncherEdit.Parent := FSettingsPanel;
  FLauncherEdit.SetBounds(215, 10, 560, 26);
  MakeLabel(Self, FSettingsPanel, 'ERP una.md, адрес API:', 15, 50, 190, ST_PRIMARY_FG, 10);
  FErpUrlEdit := TEdit.Create(Self);
  FErpUrlEdit.Parent := FSettingsPanel;
  FErpUrlEdit.SetBounds(215, 46, 330, 26);
  FErpUrlEdit.TextHint := 'http://127.0.0.1:9000';
  MakeLabel(Self, FSettingsPanel, 'Ключ:', 555, 50, 50, ST_PRIMARY_FG, 10);
  FErpKeyEdit := TEdit.Create(Self);
  FErpKeyEdit.Parent := FSettingsPanel;
  FErpKeyEdit.SetBounds(600, 46, 175, 26);
  FErpKeyEdit.PasswordChar := '•';
  Btn := MakeButton(Self, FSettingsPanel, 'Сохранить', True, OnSettingsSave, 110);
  Btn.SetBounds(790, 28, 110, 36);
end;

{ ── навигация ── }

procedure TMainForm.SelectSection(Section: TNavSection);
var
  S: TNavSection;
  Titles: array[TNavSection] of string;
begin
  Titles[nsWorkspace] := 'Рабочий стол'; Titles[nsAccounts] := 'Клиенты';
  Titles[nsKanban] := 'Канбан'; Titles[nsGantt] := 'План работ';
  Titles[nsContacts] := 'Контакты'; Titles[nsLeads] := 'Лиды';
  Titles[nsDeals] := 'Сделки'; Titles[nsItems] := 'Номенклатура';
  Titles[nsOrders] := 'Заказы'; Titles[nsCalendar] := 'Календарь';
  Titles[nsReports] := 'Отчёты'; Titles[nsSettings] := 'Настройки';

  if Section = nsSettings then
  begin
    FSettingsPanel.Visible := not FSettingsPanel.Visible;
    if FSettingsPanel.Visible then
    begin
      FLauncherEdit.Text := FCli.LauncherExe;
      FErpUrlEdit.Text := FErp.Url;
      FErpKeyEdit.Text := FErp.Key;
      Say(mkInfo, 'Путь к Contragenti и адрес ERP — затем «Сохранить».');
    end;
    FNavItems[nsSettings].Color := IfThen(FSettingsPanel.Visible, ESPO_NAV_ACT, ESPO_BODY);
    Exit;
  end;

  FSection := Section;
  for S := Low(TNavSection) to High(TNavSection) do
    if (FNavItems[S] <> nil) and (S <> nsSettings) then
      FNavItems[S].Color := IfThen(S = Section, ESPO_NAV_ACT, ESPO_BODY);

  FPageAccounts.Visible := Section = nsAccounts;
  FWorkspace.Visible := Section = nsWorkspace;
  FReportsPage.Visible := Section = nsReports;
  FKanbanPage.Visible := Section = nsKanban;
  FGanttPage.Visible := Section = nsGantt;
  for S := Low(TNavSection) to High(TNavSection) do
    if FPages[S] <> nil then
    begin
      FPages[S].Visible := S = Section;
      if S = Section then
      begin
        FPages[S].Cancel;    // при входе в раздел — чистый список, без редактора прошлой записи
        FPages[S].Refresh;
      end;
    end;
  if Section = nsWorkspace then FWorkspace.Refresh;
  if Section = nsReports then FReportsPage.Refresh;
  if Section = nsKanban then FKanbanPage.Refresh;
  if Section = nsGantt then FGanttPage.Refresh;
  Caption := 'Demo CRM · ' + Titles[Section];
end;

procedure TMainForm.OnNavClick(Sender: TObject);
begin
  FPendingDeleteId := 0;
  SelectSection(TNavSection((Sender as TComponent).Tag));
end;

function TMainForm.Page(Section: TNavSection): TEntityPage;
begin
  Result := FPages[Section];
end;

{ ── настройки ── }

procedure TMainForm.LoadSettings;
var
  Ini: TIniFile;
  DefExe: string;
begin
  DefExe := TPath.Combine(AppDir, 'Contragenti.exe');
  if not TFile.Exists(DefExe) then
    DefExe := TPath.Combine(TPath.Combine(AppDir, '..'), 'Contragenti.exe');
  if not TFile.Exists(DefExe) then
    DefExe := TPath.Combine(
      TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'Contragenti'), 'Contragenti.exe');
  Ini := TIniFile.Create(FIniPath);
  try
    FCli.LauncherExe := Ini.ReadString('contragenti', 'launcher', DefExe);
    FCli.Lang := Ini.ReadString('contragenti', 'lang', 'ru');
    // связь с ERP una.md: адрес хаба и ключ клиента (ключ хранится локально)
    FErp.Url := Ini.ReadString('erp', 'url', 'http://127.0.0.1:9000');
    FErp.Key := Ini.ReadString('erp', 'key', '');
    FErp.ClientId := Ini.ReadString('erp', 'client_id', 'demo-crm');
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveSettings;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(FIniPath);
  try
    Ini.WriteString('contragenti', 'launcher', FCli.LauncherExe);
    Ini.WriteString('contragenti', 'lang', FCli.Lang);
    Ini.WriteString('erp', 'url', FErp.Url);
    Ini.WriteString('erp', 'key', FErp.Key);
    Ini.WriteString('erp', 'client_id', FErp.ClientId);
  finally
    Ini.Free;
  end;
end;

{ ── данные ── }

procedure TMainForm.Say(Kind: TMsgKind; const Msg: string);
begin
  case Kind of
    mkOk:   begin FMsg.Color := ST_SUCCESS_BG; FMsg.Font.Color := ST_SUCCESS_FG; end;
    mkWarn: begin FMsg.Color := ST_WARNING_BG; FMsg.Font.Color := ST_WARNING_FG; end;
    mkErr:  begin FMsg.Color := ST_DANGER_BG;  FMsg.Font.Color := ST_DANGER_FG;  end;
  else      begin FMsg.Color := ST_PRIMARY_BG; FMsg.Font.Color := ST_PRIMARY_FG; end;
  end;
  FMsg.Caption := '   ' + Msg;
  FMsg.Tag := Ord(Kind);
end;

procedure TMainForm.RefreshList;
var
  Rows: TArray<TClientRow>;
  Row: TClientRow;
  Item: TListItem;
  Today: string;
begin
  Today := FormatDateTime('yyyy-mm-dd', Now);
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    Rows := FDB.List(FSearch.Text);
    for Row in Rows do
    begin
      if (FPreset.ItemIndex = 1) and not StartsText(Today, Row.AddedAt) then Continue;
      if (FPreset.ItemIndex = 2) and (Trim(Row.Adresa) = '') then Continue;
      Item := FList.Items.Add;
      Item.Caption := Row.Denumire;
      Item.Data := Pointer(Row.Id);
      Item.SubItems.Add(Row.Idno);
      Item.SubItems.Add(Row.FormaJuridica);
      Item.SubItems.Add(Row.Adresa);
      Item.SubItems.Add(Row.Administrator);
      Item.SubItems.Add(Row.AddedAt);
    end;
  finally
    FList.Items.EndUpdate;
  end;
  if FList.Items.Count = 0 then
    FPager.Caption := '0 записей'
  else
    FPager.Caption := Format('1 – %d из %d', [FList.Items.Count, FDB.Count]);
  ShowOverview(nil);
end;

procedure TMainForm.ShowOverview(Item: TListItem);
var
  I, Id: Integer;
begin
  if Item = nil then
  begin
    for I := 0 to 5 do FOvValues[I].Caption := '—';
    FOvType.ItemIndex := 0; FOvPhone.Text := ''; FOvEmail.Text := ''; FOvContact.Text := '';
    Exit;
  end;
  FOvValues[0].Caption := Item.Caption;
  for I := 1 to 5 do
    if Item.SubItems.Count >= I then
      FOvValues[I].Caption := IfThen(Trim(Item.SubItems[I - 1]) = '', '—', Item.SubItems[I - 1]);
  Id := Integer(Item.Data);
  FOvType.ItemIndex := Max(0, FOvType.Items.IndexOf(
    VarToStr(FCrm.Scalar('SELECT client_type FROM clients WHERE id = ' + IntToStr(Id)))));
  FOvPhone.Text := VarToStr(FCrm.Scalar('SELECT phone FROM clients WHERE id = ' + IntToStr(Id)));
  FOvEmail.Text := VarToStr(FCrm.Scalar('SELECT email FROM clients WHERE id = ' + IntToStr(Id)));
  FOvContact.Text := VarToStr(FCrm.Scalar('SELECT contact_person FROM clients WHERE id = ' + IntToStr(Id)));
end;

function TMainForm.SelectedId: Integer;
begin
  if FList.Selected <> nil then
    Result := Integer(FList.Selected.Data)
  else
    Result := 0;
end;

{ ── действия ── }

{ Пока открыт Contragenti, SDK зовёт это каждые 200 мс: без прокачки очереди
  сообщений окно CRM переставало перерисовываться и Windows помечала его
  «не отвечает». Заодно показываем, сколько уже ждём. }
procedure TMainForm.OnContragentiWait;
begin
  Inc(FWaitTicks);
  if FWaitTicks mod 5 = 0 then
    Say(mkWarn, Format('Открыт Contragenti — выберите контрагента в его окне…   (%d с)',
      [FWaitTicks div 5]));
  Application.ProcessMessages;
end;

{ Путь из настроек, а если его нет — известные места: рядом с программой,
  собранный exe и исходник в репозитории. }
function TMainForm.ResolveLauncher: string;
var
  C: string;
  Candidates: TArray<string>;
begin
  Result := FCli.LauncherExe;
  if TFile.Exists(Result) then Exit;
  Candidates := [
    TPath.Combine(AppDir, 'Contragenti.exe'),
    TPath.Combine(TPath.GetFullPath(TPath.Combine(AppDir, '..')), 'Contragenti.exe'),
    TPath.Combine(TPath.GetFullPath(TPath.Combine(AppDir, '..\build\exe.win-amd64-3.12')), 'Contragenti.exe'),
    TPath.Combine(TPath.GetFullPath(TPath.Combine(AppDir, '..')), 'company_search.py'),
    TPath.Combine(TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'Contragenti'), 'Contragenti.exe')];
  for C in Candidates do
    if TFile.Exists(C) then
    begin
      FCli.LauncherExe := C;
      SaveSettings;
      Exit(C);
    end;
end;

procedure TMainForm.OnAddClick(Sender: TObject);
var
  Card: TCounterpartyCard;
  NewId: Integer;
begin
  if FAdding then
  begin
    Say(mkWarn, 'Contragenti уже открыт — завершите выбор в его окне.');
    Exit;
  end;
  if FSection <> nsAccounts then
    SelectSection(nsAccounts);
  if not TFile.Exists(ResolveLauncher) then
  begin
    Say(mkErr, 'Не найден Contragenti: ' + FCli.LauncherExe + '  — укажите путь в «Настройки»');
    Exit;
  end;
  Say(mkWarn, 'Открыт Contragenti — выберите контрагента в его окне…');
  FAdding := True;
  FWaitTicks := 0;
  FCli.OnWait := OnContragentiWait;
  FBtnAdd.Enabled := False;
  try
    if FCli.Pick(Trim(FSearch.Text), Card) then
      case FDB.AddFromCard(Card, NewId) of
        arAdded:
          begin
            RefreshList;
            Say(mkOk, Format('Добавлен клиент: %s (IDNO %s)', [Card.Denumire, Card.Idno]));
          end;
        arDuplicate:
          Say(mkWarn, Format('Уже в базе: %s (IDNO %s)', [Card.Denumire, Card.Idno]));
      else
        Say(mkErr, 'Не удалось сохранить клиента.');
      end
    else
      Say(mkWarn, 'Выбор отменён: ' + FCli.LastError);
  finally
    FBtnAdd.Enabled := True;
    FCli.OnWait := nil;
    FAdding := False;
  end;
end;

procedure TMainForm.OnDeleteClick(Sender: TObject);
var
  Id: Integer;
  Name: string;
begin
  Id := SelectedId;
  if Id = 0 then
  begin
    Say(mkWarn, 'Выберите клиента в списке, затем нажмите «Удалить».');
    Exit;
  end;
  Name := FList.Selected.Caption;
  if FPendingDeleteId <> Id then
  begin
    FPendingDeleteId := Id;
    Say(mkWarn, Format('Удалить «%s»? Нажмите «Удалить» ещё раз для подтверждения.', [Name]));
    Exit;
  end;
  FPendingDeleteId := 0;
  FDB.Delete(Id);
  RefreshList;
  Say(mkOk, Format('Удалён клиент «%s».   Записей: %d', [Name, FDB.Count]));
end;

procedure TMainForm.OnRefreshClick(Sender: TObject);
begin
  FPendingDeleteId := 0;
  RefreshList;
  Say(mkInfo, 'Обновлено.   Записей: ' + IntToStr(FDB.Count));
end;

procedure TMainForm.OnSearchChange(Sender: TObject);
begin
  FPendingDeleteId := 0;
  RefreshList;
  if FSearch.Text <> '' then
    Say(mkInfo, Format('Фильтр «%s»: показано %d из %d', [FSearch.Text, FList.Items.Count, FDB.Count]));
end;

procedure TMainForm.OnGlobalSearchChange(Sender: TObject);
begin
  if FSection <> nsAccounts then
    SelectSection(nsAccounts);
  FSearch.Text := FGlobalSearch.Text;
end;

procedure TMainForm.OnPresetChange(Sender: TObject);
begin
  FPendingDeleteId := 0;
  RefreshList;
  Say(mkInfo, Format('Фильтр «%s»: показано %d из %d', [FPreset.Text, FList.Items.Count, FDB.Count]));
end;

procedure TMainForm.OnListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if Selected and (Integer(Item.Data) <> FPendingDeleteId) then
    FPendingDeleteId := 0;
  if Selected then
    ShowOverview(Item)
  else if FList.Selected = nil then
    ShowOverview(nil);
end;

procedure TMainForm.OnOverviewSave(Sender: TObject);
var
  Id: Integer;
begin
  Id := SelectedId;
  if Id = 0 then
  begin
    Say(mkWarn, 'Выберите клиента в списке.');
    Exit;
  end;
  FDB.Connection.ExecSQL(
    'UPDATE clients SET client_type = :t, phone = :p, email = :e, contact_person = :c WHERE id = :id',
    [FOvType.Text, Trim(FOvPhone.Text), Trim(FOvEmail.Text), Trim(FOvContact.Text), Id]);
  Say(mkOk, 'Карточка клиента «' + FList.Selected.Caption + '» сохранена.');
end;

procedure TMainForm.OnLeadConvert(Sender: TObject);
var
  Id, ClientId: Integer;
  Msg: string;
begin
  Id := FPages[nsLeads].SelectedId;
  if Id = 0 then
  begin
    Say(mkWarn, 'Выберите лид в списке.');
    Exit;
  end;
  Msg := FCrm.ConvertLead(Id, ClientId);
  FPages[nsLeads].Refresh;
  RefreshList;
  if ClientId > 0 then
    Say(mkOk, 'Лид конвертирован: ' + Msg)
  else
    Say(mkWarn, 'Лид не конвертирован: ' + Msg);
end;

procedure TMainForm.OnTaskDone(Sender: TObject);
var
  Id: Integer;
begin
  Id := FPages[nsCalendar].SelectedId;
  if Id = 0 then
  begin
    Say(mkWarn, 'Выберите задачу в списке.');
    Exit;
  end;
  FCrm.DB.Connection.ExecSQL('UPDATE tasks SET done = 1 WHERE id = :id', [Id]);
  FPages[nsCalendar].Cancel;
  FPages[nsCalendar].Refresh;
  Say(mkOk, 'Задача отмечена выполненной.');
end;

procedure TMainForm.OnPageChanged(Sender: TObject);
begin
  // изменения в разделах влияют на показатели «Главной» — она пересчитается при открытии
end;

procedure TMainForm.OnSettingsSave(Sender: TObject);
begin
  FCli.LauncherExe := Trim(FLauncherEdit.Text);
  FErp.Url := Trim(FErpUrlEdit.Text);
  FErp.Key := Trim(FErpKeyEdit.Text);
  SaveSettings;
  SelectSection(nsSettings);
  if TFile.Exists(FCli.LauncherExe) then
    Say(mkOk, 'Настройки сохранены: ' + FCli.LauncherExe)
  else
    Say(mkWarn, 'Сохранено, но файл не найден: ' + FCli.LauncherExe);
end;

procedure TMainForm.OnFormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caFree;
  Application.Terminate;
end;

{ ── хуки самотеста ── }

procedure TMainForm.TestShowBanner(Step: Integer; const Title: string);
begin
  FTestBanner.Caption := Format('   Шаг %.2d · %s', [Step, Title]);
  FTestBanner.Visible := True;
end;

procedure TMainForm.TestHideBanner;
begin
  FTestBanner.Visible := False;
end;

procedure TMainForm.TestSetFilter(const Text: string);
begin
  FSearch.Text := Text;
end;

procedure TMainForm.TestClickAdd;
begin
  OnAddClick(FBtnAdd);
end;

procedure TMainForm.TestClickNav(Section: TNavSection);
begin
  OnNavClick(FNavItems[Section]);
end;

function TMainForm.TestImportXml(const Xml: string; out Card: TCounterpartyCard): TAddResult;
var
  NewId: Integer;
begin
  if not FCli.ParseCardXml(Xml, Card) then
  begin
    Say(mkErr, 'Разбор XML не удался: ' + FCli.LastError);
    Exit(arError);
  end;
  Result := FDB.AddFromCard(Card, NewId);
  RefreshList;
  case Result of
    arAdded:     Say(mkOk,   Format('Добавлен клиент: %s (IDNO %s)', [Card.Denumire, Card.Idno]));
    arDuplicate: Say(mkWarn, Format('Уже в базе: %s (IDNO %s)', [Card.Denumire, Card.Idno]));
  else           Say(mkErr,  'Не удалось сохранить клиента.');
  end;
end;

function TMainForm.TestSelectFirst: Boolean;
begin
  Result := FList.Items.Count > 0;
  if Result then
  begin
    FList.Items[0].Selected := True;
    FList.Items[0].Focused := True;
    FList.Selected := FList.Items[0];
    ShowOverview(FList.Items[0]);
  end;
end;

procedure TMainForm.TestClickDelete;
begin
  OnDeleteClick(nil);
end;

procedure TMainForm.TestClickSettings;
begin
  OnNavClick(FNavItems[nsSettings]);
end;

procedure TMainForm.TestLeadConvert;
begin
  OnLeadConvert(nil);
end;

procedure TMainForm.TestTaskDone;
begin
  OnTaskDone(nil);
end;

procedure TMainForm.TestOverviewSet(const AType, Phone, Email, Contact: string);
begin
  FOvType.ItemIndex := Max(0, FOvType.Items.IndexOf(AType));
  FOvPhone.Text := Phone;
  FOvEmail.Text := Email;
  FOvContact.Text := Contact;
  OnOverviewSave(nil);
end;

function TMainForm.TestListCount: Integer;
begin
  Result := FList.Items.Count;
end;

function TMainForm.TestDbCount: Integer;
begin
  Result := FDB.Count;
end;

function TMainForm.TestMessage: string;
begin
  Result := Trim(FMsg.Caption);
end;

function TMainForm.TestMessageKind: TMsgKind;
begin
  Result := TMsgKind(FMsg.Tag);
end;

function TMainForm.TestSection: TNavSection;
begin
  Result := FSection;
end;

function TMainForm.TestWaitTicks: Integer;
begin
  Result := FWaitTicks;
end;


end.
