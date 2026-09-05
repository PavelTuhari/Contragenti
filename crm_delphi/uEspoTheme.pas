unit uEspoTheme;
{
  Палитра и фабрики элементов в стиле EspoCRM (тема «Espo»), общие для
  главной формы и страниц сущностей. TColor = BGR.
}

interface

uses
  System.Classes, Vcl.Controls, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.Graphics;

const
  ESPO_BODY      = $00F5F3F1;  // #f1f3f5 фон страницы и навигации
  ESPO_BORDER    = $00E3E2E0;  // #e0e2e3
  ESPO_PANEL_BRD = $00EDEAE7;  // #e7eaed
  ESPO_WHITE     = $00FFFFFF;
  ESPO_TEXT      = $00262626;
  ESPO_MUTED     = $00969696;
  ESPO_GRAY      = $006A6A6A;
  ESPO_SOFT      = $00777777;
  ESPO_PRIMARY   = $00CA8955;  // #5589ca
  ESPO_NAV_ACT   = $00E7E1DE;  // #dee1e7
  ESPO_NAV_HOV   = $00EDECEC;
  ESPO_BTN_BG    = $00FCFCFC;
  ESPO_BTN_BRD   = $00CCCAC2;
  ESPO_BTN_TXT   = $00585858;
  ESPO_LINK      = $008C5B24;
  ESPO_HEAD_BG   = $00F8F4EC;  // #ecf4f8

  ST_PRIMARY_FG = $00CA9339;  ST_PRIMARY_BG = $00FFF3E5;
  ST_SUCCESS_FG = $004C9A2A;  ST_SUCCESS_BG = $00D1EFC4;
  ST_WARNING_FG = $0022719F;  ST_WARNING_BG = $00D6F4FA;
  ST_DANGER_FG  = $004648AD;  ST_DANGER_BG  = $00DEDEF2;

type
  TMsgKind = (mkInfo, mkOk, mkWarn, mkErr);
  TSayProc = procedure(Kind: TMsgKind; const Msg: string) of object;

function MakeButton(AOwner: TComponent; AParent: TWinControl; const ACaption: string;
  APrimary: Boolean; AOnClick: TNotifyEvent; AWidth: Integer = 120): TPanel;
function MakePanelBox(AOwner: TComponent; AParent: TWinControl; const ATitle: string): TPanel;
function MakeLabel(AOwner: TComponent; AParent: TWinControl; const ACaption: string;
  X, Y, W: Integer; AColor: TColor = ESPO_MUTED; ASize: Integer = 9): TLabel;

implementation

function MakeButton(AOwner: TComponent; AParent: TWinControl; const ACaption: string;
  APrimary: Boolean; AOnClick: TNotifyEvent; AWidth: Integer): TPanel;
begin
  Result := TPanel.Create(AOwner);
  Result.Parent := AParent;
  Result.Width := AWidth;
  Result.Height := 36;
  Result.Caption := ACaption;
  Result.BevelOuter := bvNone;
  Result.ParentBackground := False;
  Result.Cursor := crHandPoint;
  Result.Font.Name := 'Segoe UI';
  Result.Font.Size := 10;
  if APrimary then
  begin
    Result.Color := ESPO_PRIMARY;
    Result.Font.Color := clWhite;
    Result.Font.Style := [fsBold];
  end
  else
  begin
    Result.Color := ESPO_BTN_BG;
    Result.Font.Color := ESPO_BTN_TXT;
    Result.BevelKind := bkFlat;
  end;
  Result.OnClick := AOnClick;
end;

function MakePanelBox(AOwner: TComponent; AParent: TWinControl; const ATitle: string): TPanel;
var
  H: TLabel;
begin
  Result := TPanel.Create(AOwner);
  Result.Parent := AParent;
  Result.BevelOuter := bvNone;
  Result.BevelKind := bkFlat;
  Result.Color := ESPO_WHITE;
  Result.ParentBackground := False;
  if ATitle <> '' then
  begin
    H := TLabel.Create(AOwner);
    H.Parent := Result;
    H.SetBounds(14, 8, 400, 22);
    H.Caption := ATitle;
    H.Font.Name := 'Segoe UI';
    H.Font.Size := 11;
    H.Font.Style := [fsBold];
    H.Font.Color := ESPO_SOFT;
  end;
end;

function MakeLabel(AOwner: TComponent; AParent: TWinControl; const ACaption: string;
  X, Y, W: Integer; AColor: TColor; ASize: Integer): TLabel;
begin
  Result := TLabel.Create(AOwner);
  Result.Parent := AParent;
  Result.AutoSize := False;
  Result.SetBounds(X, Y, W, 18);
  Result.Caption := ACaption;
  Result.Font.Name := 'Segoe UI';
  Result.Font.Size := ASize;
  Result.Font.Color := AColor;
end;

end.
