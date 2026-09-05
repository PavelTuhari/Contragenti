unit uEntityPage;
{
  Универсальная страница раздела CRM: заголовок с кнопками, строка фильтра,
  таблица записей и встроенный редактор (панель внутри страницы, без
  модальных окон). Строится из TEntityDef (uCrmData): поля → колонки списка
  и элементы редактора.

  Для заказов дополнительно показывает строки заказа с итогом и кнопку
  «Провести» (списание/оприходование остатков номенклатуры).
}

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Generics.Collections,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  uCrmData, uEspoTheme;

type
  TEntityPage = class(TPanel)
  private
    FData: TCrmData;
    FDef: TEntityDef;
    FRows: TArray<TRow>;
    FOnSay: TSayProc;
    FOnChanged: TNotifyEvent;

    FHeader: TPanel;
    FTitle: TLabel;
    FBtnNew, FBtnDelete, FBtnRefresh: TPanel;
    FExtraBtns: TArray<TPanel>;
    FSearchRow: TPanel;
    FPreset: TComboBox;
    FPresetWheres: TArray<string>;
    FSearch: TEdit;
    FPager: TLabel;
    FColHeader: TPanel;
    FList: TListView;

    FEditor: TPanel;
    FEditTitle: TLabel;
    FCtrls: TArray<TControl>;
    FLookupIds: TArray<TArray<Integer>>;
    FEditingId: Integer;
    FPendingDeleteId: Integer;

    // строки заказа
    FLines: TPanel;
    FLinesList: TListView;
    FLineItem: TComboBox;
    FLineItemIds: TArray<Integer>;
    FLineQty, FLinePrice: TEdit;
    FLinesTotal: TLabel;
    FPendingLineDelete: Integer;

    procedure Say(Kind: TMsgKind; const Msg: string);
    procedure LayoutHeader;
    procedure OnHeaderResize(Sender: TObject);
    procedure BuildHeader;
    procedure BuildSearchRow;
    procedure BuildList;
    procedure BuildEditor;
    procedure BuildLines;
    function  ExtraWhere: string;
    procedure FillLookups;
    procedure ShowEditor(Id: Integer);
    procedure LoadLines;

    procedure OnNewClick(Sender: TObject);
    procedure OnDeleteClick(Sender: TObject);
    procedure OnRefreshClick(Sender: TObject);
    procedure OnSearchChange(Sender: TObject);
    procedure OnSaveClick(Sender: TObject);
    procedure OnCancelClick(Sender: TObject);
    procedure OnListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure OnListDblClick(Sender: TObject);
    procedure OnLineAdd(Sender: TObject);
    procedure OnLineDelete(Sender: TObject);
    procedure OnLineItemChange(Sender: TObject);
    procedure OnPostOrder(Sender: TObject);
  public
    { AParent обязателен: элементы (TComboBox.Items) требуют оконный handle,
      а он есть только у контролов с цепочкой родителей до формы. }
    constructor Create(AOwner: TComponent; AParent: TWinControl; AData: TCrmData;
      const ADef: TEntityDef; ASay: TSayProc); reintroduce;

    procedure Refresh;
    procedure SetFilter(const Text: string);
    procedure SetPresets(const Names, Wheres: TArray<string>);
    function  AddExtraButton(const Caption: string; OnClick: TNotifyEvent;
      Primary: Boolean = False; Width: Integer = 130): TPanel;

    // действия — они же хуки самотеста
    procedure NewRecord;
    procedure EditSelected;
    procedure SetField(const FieldName, Value: string);
    function  GetField(const FieldName: string): string;
    procedure Save;
    procedure Cancel;
    procedure DeleteSelected;
    function  SelectFirst: Boolean;
    function  SelectById(Id: Integer): Boolean;
    function  SelectedId: Integer;
    function  ListCount: Integer;
    function  EditorVisible: Boolean;
    // строки заказа
    procedure LineSet(ItemIndex: Integer; Qty, Price: Double);
    function  LineItemIndex(const NamePart: string): Integer;
    procedure SelectPreset(Index: Integer);
    procedure LineAdd;
    procedure PostOrder;
    function  LinesCount: Integer;
    function  LinesTotal: Double;

    property Def: TEntityDef read FDef;
    property Data: TCrmData read FData;
    property List: TListView read FList;
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

uses
  System.StrUtils, System.Math;

