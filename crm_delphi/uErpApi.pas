unit uErpApi;
{
  Связь CRM с ERP una.md по HTTP-API хаба (hub/app.py):

    GET  /api/v1/health           проверка связи
    GET  /api/v1/stats            сводка по принятым данным
    POST /api/v1/batches          приём базы: тело — gzip(sqlite),
                                  заголовки X-API-Key и X-Client-Id
    GET  /api/v1/batches/<id>     статус импорта пакета

  Хаб принимает базу целиком и в фоне переносит записи в Oracle-схемы
  una.md, поэтому CRM отправляет копию своей SQLite: копия снимается до
  сжатия, чтобы не читать файл, открытый FireDAC.

  Параметры — в crm.ini, секция [erp]: url, key, client_id.
  Без внешних библиотек: System.Net.HttpClient + System.ZLib.
}

interface

uses
  System.SysUtils, System.Classes;

type
  TErpStatus = record
    Online: Boolean;
    Message: string;      // текст для строки сообщений
    QueueDepth: Integer;
    ServerTime: string;
    RowsNew: Integer;     // сколько записей ERP уже приняла от клиентов
    Batches: Integer;
  end;

  TErpClient = class
  private
    FUrl: string;
    FKey: string;
    FClientId: string;
    FTimeoutMs: Integer;
    FLastError: string;
    function BaseUrl: string;
    function Get(const Path: string; out Body: string): Boolean;
  public
    constructor Create;
    function Configured: Boolean;
    function Health(out Status: TErpStatus): Boolean;
    { Отправляет копию базы в ERP. BatchId — идентификатор пакета в хабе. }
    function SendDatabase(const DbPath: string; out BatchId: string): Boolean;
    function BatchStatus(const BatchId: string; out State: string): Boolean;

    property Url: string read FUrl write FUrl;
    property Key: string read FKey write FKey;
    property ClientId: string read FClientId write FClientId;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    property LastError: string read FLastError;
  end;

implementation

uses
  Winapi.Windows, System.Net.HttpClient, System.Net.URLClient, System.ZLib,
  System.JSON, System.IOUtils, System.StrUtils;

constructor TErpClient.Create;
begin
  inherited;
  FUrl := 'http://127.0.0.1:9000';
  FClientId := 'demo-crm';
  FTimeoutMs := 15000;
end;

function TErpClient.Configured: Boolean;
begin
  Result := Trim(FUrl) <> '';
end;

function TErpClient.BaseUrl: string;
begin
  Result := Trim(FUrl);
  while (Result <> '') and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

{ Мягкое чтение JSON: отсутствующее поле — не ошибка. }
function JStr(J: TJSONObject; const Name: string): string;
var
  V: TJSONValue;
begin
  Result := '';
  if J = nil then Exit;
  V := J.GetValue(Name);
  if (V <> nil) and not (V is TJSONNull) then
    Result := V.Value;
end;

function JInt(J: TJSONObject; const Name: string): Integer;
begin
  Result := StrToIntDef(JStr(J, Name), 0);
end;

function TErpClient.Get(const Path: string; out Body: string): Boolean;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
begin
  Result := False;
  Body := '';
  FLastError := '';
  if not Configured then
  begin
    FLastError := 'адрес ERP не задан (crm.ini, секция [erp])';
    Exit;
  end;
  Http := THTTPClient.Create;
  try
    Http.ConnectionTimeout := FTimeoutMs;
    Http.ResponseTimeout := FTimeoutMs;
    if FKey <> '' then
      Http.CustomHeaders['X-API-Key'] := FKey;
    try
      Resp := Http.Get(BaseUrl + Path);
      Body := Resp.ContentAsString(TEncoding.UTF8);
      Result := Resp.StatusCode = 200;
      if not Result then
        FLastError := Format('HTTP %d: %s', [Resp.StatusCode, Copy(Body, 1, 200)]);
    except
      on E: Exception do
        FLastError := E.Message;
    end;
  finally
    Http.Free;
  end;
end;

function TErpClient.Health(out Status: TErpStatus): Boolean;
var
  Body: string;
  J: TJSONObject;
