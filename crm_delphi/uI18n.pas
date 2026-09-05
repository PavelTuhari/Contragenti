unit uI18n;
{
  Локализация интерфейса. Все тексты лежат во внешнем lang.json рядом с
  программой — файл можно править и переводить без пересборки.

  Три языка: ro (основной), en, ru. Выбранный язык хранится в реестре
  Windows: HKEY_CURRENT_USER\Software\DemoCRM, значение Language, — поэтому
  он переживает переустановку программы и не зависит от crm.ini.

  Значения перечислений (статусы, этапы) в базе остаются каноническими —
  такими, как их знает uCrmData. Переводится только показ: список берётся
  по позиции, поэтому порядок значений в lang.json менять нельзя.
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections;

type
  TLangInfo = record
    Code: string;
    Name: string;
  end;

  TI18n = class
  private
    FStrings: TDictionary<string, string>;
    FEnums: TDictionary<string, TArray<string>>;
    FLangs: TArray<TLangInfo>;
    FLang: string;
    FFile: string;
    FLoaded: Boolean;
    FError: string;
    procedure ParseLang(const Json: string; const Code: string);
  public
    constructor Create;
    destructor Destroy; override;

    { Читает lang.json; ищет рядом с exe, затем в каталоге исходников. }
    function Load(const FileName: string = ''): Boolean;
    procedure UseLang(const Code: string);

    function S(const Key: string): string;                       // строка
    function F(const Key: string; const Args: array of const): string;  // строка с подстановкой
    function EnumList(const Name: string): TArray<string>;       // перевод списка
    function EnumAt(const Name: string; Index: Integer): string; // перевод значения

    class function ReadLangFromRegistry(const Default: string): string;
    class procedure WriteLangToRegistry(const Code: string);

    property Lang: string read FLang;
    property Langs: TArray<TLangInfo> read FLangs;
    property Loaded: Boolean read FLoaded;
    property Error: string read FError;
    property FileName: string read FFile;
  end;

var
  T: TI18n;   // единственный экземпляр на приложение

const
  REG_KEY = 'Software\DemoCRM';

implementation

uses
  System.JSON, System.IOUtils, System.Win.Registry, Winapi.Windows;

constructor TI18n.Create;
begin
  inherited;
  FStrings := TDictionary<string, string>.Create;
  FEnums := TDictionary<string, TArray<string>>.Create;
  FLang := 'ro';
end;

destructor TI18n.Destroy;
begin
  FStrings.Free;
  FEnums.Free;
  inherited;
end;

class function TI18n.ReadLangFromRegistry(const Default: string): string;
var
  R: TRegistry;
begin
  Result := Default;
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly(REG_KEY) and R.ValueExists('Language') then
      Result := R.ReadString('Language');
  finally
    R.Free;
  end;
end;

class procedure TI18n.WriteLangToRegistry(const Code: string);
var
  R: TRegistry;
begin
  R := TRegistry.Create(KEY_WRITE);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKey(REG_KEY, True) then
      R.WriteString('Language', Code);
  finally
    R.Free;
  end;
end;

function TI18n.Load(const FileName: string): Boolean;
var
  Path: string;
  Root, LangObj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Info: TLangInfo;
  Text: string;
begin
  FLoaded := False;
  FError := '';
  Path := FileName;
  if Path = '' then
  begin
    Path := TPath.Combine(ExtractFilePath(ParamStr(0)), 'lang.json');
    if not TFile.Exists(Path) then
      Path := TPath.Combine(TPath.GetFullPath(TPath.Combine(
        ExtractFilePath(ParamStr(0)), '..\crm_delphi')), 'lang.json');
  end;
  FFile := Path;
  if not TFile.Exists(Path) then
  begin
    FError := 'Не найден файл переводов: ' + Path;
    Exit(False);
  end;

  try
    Text := TFile.ReadAllText(Path, TEncoding.UTF8);
    Root := TJSONObject.ParseJSONValue(Text) as TJSONObject;
    if Root = nil then
    begin
      FError := 'lang.json повреждён: не удалось разобрать JSON';
      Exit(False);
    end;
    try
      FLangs := nil;
      Arr := Root.GetValue('languages') as TJSONArray;
      if Arr <> nil then
        for I := 0 to Arr.Count - 1 do
        begin
          LangObj := Arr.Items[I] as TJSONObject;
          Info.Code := LangObj.GetValue('code').Value;
          Info.Name := LangObj.GetValue('name').Value;
          FLangs := FLangs + [Info];
        end;
      if Length(FLangs) = 0 then
      begin
        FError := 'в lang.json не описан ни один язык';
        Exit(False);
      end;
      FLoaded := True;
      ParseLang(Text, FLang);
      Result := True;
    finally
      Root.Free;
    end;
  except
    on E: Exception do
    begin
      FError := 'lang.json: ' + E.Message;
      Result := False;
    end;
  end;
end;

procedure TI18n.ParseLang(const Json, Code: string);
var
  Root, LangObj, Strs, Enums: TJSONObject;
  Pair: TJSONPair;
  Arr: TJSONArray;
  Vals: TArray<string>;
  I: Integer;
begin
  FStrings.Clear;
  FEnums.Clear;
  Root := TJSONObject.ParseJSONValue(Json) as TJSONObject;
  if Root = nil then Exit;
  try
    LangObj := Root.GetValue(Code) as TJSONObject;
    if LangObj = nil then Exit;

    Strs := LangObj.GetValue('strings') as TJSONObject;
    if Strs <> nil then
      for Pair in Strs do
        FStrings.AddOrSetValue(Pair.JsonString.Value, Pair.JsonValue.Value);

    Enums := LangObj.GetValue('enums') as TJSONObject;
    if Enums <> nil then
      for Pair in Enums do
      begin
        Arr := Pair.JsonValue as TJSONArray;
        Vals := nil;
        for I := 0 to Arr.Count - 1 do
          Vals := Vals + [Arr.Items[I].Value];
        FEnums.AddOrSetValue(Pair.JsonString.Value, Vals);
      end;
  finally
    Root.Free;
  end;
end;

procedure TI18n.UseLang(const Code: string);
var
  L: TLangInfo;
  Ok: Boolean;
begin
  Ok := False;
  for L in FLangs do
    if SameText(L.Code, Code) then Ok := True;
  if not Ok then Exit;
  FLang := Code;
  if FLoaded and TFile.Exists(FFile) then
    ParseLang(TFile.ReadAllText(FFile, TEncoding.UTF8), Code);
  WriteLangToRegistry(Code);
end;

function TI18n.S(const Key: string): string;
begin
  // ключ, которого нет в переводе, показываем как есть: пропажа строки
  // видна сразу, но программа продолжает работать
  if not FStrings.TryGetValue(Key, Result) then
    Result := Key;
end;

function TI18n.F(const Key: string; const Args: array of const): string;
begin
  try
    Result := Format(S(Key), Args);
  except
    Result := S(Key);   // в переводе испорчены подстановки — показываем шаблон
  end;
end;

function TI18n.EnumList(const Name: string): TArray<string>;
begin
  if not FEnums.TryGetValue(Name, Result) then
    Result := nil;
end;

function TI18n.EnumAt(const Name: string; Index: Integer): string;
var
  L: TArray<string>;
begin
  L := EnumList(Name);
  if (Index >= 0) and (Index <= High(L)) then
    Result := L[Index]
  else
    Result := '';
end;

initialization
  T := TI18n.Create;

finalization
  T.Free;

end.