{ TEntityPage }

constructor TEntityPage.Create(AOwner: TComponent; AParent: TWinControl;
  AData: TCrmData; const ADef: TEntityDef; ASay: TSayProc);
begin
  inherited Create(AOwner);
  Parent := AParent;
  Align := alClient;
  Visible := False;
  FData := AData;
  FDef := ADef;
  FOnSay := ASay;
  FEditingId := -1;
  BevelOuter := bvNone;
  Color := ESPO_BODY;
  ParentBackground := False;
  Padding.SetBounds(15, 12, 15, 12);
  Font.Name := 'Segoe UI';
  Font.Size := 10;
  Font.Color := ESPO_TEXT;

  BuildHeader;
  BuildSearchRow;
  BuildEditor;
  if FDef.Table = 'orders' then
    BuildLines;
  BuildList;
end;

procedure TEntityPage.Say(Kind: TMsgKind; const Msg: string);
begin
  if Assigned(FOnSay) then FOnSay(Kind, Msg);
end;

procedure TEntityPage.BuildHeader;
begin
  FHeader := TPanel.Create(Self);
  FHeader.Parent := Self;
  FHeader.Align := alTop;
  FHeader.Height := 48;
  FHeader.BevelOuter := bvNone;
  FHeader.Color := ESPO_BODY;
  FHeader.ParentBackground := False;

  FTitle := TLabel.Create(Self);
  FTitle.Parent := FHeader;
  FTitle.SetBounds(0, 6, 400, 30);
  FTitle.Caption := FDef.Title;
  FTitle.Font.Size := 16;
  FTitle.Font.Color := ESPO_TEXT;

  FBtnNew := MakeButton(Self, FHeader, 'Создать ' + FDef.TitleOne, True, OnNewClick, 170);
  FBtnRefresh := MakeButton(Self, FHeader, 'Обновить', False, OnRefreshClick, 100);
  FBtnDelete := MakeButton(Self, FHeader, 'Удалить', False, OnDeleteClick, 100);
  FExtraBtns := nil;
  // Кнопки раскладываются справа налево при каждом изменении ширины шапки:
  // якоря ненадёжны, пока невидимая страница ещё не разложена.
  FHeader.OnResize := OnHeaderResize;
  LayoutHeader;
end;

procedure TEntityPage.LayoutHeader;
var
  X, I: Integer;
begin
  X := FHeader.Width;
  Dec(X, FBtnNew.Width);     FBtnNew.SetBounds(X, 4, FBtnNew.Width, 36);
  Dec(X, 8 + FBtnRefresh.Width); FBtnRefresh.SetBounds(X, 4, FBtnRefresh.Width, 36);
  Dec(X, 8 + FBtnDelete.Width);  FBtnDelete.SetBounds(X, 4, FBtnDelete.Width, 36);
  for I := 0 to High(FExtraBtns) do
  begin
    Dec(X, 8 + FExtraBtns[I].Width);
    FExtraBtns[I].SetBounds(X, 4, FExtraBtns[I].Width, 36);
  end;
end;

procedure TEntityPage.OnHeaderResize(Sender: TObject);
begin
  LayoutHeader;
end;

function TEntityPage.AddExtraButton(const Caption: string; OnClick: TNotifyEvent;
  Primary: Boolean; Width: Integer): TPanel;
begin
  Result := MakeButton(Self, FHeader, Caption, Primary, OnClick, Width);
  FExtraBtns := FExtraBtns + [Result];
  LayoutHeader;
end;

procedure TEntityPage.BuildSearchRow;
begin
  FSearchRow := TPanel.Create(Self);
  FSearchRow.Parent := Self;
  FSearchRow.Align := alTop;
  FSearchRow.Top := 60;
  FSearchRow.Height := 48;
  FSearchRow.BevelOuter := bvNone;
  FSearchRow.Color := ESPO_BODY;
  FSearchRow.ParentBackground := False;

  FPreset := TComboBox.Create(Self);
  FPreset.Parent := FSearchRow;
  FPreset.Style := csDropDownList;
  FPreset.SetBounds(0, 8, 190, 28);
  FPreset.Items.Add('Все');
  FPreset.ItemIndex := 0;
  FPreset.OnChange := OnSearchChange;
  FPresetWheres := [''];

  FSearch := TEdit.Create(Self);
  FSearch.Parent := FSearchRow;
  FSearch.SetBounds(198, 8, 320, 28);
  FSearch.TextHint := 'Поиск…';
  FSearch.OnChange := OnSearchChange;

  FPager := TLabel.Create(Self);
  FPager.Parent := FSearchRow;
  FPager.AutoSize := False;
  FPager.SetBounds(FSearchRow.Width - 200, 12, 200, 22);
  FPager.Anchors := [akTop, akRight];
  FPager.Alignment := taRightJustify;
  FPager.Font.Color := ESPO_MUTED;