begin
  FillChar(Status, SizeOf(Status), 0);
  Status.Message := '';
  Result := Get('/api/v1/health', Body);
  if not Result then
  begin
    Status.Online := False;
    Status.Message := 'ERP недоступна: ' + FLastError;
    Exit;
  end;
  J := TJSONObject.ParseJSONValue(Body) as TJSONObject;
  try
    Status.Online := JStr(J, 'status') = 'ok';
    Status.ServerTime := JStr(J, 'time');
    Status.QueueDepth := JInt(J, 'queue');
  finally
    J.Free;
  end;
  // сводка — отдельным запросом, её отсутствие не считаем ошибкой связи
  if Get('/api/v1/stats', Body) then
  begin
    J := TJSONObject.ParseJSONValue(Body) as TJSONObject;
    try
      Status.RowsNew := JInt(J, 'rows_new');
      Status.Batches := JInt(J, 'batches');
    finally
      J.Free;
    end;
  end;
  Status.Message := Format('ERP на связи (%s): очередь %d, пакетов %d, записей принято %d',
    [BaseUrl, Status.QueueDepth, Status.Batches, Status.RowsNew]);
end;

function TErpClient.SendDatabase(const DbPath: string; out BatchId: string): Boolean;
var
  Http: THTTPClient;
  Resp: IHTTPResponse;
  Src, Gz: TMemoryStream;
  Zip: TZCompressionStream;
  TmpDb, Body: string;
  J: TJSONObject;
begin
  Result := False;
  BatchId := '';
  FLastError := '';
  if not Configured then
  begin
    FLastError := 'адрес ERP не задан (crm.ini, секция [erp])';
    Exit;
  end;
  if not TFile.Exists(DbPath) then
  begin
    FLastError := 'база не найдена: ' + DbPath;
    Exit;
  end;

  // копия: файл открыт FireDAC, читать его напрямую нельзя
  TmpDb := TPath.Combine(TPath.GetTempPath, 'crm_erp_' + IntToStr(GetTickCount) + '.db');
  Src := TMemoryStream.Create;
  Gz := TMemoryStream.Create;
  try
    try
      TFile.Copy(DbPath, TmpDb, True);
      Src.LoadFromFile(TmpDb);
      Src.Position := 0;
      // 15 + 16 — заголовок gzip, как ждёт хаб
      Zip := TZCompressionStream.Create(Gz, zcDefault, 15 + 16);
      try
        Zip.CopyFrom(Src, Src.Size);
      finally
        Zip.Free;
      end;
      Gz.Position := 0;

      Http := THTTPClient.Create;
      try
        Http.ConnectionTimeout := FTimeoutMs;
        Http.ResponseTimeout := FTimeoutMs * 4;   // отправка базы дольше
        Http.CustomHeaders['Content-Type'] := 'application/gzip';
        Http.CustomHeaders['X-Client-Id'] := FClientId;
        if FKey <> '' then
          Http.CustomHeaders['X-API-Key'] := FKey;
        Resp := Http.Post(BaseUrl + '/api/v1/batches', Gz);
        Body := Resp.ContentAsString(TEncoding.UTF8);
        Result := Resp.StatusCode in [200, 201, 202];
        if Result then
        begin
          J := TJSONObject.ParseJSONValue(Body) as TJSONObject;
          try
            BatchId := JStr(J, 'batch_id');
            if BatchId = '' then BatchId := JStr(J, 'id');
            FLastError := JStr(J, 'status');   // accepted | duplicate
          finally
            J.Free;
          end;
        end
        else
          FLastError := Format('HTTP %d: %s', [Resp.StatusCode, Copy(Body, 1, 200)]);
      finally
        Http.Free;
      end;
    except
      on E: Exception do
        FLastError := E.ClassName + ': ' + E.Message;
    end;
  finally
    Gz.Free;
    Src.Free;
    if TFile.Exists(TmpDb) then
      TFile.Delete(TmpDb);
  end;
end;

function TErpClient.BatchStatus(const BatchId: string; out State: string): Boolean;
var
  Body: string;
  J: TJSONObject;
begin
  State := '';
  Result := Get('/api/v1/batches/' + BatchId, Body);
  if not Result then Exit;
  J := TJSONObject.ParseJSONValue(Body) as TJSONObject;
  try
    State := JStr(J, 'status');
  finally
    J.Free;
  end;
end;

end.
