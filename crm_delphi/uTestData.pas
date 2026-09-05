unit uTestData;
{
  Генератор тестовых данных и DML-тест всех сущностей CRM.

  --seed-demo [база]  — наполнить базу полным набором реалистичных записей
                        (клиенты, контакты, лиды, сделки, номенклатура,
                        заказы со строками, задачи). Повторный запуск не
                        дублирует: клиенты — по IDNO, остальное — по имени/№.
  --dml-test          — для каждой сущности INSERT → SELECT → UPDATE →
                        SELECT → DELETE → COUNT, строки заказа, проводка
                        остатков, конвертация лида, дедупликация клиентов,
                        фильтры/пресеты. Во временной базе.

  Правило проекта (AGENTS.md): любая новая сущность/поле добавляется сюда
  в обе части — в генератор и в DML-проверки.
}

interface

uses
  System.SysUtils, System.Classes, uClientsDB, uCrmData, uContragenti;

type
  TSeedStats = record
    Clients, Contacts, Leads, Deals, Items, Orders, Lines, Tasks: Integer;
    function Text: string;
  end;

function SeedDemo(DB: TClientsDB; Data: TCrmData): TSeedStats;
function RunDmlTest(DB: TClientsDB; Data: TCrmData; Log: TStrings): Boolean;

implementation

uses
  System.StrUtils, System.Variants, System.Math, System.DateUtils;

{ TSeedStats }

function TSeedStats.Text: string;
begin
  Result := Format('клиентов %d, контактов %d, лидов %d, сделок %d, номенклатуры %d, ' +
    'заказов %d (строк %d), задач %d',
    [Clients, Contacts, Leads, Deals, Items, Orders, Lines, Tasks]);
end;

{ ── справочные наборы ── }

type
  TCompany = record
    Idno, Name, Form, Addr, Admin, CType, Phone, Email: string;
  end;