end;

procedure TEntityPage.SetPresets(const Names, Wheres: TArray<string>);
var
  S: string;
begin
  FPreset.Items.Clear;
  for S in Names do FPreset.Items.Add(S);
  FPresetWheres := Wheres;
  FPreset.ItemIndex := 0;
end;

function TEntityPage.ExtraWhere: string;
begin
  if (FPreset.ItemIndex >= 0) and (FPreset.ItemIndex <= High(FPresetWheres)) then
    Result := FPresetWheres[FPreset.ItemIndex]
  else
    Result := '';
end;

procedure TEntityPage.BuildList;
var
  I, X: Integer;
  L: TLabel;
  Col: TListColumn;
begin
  FColHeader := TPanel.Create(Self);
  FColHeader.Parent := Self;
  FColHeader.Align := alTop;
  FColHeader.Top := 200;
  FColHeader.Height := 30;
  FColHeader.BevelOuter := bvNone;
  FColHeader.Color := ESPO_WHITE;
  FColHeader.ParentBackground := False;
  with TPanel.Create(Self) do
  begin
    Parent := FColHeader; Align := alBottom; Height := 1;
    BevelOuter := bvNone; Color := ESPO_BORDER; ParentBackground := False;
  end;
  X := 6;
  for I := 0 to High(FDef.Fields) do
    if FDef.Fields[I].ListWidth > 0 then
    begin
      L := MakeLabel(Self, FColHeader, UpperCase(FDef.Fields[I].Caption), X + 4, 8,
        FDef.Fields[I].ListWidth - 8, ESPO_MUTED, 8);
      Inc(X, FDef.Fields[I].ListWidth);
    end;

  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.GridLines := False;
  FList.HideSelection := False;
  FList.ShowColumnHeaders := False;
  FList.BorderStyle := bsNone;
  FList.Color := ESPO_WHITE;
  FList.Font.Color := ESPO_TEXT;
  FList.OnSelectItem := OnListSelect;
  FList.OnDblClick := OnListDblClick;
  for I := 0 to High(FDef.Fields) do
    if FDef.Fields[I].ListWidth > 0 then
    begin
      Col := FList.Columns.Add;
      Col.Caption := FDef.Fields[I].Caption;
      Col.Width := FDef.Fields[I].ListWidth;
    end;
end;

procedure TEntityPage.BuildEditor;
var
  I, Col, RowN, X, Y, W: Integer;
  F: TFieldDef;
  E: TEdit;
  M: TMemo;
  Cb: TComboBox;
  Ck: TCheckBox;
  Btn: TPanel;
  MemoIdx: Integer;
