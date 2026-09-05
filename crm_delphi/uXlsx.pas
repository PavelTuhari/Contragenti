unit uXlsx;
{
  Запись настоящего .xlsx без внешних библиотек: Open XML — это zip с
  несколькими XML внутри, а zip умеет System.Zip из поставки Delphi.

  Строки пишутся как inlineStr (без общей таблицы строк) — так файл
  проще и полностью корректен для Excel, LibreOffice и Google Sheets.
}

interface

uses
  System.SysUtils, System.Classes, uReportTable;

procedure SaveTableToXlsx(Table: TReportTable; const FileName: string);

implementation

uses
  System.Zip, System.StrUtils, System.IOUtils, System.Math;

function XmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function ColName(Index: Integer): string;
begin
  // 0 → A, 25 → Z, 26 → AA
  Result := '';
  Inc(Index);
  while Index > 0 do
  begin
    Result := Chr(Ord('A') + (Index - 1) mod 26) + Result;
    Index := (Index - 1) div 26;
  end;
end;

{ Число для Excel: точка как разделитель, без пробелов-разрядов. }
function AsNumber(const S: string; out Num: string): Boolean;
var
  T: string;
  D: Double;
  FS: TFormatSettings;
begin
  T := StringReplace(Trim(S), ' ', '', [rfReplaceAll]);
  T := StringReplace(T, #160, '', [rfReplaceAll]);
  T := StringReplace(T, ',', '.', [rfReplaceAll]);
  FS := TFormatSettings.Create;
  FS.DecimalSeparator := '.';
  Result := (T <> '') and TryStrToFloat(T, D, FS);
  if Result then
    Num := FormatFloat('0.####', D, FS);
end;

const
  CONTENT_TYPES =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
    '<Default Extension="xml" ContentType="application/xml"/>' +
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
    '</Types>';

  RELS =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
    '</Relationships>';

  WB_RELS =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
    '</Relationships>';

  // стили: 0 обычный, 1 заголовок отчёта, 2 шапка таблицы, 3 деньги, 4 итог, 5 итог-деньги
  STYLES =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
    '<numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>' +
    '<fonts count="4">' +
    '<font><sz val="10"/><name val="Calibri"/></font>' +
    '<font><b/><sz val="14"/><name val="Calibri"/></font>' +
    '<font><b/><sz val="10"/><color rgb="FF444444"/><name val="Calibri"/></font>' +
    '<font><b/><sz val="10"/><name val="Calibri"/></font>' +
    '</fonts>' +
    '<fills count="3">' +
    '<fill><patternFill patternType="none"/></fill>' +
    '<fill><patternFill patternType="gray125"/></fill>' +
    '<fill><patternFill patternType="solid"><fgColor rgb="FFECF4F8"/><bgColor indexed="64"/></patternFill></fill>' +
    '</fills>' +
    '<borders count="2"><border/>' +
    '<border><left/><right/><top/><bottom style="thin"><color rgb="FFD0D7DC"/></bottom><diagonal/></border>' +
    '</borders>' +
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
    '<cellXfs count="6">' +
    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>' +
    '<xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>' +
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
    '<xf numFmtId="0" fontId="3" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>' +
    '<xf numFmtId="164" fontId="3" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1"/>' +
    '</cellXfs>' +
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>' +
    '</styleSheet>';

  WORKBOOK =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
    '<sheets><sheet name="%s" sheetId="1" r:id="rId1"/></sheets></workbook>';

procedure AddText(Zip: TZipFile; const Name, Content: string);
var
  Bytes: TBytes;
  MS: TMemoryStream;
begin
  Bytes := TEncoding.UTF8.GetBytes(Content);
  MS := TMemoryStream.Create;
  try
    if Length(Bytes) > 0 then
      MS.WriteBuffer(Bytes[0], Length(Bytes));
    MS.Position := 0;
    Zip.Add(MS, Name, zcDeflate);
  finally
    MS.Free;
  end;
end;

procedure SaveTableToXlsx(Table: TReportTable; const FileName: string);
var
  Zip: TZipFile;
  Sheet: TStringBuilder;
  R, C, RowNo: Integer;
  Val, Num, Style, SheetName: string;
  IsTotals: Boolean;

  procedure WriteCell(Col, Row: Integer; const Text, AStyle: string; NumericCol: Boolean);
  var
    N: string;
  begin
    if Text = '' then Exit;
    Sheet.Append('<c r="').Append(ColName(Col)).Append(Row).Append('"');
    if AStyle <> '' then Sheet.Append(' s="').Append(AStyle).Append('"');
    if NumericCol and AsNumber(Text, N) then
      Sheet.Append('><v>').Append(N).Append('</v></c>')
    else
      Sheet.Append(' t="inlineStr"><is><t xml:space="preserve">')
           .Append(XmlEsc(Text)).Append('</t></is></c>');
  end;

begin
  SheetName := Copy(StringReplace(Table.Title, '/', '-', [rfReplaceAll]), 1, 28);
  if SheetName = '' then SheetName := 'Отчёт';

  Sheet := TStringBuilder.Create;
  try
    Sheet.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
         .Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
         .Append('<cols>');
    for C := 0 to Table.ColCount - 1 do
      Sheet.Append('<col min="').Append(C + 1).Append('" max="').Append(C + 1)
           .Append('" width="').Append(Max(9, Table.Cols[C].Width div 6))
           .Append('" customWidth="1"/>');
    Sheet.Append('</cols><sheetData>');

    // заголовок и подзаголовок
    Sheet.Append('<row r="1" ht="20" customHeight="1">');
    WriteCell(0, 1, Table.Title, '1', False);
    Sheet.Append('</row>');
    Sheet.Append('<row r="2">');
    WriteCell(0, 2, Table.Subtitle, '', False);
    Sheet.Append('</row>');

    // шапка таблицы
    RowNo := 4;
    Sheet.Append('<row r="').Append(RowNo).Append('">');
    for C := 0 to Table.ColCount - 1 do
      WriteCell(C, RowNo, Table.Cols[C].Title, '2', False);
    Sheet.Append('</row>');

    // данные
    for R := 0 to Table.RowCount - 1 do
    begin
      Inc(RowNo);
      Sheet.Append('<row r="').Append(RowNo).Append('">');
      for C := 0 to Table.ColCount - 1 do
      begin
        Val := Table.Cell(R, C);
        if Table.Cols[C].Kind = ckMoney then Style := '3' else Style := '';
        WriteCell(C, RowNo, Val, Style, Table.IsNumeric(C));
      end;
      Sheet.Append('</row>');
    end;

    // итоги
    if Length(Table.Totals) > 0 then
    begin
      Inc(RowNo);
      Sheet.Append('<row r="').Append(RowNo).Append('">');
      for C := 0 to Table.ColCount - 1 do
      begin
        if C > High(Table.Totals) then Continue;
        if Table.Cols[C].Kind = ckMoney then Style := '5' else Style := '4';
        WriteCell(C, RowNo, Table.Totals[C], Style, Table.IsNumeric(C));
      end;
      Sheet.Append('</row>');
    end;

    Sheet.Append('</sheetData>')
         .Append('<autoFilter ref="A4:').Append(ColName(Table.ColCount - 1)).Append(4 + Table.RowCount).Append('"/>')
         .Append('</worksheet>');

    if TFile.Exists(FileName) then
      TFile.Delete(FileName);
    Zip := TZipFile.Create;
    try
      Zip.Open(FileName, zmWrite);
      AddText(Zip, '[Content_Types].xml', CONTENT_TYPES);
      AddText(Zip, '_rels/.rels', RELS);
      AddText(Zip, 'xl/workbook.xml', Format(WORKBOOK, [XmlEsc(SheetName)]));
      AddText(Zip, 'xl/_rels/workbook.xml.rels', WB_RELS);
      AddText(Zip, 'xl/styles.xml', STYLES);
      AddText(Zip, 'xl/worksheets/sheet1.xml', Sheet.ToString);
      Zip.Close;
    finally
      Zip.Free;
    end;
  finally
    Sheet.Free;
  end;
end;

end.
