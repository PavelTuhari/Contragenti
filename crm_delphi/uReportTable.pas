unit uReportTable;
{
  Модель отчёта, общая для экспорта в Excel (uXlsx) и PDF (uPdf).
  Отчёт — заголовок, подзаголовок, описание колонок, строки и строка итогов.
}

interface

uses
  System.SysUtils, System.Classes;

type
  TColKind = (ckText, ckNumber, ckMoney, ckDate, ckRight);

  TReportCol = record
    Title: string;
    Kind: TColKind;
    Width: Integer;   // ширина в пунктах (PDF); для Excel делится на 7
  end;

  TReportTable = class
  private
    FRows: TArray<TArray<string>>;
  public
    Title: string;
    Subtitle: string;
    Cols: TArray<TReportCol>;
    Totals: TArray<string>;   // пусто — итогов нет

    procedure AddCol(const ATitle: string; AKind: TColKind; AWidth: Integer);
    procedure AddRow(const Cells: array of string);
    procedure SetTotals(const Cells: array of string);
    function RowCount: Integer;
    function ColCount: Integer;
    function Cell(Row, Col: Integer): string;
    function IsNumeric(Col: Integer): Boolean;
    property Rows: TArray<TArray<string>> read FRows;
  end;

implementation

procedure TReportTable.AddCol(const ATitle: string; AKind: TColKind; AWidth: Integer);
var
  C: TReportCol;
begin
  C.Title := ATitle;
  C.Kind := AKind;
  C.Width := AWidth;
  Cols := Cols + [C];
end;

procedure TReportTable.AddRow(const Cells: array of string);
var
  R: TArray<string>;
  I: Integer;
begin
  SetLength(R, Length(Cells));
  for I := 0 to High(Cells) do R[I] := Cells[I];
  FRows := FRows + [R];
end;

procedure TReportTable.SetTotals(const Cells: array of string);
var
  I: Integer;
begin
  SetLength(Totals, Length(Cells));
  for I := 0 to High(Cells) do Totals[I] := Cells[I];
end;

function TReportTable.RowCount: Integer;
begin
  Result := Length(FRows);
end;

function TReportTable.ColCount: Integer;
begin
  Result := Length(Cols);
end;

function TReportTable.Cell(Row, Col: Integer): string;
begin
  if (Row < 0) or (Row > High(FRows)) or (Col < 0) or (Col > High(FRows[Row])) then
    Result := ''
  else
    Result := FRows[Row][Col];
end;

function TReportTable.IsNumeric(Col: Integer): Boolean;
begin
  Result := (Col >= 0) and (Col <= High(Cols)) and (Cols[Col].Kind in [ckNumber, ckMoney]);
end;

end.