begin
  // редактор внизу страницы: три колонки полей, memo на всю ширину
  FEditor := MakePanelBox(Self, Self, '');
  FEditor.Align := alBottom;
  FEditor.Visible := False;

  FEditTitle := TLabel.Create(Self);
  FEditTitle.Parent := FEditor;
  FEditTitle.SetBounds(14, 8, 500, 22);
  FEditTitle.Font.Size := 11;
  FEditTitle.Font.Style := [fsBold];
  FEditTitle.Font.Color := ESPO_SOFT;

  SetLength(FCtrls, Length(FDef.Fields));
  SetLength(FLookupIds, Length(FDef.Fields));
  Col := 0; RowN := 0; MemoIdx := -1;
  W := 300;
  for I := 0 to High(FDef.Fields) do
  begin
    F := FDef.Fields[I];
    if F.Kind = fkMemo then
    begin
      MemoIdx := I;
      Continue;
    end;
    X := 14 + Col * (W + 20);
    Y := 36 + RowN * 52;
    MakeLabel(Self, FEditor, F.Caption + IfThen(F.Required, ' *', ''), X, Y, W);
    case F.Kind of
      fkEnum, fkLookupClient, fkLookupDeal, fkLookupItem:
        begin
          Cb := TComboBox.Create(Self);
          Cb.Parent := FEditor;
          Cb.Style := csDropDownList;
          Cb.SetBounds(X, Y + 18, W, 26);
          // показываем перевод, а в базу пишем каноническое значение по позиции
          if F.Kind = fkEnum then
            Cb.Items.AddStrings(EnumDisplayList(F.EnumName, F.Enum));
          FCtrls[I] := Cb;
        end;
      fkBool:
        begin
          Ck := TCheckBox.Create(Self);
          Ck.Parent := FEditor;
          Ck.SetBounds(X, Y + 20, W, 22);
          Ck.Caption := 'Да';
          FCtrls[I] := Ck;
        end;
    else
      E := TEdit.Create(Self);
      E.Parent := FEditor;
      E.SetBounds(X, Y + 18, W, 26);
      E.ReadOnly := F.Kind = fkReadOnly;
      if F.Kind = fkDate then E.TextHint := 'ГГГГ-ММ-ДД';
      FCtrls[I] := E;
    end;
    Inc(Col);
    if Col = 3 then begin Col := 0; Inc(RowN); end;
  end;
  if Col > 0 then Inc(RowN);
  Y := 36 + RowN * 52;
  if MemoIdx >= 0 then
  begin
    MakeLabel(Self, FEditor, FDef.Fields[MemoIdx].Caption, 14, Y, 300);
    M := TMemo.Create(Self);
    M.Parent := FEditor;
    M.SetBounds(14, Y + 18, 3 * W + 40, 54);
    M.ScrollBars := ssVertical;
    FCtrls[MemoIdx] := M;
    Y := Y + 18 + 54 + 10;
  end;
  Btn := MakeButton(Self, FEditor, 'Сохранить', True, OnSaveClick, 120);
  Btn.SetBounds(14, Y, 120, 36);
  Btn := MakeButton(Self, FEditor, 'Отмена', False, OnCancelClick, 100);
  Btn.SetBounds(142, Y, 100, 36);
  FEditor.Height := Y + 36 + 14;
end;

procedure TEntityPage.BuildLines;
var
  Col: TListColumn;
  Btn: TPanel;
begin
  // панель строк заказа — над редактором (alBottom, создаётся после него,
  // поэтому оказывается выше)
  FLines := MakePanelBox(Self, Self, 'Строки заказа');
  FLines.Align := alBottom;
  FLines.Height := 190;
  FLines.Visible := False;

  FLinesList := TListView.Create(Self);
  FLinesList.Parent := FLines;
  FLinesList.SetBounds(14, 34, 640, 100);
  FLinesList.Anchors := [akLeft, akTop, akRight];
  FLinesList.ViewStyle := vsReport;
  FLinesList.ReadOnly := True;
  FLinesList.RowSelect := True;
  FLinesList.HideSelection := False;
  FLinesList.BorderStyle := bsNone;
  FLinesList.Color := ESPO_HEAD_BG;
  Col := FLinesList.Columns.Add; Col.Caption := 'Позиция';  Col.Width := 300;
  Col := FLinesList.Columns.Add; Col.Caption := 'Ед.';      Col.Width := 50;
  Col := FLinesList.Columns.Add; Col.Caption := 'Кол-во';   Col.Width := 80;
  Col := FLinesList.Columns.Add; Col.Caption := 'Цена';     Col.Width := 90;
  Col := FLinesList.Columns.Add; Col.Caption := 'Сумма';    Col.Width := 100;

  MakeLabel(Self, FLines, 'Позиция', 14, 140, 300);
  FLineItem := TComboBox.Create(Self);
  FLineItem.Parent := FLines;
  FLineItem.Style := csDropDownList;
  FLineItem.SetBounds(14, 158, 300, 26);
  FLineItem.OnChange := OnLineItemChange;
  MakeLabel(Self, FLines, 'Кол-во', 324, 140, 80);
  FLineQty := TEdit.Create(Self);
  FLineQty.Parent := FLines;
  FLineQty.SetBounds(324, 158, 80, 26);
  FLineQty.Text := '1';
  MakeLabel(Self, FLines, 'Цена', 414, 140, 100);
  FLinePrice := TEdit.Create(Self);
  FLinePrice.Parent := FLines;
  FLinePrice.SetBounds(414, 158, 100, 26);
  Btn := MakeButton(Self, FLines, '+ Строка', True, OnLineAdd, 100);
  Btn.SetBounds(524, 152, 100, 32);
  Btn := MakeButton(Self, FLines, 'Убрать строку', False, OnLineDelete, 130);
  Btn.SetBounds(632, 152, 130, 32);
  Btn := MakeButton(Self, FLines, 'Провести', False, OnPostOrder, 110);
  Btn.SetBounds(770, 152, 110, 32);

  FLinesTotal := MakeLabel(Self, FLines, 'Итого: 0.00 MDL', 670, 34, 240, ESPO_TEXT, 11);
  FLinesTotal.Anchors := [akTop, akRight];
  FLinesTotal.Alignment := taRightJustify;
  FLinesTotal.Font.Style := [fsBold];
