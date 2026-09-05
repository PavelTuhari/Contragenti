unit uPdf;
{
  Запись PDF с таблицей отчёта без внешних библиотек.

  Кириллица в PDF со стандартными шрифтами (WinAnsi) невозможна, поэтому
  системный TrueType (Arial/Tahoma) встраивается целиком как CIDFontType2 с
  кодировкой Identity-H: текст пишется индексами глифов, а ширины берутся из
  таблицы hmtx самого шрифта — иначе просмотрщик расставит символы неверно.

  Разбираются только нужные таблицы шрифта: head, hhea, maxp, hmtx, cmap
  (формат 4 — BMP, этого достаточно для кириллицы и латиницы).
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, uReportTable;

procedure SaveTableToPdf(Table: TReportTable; const FileName: string);

implementation

uses
  System.IOUtils, System.Math, System.StrUtils;

var
  // числа в PDF пишутся только с точкой, независимо от локали Windows
  PdfFS: TFormatSettings;

type
  TTrueTypeFont = class
  private
    FData: TBytes;
    FUnitsPerEm: Integer;
    FNumGlyphs: Integer;
    FAdvances: TArray<Word>;                 // ширины глифов в единицах шрифта
    FCmap: TDictionary<Word, Word>;          // unicode → glyph id
    FAscent, FDescent, FCapHeight: Integer;
    FBBox: array[0..3] of Integer;
    function U8(P: Integer): Byte;
    function U16(P: Integer): Word;
    function I16(P: Integer): SmallInt;
    function U32(P: Integer): Cardinal;
    function TableOffset(const Tag: string; out Len: Integer): Integer;
    procedure ParseCmap4(Base: Integer);
    procedure Parse;
  public
    constructor Create(const FontFile: string);
    destructor Destroy; override;
    function GlyphOf(Ch: Char): Word;
    function GlyphWidth(Gid: Word): Integer;   // в 1/1000 em
    function TextWidth(const S: string; FontSize: Double): Double;
    function HexGlyphs(const S: string): string;
    property Data: TBytes read FData;
    property NumGlyphs: Integer read FNumGlyphs;
    property Ascent: Integer read FAscent;
    property Descent: Integer read FDescent;
    property CapHeight: Integer read FCapHeight;
  end;

{ TTrueTypeFont }

constructor TTrueTypeFont.Create(const FontFile: string);
var
  FS: TFileStream;
begin
  inherited Create;
  FCmap := TDictionary<Word, Word>.Create;
  // системный шрифт открыт самой Windows, поэтому только совместное чтение
  FS := TFileStream.Create(FontFile, fmOpenRead or fmShareDenyNone);
  try
    SetLength(FData, FS.Size);
    if Length(FData) > 0 then
      FS.ReadBuffer(FData[0], Length(FData));
  finally
    FS.Free;
  end;
  FUnitsPerEm := 1000;
  Parse;
end;

destructor TTrueTypeFont.Destroy;
begin
  FCmap.Free;
  inherited;
end;

function TTrueTypeFont.U8(P: Integer): Byte;
begin
  if (P < 0) or (P > High(FData)) then Exit(0);
  Result := FData[P];
end;

function TTrueTypeFont.U16(P: Integer): Word;
begin
  Result := (U8(P) shl 8) or U8(P + 1);
end;

function TTrueTypeFont.I16(P: Integer): SmallInt;
begin
  Result := SmallInt(U16(P));
end;

function TTrueTypeFont.U32(P: Integer): Cardinal;
begin
  Result := (Cardinal(U8(P)) shl 24) or (Cardinal(U8(P + 1)) shl 16) or
            (Cardinal(U8(P + 2)) shl 8) or Cardinal(U8(P + 3));
end;

function TTrueTypeFont.TableOffset(const Tag: string; out Len: Integer): Integer;
var
  I, N, P: Integer;
  T: string;
begin
  Result := -1;
  Len := 0;
  N := U16(4);
  for I := 0 to N - 1 do
  begin
    P := 12 + I * 16;
    T := Chr(U8(P)) + Chr(U8(P + 1)) + Chr(U8(P + 2)) + Chr(U8(P + 3));
    if T = Tag then
    begin
      Result := Integer(U32(P + 8));
      Len := Integer(U32(P + 12));
      Exit;
    end;
  end;
end;

procedure TTrueTypeFont.ParseCmap4(Base: Integer);
var
  SegCount, I, J, Idx: Integer;
  EndP, StartP, DeltaP, RangeP: Integer;
  StartC, EndC, Delta, RangeOff: Word;
  Gid: Word;
  C: Cardinal;
begin
  SegCount := U16(Base + 6) div 2;
  EndP := Base + 14;
  StartP := EndP + SegCount * 2 + 2;
  DeltaP := StartP + SegCount * 2;
  RangeP := DeltaP + SegCount * 2;
  for I := 0 to SegCount - 1 do
  begin
    EndC := U16(EndP + I * 2);
    StartC := U16(StartP + I * 2);
    Delta := U16(DeltaP + I * 2);
    RangeOff := U16(RangeP + I * 2);
    if StartC = $FFFF then Continue;
    for C := StartC to EndC do
    begin
      if RangeOff = 0 then
        Gid := Word((C + Delta) and $FFFF)
      else
      begin
        Idx := RangeP + I * 2 + RangeOff + Integer(C - StartC) * 2;
        Gid := U16(Idx);
        if Gid <> 0 then
          Gid := Word((Gid + Delta) and $FFFF);
      end;
      if Gid <> 0 then
        FCmap.AddOrSetValue(Word(C), Gid);
      if C = $FFFF then Break;
    end;
  end;
end;

procedure TTrueTypeFont.Parse;
var
  Head, HHea, MaxP, HMtx, CMapT, Len: Integer;
  NumHMetrics, I, N, Sub, Fmt, Best: Integer;
  Plat, Enc: Word;
begin
  Head := TableOffset('head', Len);
  if Head > 0 then
  begin
    FUnitsPerEm := U16(Head + 18);
    if FUnitsPerEm = 0 then FUnitsPerEm := 1000;
    FBBox[0] := I16(Head + 36);
    FBBox[1] := I16(Head + 38);
    FBBox[2] := I16(Head + 40);
    FBBox[3] := I16(Head + 42);
  end;
  HHea := TableOffset('hhea', Len);
  NumHMetrics := 0;
  if HHea > 0 then
  begin
    FAscent := Round(I16(HHea + 4) * 1000 / FUnitsPerEm);
    FDescent := Round(I16(HHea + 6) * 1000 / FUnitsPerEm);
    NumHMetrics := U16(HHea + 34);
  end;
  FCapHeight := Round(FBBox[3] * 1000 / FUnitsPerEm);
  MaxP := TableOffset('maxp', Len);
  if MaxP > 0 then FNumGlyphs := U16(MaxP + 4);

  HMtx := TableOffset('hmtx', Len);
  SetLength(FAdvances, Max(FNumGlyphs, 1));
  if (HMtx > 0) and (NumHMetrics > 0) then
    for I := 0 to FNumGlyphs - 1 do
      if I < NumHMetrics then
        FAdvances[I] := U16(HMtx + I * 4)
      else
        FAdvances[I] := U16(HMtx + (NumHMetrics - 1) * 4);

  CMapT := TableOffset('cmap', Len);
  if CMapT > 0 then
  begin
    N := U16(CMapT + 2);
    Best := -1;
    for I := 0 to N - 1 do
    begin
      Plat := U16(CMapT + 4 + I * 8);
      Enc := U16(CMapT + 6 + I * 8);
      Sub := CMapT + Integer(U32(CMapT + 8 + I * 8));
      Fmt := U16(Sub);
      if (Fmt = 4) and (((Plat = 3) and (Enc = 1)) or (Plat = 0)) then
      begin
        Best := Sub;
        if (Plat = 3) and (Enc = 1) then Break;   // предпочитаем Windows BMP
      end;
    end;
    if Best > 0 then ParseCmap4(Best);
  end;
end;

function TTrueTypeFont.GlyphOf(Ch: Char): Word;
begin
  if not FCmap.TryGetValue(Word(Ch), Result) then
    if not FCmap.TryGetValue(Word('?'), Result) then
      Result := 0;
end;

function TTrueTypeFont.GlyphWidth(Gid: Word): Integer;
begin
  if Gid <= High(FAdvances) then
    Result := Round(FAdvances[Gid] * 1000 / FUnitsPerEm)
  else
    Result := 500;
end;

function TTrueTypeFont.TextWidth(const S: string; FontSize: Double): Double;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do
    Result := Result + GlyphWidth(GlyphOf(S[I])) * FontSize / 1000;
end;

function TTrueTypeFont.HexGlyphs(const S: string): string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 1 to Length(S) do
      SB.Append(IntToHex(GlyphOf(S[I]), 4));
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ ── сборка PDF ── }