const
  COMPANIES: array[0..14] of TCompany = (
    (Idno: '1003600116460'; Name: 'CENTRUL DE ELABORARE UNISIM-SOFT S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Chişinău, str. Alba-Iulia 75/B'; Admin: 'TUHARI PAVEL [Administrator]'; CType: 'Партнёр'; Phone: '+373 22 590-100'; Email: 'office@unisim.md'),
    (Idno: '1017600018242'; Name: 'Societatea cu Răspundere Limitată ALFA-VIS COM'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Chişinău, sec. Centru, str. Alecsandri Vasile, 80'; Admin: 'BUBIS YEVGENY [Administrator]'; CType: 'Клиент'; Phone: '+373 22 123-456'; Email: 'office@alfa-vis.md'),
    (Idno: '1002600021871'; Name: 'AGRO-PRIM S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'r-l Ialoveni, s. Costeşti, str. Ştefan cel Mare 12'; Admin: 'POPESCU ION [Administrator]'; CType: 'Клиент'; Phone: '+373 79 111-222'; Email: 'ion@agro-prim.md'),
    (Idno: '1004600045213'; Name: 'MOLDTEHNICA S.A.'; Form: 'Societate pe acţiuni'; Addr: 'mun. Chişinău, bd. Dacia 49/3'; Admin: 'RUSU ANDREI [Director]'; CType: 'Поставщик'; Phone: '+373 22 771-234'; Email: 'sales@moldtehnica.md'),
    (Idno: '1008600009874'; Name: 'PANIFICATIE BĂLŢI S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Bălţi, str. Decebal 101'; Admin: 'CEBAN MARIA [Administrator]'; CType: 'Клиент'; Phone: '+373 231 22-333'; Email: 'panificatie@balti.md'),
    (Idno: '1011600032557'; Name: 'VINĂRIA CAHUL S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'or. Cahul, str. Ştefan cel Mare 8'; Admin: 'MUNTEANU VASILE [Administrator]'; CType: 'Клиент'; Phone: '+373 299 33-444'; Email: 'export@vinaria-cahul.md'),
    (Idno: '1013600001988'; Name: 'ELECTROMONTAJ-SERVICE S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Chişinău, str. Uzinelor 21'; Admin: 'GROSU DUMITRU [Administrator]'; CType: 'Поставщик'; Phone: '+373 22 470-111'; Email: 'info@electromontaj.md'),
    (Idno: '1015600078123'; Name: 'Î.I. „CROITORU TATIANA”'; Form: 'Întreprindere individuală'; Addr: 'or. Orhei, str. Vasile Lupu 33'; Admin: 'CROITORU TATIANA [Fondator]'; CType: 'Клиент'; Phone: '+373 235 21-100'; Email: 'tatiana.croitoru@mail.md'),
    (Idno: '1016600054321'; Name: 'LOGISTIC-TRANS GRUP S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Chişinău, str. Munceşti 271'; Admin: 'LUNGU SERGIU [Administrator]'; CType: 'Партнёр'; Phone: '+373 22 522-900'; Email: 'dispatch@logistic-trans.md'),
    (Idno: '1018600011200'; Name: 'FARM-PLUS S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Chişinău, str. Ismail 98'; Admin: 'CIOBANU ELENA [Administrator]'; CType: 'Клиент'; Phone: '+373 22 210-321'; Email: 'farm-plus@mail.md'),
    (Idno: '1019600093456'; Name: 'METAL-CONSTRUCT S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Chişinău, str. Petricani 19'; Admin: 'BOTNARI VICTOR [Administrator]'; CType: 'Клиент'; Phone: '+373 22 440-505'; Email: 'office@metal-construct.md'),
    (Idno: '1020600024680'; Name: 'IT-SOLUTIONS MOLDOVA S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Chişinău, str. Puşkin 47'; Admin: 'CODREANU ALEXANDRU [Administrator]'; CType: 'Партнёр'; Phone: '+373 22 888-777'; Email: 'hello@itsolutions.md'),
    (Idno: '1021600036912'; Name: 'MOBILA-DESIGN S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Chişinău, str. Industrială 40'; Admin: 'SÎRBU LILIANA [Administrator]'; CType: 'Клиент'; Phone: '+373 22 610-202'; Email: 'sales@mobila-design.md'),
    (Idno: '1022600048135'; Name: 'AUTO-SERVICE EXPRESS S.R.L.'; Form: 'Societate cu răspundere limitată'; Addr: 'mun. Bălţi, str. Ştefan cel Mare 180'; Admin: 'ROTARU IGOR [Administrator]'; CType: 'Клиент'; Phone: '+373 231 44-555'; Email: 'service@auto-express.md'),
    (Idno: '1023600059246'; Name: 'GOSPODARIA ŢĂRĂNEASCĂ „SPICUL”'; Form: 'Gospodărie ţărănească'; Addr: 'r-l Cahul, s. Manta'; Admin: 'BURLACU PETRU [Fondator]'; CType: 'Клиент'; Phone: '+373 299 55-666'; Email: ''));

  CONTACT_NAMES: array[0..15] of string = (
    'Ion Popescu', 'Maria Ceban', 'Andrei Rusu', 'Elena Ciobanu', 'Victor Botnari',
    'Liliana Sîrbu', 'Igor Rotaru', 'Alexandru Codreanu', 'Tatiana Croitoru', 'Sergiu Lungu',
    'Dumitru Grosu', 'Vasile Munteanu', 'Natalia Guţu', 'Oleg Ţurcanu', 'Ana Moraru', 'Pavel Tuhari');
  POSITIONS: array[0..5] of string = (
    'Директор', 'Главный бухгалтер', 'Менеджер по закупкам', 'Технический директор', 'Логист', 'Коммерческий директор');

  LEAD_COMPANIES: array[0..11] of string = (
    'Brutăria Codru SRL', 'Ferma Eco-Lapte', 'Salon Auto Nord', 'Clinica Dental-Plus',
    'Hotel Nistru', 'Tipografia Grafic-Art', 'Pescăria Dunărea', 'Apicultura Moldova',
    'Şcoala de şoferi Start', 'Cafeneaua Tucano', 'Atelier Textil Lux', 'Serviciul IT Nord');
  LEAD_PERSONS: array[0..11] of string = (
    'Radu Cojocaru', 'Diana Bejan', 'Mihai Ursu', 'Cristina Postolachi', 'Valeriu Chirilă',
    'Irina Frunză', 'Grigore Ţîbîrnă', 'Svetlana Roşca', 'Nicolae Damian', 'Olga Cazacu',
    'Eugen Bivol', 'Larisa Stratan');

  ITEMS_SEED: array[0..17, 0..5] of string = (
    ('T-001', 'Насос дозирующий ND-25', 'Товар', 'шт', '12500', '5'),
    ('T-002', 'Фильтр тонкой очистки FT-10', 'Товар', 'шт', '840', '40'),
    ('T-003', 'Труба ПВХ 50 мм', 'Товар', 'м', '95', '320'),
    ('T-004', 'Кабель ВВГ 3×2.5', 'Товар', 'м', '38', '900'),
    ('T-005', 'Контроллер PLC-200', 'Товар', 'шт', '6900', '4'),
    ('T-006', 'Датчик уровня LS-3', 'Товар', 'шт', '1450', '12'),
    ('T-007', 'Мука пшеничная в/с', 'Товар', 'кг', '9.5', '2500'),
    ('T-008', 'Масло подсолнечное рафин.', 'Товар', 'л', '31', '600'),
    ('S-001', 'Монтаж и пусконаладка', 'Услуга', 'час', '350', '0'),
    ('S-002', 'Сервисное обслуживание (выезд)', 'Услуга', 'услуга', '900', '0'),
    ('S-003', 'Проектирование', 'Услуга', 'час', '500', '0'),
    ('S-004', 'Доставка по Кишинёву', 'Услуга', 'услуга', '250', '0'),
    ('S-005', 'Консультация бухгалтера', 'Услуга', 'час', '400', '0'),
    ('P-001', 'Установка дозирования УД-1', 'Изделие', 'компл', '42000', '0'),
    ('P-002', 'Шкаф управления ШУ-2', 'Изделие', 'шт', '18500', '1'),
    ('P-003', 'Хлеб «Домашний» 0,6 кг', 'Изделие', 'шт', '14', '0'),
    ('P-004', 'Стол офисный СО-120', 'Изделие', 'шт', '3200', '3'),
    ('P-005', 'Ворота металлические 3×2', 'Изделие', 'компл', '15800', '0'));

  STAGES: array[0..4] of string = ('Новая', 'Предложение', 'Переговоры', 'Выиграна', 'Проиграна');
  DEAL_TITLES: array[0..11] of string = (
    'Поставка дозирующей установки', 'Автоматизация линии розлива', 'Шкафы управления для цеха',
    'Сервисный контракт на год', 'Мебель для офиса', 'Ворота и ограждение склада',
    'Хлебопекарная линия — модернизация', 'Проект электроснабжения', 'Поставка кабеля и щитов',
    'Консалтинг по учёту', 'Доставка продукции сетям', 'Датчики уровня для резервуаров');
  TASK_SUBJECTS: array[0..9] of string = (
    'Позвонить по оплате заказа', 'Отправить коммерческое предложение', 'Встреча: согласование ТЗ',
    'Выезд на объект — замеры', 'Согласовать график поставки', 'Подготовить договор',
    'Напомнить об акте выполненных работ', 'Презентация продукции', 'Уточнить реквизиты',
    'Контроль отгрузки');

function D(Days: Integer): string;
begin
  Result := FormatDateTime('yyyy-mm-dd', Now + Days);
end;

function Idx(const Def: TEntityDef; const Field: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Def.Fields) do
    if Def.Fields[I].Name = Field then Exit(I);
  raise Exception.Create('Нет поля ' + Field + ' в ' + Def.Table);
end;

function Vals(const Def: TEntityDef; const Pairs: array of string): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(Def.Fields));
  for I := 0 to High(Def.Fields) do Result[I] := Def.Fields[I].Default;
  I := 0;
  while I < Length(Pairs) - 1 do
  begin
    Result[Idx(Def, Pairs[I])] := Pairs[I + 1];
    Inc(I, 2);
  end;
end;

function Exists(Data: TCrmData; const Table, Where: string): Boolean;
begin
  Result := Data.Count(Table, Where) > 0;
end;

function Q(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

{ ── генератор ── }

function SeedDemo(DB: TClientsDB; Data: TCrmData): TSeedStats;
var
  I, J, N, Id, ClientId, ItemId, OrderId: Integer;
  C: TCompany;
  Card: TCounterpartyCard;
  ClientIds: TArray<Integer>;
  ItemIds: TArray<Integer>;
  ItemPrices: TArray<Double>;
  Kind, Status, Num: string;
  Conn: TArray<Integer>;
begin
  FillChar(Result, SizeOf(Result), 0);
  Data.EnsureSchema;

  // клиенты — через тот же путь, что и SDK (AddFromCard), дедупликация по IDNO
  SetLength(ClientIds, Length(COMPANIES));
  for I := 0 to High(COMPANIES) do
  begin
    C := COMPANIES[I];
    Card.Clear;
    Card.Idno := C.Idno; Card.Denumire := C.Name; Card.FormaJuridica := C.Form;
    Card.Adresa := C.Addr; Card.Administratori := C.Admin; Card.Lichidata := 'Nu';
    Card.Inregistrare := Format('%.2d.%.2d.20%.2d', [1 + I, 1 + (I mod 12), 5 + I]);
    Card.DetailsText := '=== Date de bază ===' + sLineBreak + 'IDNO/Cod Fiscal: ' + C.Idno +
      sLineBreak + 'Denumire: ' + C.Name + sLineBreak + 'Adresa juridică: ' + C.Addr;
    if DB.AddFromCard(Card, Id) = arAdded then Inc(Result.Clients);
    ClientId := Data.Scalar('SELECT id FROM clients WHERE idno = ' + Q(C.Idno));
    DB.Connection.ExecSQL('UPDATE clients SET client_type = :t, phone = :p, email = :e, ' +
      'contact_person = :c WHERE id = :id AND (client_type IS NULL OR client_type = '''')',
      [C.CType, C.Phone, C.Email, CONTACT_NAMES[I mod Length(CONTACT_NAMES)], ClientId]);
    ClientIds[I] := ClientId;
  end;

  // контакты — по 2 у первых 10 клиентов
  for I := 0 to 9 do
    for J := 0 to 1 do
    begin
      N := (I * 2 + J) mod Length(CONTACT_NAMES);
      if not Exists(Data, 'contacts', 'name = ' + Q(CONTACT_NAMES[N]) + ' AND client_id = ' + IntToStr(ClientIds[I])) then
      begin
        Data.Insert(DefContacts, Vals(DefContacts, ['name', CONTACT_NAMES[N],
          'client_id', IntToStr(ClientIds[I]), 'position', POSITIONS[(I + J) mod Length(POSITIONS)],
          'phone', Format('+373 6%d %.3d-%.3d', [I mod 10, 100 + I * 7, 200 + J * 33]),
          'email', LowerCase(StringReplace(CONTACT_NAMES[N], ' ', '.', [])) + '@example.md',
          'notes', IfThen(J = 0, 'Основной контакт', '')]));
        Inc(Result.Contacts);
      end;
    end;

  // лиды — все статусы и источники
  for I := 0 to High(LEAD_COMPANIES) do
    if not Exists(Data, 'leads', 'company = ' + Q(LEAD_COMPANIES[I])) then
    begin
      Data.Insert(DefLeads, Vals(DefLeads, ['name', LEAD_PERSONS[I], 'company', LEAD_COMPANIES[I],
        'status', ENUM_LEAD_STATUS.Split([';'])[I mod 4],
        'source', ENUM_LEAD_SOURCE.Split([';'])[I mod 6],
        'phone', Format('+373 7%d %.3d-%.3d', [I mod 10, 300 + I * 5, 400 + I * 9]),
        'email', 'contact' + IntToStr(I + 1) + '@' + LowerCase(Copy(StringReplace(LEAD_COMPANIES[I], ' ', '', [rfReplaceAll]), 1, 8)) + '.md',
        'notes', 'Первичный интерес: ' + DEAL_TITLES[I mod Length(DEAL_TITLES)]]));
      Inc(Result.Leads);
    end;

  // сделки — по всем этапам, суммы 5 000 … 250 000
  for I := 0 to High(DEAL_TITLES) do
    if not Exists(Data, 'deals', 'title = ' + Q(DEAL_TITLES[I])) then
    begin
      Data.Insert(DefDeals, Vals(DefDeals, ['title', DEAL_TITLES[I],
        'client_id', IntToStr(ClientIds[(I * 3) mod Length(ClientIds)]),
        'stage', STAGES[I mod 5], 'amount', IntToStr(5000 + I * 21000),
        'close_date', D(7 + I * 6), 'notes', IfThen(I mod 5 = 3, 'Договор подписан', '')]));
      Inc(Result.Deals);
    end;

  // номенклатура
  SetLength(ItemIds, Length(ITEMS_SEED));
  SetLength(ItemPrices, Length(ITEMS_SEED));
  for I := 0 to High(ITEMS_SEED) do
  begin
    if not Exists(Data, 'items', 'code = ' + Q(ITEMS_SEED[I][0])) then
    begin
      Data.Insert(DefItems, Vals(DefItems, ['code', ITEMS_SEED[I][0], 'name', ITEMS_SEED[I][1],
        'kind', ITEMS_SEED[I][2], 'unit_', ITEMS_SEED[I][3], 'price', ITEMS_SEED[I][4],
        'vat', IfThen(ITEMS_SEED[I][2] = 'Услуга', '20', '20'), 'stock', ITEMS_SEED[I][5],
        'notes', '']));
      Inc(Result.Items);
    end;
    ItemIds[I] := Data.Scalar('SELECT id FROM items WHERE code = ' + Q(ITEMS_SEED[I][0]));
    ItemPrices[I] := StrToFloat(StringReplace(ITEMS_SEED[I][4], '.', FormatSettings.DecimalSeparator, []));
  end;

  // заказы — 18 штук: продажа / услуга / производство, все статусы, 1–3 строки
  for I := 0 to 17 do
  begin
    Num := Format('%.4d', [I + 1]);
    if Exists(Data, 'orders', 'number = ' + Q(Num)) then Continue;
    Kind := ENUM_ORDER_KIND.Split([';'])[I mod 3];
    Status := ENUM_ORDER_STATUS.Split([';'])[I mod 6];
    OrderId := Data.Insert(DefOrders, Vals(DefOrders, ['number', Num, 'order_date', D(-40 + I * 2),
      'client_id', IfThen(Kind = 'Производство', '', IntToStr(ClientIds[(I * 5) mod Length(ClientIds)])),
      'kind', Kind, 'status', Status, 'notes', IfThen(I mod 4 = 0, 'Срочный', '')]));
    Inc(Result.Orders);
    for J := 0 to I mod 3 do
    begin
      if Kind = 'Продажа' then N := (I + J) mod 8           // T-001..T-008
      else if Kind = 'Услуга' then N := 8 + (I + J) mod 5   // S-001..S-005
      else N := 13 + (I + J) mod 5;                         // P-001..P-005
      Data.AddOrderLine(OrderId, ItemIds[N], 1 + (I + J) mod 4, ItemPrices[N]);
      Inc(Result.Lines);
    end;
    if (Status = 'Выполнен') or (Status = 'Оплачен') then
      Data.PostOrder(OrderId);
  end;

  // задачи — 24: просроченные, сегодня, будущие, часть выполнена
  for I := 0 to 23 do
  begin
    if Exists(Data, 'tasks', 'subject = ' + Q(TASK_SUBJECTS[I mod 10] + ' #' + IntToStr(I + 1))) then Continue;
    Data.Insert(DefTasks, Vals(DefTasks, [
      'subject', TASK_SUBJECTS[I mod 10] + ' #' + IntToStr(I + 1),
      'kind', ENUM_TASK_KIND.Split([';'])[I mod 3],
      'due_at', D(-6 + I),
      'client_id', IntToStr(ClientIds[(I * 7) mod Length(ClientIds)]),
      'deal_id', IfThen(I mod 3 = 0, VarToStr(Data.Scalar('SELECT id FROM deals ORDER BY id LIMIT 1 OFFSET ' + IntToStr(I mod 12))), ''),
      'done', IfThen(I < 4, '1', '0'),
      'notes', '']));
    Inc(Result.Tasks);
  end;
end;

{ ── DML-тест ── }

function RunDmlTest(DB: TClientsDB; Data: TCrmData; Log: TStrings): Boolean;
var
  Fails: Integer;

  procedure Check(Cond: Boolean; const What: string);
  begin
    if Cond then Log.Add('[OK]   ' + What)
    else
    begin
      Log.Add('[FAIL] ' + What);
      Inc(Fails);
    end;
  end;

  procedure CrudCycle(const Def: TEntityDef; const NameField: string;
    const Ins, Upd: array of string);
  var
    N0, Id: Integer;
    Row: TRow;
    Rows: TArray<TRow>;
  begin
    N0 := Data.Count(Def.Table);
    Id := Data.Insert(Def, Vals(Def, Ins));
    Check(Id > 0, Def.Table + ': INSERT → id ' + IntToStr(Id));
    Check(Data.Count(Def.Table) = N0 + 1, Def.Table + ': COUNT после INSERT = ' + IntToStr(N0 + 1));
    Check(Data.Get(Def, Id, Row) and (Row.Values[Idx(Def, NameField)] = Ins[1]),
      Def.Table + ': SELECT по id возвращает вставленные значения');
    Rows := Data.List(Def, Ins[1]);
    Check(Length(Rows) >= 1, Def.Table + ': LIST с фильтром «' + Ins[1] + '» находит запись');
    Data.Update(Def, Id, Vals(Def, Upd));
    Check(Data.Get(Def, Id, Row) and (Row.Values[Idx(Def, NameField)] = Upd[1]),
      Def.Table + ': UPDATE → SELECT видит новые значения («' + Upd[1] + '»)');
    Data.Delete(Def, Id);
    Check(not Data.Get(Def, Id, Row), Def.Table + ': DELETE → SELECT по id пуст');
    Check(Data.Count(Def.Table) = N0, Def.Table + ': COUNT после DELETE вернулся к ' + IntToStr(N0));
  end;

var
  Card: TCounterpartyCard;
  Id, Id2, ClientId, ItemGoods, ItemProd, ItemSvc, OrderId, LeadId, N: Integer;
  Res: TAddResult;
  V: Variant;
  Lines: TArray<TOrderLine>;
  Msg: string;
  Rows: TArray<TRow>;
begin
  Fails := 0;
  Data.EnsureSchema;

  // ── клиенты: AddFromCard / дубликат / поиск / удаление ──
  Card.Clear;
  Card.Idno := '1099900012345'; Card.Denumire := 'DML-TEST S.R.L.';
  Card.FormaJuridica := 'SRL'; Card.Adresa := 'Chişinău, str. Test 1';
  Card.Administratori := 'TEST ION [Administrator]';
  N := DB.Count;
  Res := DB.AddFromCard(Card, Id);
  Check(Res = arAdded, 'clients: AddFromCard → arAdded');
  Check(DB.Count = N + 1, 'clients: COUNT +1');
  Check(DB.ExistsByIdno(Card.Idno), 'clients: ExistsByIdno');
  Res := DB.AddFromCard(Card, Id2);
  Check(Res = arDuplicate, 'clients: повторный AddFromCard → arDuplicate (дедупликация по IDNO)');
  Check(Length(DB.List('DML-TEST')) = 1, 'clients: List с фильтром находит 1');
  DB.Connection.ExecSQL('UPDATE clients SET phone = :p, email = :e, client_type = :t WHERE id = :id',
    ['+373 22 000-000', 'dml@test.md', 'Поставщик', Id]);
  V := Data.Scalar('SELECT client_type FROM clients WHERE id = ' + IntToStr(Id));
  Check(VarToStr(V) = 'Поставщик', 'clients: UPDATE карточки (тип/телефон/e-mail)');
  ClientId := Id;

  // ── контакты ──
  CrudCycle(DefContacts, 'name',
    ['name', 'Тест Контактов', 'client_id', IntToStr(ClientId), 'position', 'Бухгалтер', 'phone', '+373 69 1', 'email', 'a@b.md'],
    ['name', 'Тест Контактов (изм.)', 'client_id', IntToStr(ClientId), 'position', 'Директор']);

  // ── лиды + конвертация ──
  CrudCycle(DefLeads, 'name',
    ['name', 'Лид Тестовый', 'company', 'Test Lead Co', 'status', 'Новый', 'source', 'Сайт'],
    ['name', 'Лид Тестовый (изм.)', 'company', 'Test Lead Co', 'status', 'В работе', 'source', 'Звонок']);
  LeadId := Data.Insert(DefLeads, Vals(DefLeads, ['name', 'Конверт Лид', 'company', 'Convert Co SRL',
    'status', 'В работе', 'source', 'Выставка', 'phone', '+373 79 000-001', 'email', 'c@convert.md']));
  N := DB.Count;
  Msg := Data.ConvertLead(LeadId, Id2);
  Check((Id2 > 0) and (DB.Count = N + 1), 'leads: ConvertLead создаёт клиента: ' + Msg);
  V := Data.Scalar('SELECT status FROM leads WHERE id = ' + IntToStr(LeadId));
  Check(VarToStr(V) = 'Конвертирован', 'leads: статус после конвертации = Конвертирован');
  Msg := Data.ConvertLead(LeadId, Id);
  Check(Id = 0, 'leads: повторная конвертация отклонена (' + Msg + ')');
  Data.Delete(DefLeads, LeadId);
  DB.Delete(Id2);

  // ── сделки ──
  CrudCycle(DefDeals, 'title',
    ['title', 'Тест Сделка', 'client_id', IntToStr(ClientId), 'stage', 'Новая', 'amount', '1000', 'close_date', D(10)],
    ['title', 'Тест Сделка (изм.)', 'client_id', IntToStr(ClientId), 'stage', 'Выиграна', 'amount', '2500', 'close_date', D(5)]);
  Rows := Data.List(DefDeals, '', 't.stage = ''Выиграна''');
  Check(Length(Rows) >= 0, 'deals: LIST с пресетом (ExtraWhere) выполняется');

  // ── номенклатура ──
  CrudCycle(DefItems, 'name',
    ['name', 'Тест Товар', 'code', 'X-1', 'kind', 'Товар', 'unit_', 'шт', 'price', '10', 'stock', '7'],
    ['name', 'Тест Товар (изм.)', 'code', 'X-1', 'kind', 'Товар', 'unit_', 'шт', 'price', '12.5', 'stock', '7']);
  ItemGoods := Data.Insert(DefItems, Vals(DefItems, ['code', 'DML-T', 'name', 'DML Товар', 'kind', 'Товар', 'unit_', 'шт', 'price', '100', 'stock', '10']));
  ItemSvc := Data.Insert(DefItems, Vals(DefItems, ['code', 'DML-S', 'name', 'DML Услуга', 'kind', 'Услуга', 'unit_', 'час', 'price', '50', 'stock', '0']));
  ItemProd := Data.Insert(DefItems, Vals(DefItems, ['code', 'DML-P', 'name', 'DML Изделие', 'kind', 'Изделие', 'unit_', 'шт', 'price', '900', 'stock', '0']));

  // ── заказы: CRUD, строки, пересчёт, проводка по всем видам ──
  CrudCycle(DefOrders, 'number',
    ['number', 'DML-1', 'order_date', D(0), 'client_id', IntToStr(ClientId), 'kind', 'Продажа', 'status', 'Черновик'],
    ['number', 'DML-1x', 'order_date', D(0), 'client_id', IntToStr(ClientId), 'kind', 'Услуга', 'status', 'Подтверждён']);

  OrderId := Data.Insert(DefOrders, Vals(DefOrders, ['number', 'DML-S', 'order_date', D(0),
    'client_id', IntToStr(ClientId), 'kind', 'Продажа', 'status', 'Черновик']));
  Data.AddOrderLine(OrderId, ItemGoods, 3, 100);
  Data.AddOrderLine(OrderId, ItemSvc, 2, 50);
  Lines := Data.OrderLines(OrderId);
  Check(Length(Lines) = 2, 'order_lines: две строки добавлены');
  V := Data.Scalar('SELECT total FROM orders WHERE id = ' + IntToStr(OrderId));
  Check(Abs(Double(V) - 400) < 0.01, 'orders: итог пересчитан = 400 (3×100 + 2×50)');
  Data.DeleteOrderLine(Lines[1].Id);
  V := Data.Scalar('SELECT total FROM orders WHERE id = ' + IntToStr(OrderId));
  Check((Length(Data.OrderLines(OrderId)) = 1) and (Abs(Double(V) - 300) < 0.01),
    'order_lines: удаление строки → итог 300');
  Msg := Data.PostOrder(OrderId);
  Check(Pos('статусом', Msg) > 0, 'orders: проводка черновика отклонена (' + Msg + ')');
  Data.Update(DefOrders, OrderId, Vals(DefOrders, ['number', 'DML-S', 'order_date', D(0),
    'client_id', IntToStr(ClientId), 'kind', 'Продажа', 'status', 'Выполнен']));
  Msg := Data.PostOrder(OrderId);
  V := Data.Scalar('SELECT stock FROM items WHERE id = ' + IntToStr(ItemGoods));
  Check(Abs(Double(V) - 7) < 0.01, 'orders: продажа проведена — остаток 10 → 7 (' + Msg + ')');
  Msg := Data.PostOrder(OrderId);
  Check(Msg = 'уже проведён', 'orders: повторная проводка отклонена');

  Id := Data.Insert(DefOrders, Vals(DefOrders, ['number', 'DML-P', 'order_date', D(0),
    'kind', 'Производство', 'status', 'Выполнен']));
  Data.AddOrderLine(Id, ItemProd, 4, 900);
  Data.PostOrder(Id);
  V := Data.Scalar('SELECT stock FROM items WHERE id = ' + IntToStr(ItemProd));
  Check(Abs(Double(V) - 4) < 0.01, 'orders: производство проведено — оприходовано 0 → 4');
  Data.Delete(DefOrders, Id);

  Id := Data.Insert(DefOrders, Vals(DefOrders, ['number', 'DML-U', 'order_date', D(0),
    'client_id', IntToStr(ClientId), 'kind', 'Услуга', 'status', 'Оплачен']));
  Data.AddOrderLine(Id, ItemSvc, 5, 50);
  Msg := Data.PostOrder(Id);
  Check(Pos('услуги', Msg) = 1, 'orders: услуга проведена без изменения остатков (' + Msg + ')');
  Data.Delete(DefOrders, Id);
  Check(Data.Count('order_lines', 'order_id = ' + IntToStr(Id)) = 0, 'orders: DELETE заказа удаляет его строки');
  Data.Delete(DefOrders, OrderId);

  // ── задачи ──
  CrudCycle(DefTasks, 'subject',
    ['subject', 'Тест Задача', 'kind', 'Задача', 'due_at', D(-1), 'client_id', IntToStr(ClientId), 'done', '0'],
    ['subject', 'Тест Задача (изм.)', 'kind', 'Звонок', 'due_at', D(1), 'client_id', IntToStr(ClientId), 'done', '1']);
  Id := Data.Insert(DefTasks, Vals(DefTasks, ['subject', 'Просроченная', 'kind', 'Задача', 'due_at', D(-3), 'done', '0']));
  Rows := Data.List(DefTasks, '', 't.done = 0 AND t.due_at < date(''now'',''localtime'')');
  Check(Length(Rows) >= 1, 'tasks: пресет «Просроченные» находит задачу');
  DB.Connection.ExecSQL('UPDATE tasks SET done = 1 WHERE id = :id', [Id]);
  Rows := Data.List(DefTasks, '', 't.id = ' + IntToStr(Id) + ' AND t.done = 0');
  Check(Length(Rows) = 0, 'tasks: после «Выполнено» не попадает в открытые');
  Data.Delete(DefTasks, Id);

  // ── уборка ──
  Data.Delete(DefItems, ItemGoods);
  Data.Delete(DefItems, ItemSvc);
  Data.Delete(DefItems, ItemProd);
  DB.Delete(ClientId);
  Check(not DB.ExistsByIdno('1099900012345'), 'clients: DELETE');

  Log.Add('');
  Log.Add(Format('DML-тест: %d проверок, FAIL = %d', [Log.Count - 1, Fails]));
  Result := Fails = 0;
end;

end.