end;

procedure TEntityPage.FillLookups;
var
  I, J: Integer;
  Pairs: TArray<TPair<Integer, string>>;
  Cb: TComboBox;
begin
  for I := 0 to High(FDef.Fields) do
    if FDef.Fields[I].Kind in [fkLookupClient, fkLookupDeal, fkLookupItem] then
    begin
      Cb := FCtrls[I] as TComboBox;
      Cb.Items.Clear;
      Cb.Items.Add('—');
      Pairs := FData.LookupPairs(FDef.Fields[I].Kind);
      SetLength(FLookupIds[I], Length(Pairs) + 1);
      FLookupIds[I][0] := 0;
      for J := 0 to High(Pairs) do
      begin
        Cb.Items.Add(Pairs[J].Value);
        FLookupIds[I][J + 1] := Pairs[J].Key;
      end;
    end;
  if FDef.Table = 'orders' then
  begin
    FLineItem.Items.Clear;
    Pairs := FData.LookupPairs(fkLookupItem);
    SetLength(FLineItemIds, Length(Pairs));
    for J := 0 to High(Pairs) do
    begin
      FLineItem.Items.Add(Pairs[J].Value);
      FLineItemIds[J] := Pairs[J].Key;
    end;
  end;
end;

procedure TEntityPage.Refresh;
var
  R: TRow;
  I: Integer;
  Item: TListItem;
  First: Boolean;
begin
  FRows := FData.List(FDef, FSearch.Text, ExtraWhere);
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for R in FRows do
    begin
      Item := FList.Items.Add;
      Item.Data := Pointer(R.Id);
      First := True;
      for I := 0 to High(FDef.Fields) do
        if FDef.Fields[I].ListWidth > 0 then
          if First then
          begin
            Item.Caption := R.Display[I];
            First := False;
          end
          else
            Item.SubItems.Add(R.Display[I]);
    end;
  finally
    FList.Items.EndUpdate;
  end;
  if Length(FRows) = 0 then
    FPager.Caption := '0 записей'
  else
    FPager.Caption := Format('1 – %d из %d', [Length(FRows), FData.Count(FDef.Table)]);
end;

procedure TEntityPage.SetFilter(const Text: string);
begin
  FSearch.Text := Text;
end;

procedure TEntityPage.ShowEditor(Id: Integer);
var
  Row: TRow;
  I, J: Integer;
  F: TFieldDef;
  V: string;
begin
  FillLookups;
  FEditingId := Id;
  if Id > 0 then
  begin
    if not FData.Get(FDef, Id, Row) then Exit;
    FEditTitle.Caption := 'Изменить ' + FDef.TitleOne;
  end
  else
    FEditTitle.Caption := 'Новая запись: ' + FDef.TitleOne;

  for I := 0 to High(FDef.Fields) do
  begin
    F := FDef.Fields[I];
    // Дата подставляется только там, где объявлена по умолчанию («today»,
    // «today+N»). Иначе новый заказ получал бы дату отгрузки сегодняшним
    // числом и сразу считался отгруженным.
    if Id > 0 then V := Row.Values[I] else V := ResolveDefault(F.Default);
    case F.Kind of
      fkEnum:
        (FCtrls[I] as TComboBox).ItemIndex := Max(0, IndexStr(V, F.Enum.Split([';'])));
      fkLookupClient, fkLookupDeal, fkLookupItem:
        begin
          (FCtrls[I] as TComboBox).ItemIndex := 0;
          for J := 0 to High(FLookupIds[I]) do
            if IntToStr(FLookupIds[I][J]) = V then
              (FCtrls[I] as TComboBox).ItemIndex := J;
        end;
      fkBool: (FCtrls[I] as TCheckBox).Checked := V = '1';
      fkMemo: (FCtrls[I] as TMemo).Text := V;
    else
      (FCtrls[I] as TEdit).Text := V;
    end;
  end;
  FEditor.Visible := True;
  if FDef.Table = 'orders' then
  begin
    FLines.Visible := Id > 0;   // строки — только у сохранённого заказа
    if Id > 0 then LoadLines;
  end;
