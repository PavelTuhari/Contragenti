unit uMainForm;
{
  Главное окно демо-CRM в стиле EspoCRM (бесплатная редакция, тема «Espo»):
  левая навигация, верхняя панель с глобальным поиском и «+», заголовок
  раздела с основной синей кнопкой, строка фильтров, белая таблица записей
  с чекбоксами, панель «Обзор» выбранной записи, дашлеты на «Главной».
  Палитра и размеры взяты из исходников EspoCRM (frontend/less/espo).

  Интерфейс строится в коде (без .dfm), чтобы проект собирался консольным
  компилятором dcc32 без участия IDE.

  Принцип интерфейса: никаких модальных окон. Все сообщения — в цветной
  строке внизу окна (зелёный — успех, янтарный — внимание, красный — ошибка),
  настройки — во встроенной панели, подтверждение удаления — повторным
  нажатием. Это удобно оператору и делает окно полностью проверяемым
  встроенным самотестом без внешней автоматизации.
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  Vcl.Graphics,
  uClientsDB, uContragenti;

type
  TMsgKind = (mkInfo, mkOk, mkWarn, mkErr);

  { Разделы левой навигации }
  TNavSection = (nsHome, nsAccounts, nsContacts, nsLeads, nsOpportunities,
    nsCalendar, nsSettings);

  TMainForm = class(TForm)
  private
    FDB: TClientsDB;
    FCli: TContragentiClient;
    FIniPath: string;
    FPendingDeleteId: Integer;
    FSection: TNavSection;

    // каркас
    FTestBanner: TPanel;
    FSidebar: TPanel;
    FSidebarLine: TPanel;
    FNavItems: array[TNavSection] of TPanel;
    FTopBar: TPanel;
    FGlobalSearch: TEdit;
    FContent: TPanel;
    FMsg: TPanel;

    // раздел «Клиенты»
    FPageAccounts: TPanel;
    FTitle: TLabel;
    FBtnAdd, FBtnDelete, FBtnRefresh: TPanel;
    FPreset: TComboBox;
    FSearch: TEdit;
    FPager: TLabel;
    FList: TListView;
    FOverview: TPanel;
    FOvValues: array[0..5] of TLabel;

    // раздел «Главная»
    FPageHome: TPanel;
    FDashCount, FDashToday, FDashLast: TLabel;

    // встроенная панель настроек
    FSettingsPanel: TPanel;
    FLauncherEdit: TEdit;

    procedure BuildUI;
    procedure BuildSidebar;
    procedure BuildTopBar;
    procedure BuildAccountsPage;
    procedure BuildHomePage;
    procedure BuildSettingsPanel;
    function  MakeButton(AParent: TWinControl; const ACaption: string;
      APrimary: Boolean; AOnClick: TNotifyEvent): TPanel;
    function  MakePanelBox(AParent: TWinControl; const ATitle: string): TPanel;
    procedure AddNavItem(Section: TNavSection; const Glyph, Title: string);
    procedure SelectSection(Section: TNavSection);
    procedure LoadSettings;
    procedure SaveSettings;
    procedure RefreshList;
    procedure RefreshHome;
    procedure ShowOverview(Item: TListItem);
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
    procedure OnFormClose(Sender: TObject; var Action: TCloseAction);
    procedure OnAppException(Sender: TObject; E: Exception);
    function SelectedId: Integer;
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
    destructor Destroy; override;

    { ── хуки для встроенного GUI-самотеста (uGuiSelfTest) ──
      Всё выполняется в процессе и без модальных диалогов, поэтому тест
      не зависит от внешней автоматизации и работает в headless-сессии. }
    procedure TestShowBanner(Step: Integer; const Title: string);
    procedure TestHideBanner;
    procedure TestSetFilter(const Text: string);
    { Реальное нажатие «Создать клиента»: запускает Contragenti через SDK. }
    procedure TestClickAdd;
    procedure TestClickNav(Section: TNavSection);
    property Client: TContragentiClient read FCli;
    function  TestImportXml(const Xml: string; out Card: TCounterpartyCard): TAddResult;
    function  TestSelectFirst: Boolean;
    procedure TestClickDelete;
    procedure TestClickSettings;
    function  TestListCount: Integer;
    function  TestDbCount: Integer;
    function  TestMessage: string;
    function  TestMessageKind: TMsgKind;
    function  TestSection: TNavSection;
  end;

var
  { Переопределение пути к базе — самотест работает в своей копии,
    не трогая рабочую clients.db. Задаётся до создания формы. }
  GDBPathOverride: string = '';

implementation

uses
  System.IOUtils, System.IniFiles, System.StrUtils, System.DateUtils, System.Math;

const
  // ── палитра EspoCRM, тема «Espo» (TColor = BGR) ──
  ESPO_BODY      = $00F5F3F1;  // #f1f3f5 фон страницы и навигации
  ESPO_BORDER    = $00E3E2E0;  // #e0e2e3 границы
  ESPO_PANEL_BRD = $00EDEAE7;  // #e7eaed граница панелей
  ESPO_WHITE     = $00FFFFFF;
  ESPO_TEXT      = $00262626;  // #262626
  ESPO_MUTED     = $00969696;  // #969696
  ESPO_GRAY      = $006A6A6A;  // #6a6a6a иконки
  ESPO_SOFT      = $00777777;  // #777 заголовки панелей
  ESPO_PRIMARY   = $00CA8955;  // #5589ca основная кнопка
  ESPO_NAV_ACT   = $00E7E1DE;  // #dee1e7 активный пункт
  ESPO_NAV_HOV   = $00EDECEC;  // #ececed
  ESPO_BTN_BG    = $00FCFCFC;  // #fcfcfc
  ESPO_BTN_BRD   = $00CCCAC2;  // #c2cacc
  ESPO_BTN_TXT   = $00585858;  // #585858
  ESPO_LINK      = $008C5B24;  // #245b8c
  ESPO_HEAD_BG   = $00F8F4EC;  // #ecf4f8 подсветка строки

  // состояния (label-state): текст / фон
  ST_PRIMARY_FG = $00CA9339;  ST_PRIMARY_BG = $00FFF3E5;   // #3993ca / #e5f3ff
  ST_SUCCESS_FG = $004C9A2A;  ST_SUCCESS_BG = $00D1EFC4;   // #2a9a4c / #c4efd1
  ST_WARNING_FG = $0022719F;  ST_WARNING_BG = $00D6F4FA;   // #9f7122 / #faf4d6
  ST_DANGER_FG  = $004648AD;  ST_DANGER_BG  = $00DEDEF2;   // #ad4846 / #f2dede

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

  FCli := TContragentiClient.Create;
  LoadSettings;

  BuildUI;
  // необработанные исключения — тоже в строку сообщений, а не в MessageBox
  Application.OnException := OnAppException;
  RefreshList;
  SelectSection(nsAccounts);
  Say(mkInfo, Format('База клиентов: %s   |   записей: %d', [FDB.DBPath, FDB.Count]));
end;

procedure TMainForm.OnAppException(Sender: TObject; E: Exception);
begin
  Say(mkErr, 'Ошибка: ' + E.Message);
end;

destructor TMainForm.Destroy;
begin
  FCli.Free;
  FDB.Free;
  inherited;
end;

{ ── строительство интерфейса ── }

function TMainForm.MakeButton(AParent: TWinControl; const ACaption: string;
  APrimary: Boolean; AOnClick: TNotifyEvent): TPanel;
begin
  // кнопки EspoCRM: 36px, btn-primary синяя без рамки, btn-default светлая
  // с рамкой. TPanel вместо TButton — VCL-кнопка не красится.
  Result := TPanel.Create(Self);
  Result.Parent := AParent;
  Result.Height := 36;
  Result.Caption := ACaption;
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.Cursor := crHandPoint;
  Result.Font.Name := 'Segoe UI';
  Result.Font.Size := 10;
  Result.Font.Style := [fsBold];
  if APrimary then
  begin
    Result.Color := ESPO_PRIMARY;
    Result.Font.Color := clWhite;
  end
  else
  begin
    Result.Color := ESPO_BTN_BG;
    Result.Font.Color := ESPO_BTN_TXT;
    Result.BevelKind := bkFlat;
  end;
  Result.OnClick := AOnClick;
end;

function TMainForm.MakePanelBox(AParent: TWinControl; const ATitle: string): TPanel;
var
  H: TLabel;
begin
  // .panel.panel-default: белый, рамка #e7eaed, заголовок 15px #777
  Result := TPanel.Create(Self);
  Result.Parent := AParent;
  Result.BevelOuter := bvNone;
  Result.BevelKind := bkFlat;
  Result.Color := ESPO_WHITE;
  Result.ParentBackground := False;
  H := TLabel.Create(Self);
  H.Parent := Result;
  H.SetBounds(14, 8, 300, 22);
  H.Caption := ATitle;
  H.Font.Name := 'Segoe UI';
  H.Font.Size := 11;
  H.Font.Style := [fsBold];
  H.Font.Color := ESPO_SOFT;
end;

procedure TMainForm.BuildUI;
begin
  Caption := 'Demo CRM · Клиенты';
  Width := 1180;
  Height := 720;
  Position := poScreenCenter;
  Color := ESPO_BODY;
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;
  OnClose := OnFormClose;

  // плашка текущего шага самотеста (скрыта в обычной работе) — над всем
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

  // строка сообщений внизу — единственный канал обратной связи
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
  BuildHomePage;
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
  P.Top := 1000;                 // в конец стопки alTop
  P.BevelOuter := bvNone;
  P.Color := ESPO_BODY;
  P.ParentBackground := False;
  P.Cursor := crHandPoint;
  P.Tag := Ord(Section);
  P.OnClick := OnNavClick;

  G := TLabel.Create(Self);      // иконка (глиф Segoe UI Symbol)
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
  Hdr, Sep: TPanel;
begin
  // #navbar: 232px, фон как у страницы, правая граница 1px #e0e2e3
  FSidebar := TPanel.Create(Self);
  FSidebar.Parent := Self;
  FSidebar.Align := alLeft;
  FSidebar.Width := NAV_WIDTH;
  FSidebar.BevelOuter := bvNone;
  FSidebar.Color := ESPO_BODY;
  FSidebar.ParentBackground := False;

  FSidebarLine := TPanel.Create(Self);
  FSidebarLine.Parent := FSidebar;
  FSidebarLine.Align := alRight;
  FSidebarLine.Width := 1;
  FSidebarLine.BevelOuter := bvNone;
  FSidebarLine.Color := ESPO_BORDER;
  FSidebarLine.ParentBackground := False;

  // шапка с логотипом, 65px
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

  AddNavItem(nsHome,          '⌂', 'Главная');
  AddNavItem(nsAccounts,      '▣', 'Клиенты');
  AddNavItem(nsContacts,      '☺', 'Контакты');
  AddNavItem(nsLeads,         '✉', 'Лиды');
  AddNavItem(nsOpportunities, '$', 'Сделки');
  AddNavItem(nsCalendar,      '▦', 'Календарь');

  Sep := TPanel.Create(Self);   // _delimiter_
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

  // «минимизатор» внизу навигации
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
  // верхняя полоса 32px: справа глобальный поиск (260px), «+», уведомления, пользователь
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
  User.Font.Color := ESPO_TEXT;

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
  Plus.OnClick := OnAddClick;   // quick create → Клиент из реестра

  FGlobalSearch := TEdit.Create(Self);
  FGlobalSearch.Parent := FTopBar;
  FGlobalSearch.SetBounds(0, 4, 260, 24);
  FGlobalSearch.Anchors := [akTop, akRight];
  FGlobalSearch.TextHint := 'Поиск…';
  FGlobalSearch.OnChange := OnGlobalSearchChange;
  FGlobalSearch.Left := FTopBar.Width - 260 - 34 - 34 - 120 - 12;
end;

procedure TMainForm.BuildAccountsPage;
var
  Col: TListColumn;
  Hdr, SearchRow, Line: TPanel;
  I, X: Integer;
  L: TLabel;
  Mag, Dots: TPanel;
begin
  FPageAccounts := TPanel.Create(Self);
  FPageAccounts.Parent := FContent;
  FPageAccounts.Align := alClient;
  FPageAccounts.BevelOuter := bvNone;
  FPageAccounts.Color := ESPO_BODY;
  FPageAccounts.ParentBackground := False;
  FPageAccounts.Padding.SetBounds(15, 12, 15, 12);

  // .page-header-row: заголовок 22px слева, кнопки справа
  Hdr := TPanel.Create(Self);
  Hdr.Parent := FPageAccounts;
  Hdr.Align := alTop;
  Hdr.Height := 48;
  Hdr.BevelOuter := bvNone;
  Hdr.Color := ESPO_BODY;
  Hdr.ParentBackground := False;

  FTitle := TLabel.Create(Self);
  FTitle.Parent := Hdr;
  FTitle.SetBounds(0, 6, 400, 30);
  FTitle.Caption := 'Клиенты';
  FTitle.Font.Size := 16;
  FTitle.Font.Color := ESPO_TEXT;

  FBtnAdd := MakeButton(Hdr, 'Создать клиента', True, OnAddClick);
  FBtnAdd.Width := 160;
  FBtnAdd.Anchors := [akTop, akRight];
  FBtnAdd.SetBounds(Hdr.Width - 160, 4, 160, 36);

  Dots := MakeButton(Hdr, '⋯', False, nil);
  Dots.Width := 36;
  Dots.Anchors := [akTop, akRight];
  Dots.SetBounds(Hdr.Width - 160 - 8 - 36, 4, 36, 36);
  Dots.Font.Name := 'Segoe UI Symbol';
  Dots.Font.Style := [];

  FBtnRefresh := MakeButton(Hdr, 'Обновить', False, OnRefreshClick);
  FBtnRefresh.Width := 100;
  FBtnRefresh.Anchors := [akTop, akRight];
  FBtnRefresh.SetBounds(Hdr.Width - 160 - 8 - 36 - 8 - 100, 4, 100, 36);
  FBtnRefresh.Font.Style := [];

  FBtnDelete := MakeButton(Hdr, 'Удалить', False, OnDeleteClick);
  FBtnDelete.Width := 100;
  FBtnDelete.Anchors := [akTop, akRight];
  FBtnDelete.SetBounds(Hdr.Width - 160 - 8 - 36 - 8 - 100 - 8 - 100, 4, 100, 36);
  FBtnDelete.Font.Style := [];

  // .search-row: пресет-фильтр, поле поиска, лупа, «⋯», справа пагинация
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

  Mag := MakeButton(SearchRow, '🔍', False, OnRefreshClick);
  Mag.SetBounds(524, 4, 36, 36);
  Mag.Font.Name := 'Segoe UI Symbol';
  Mag.Font.Style := [];

  FPager := TLabel.Create(Self);
  FPager.Parent := SearchRow;
  FPager.AutoSize := False;
  FPager.SetBounds(SearchRow.Width - 200, 12, 200, 22);
  FPager.Anchors := [akTop, akRight];
  FPager.Alignment := taRightJustify;
  FPager.Font.Color := ESPO_MUTED;

  // панель «Обзор» выбранной записи (detail view, две колонки label/value)
  FOverview := MakePanelBox(FPageAccounts, 'Обзор');
  FOverview.Align := alBottom;
  FOverview.Height := 118;
  for I := 0 to 5 do
  begin
    L := TLabel.Create(Self);
    L.Parent := FOverview;
    L.SetBounds(14 + (I mod 3) * 340, 36 + (I div 3) * 40, 300, 16);
    L.Caption := OV_LABELS[I];
    L.Font.Size := 9;
    L.Font.Color := ESPO_MUTED;
    FOvValues[I] := TLabel.Create(Self);
    FOvValues[I].Parent := FOverview;
    FOvValues[I].AutoSize := False;
    FOvValues[I].SetBounds(14 + (I mod 3) * 340, 52 + (I div 3) * 40, 330, 20);
    FOvValues[I].Font.Color := ESPO_TEXT;
    FOvValues[I].Caption := '—';
  end;

  Line := TPanel.Create(Self);   // зазор между таблицей и «Обзором»
  Line.Parent := FPageAccounts;
  Line.Align := alBottom;
  Line.Height := 14;
  Line.BevelOuter := bvNone;
  Line.Color := ESPO_BODY;
  Line.ParentBackground := False;

  // шапка таблицы — свои метки (th: 11px, разрядка, приглушённый цвет),
  // стандартный header ListView не попадает в снимок GetFormImage
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
  X := 24;   // после колонки чекбоксов
  for I := 0 to High(COL_TITLES) do
  begin
    L := TLabel.Create(Self);
    L.Parent := Hdr;
    L.SetBounds(X + 4, 8, COL_WIDTHS[I] - 8, 16);
    L.AutoSize := False;
    L.Caption := UpperCase(COL_TITLES[I]);
    L.Font.Size := 8;
    L.Font.Color := ESPO_MUTED;
    Inc(X, COL_WIDTHS[I]);
  end;

  // таблица записей: белая, чекбоксы, без сетки (как table.table)
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

procedure TMainForm.BuildHomePage;
var
  T: TLabel;
  B1, B2, B3: TPanel;
begin
  FPageHome := TPanel.Create(Self);
  FPageHome.Parent := FContent;
  FPageHome.Align := alClient;
  FPageHome.BevelOuter := bvNone;
  FPageHome.Color := ESPO_BODY;
  FPageHome.ParentBackground := False;
  FPageHome.Visible := False;

  T := TLabel.Create(Self);
  T.Parent := FPageHome;
  T.SetBounds(15, 18, 400, 30);
  T.Caption := 'Главная';
  T.Font.Size := 16;

  // дашлеты: белые панели 8px-радиуса, сетка 16px
  B1 := MakePanelBox(FPageHome, 'Клиенты в базе');
  B1.SetBounds(15, 64, 280, 120);
  FDashCount := TLabel.Create(Self);
  FDashCount.Parent := B1;
  FDashCount.SetBounds(14, 40, 250, 50);
  FDashCount.Font.Size := 26;
  FDashCount.Font.Style := [fsBold];
  FDashCount.Font.Color := ESPO_PRIMARY;

  B2 := MakePanelBox(FPageHome, 'Добавлено сегодня');
  B2.SetBounds(311, 64, 280, 120);
  FDashToday := TLabel.Create(Self);
  FDashToday.Parent := B2;
  FDashToday.SetBounds(14, 40, 250, 50);
  FDashToday.Font.Size := 26;
  FDashToday.Font.Style := [fsBold];
  FDashToday.Font.Color := ST_SUCCESS_FG;

  B3 := MakePanelBox(FPageHome, 'Последние клиенты');
  B3.SetBounds(15, 200, 576, 230);
  FDashLast := TLabel.Create(Self);
  FDashLast.Parent := B3;
  FDashLast.AutoSize := False;
  FDashLast.WordWrap := True;
  FDashLast.SetBounds(14, 38, 548, 180);
  FDashLast.Font.Color := ESPO_TEXT;

  with TLabel.Create(Self) do
  begin
    Parent := FPageHome;
    SetBounds(15, 446, 600, 64);
    AutoSize := False;
    WordWrap := True;
    Font.Color := ESPO_MUTED;
    Caption := 'Демо: разделы «Контакты», «Лиды», «Сделки» и «Календарь» показаны ' +
      'для вида навигации EspoCRM; рабочий раздел — «Клиенты» с заведением ' +
      'из государственного реестра через SDK Contragenti.';
  end;
end;

procedure TMainForm.BuildSettingsPanel;
var
  Lbl: TLabel;
  Btn: TPanel;
begin
  // встроенная панель настроек (вместо модального окна), над содержимым
  FSettingsPanel := TPanel.Create(Self);
  FSettingsPanel.Parent := FContent;
  FSettingsPanel.Align := alTop;
  FSettingsPanel.Height := 56;
  FSettingsPanel.BevelOuter := bvNone;
  FSettingsPanel.Color := ST_PRIMARY_BG;
  FSettingsPanel.ParentBackground := False;
  FSettingsPanel.Visible := False;
  Lbl := TLabel.Create(Self);
  Lbl.Parent := FSettingsPanel;
  Lbl.SetBounds(15, 18, 190, 18);
  Lbl.Caption := 'Путь к Contragenti (exe/py):';
  Lbl.Font.Color := ST_PRIMARY_FG;
  FLauncherEdit := TEdit.Create(Self);
  FLauncherEdit.Parent := FSettingsPanel;
  FLauncherEdit.SetBounds(205, 14, 560, 26);
  Btn := MakeButton(FSettingsPanel, 'Сохранить', True, OnSettingsSave);
  Btn.SetBounds(775, 10, 110, 36);
end;

{ ── навигация ── }

procedure TMainForm.SelectSection(Section: TNavSection);
var
  S: TNavSection;
begin
  for S := Low(TNavSection) to High(TNavSection) do
    if FNavItems[S] <> nil then
      if S = Section then
        FNavItems[S].Color := ESPO_NAV_ACT
      else
        FNavItems[S].Color := ESPO_BODY;

  case Section of
    nsHome:
      begin
        FSection := nsHome;
        FPageAccounts.Visible := False;
        FPageHome.Visible := True;
        RefreshHome;
        Caption := 'Demo CRM · Главная';
      end;
    nsAccounts:
      begin
        FSection := nsAccounts;
        FPageHome.Visible := False;
        FPageAccounts.Visible := True;
        Caption := 'Demo CRM · Клиенты';
      end;
    nsSettings:
      begin
        // раздел-панель: раскрывается над текущей страницей
        FSettingsPanel.Visible := not FSettingsPanel.Visible;
        if FSettingsPanel.Visible then
        begin
          FLauncherEdit.Text := FCli.LauncherExe;
          Say(mkInfo, 'Укажите путь к Contragenti.exe и нажмите «Сохранить».');
        end
        else
          for S := Low(TNavSection) to High(TNavSection) do
            if FNavItems[S] <> nil then
              FNavItems[S].Color := IfThen(S = FSection, ESPO_NAV_ACT, ESPO_BODY);
      end;
  else
    // демонстрационные разделы навигации
    for S := Low(TNavSection) to High(TNavSection) do
      if FNavItems[S] <> nil then
        FNavItems[S].Color := IfThen(S = FSection, ESPO_NAV_ACT, ESPO_BODY);
    Say(mkInfo, 'Раздел показан для вида навигации EspoCRM. Рабочий раздел демо — «Клиенты».');
  end;
end;

procedure TMainForm.OnNavClick(Sender: TObject);
begin
  FPendingDeleteId := 0;
  SelectSection(TNavSection((Sender as TComponent).Tag));
end;

{ ── настройки ── }

procedure TMainForm.LoadSettings;
var
  Ini: TIniFile;
  DefExe: string;
begin
  DefExe := TPath.Combine(AppDir, 'Contragenti.exe');
  if not TFile.Exists(DefExe) then
    DefExe := TPath.Combine(
      TPath.Combine(GetEnvironmentVariable('LOCALAPPDATA'), 'Contragenti'),
      'Contragenti.exe');
  Ini := TIniFile.Create(FIniPath);
  try
    FCli.LauncherExe := Ini.ReadString('contragenti', 'launcher', DefExe);
    FCli.Lang := Ini.ReadString('contragenti', 'lang', 'ru');
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
  finally
    Ini.Free;
  end;
end;

{ ── данные ── }

procedure TMainForm.Say(Kind: TMsgKind; const Msg: string);
begin
  // цвета label-state EspoCRM: primary / success / warning / danger
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
      // пресет-фильтры («Все» — без ограничений)
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

procedure TMainForm.RefreshHome;
var
  Rows: TArray<TClientRow>;
  I, N, TodayN: Integer;
  Today, S: string;
begin
  Rows := FDB.List('');
  Today := FormatDateTime('yyyy-mm-dd', Now);
  TodayN := 0;
  for I := 0 to High(Rows) do
    if StartsText(Today, Rows[I].AddedAt) then Inc(TodayN);
  FDashCount.Caption := IntToStr(Length(Rows));
  FDashToday.Caption := IntToStr(TodayN);
  S := '';
  N := 0;
  for I := 0 to High(Rows) do
  begin
    S := S + '• ' + Rows[I].Denumire + '   (' + Rows[I].Idno + ')' + sLineBreak;
    Inc(N);
    if N >= 6 then Break;
  end;
  if S = '' then S := 'Пока нет ни одного клиента — нажмите «Создать клиента» в разделе «Клиенты».';
  FDashLast.Caption := S;
end;

procedure TMainForm.ShowOverview(Item: TListItem);
var
  I: Integer;
begin
  if Item = nil then
  begin
    for I := 0 to 5 do FOvValues[I].Caption := '—';
    Exit;
  end;
  FOvValues[0].Caption := Item.Caption;
  for I := 1 to 5 do
    if Item.SubItems.Count >= I then
      FOvValues[I].Caption := IfThen(Trim(Item.SubItems[I - 1]) = '', '—', Item.SubItems[I - 1]);
end;

function TMainForm.SelectedId: Integer;
begin
  if FList.Selected <> nil then
    Result := Integer(FList.Selected.Data)
  else
    Result := 0;
end;

{ ── действия ── }

procedure TMainForm.OnAddClick(Sender: TObject);
var
  Card: TCounterpartyCard;
  NewId: Integer;
begin
  if FSection <> nsAccounts then
    SelectSection(nsAccounts);
  if not TFile.Exists(FCli.LauncherExe) then
  begin
    Say(mkErr, 'Не найден Contragenti: ' + FCli.LauncherExe +
      '  — укажите путь в «Настройки»');
    Exit;
  end;
  // начальный фильтр берём из поля поиска — никаких запросов во всплывающих окнах
  Say(mkWarn, 'Открыт Contragenti — выберите контрагента в его окне…');
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
  // подтверждение — повторным нажатием, без модального окна
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
    Say(mkInfo, Format('Фильтр «%s»: показано %d из %d',
      [FSearch.Text, FList.Items.Count, FDB.Count]));
end;

procedure TMainForm.OnGlobalSearchChange(Sender: TObject);
begin
  // глобальный поиск верхней панели ведёт в «Клиенты» с тем же фильтром
  if FSection <> nsAccounts then
    SelectSection(nsAccounts);
  FSearch.Text := FGlobalSearch.Text;
end;

procedure TMainForm.OnPresetChange(Sender: TObject);
begin
  FPendingDeleteId := 0;
  RefreshList;
  Say(mkInfo, Format('Фильтр «%s»: показано %d из %d',
    [FPreset.Text, FList.Items.Count, FDB.Count]));
end;

procedure TMainForm.OnListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  // смена выделения снимает незавершённое подтверждение удаления
  if Selected and (Integer(Item.Data) <> FPendingDeleteId) then
    FPendingDeleteId := 0;
  if Selected then
    ShowOverview(Item)
  else if FList.Selected = nil then
    ShowOverview(nil);
end;

procedure TMainForm.OnSettingsSave(Sender: TObject);
begin
  FCli.LauncherExe := Trim(FLauncherEdit.Text);
  SaveSettings;
  SelectSection(nsSettings);   // скрыть панель
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
  FSearch.Text := Text;   // OnChange обновит список и сообщение
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

end.