type
  TPdfDoc = class
  private
    FStream: TMemoryStream;
    FOffsets: TList<Integer>;
    procedure Raw(const S: RawByteString);
  public
    constructor Create;
    destructor Destroy; override;
    function BeginObj: Integer;                 // возвращает номер объекта
    procedure EndObj;
    procedure Text(const S: string);
    procedure Bytes(const B: TBytes);
    function ObjCount: Integer;
    procedure Finish(RootObj: Integer; const FileName: string);
  end;

constructor TPdfDoc.Create;
begin
  inherited;
  FStream := TMemoryStream.Create;
  FOffsets := TList<Integer>.Create;
  Raw('%PDF-1.4'#10'%'#$E2#$E3#$CF#$D3#10);
end;

destructor TPdfDoc.Destroy;
begin
  FOffsets.Free;
  FStream.Free;
  inherited;
end;

procedure TPdfDoc.Raw(const S: RawByteString);
begin
  if Length(S) > 0 then
    FStream.WriteBuffer(S[1], Length(S));
end;

procedure TPdfDoc.Text(const S: string);
begin
  Raw(RawByteString(UTF8Encode(S)));
end;

procedure TPdfDoc.Bytes(const B: TBytes);
begin
  if Length(B) > 0 then
    FStream.WriteBuffer(B[0], Length(B));
end;

function TPdfDoc.BeginObj: Integer;
begin
  FOffsets.Add(FStream.Position);
  Result := FOffsets.Count;
  Raw(RawByteString(IntToStr(Result) + ' 0 obj'#10));
end;

procedure TPdfDoc.EndObj;
begin
  Raw('endobj'#10);
end;

function TPdfDoc.ObjCount: Integer;
begin
  Result := FOffsets.Count;
end;

procedure TPdfDoc.Finish(RootObj: Integer; const FileName: string);
var
  XrefPos, I: Integer;
begin
  XrefPos := FStream.Position;
  Raw(RawByteString(Format('xref'#10'0 %d'#10, [FOffsets.Count + 1])));
  Raw('0000000000 65535 f '#10);
  for I := 0 to FOffsets.Count - 1 do
    Raw(RawByteString(Format('%.10d 00000 n '#10, [FOffsets[I]])));
  Raw(RawByteString(Format('trailer'#10'<< /Size %d /Root %d 0 R >>'#10'startxref'#10'%d'#10'%%%%EOF'#10,
    [FOffsets.Count + 1, RootObj, XrefPos])));
  FStream.SaveToFile(FileName);
end;

{ Экранирование не нужно: текст пишется как hex-строка глифов. }

function FindSystemFont: string;
const
  CANDIDATES: array[0..4] of string = ('arial.ttf', 'tahoma.ttf', 'segoeui.ttf', 'calibri.ttf', 'verdana.ttf');
var
  Dir, C, P: string;
begin
  Dir := TPath.Combine(GetEnvironmentVariable('WINDIR'), 'Fonts');
  for C in CANDIDATES do
  begin
    P := TPath.Combine(Dir, C);
    if TFile.Exists(P) then Exit(P);
  end;
  raise Exception.Create('Не найден системный TrueType-шрифт для PDF (' + Dir + ')');
end;

procedure SaveTableToPdf(Table: TReportTable; const FileName: string);
const
  PAGE_W = 842.0;   // A4 альбомная
  PAGE_H = 595.0;
  MARGIN = 36.0;
  ROW_H = 16.0;
  FS_TITLE = 15.0;
  FS_SUB = 9.0;
  FS_HEAD = 8.5;
  FS_ROW = 9.0;
var
  Font: TTrueTypeFont;
  Doc: TPdfDoc;
  FontFileObj, DescrObj, CidObj, FontObj, PagesObj, RootObj: Integer;
  PageObjs, ContentObjs: TList<Integer>;
  Content: TStringBuilder;
  Y, X, Scale, TotalW: Double;
  R, C, I: Integer;
  W: TStringBuilder;
  ColX: TArray<Double>;
  PageNo: Integer;
  Bytes: TBytes;

  function Fit(const S: string; MaxW: Double; Size: Double): string;
  begin
    Result := S;
    if Font.TextWidth(Result, Size) <= MaxW then Exit;
    while (Length(Result) > 1) and (Font.TextWidth(Result + '…', Size) > MaxW) do
      Delete(Result, Length(Result), 1);
    Result := Result + '…';
  end;

  procedure Show(const S: string; AX, AY, Size: Double);
  begin
    if S = '' then Exit;
    Content.Append(Format('BT /F1 %s Tf 1 0 0 1 %s %s Tm <%s> Tj ET'#10,
      [FormatFloat('0.##', Size, PdfFS),
       FormatFloat('0.##', AX, PdfFS),
       FormatFloat('0.##', AY, PdfFS),
       Font.HexGlyphs(S)]));
  end;

  procedure ShowRight(const S: string; ARight, AY, Size: Double);
  begin
    Show(S, ARight - Font.TextWidth(S, Size), AY, Size);
  end;

  procedure Rect(AX, AY, AW, AH: Double; Rr, Gg, Bb: Double);
  begin
    Content.Append(Format('%s %s %s rg %s %s %s %s re f'#10,
      [FormatFloat('0.###', Rr, PdfFS),
       FormatFloat('0.###', Gg, PdfFS),
       FormatFloat('0.###', Bb, PdfFS),
       FormatFloat('0.##', AX, PdfFS),
       FormatFloat('0.##', AY, PdfFS),
       FormatFloat('0.##', AW, PdfFS),
       FormatFloat('0.##', AH, PdfFS)]));
    Content.Append('0.15 0.15 0.15 rg'#10);
  end;

  procedure DrawHeaderRow;
  var
    K: Integer;
  begin
    Rect(MARGIN, Y - 4, PAGE_W - 2 * MARGIN, ROW_H, 0.926, 0.957, 0.973);
    Content.Append('0.35 0.4 0.45 rg'#10);
    for K := 0 to Table.ColCount - 1 do
      if Table.Cols[K].Kind in [ckMoney, ckNumber, ckRight] then
        ShowRight(Fit(Table.Cols[K].Title, ColX[K + 1] - ColX[K] - 8, FS_HEAD), ColX[K + 1] - 4, Y, FS_HEAD)
      else
        Show(Fit(Table.Cols[K].Title, ColX[K + 1] - ColX[K] - 8, FS_HEAD), ColX[K] + 4, Y, FS_HEAD);
    Content.Append('0.15 0.15 0.15 rg'#10);
    Y := Y - ROW_H - 2;
  end;

  procedure ClosePage;
  var
    Obj: Integer;
    Data: TBytes;
  begin
    Show(Format('стр. %d', [PageNo]), PAGE_W - MARGIN - 40, MARGIN - 12, 8);
    Data := TEncoding.UTF8.GetBytes(Content.ToString);
    Obj := Doc.BeginObj;
    Doc.Text(Format('<< /Length %d >>'#10'stream'#10, [Length(Data)]));
    Doc.Bytes(Data);
    Doc.Text(#10'endstream'#10);
    Doc.EndObj;
    ContentObjs.Add(Obj);
    Content.Clear;
  end;

  procedure NewPage;
  begin
    Inc(PageNo);
    Y := PAGE_H - MARGIN;
    Content.Append('0.15 0.15 0.15 rg'#10);
    if PageNo = 1 then
    begin
      Show(Table.Title, MARGIN, Y - FS_TITLE, FS_TITLE);
      Y := Y - FS_TITLE - 8;
      Content.Append('0.45 0.5 0.55 rg'#10);
      Show(Table.Subtitle, MARGIN, Y - FS_SUB, FS_SUB);
      Content.Append('0.15 0.15 0.15 rg'#10);
      Y := Y - FS_SUB - 14;
    end
    else
    begin
      Show(Table.Title + ' (продолжение)', MARGIN, Y - 11, 11);
      Y := Y - 24;
    end;
    DrawHeaderRow;
  end;

begin
  Font := TTrueTypeFont.Create(FindSystemFont);
  Doc := TPdfDoc.Create;
  Content := TStringBuilder.Create;
  PageObjs := TList<Integer>.Create;
  ContentObjs := TList<Integer>.Create;
  try
    // раскладка колонок по ширине страницы
    TotalW := 0;
    for C := 0 to Table.ColCount - 1 do TotalW := TotalW + Table.Cols[C].Width;
    if TotalW <= 0 then TotalW := 1;
    Scale := (PAGE_W - 2 * MARGIN) / TotalW;
    SetLength(ColX, Table.ColCount + 1);
    ColX[0] := MARGIN;
    for C := 0 to Table.ColCount - 1 do
      ColX[C + 1] := ColX[C] + Table.Cols[C].Width * Scale;

    PageNo := 0;
    NewPage;
    for R := 0 to Table.RowCount - 1 do
    begin
      if Y < MARGIN + 30 then
      begin
        ClosePage;
        NewPage;
      end;
      if R mod 2 = 1 then
        Rect(MARGIN, Y - 4, PAGE_W - 2 * MARGIN, ROW_H - 2, 0.972, 0.976, 0.98);
      for C := 0 to Table.ColCount - 1 do
        if Table.Cols[C].Kind in [ckMoney, ckNumber, ckRight] then
          ShowRight(Fit(Table.Cell(R, C), ColX[C + 1] - ColX[C] - 8, FS_ROW), ColX[C + 1] - 4, Y, FS_ROW)
        else
          Show(Fit(Table.Cell(R, C), ColX[C + 1] - ColX[C] - 8, FS_ROW), ColX[C] + 4, Y, FS_ROW);
      Y := Y - ROW_H;
    end;

    if Length(Table.Totals) > 0 then
    begin
      if Y < MARGIN + 30 then
      begin
        ClosePage;
        NewPage;
      end;
      Rect(MARGIN, Y - 4, PAGE_W - 2 * MARGIN, ROW_H, 0.9, 0.93, 0.9);
      for C := 0 to Min(Table.ColCount, Length(Table.Totals)) - 1 do
        if Table.Cols[C].Kind in [ckMoney, ckNumber, ckRight] then
          ShowRight(Table.Totals[C], ColX[C + 1] - 4, Y, FS_ROW)
        else
          Show(Table.Totals[C], ColX[C] + 4, Y, FS_ROW);
      Y := Y - ROW_H;
    end;
    ClosePage;

    // ── объекты шрифта ──
    Bytes := Font.Data;
    FontFileObj := Doc.BeginObj;
    Doc.Text(Format('<< /Length %d /Length1 %d >>'#10'stream'#10, [Length(Bytes), Length(Bytes)]));
    Doc.Bytes(Bytes);
    Doc.Text(#10'endstream'#10);
    Doc.EndObj;

    DescrObj := Doc.BeginObj;
    Doc.Text(Format('<< /Type /FontDescriptor /FontName /CRMFont /Flags 32 ' +
      '/FontBBox [-666 -325 2000 1006] /ItalicAngle 0 /Ascent %d /Descent %d ' +
      '/CapHeight %d /StemV 80 /FontFile2 %d 0 R >>'#10,
      [Font.Ascent, Font.Descent, Font.CapHeight, FontFileObj]));
    Doc.EndObj;

    // ширины глифов: /W [gid [w] gid [w] ...] только для реально использованных
    W := TStringBuilder.Create;
    try
      W.Append('[');
      for I := 0 to Font.NumGlyphs - 1 do
        if Font.GlyphWidth(I) <> 1000 then
          W.Append(I).Append(' [').Append(Font.GlyphWidth(I)).Append('] ');
      W.Append(']');
      CidObj := Doc.BeginObj;
      Doc.Text('<< /Type /Font /Subtype /CIDFontType2 /BaseFont /CRMFont ' +
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> ' +
        '/FontDescriptor ' + IntToStr(DescrObj) + ' 0 R /DW 1000 /W ' + W.ToString +
        ' /CIDToGIDMap /Identity >>'#10);
      Doc.EndObj;
    finally
      W.Free;
    end;

    FontObj := Doc.BeginObj;
    Doc.Text(Format('<< /Type /Font /Subtype /Type0 /BaseFont /CRMFont ' +
      '/Encoding /Identity-H /DescendantFonts [%d 0 R] >>'#10, [CidObj]));
    Doc.EndObj;

    // ── страницы ──
    PagesObj := Doc.ObjCount + ContentObjs.Count + 1;   // объект Pages создаём после страниц
    for I := 0 to ContentObjs.Count - 1 do
    begin
      PageObjs.Add(Doc.BeginObj);
      Doc.Text(Format('<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %s %s] ' +
        '/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>'#10,
        [PagesObj, FormatFloat('0', PAGE_W, PdfFS),
         FormatFloat('0', PAGE_H, PdfFS), FontObj, ContentObjs[I]]));
      Doc.EndObj;
    end;

    PagesObj := Doc.BeginObj;
    Content.Clear;
    Content.Append('<< /Type /Pages /Count ').Append(PageObjs.Count).Append(' /Kids [');
    for I := 0 to PageObjs.Count - 1 do
      Content.Append(PageObjs[I]).Append(' 0 R ');
    Content.Append('] >>'#10);
    Doc.Text(Content.ToString);
    Doc.EndObj;

    RootObj := Doc.BeginObj;
    Doc.Text(Format('<< /Type /Catalog /Pages %d 0 R >>'#10, [PagesObj]));
    Doc.EndObj;

    Doc.Finish(RootObj, FileName);
  finally
    ContentObjs.Free;
    PageObjs.Free;
    Content.Free;
    Doc.Free;
    Font.Free;
  end;
end;

initialization
  PdfFS := TFormatSettings.Create;
  PdfFS.DecimalSeparator := '.';
  PdfFS.ThousandSeparator := #0;

end.