end;

procedure TEntityPage.LoadLines;
var
  L: TOrderLine;
  Item: TListItem;
  I: Integer;
begin
  FLinesList.Items.BeginUpdate;
  try
    FLinesList.Items.Clear;
    for L in FData.OrderLines(FEditingId) do
    begin
      Item := FLinesList.Items.Add;
      Item.Caption := L.ItemName;
      Item.Data := Pointer(L.Id);
      Item.SubItems.Add(L.Unit_);
      Item.SubItems.Add(FormatFloat('0.##', L.Qty));
      Item.SubItems.Add(FormatFloat('0.00', L.Price));
      Item.SubItems.Add(FormatFloat('0.00', L.Sum));
    end;
  finally
    FLinesList.Items.EndUpdate;
  end;
  FLinesTotal.Caption := Format('Итого: %s MDL', [FormatFloat('#,##0.00', LinesTotal)]);
  // обновить колонку «Итого» в редакторе
  for I := 0 to High(FDef.Fields) do
    if FDef.Fields[I].Kind = fkReadOnly then
      (FCtrls[I] as TEdit).Text := FormatFloat('0.00', LinesTotal);
end;

{ ── действия ── }

procedure TEntityPage.NewRecord;
begin
  FPendingDeleteId := 0;
  ShowEditor(0);
  Say(mkInfo, 'Заполните поля и нажмите «Сохранить».');
end;

procedure TEntityPage.EditSelected;
begin
  if SelectedId = 0 then
  begin
    Say(mkWarn, 'Выберите запись в списке.');
    Exit;
  end;
  ShowEditor(SelectedId);
end;

procedure TEntityPage.SetField(const FieldName, Value: string);
var
  I, J: Integer;
begin
  for I := 0 to High(FDef.Fields) do
    if SameText(FDef.Fields[I].Name, FieldName) then
      case FDef.Fields[I].Kind of
        fkEnum:
          // принимаем каноническое значение — оно же лежит в базе
          (FCtrls[I] as TComboBox).ItemIndex :=
            IndexStr(Value, FDef.Fields[I].Enum.Split([';']));
        fkLookupClient, fkLookupDeal, fkLookupItem:
          begin
            // значение — id или отображаемое имя
            J := (FCtrls[I] as TComboBox).Items.IndexOf(Value);
            if J < 0 then
              for J := High(FLookupIds[I]) downto 0 do
                if IntToStr(FLookupIds[I][J]) = Value then Break;
            (FCtrls[I] as TComboBox).ItemIndex := Max(0, J);
          end;
        fkBool: (FCtrls[I] as TCheckBox).Checked := (Value = '1') or SameText(Value, 'true');
        fkMemo: (FCtrls[I] as TMemo).Text := Value;
      else
        (FCtrls[I] as TEdit).Text := Value;
      end;
end;

function TEntityPage.GetField(const FieldName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FDef.Fields) do
    if SameText(FDef.Fields[I].Name, FieldName) then
      case FDef.Fields[I].Kind of
        fkEnum:
          // из показанного перевода возвращаем каноническое значение
          if (FCtrls[I] as TComboBox).ItemIndex >= 0 then
            Result := FDef.Fields[I].Enum.Split([';'])[(FCtrls[I] as TComboBox).ItemIndex];
        fkLookupClient, fkLookupDeal, fkLookupItem:
          if (FCtrls[I] as TComboBox).ItemIndex > 0 then
            Result := IntToStr(FLookupIds[I][(FCtrls[I] as TComboBox).ItemIndex]);
        fkBool: Result := IfThen((FCtrls[I] as TCheckBox).Checked, '1', '0');
        fkMemo: Result := (FCtrls[I] as TMemo).Text;
      else
        Result := (FCtrls[I] as TEdit).Text;
      end;
end;

procedure TEntityPage.Save;
var
  I: Integer;
  Values: TArray<string>;
  V: string;
  NewId: Integer;
begin
  if not FEditor.Visible then Exit;
  SetLength(Values, Length(FDef.Fields));
  for I := 0 to High(FDef.Fields) do
  begin
    V := Trim(GetField(FDef.Fields[I].Name));
    if FDef.Fields[I].Required and (V = '') then
    begin
      Say(mkErr, 'Не заполнено обязательное поле «' + FDef.Fields[I].Caption + '».');
      Exit;
    end;
    if (FDef.Fields[I].Kind in [fkNumber, fkMoney]) and (V <> '') then
    begin
      V := StringReplace(V, ',', '.', [rfReplaceAll]);
      if StrToFloatDef(V, -1e300) = -1e300 then
      begin
        Say(mkErr, 'Поле «' + FDef.Fields[I].Caption + '» должно быть числом.');
        Exit;
      end;
    end;
    Values[I] := V;
  end;
  if FEditingId > 0 then
  begin
    FData.Update(FDef, FEditingId, Values);
    Say(mkOk, 'Сохранено: ' + FDef.TitleOne + ' «' + Values[0] + '».');
    NewId := FEditingId;
  end
  else
  begin
    NewId := FData.Insert(FDef, Values);
    Say(mkOk, 'Добавлено: ' + FDef.TitleOne + ' «' + Values[0] + '».');
  end;
  Refresh;
  SelectById(NewId);
  if FDef.Table = 'orders' then
    ShowEditor(NewId)      // остаться в заказе — теперь доступны строки
  else
    FEditor.Visible := False;
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

procedure TEntityPage.Cancel;
begin
  FEditor.Visible := False;
  if FLines <> nil then FLines.Visible := False;
  FEditingId := -1;
end;

procedure TEntityPage.DeleteSelected;
var
  Id: Integer;
  Name: string;
begin
  Id := SelectedId;
  if Id = 0 then
  begin
    Say(mkWarn, 'Выберите запись в списке, затем нажмите «Удалить».');
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
  FData.Delete(FDef, Id);
  Cancel;
  Refresh;
  Say(mkOk, Format('Удалено: «%s».', [Name]));
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

function TEntityPage.SelectFirst: Boolean;
begin
  Result := FList.Items.Count > 0;
  if Result then
  begin
    FList.Items[0].Selected := True;
    FList.Items[0].Focused := True;
    FList.Selected := FList.Items[0];
  end;
end;

function TEntityPage.SelectById(Id: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FList.Items.Count - 1 do
    if Integer(FList.Items[I].Data) = Id then
    begin
      FList.Items[I].Selected := True;
      FList.Selected := FList.Items[I];
      Exit(True);
    end;
end;

function TEntityPage.SelectedId: Integer;
begin
  if FList.Selected <> nil then
    Result := Integer(FList.Selected.Data)
  else
    Result := 0;
end;

function TEntityPage.ListCount: Integer;
begin
  Result := FList.Items.Count;
end;

function TEntityPage.EditorVisible: Boolean;
begin
  Result := FEditor.Visible;
end;

{ ── строки заказа ── }

procedure TEntityPage.LineSet(ItemIndex: Integer; Qty, Price: Double);
begin
  FLineItem.ItemIndex := ItemIndex;
  FLineQty.Text := FormatFloat('0.##', Qty);
  FLinePrice.Text := FormatFloat('0.00', Price);
end;

function TEntityPage.LineItemIndex(const NamePart: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to FLineItem.Items.Count - 1 do
    if ContainsText(FLineItem.Items[I], NamePart) then Exit(I);
end;

procedure TEntityPage.SelectPreset(Index: Integer);
begin
  FPreset.ItemIndex := Index;
  OnSearchChange(FPreset);
end;

procedure TEntityPage.LineAdd;
var
  Qty, Price: Double;
begin
  if FEditingId <= 0 then
  begin
    Say(mkWarn, 'Сначала сохраните заказ, потом добавляйте строки.');
    Exit;
  end;
  if FLineItem.ItemIndex < 0 then
  begin
    Say(mkWarn, 'Выберите позицию номенклатуры.');
    Exit;
  end;
  Qty := StrToFloatDef(StringReplace(FLineQty.Text, ',', '.', []), 0);
  Price := StrToFloatDef(StringReplace(FLinePrice.Text, ',', '.', []), 0);
  if Qty <= 0 then
  begin
    Say(mkErr, 'Количество должно быть больше нуля.');
    Exit;
  end;
  FData.AddOrderLine(FEditingId, FLineItemIds[FLineItem.ItemIndex], Qty, Price);
  LoadLines;
  Refresh;
  SelectById(FEditingId);
  Say(mkOk, Format('Строка добавлена. Итого по заказу: %s MDL', [FormatFloat('#,##0.00', LinesTotal)]));
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

procedure TEntityPage.PostOrder;
var
  Msg: string;
begin
  if FEditingId <= 0 then
  begin
    Say(mkWarn, 'Откройте сохранённый заказ.');
    Exit;
  end;
  // проводка использует статус из базы — сначала сохраняем редактор
  Save;
  Msg := FData.PostOrder(FEditingId);
  if (Pos('списано', Msg) = 1) or (Pos('оприходовано', Msg) = 1) or (Pos('услуги', Msg) = 1) then
    Say(mkOk, 'Заказ проведён: ' + Msg)
  else
    Say(mkWarn, 'Заказ не проведён: ' + Msg);
  if Assigned(FOnChanged) then FOnChanged(Self);
end;

function TEntityPage.LinesCount: Integer;
begin
  if FLinesList = nil then Exit(0);
  Result := FLinesList.Items.Count;
end;

function TEntityPage.LinesTotal: Double;
begin
  if FEditingId <= 0 then Exit(0);
  Result := FData.Scalar('SELECT COALESCE(SUM(sum),0) FROM order_lines WHERE order_id = ' + IntToStr(FEditingId));
end;

{ ── обработчики ── }

procedure TEntityPage.OnNewClick(Sender: TObject);
begin
  NewRecord;
end;

procedure TEntityPage.OnDeleteClick(Sender: TObject);
begin
  DeleteSelected;
end;

procedure TEntityPage.OnRefreshClick(Sender: TObject);
begin
  FPendingDeleteId := 0;
  Refresh;
  Say(mkInfo, 'Обновлено. Записей: ' + IntToStr(FData.Count(FDef.Table)));
end;

procedure TEntityPage.OnSearchChange(Sender: TObject);
begin
  FPendingDeleteId := 0;
  Refresh;
  if (FSearch.Text <> '') or (FPreset.ItemIndex > 0) then
    Say(mkInfo, Format('Фильтр: показано %d из %d', [FList.Items.Count, FData.Count(FDef.Table)]));
end;

procedure TEntityPage.OnSaveClick(Sender: TObject);
begin
  Save;
end;

procedure TEntityPage.OnCancelClick(Sender: TObject);
begin
  Cancel;
end;

procedure TEntityPage.OnListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if Selected and (Integer(Item.Data) <> FPendingDeleteId) then
    FPendingDeleteId := 0;
  // выбор строки открывает её в редакторе (detail view EspoCRM)
  if Selected then
    ShowEditor(Integer(Item.Data));
end;

procedure TEntityPage.OnListDblClick(Sender: TObject);
begin
  EditSelected;
end;

procedure TEntityPage.OnLineItemChange(Sender: TObject);
var
  Price: Variant;
begin
  if FLineItem.ItemIndex < 0 then Exit;
  Price := FData.Scalar('SELECT price FROM items WHERE id = ' + IntToStr(FLineItemIds[FLineItem.ItemIndex]));
  FLinePrice.Text := FormatFloat('0.00', Double(Price));
end;

procedure TEntityPage.OnLineAdd(Sender: TObject);
begin
  LineAdd;
end;

procedure TEntityPage.OnLineDelete(Sender: TObject);
var
  Id: Integer;
begin
  if FLinesList.Selected = nil then
  begin
    Say(mkWarn, 'Выберите строку заказа.');
    Exit;
  end;
  Id := Integer(FLinesList.Selected.Data);
  if FPendingLineDelete <> Id then
  begin
    FPendingLineDelete := Id;
    Say(mkWarn, 'Убрать строку «' + FLinesList.Selected.Caption + '»? Нажмите ещё раз.');
    Exit;
  end;
  FPendingLineDelete := 0;
  FData.DeleteOrderLine(Id);
  LoadLines;
  Refresh;
  SelectById(FEditingId);
  Say(mkOk, 'Строка убрана.');
end;

procedure TEntityPage.OnPostOrder(Sender: TObject);
begin
  PostOrder;
end;

end.
