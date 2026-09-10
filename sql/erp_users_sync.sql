-- =====================================================================
--  Синхронизация сотрудников Demo CRM  <->  UNIAC/OfficePlus (сторона ERP)
--
--  Что делает
--    Держит карточку человека одинаковой в двух базах: SQLite демо-CRM и
--    конфигурационном дереве UNIA. Обе стороны работают одинаково:
--    изменение ставится в очередь **триггером**, а разбирает очередь
--    программа (хаб, hub/users_sync.py). Сторона CRM — таблица sync_log и
--    триггеры users_sync_ai/_au/_ad (crm_macos/Sources/DemoCRM/UsersSync.swift,
--    crm_delphi/uUsersSync.pas).
--
--  Как устроены пользователи в UNIA (проверено по исходникам SL/Cnf и SL/Clnt)
--    Пользователь — это узел дерева настроек, а не строка таблицы:
--      A$ADM  (A$ADM$V)  OBJ_ID, OBJ_TYPE = 7, OBJ_SUBTYPE = 0 (0 — человек,
--                        -1 — группа), PARENT_ID, NAME, SECTION,
--                        DATE_BEGIN, DATE_FINAL;
--      A$ADP  (A$ADP$V)  свойства узла: KEY = UPPER(NAME), значение в SVALUE
--                        (через представление — VALUE). Ключи, которые читает
--                        клиент: USERNAME, PASSWORD, ENCODED, Enabled, ID,
--                        ADMIN, USER_SC, NeedChangePassword, UserGroupList…
--      TMS_MUNC          кадровая карточка: COD (= свойство USER_SC), FAMILIA,
--                        NUMELE, EMAIL, KADR_TEL_WORK, KADR_TEL_CELL — именно
--                        оттуда клиент берёт почту и телефоны (uDMA.cpp,
--                        класс TOraUserInfo).
--    Пароль в CRM и в ERP **не общий**: в CRM лежит SHA-256, в UNIA его
--    кодирует серверный a$util.hide_passwd. Через очередь пароли не ходят —
--    передаётся только признак «пароль стандартный, надо сменить».
--
--  Соответствие полей
--    CRM users.login       <->  A$ADP KEY = 'USERNAME'
--    CRM users.full_name   <->  A$ADM.NAME
--    CRM users.position    <->  A$ADP KEY = 'POSITION'
--    CRM users.role        <->  A$ADP KEY = 'CRMROLE' (+ ADMIN = true для
--                               роли «Администратор»)
--    CRM users.email       <->  TMS_MUNC.EMAIL        (при известном USER_SC)
--    CRM users.phone       <->  TMS_MUNC.KADR_TEL_CELL
--    CRM users.active      <->  A$ADP KEY = 'Enabled' ('true'/'false')
--                               и A$ADM.DATE_FINAL при отключении
--    CRM users.erp_code    <->  A$ADP KEY = 'USER_SC' (код в кадрах)
--    CRM users.created_at  <->  A$ADP KEY = 'CRMREGDATE'
--
--  Установка: выполнить от владельца схемы UNIA (sqlplus / uniConf → SQL).
--  Порядок: таблица → последовательность → пакет → триггеры.
-- =====================================================================

-- ── 1. Очередь обмена ────────────────────────────────────────────────
--  Устроена как A$ACT (журнал правок конфигуратора): что изменилось,
--  когда и чем это отдали наружу.
CREATE TABLE A$CRM_SYNC (
  ID          NUMBER            NOT NULL,
  ENTITY      VARCHAR2(30)      DEFAULT 'users' NOT NULL,
  OBJ_ID      NUMBER,                 -- узел A$ADM
  USER_SC     NUMBER,                 -- TMS_MUNC.COD
  LOGIN_NAME  VARCHAR2(100),
  OP          CHAR(1)           NOT NULL,   -- I вставка, U правка, D удаление
  CHANGED_AT  DATE              DEFAULT SYSDATE NOT NULL,
  PAYLOAD     VARCHAR2(4000),         -- снимок полей в том же виде, что у CRM
  SENT_AT     DATE,                   -- когда забрал хаб
  CRM_ACK     VARCHAR2(200),
  CONSTRAINT A$CRM_SYNC_PK PRIMARY KEY (ID)
);

CREATE INDEX A$CRM_SYNC_PENDING ON A$CRM_SYNC (SENT_AT, ID);
CREATE SEQUENCE A$CRM_SYNC$SQ START WITH 1 INCREMENT BY 1 NOCACHE;

-- ── 2. Пакет обмена ──────────────────────────────────────────────────
CREATE OR REPLACE PACKAGE A$CRM$SYNC AS
  -- Приём из CRM не должен уехать обратно в CRM: на время приёма очередь молчит.
  PROCEDURE MUTE;
  PROCEDURE UNMUTE;
  FUNCTION  IS_MUTED RETURN BOOLEAN;

  -- Ставит карточку узла в очередь (payload собирается по текущим значениям).
  PROCEDURE ENQUEUE (p_obj_id IN NUMBER, p_op IN CHAR);

  -- Принимает карточку из CRM. Возвращает 'создан' / 'обновлён' / 'пропущен'.
  FUNCTION APPLY_USER (p_login     IN VARCHAR2,
                       p_full_name IN VARCHAR2,
                       p_position  IN VARCHAR2,
                       p_role      IN VARCHAR2,
                       p_email     IN VARCHAR2,
                       p_phone     IN VARCHAR2,
                       p_active    IN VARCHAR2,
                       p_erp_code  IN VARCHAR2,
                       p_reg_date  IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2;

  -- Отметить строки очереди отданными.
  PROCEDURE ACK (p_id IN NUMBER, p_ack IN VARCHAR2 DEFAULT 'crm');

  -- Узел-группа, под которым заводятся пришедшие из CRM люди.
  FUNCTION CRM_GROUP_ID RETURN NUMBER;
END A$CRM$SYNC;
/

CREATE OR REPLACE PACKAGE BODY A$CRM$SYNC AS

  g_muted BOOLEAN := FALSE;

  -- имя группы, под которой живут пользователи, заведённые из CRM
  c_group_name CONSTANT VARCHAR2(50) := 'CRM';

  PROCEDURE MUTE IS BEGIN g_muted := TRUE;  END MUTE;
  PROCEDURE UNMUTE IS BEGIN g_muted := FALSE; END UNMUTE;
  FUNCTION IS_MUTED RETURN BOOLEAN IS BEGIN RETURN g_muted; END IS_MUTED;

  -- ── свойства узла: чтение и запись через обновляемые представления ──
  FUNCTION PROP (p_obj_id IN NUMBER, p_key IN VARCHAR2) RETURN VARCHAR2 IS
    v VARCHAR2(4000);
  BEGIN
    SELECT MAX(SVALUE) INTO v FROM A$ADP WHERE OBJ_ID = p_obj_id AND UPPER(KEY) = UPPER(p_key);
    RETURN v;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
  END PROP;

  -- KEY в A$ADP выводится представлением из NAME (KEY = UPPER(NAME)),
  -- поэтому пишем в A$ADP$V, как это делает конфигуратор.
  PROCEDURE SET_PROP (p_obj_id IN NUMBER, p_name IN VARCHAR2, p_value IN VARCHAR2,
                      p_vtype IN VARCHAR2 DEFAULT 'S') IS
    n NUMBER;
  BEGIN
    IF p_value IS NULL THEN RETURN; END IF;
    SELECT COUNT(*) INTO n FROM A$ADP WHERE OBJ_ID = p_obj_id AND UPPER(KEY) = UPPER(p_name);
    IF n = 0 THEN
      INSERT INTO A$ADP$V (OBJ_ID, NAME, VTYPE, VALUE) VALUES (p_obj_id, p_name, p_vtype, p_value);
    ELSE
      UPDATE A$ADP$V SET VALUE = p_value WHERE OBJ_ID = p_obj_id AND UPPER(KEY) = UPPER(p_name);
    END IF;
  END SET_PROP;

  FUNCTION CRM_GROUP_ID RETURN NUMBER IS
    v_id NUMBER;
  BEGIN
    SELECT MAX(OBJ_ID) INTO v_id
      FROM A$ADM WHERE OBJ_TYPE = 7 AND OBJ_SUBTYPE = -1 AND UPPER(NAME) = c_group_name;
    IF v_id IS NULL THEN
      -- группы ещё нет — заводим её тем же путём, что конфигуратор
      SELECT A$ADM$SQ.NEXTVAL INTO v_id FROM DUAL;
      INSERT INTO A$ADM$V (OBJ_ID, OBJ_TYPE, OBJ_SUBTYPE, PARENT_ID, NAME, SECTION, NRORD)
      VALUES (v_id, 7, -1, NULL, c_group_name, 'CRM_USERS', 900);
      SET_PROP(v_id, '.Type', 'USERGROUP');
    END IF;
    RETURN v_id;
  END CRM_GROUP_ID;

  -- ── очередь ──
  -- Снимок в том же виде, что читает CRM (CrmData.parseSyncPayload):
  -- {"login":"…","full_name":"…","position":"…","role":"…","email":"…",
  --  "phone":"…","active":"1","erp_code":"…"}
  PROCEDURE ENQUEUE (p_obj_id IN NUMBER, p_op IN CHAR) IS
    v_login   VARCHAR2(4000);
    v_name    VARCHAR2(4000);
    v_pos     VARCHAR2(4000);
    v_role    VARCHAR2(4000);
    v_sc      VARCHAR2(4000);
    v_enabled VARCHAR2(4000);
    v_active  VARCHAR2(1);
    v_email   VARCHAR2(4000);
    v_phone   VARCHAR2(4000);
    v_payload VARCHAR2(4000);
    FUNCTION esc (s IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN RETURN REPLACE(NVL(s, ' '), '"', ''''); END esc;
  BEGIN
    IF g_muted THEN RETURN; END IF;

    BEGIN
      SELECT NAME INTO v_name FROM A$ADM WHERE OBJ_ID = p_obj_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN v_name := NULL;
    END;
    v_login   := PROP(p_obj_id, 'USERNAME');
    v_pos     := PROP(p_obj_id, 'POSITION');
    v_role    := PROP(p_obj_id, 'CRMROLE');
    v_sc      := PROP(p_obj_id, 'USER_SC');
    v_enabled := PROP(p_obj_id, 'Enabled');
    -- в новом формате пользователь включён, пока явно не написано false
    v_active  := CASE WHEN LOWER(NVL(v_enabled, 'true')) IN ('false', '0') THEN '0' ELSE '1' END;

    IF v_sc IS NOT NULL THEN
      BEGIN
        SELECT EMAIL, NVL(KADR_TEL_CELL, KADR_TEL_WORK)
          INTO v_email, v_phone
          FROM TMS_MUNC WHERE COD = TO_NUMBER(v_sc);
      EXCEPTION WHEN OTHERS THEN v_email := NULL; v_phone := NULL;
      END;
    END IF;

    v_payload := '{"login":"'     || esc(v_login) ||
                 '","full_name":"'|| esc(v_name)  ||
                 '","position":"' || esc(v_pos)   ||
                 '","role":"'     || esc(v_role)  ||
                 '","email":"'    || esc(v_email) ||
                 '","phone":"'    || esc(v_phone) ||
                 '","active":"'   || v_active     ||
                 '","erp_code":"' || esc(v_sc)    || '"}';

    INSERT INTO A$CRM_SYNC (ID, ENTITY, OBJ_ID, USER_SC, LOGIN_NAME, OP, PAYLOAD)
    VALUES (A$CRM_SYNC$SQ.NEXTVAL, 'users', p_obj_id,
            CASE WHEN v_sc IS NULL THEN NULL ELSE TO_NUMBER(v_sc) END, v_login, p_op, v_payload);
  EXCEPTION WHEN OTHERS THEN
    -- очередь не должна ронять правку пользователя: как в ClearPasswords,
    -- ошибка гасится, но остаётся видимой в самой очереди
    INSERT INTO A$CRM_SYNC (ID, ENTITY, OBJ_ID, OP, PAYLOAD, CRM_ACK)
    VALUES (A$CRM_SYNC$SQ.NEXTVAL, 'users', p_obj_id, p_op, NULL, SUBSTR(SQLERRM, 1, 200));
  END ENQUEUE;

  PROCEDURE ACK (p_id IN NUMBER, p_ack IN VARCHAR2 DEFAULT 'crm') IS
  BEGIN
    UPDATE A$CRM_SYNC SET SENT_AT = SYSDATE, CRM_ACK = p_ack WHERE ID = p_id;
  END ACK;

  -- ── приём карточки из CRM ──
  FUNCTION APPLY_USER (p_login     IN VARCHAR2,
                       p_full_name IN VARCHAR2,
                       p_position  IN VARCHAR2,
                       p_role      IN VARCHAR2,
                       p_email     IN VARCHAR2,
                       p_phone     IN VARCHAR2,
                       p_active    IN VARCHAR2,
                       p_erp_code  IN VARCHAR2,
                       p_reg_date  IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
    v_obj_id  NUMBER;
    v_result  VARCHAR2(20) := 'обновлён';
    v_enabled VARCHAR2(10);
    v_section VARCHAR2(100);
  BEGIN
    IF p_login IS NULL THEN RETURN 'пропущен'; END IF;
    MUTE;   -- принятое не ставим в очередь обратно

    -- ищем сначала по кадровому коду, потом по логину — так же, как CRM
    IF p_erp_code IS NOT NULL THEN
      SELECT MAX(OBJ_ID) INTO v_obj_id
        FROM A$ADP p JOIN A$ADM m ON m.OBJ_ID = p.OBJ_ID
       WHERE UPPER(p.KEY) = 'USER_SC' AND p.SVALUE = p_erp_code
         AND m.OBJ_TYPE = 7 AND m.OBJ_SUBTYPE = 0;
    END IF;
    IF v_obj_id IS NULL THEN
      SELECT MAX(OBJ_ID) INTO v_obj_id
        FROM A$ADP p JOIN A$ADM m ON m.OBJ_ID = p.OBJ_ID
       WHERE UPPER(p.KEY) = 'USERNAME' AND UPPER(p.SVALUE) = UPPER(p_login)
         AND m.OBJ_TYPE = 7 AND m.OBJ_SUBTYPE = 0;
    END IF;

    IF v_obj_id IS NULL THEN
      SELECT A$ADM$SQ.NEXTVAL INTO v_obj_id FROM DUAL;
      v_section := 'CRM_' || UPPER(p_login);
      INSERT INTO A$ADM$V (OBJ_ID, OBJ_TYPE, OBJ_SUBTYPE, PARENT_ID, NAME, SECTION, NRORD, DATE_BEGIN)
      VALUES (v_obj_id, 7, 0, CRM_GROUP_ID, NVL(p_full_name, p_login), v_section, v_obj_id, SYSDATE);
      SET_PROP(v_obj_id, '.User', 'true', 'B');
      SET_PROP(v_obj_id, 'USERNAME', p_login);
      -- пароль из CRM не приходит: заводим стандартный и требуем смену при
      -- первом входе (ORA-20050 -> a$util.set_passwd в клиенте)
      SET_PROP(v_obj_id, 'PASSWORD', 'crm2026');
      SET_PROP(v_obj_id, 'NeedChangePassword', 'true', 'B');
      BEGIN
        a$util.hide_passwd(v_obj_id);   -- тот же путь, что у ClearPasswords
      EXCEPTION WHEN OTHERS THEN NULL;  -- пароль закодируется при ближайшем Commit
      END;
      v_result := 'создан';
    ELSE
      UPDATE A$ADM$V SET NAME = NVL(p_full_name, NAME) WHERE OBJ_ID = v_obj_id;
      SET_PROP(v_obj_id, 'USERNAME', p_login);
    END IF;

    SET_PROP(v_obj_id, 'POSITION', p_position);
    SET_PROP(v_obj_id, 'CRMROLE', p_role);
    IF p_erp_code IS NOT NULL THEN SET_PROP(v_obj_id, 'USER_SC', p_erp_code); END IF;
    IF p_reg_date IS NOT NULL THEN SET_PROP(v_obj_id, 'CRMREGDATE', p_reg_date); END IF;
    IF p_role = 'Администратор' THEN SET_PROP(v_obj_id, 'ADMIN', 'true', 'B'); END IF;

    -- отключение счёта: свойство Enabled и закрытая дата действия узла
    v_enabled := CASE WHEN p_active = '0' THEN 'false' ELSE 'true' END;
    SET_PROP(v_obj_id, 'Enabled', v_enabled, 'B');
    IF p_active = '0' THEN
      UPDATE A$ADM$V SET DATE_FINAL = TRUNC(SYSDATE) WHERE OBJ_ID = v_obj_id;
    ELSE
      UPDATE A$ADM$V SET DATE_FINAL = NULL WHERE OBJ_ID = v_obj_id;
    END IF;

    -- почта и телефон живут в кадрах; новую кадровую карточку здесь не заводим
    IF p_erp_code IS NOT NULL THEN
      UPDATE TMS_MUNC
         SET EMAIL          = NVL(p_email, EMAIL),
             KADR_TEL_CELL  = NVL(p_phone, KADR_TEL_CELL)
       WHERE COD = TO_NUMBER(p_erp_code);
    END IF;

    -- обязательная проверка узла пользователя — тот же вызов, что делает
    -- конфигуратор после правки свойства (cnfView.cpp, AddCheckNode)
    BEGIN
      a$util.node_changed(v_obj_id, 'USERNAME');
    EXCEPTION WHEN OTHERS THEN
      UNMUTE;
      RAISE_APPLICATION_ERROR(-20077, 'node_changed: ' || SQLERRM);
    END;

    UNMUTE;
    RETURN v_result;
  EXCEPTION WHEN OTHERS THEN
    UNMUTE;
    RAISE;
  END APPLY_USER;

END A$CRM$SYNC;
/

-- ── 3. Триггеры ──────────────────────────────────────────────────────
--  Составные (compound) триггеры: строковая часть только собирает
--  затронутые узлы, а работу с теми же таблицами делает часть уровня
--  оператора — иначе ORA-04091 (mutating table).

CREATE OR REPLACE TRIGGER A$ADM$CRM_SYNC_TR
FOR INSERT OR UPDATE OR DELETE ON A$ADM
COMPOUND TRIGGER
  TYPE t_row IS RECORD (obj_id NUMBER, op CHAR(1));
  TYPE t_rows IS TABLE OF t_row INDEX BY PLS_INTEGER;
  g_rows t_rows;

  BEFORE STATEMENT IS BEGIN g_rows.DELETE; END BEFORE STATEMENT;

  AFTER EACH ROW IS
    v_type NUMBER;
    v_sub  NUMBER;
  BEGIN
    IF A$CRM$SYNC.IS_MUTED THEN RETURN; END IF;
    v_type := NVL(:NEW.OBJ_TYPE, :OLD.OBJ_TYPE);
    v_sub  := NVL(:NEW.OBJ_SUBTYPE, :OLD.OBJ_SUBTYPE);
    IF v_type <> 7 OR v_sub <> 0 THEN RETURN; END IF;   -- только пользователи
    g_rows(g_rows.COUNT + 1).obj_id := NVL(:NEW.OBJ_ID, :OLD.OBJ_ID);
    g_rows(g_rows.COUNT).op := CASE WHEN DELETING THEN 'D' WHEN INSERTING THEN 'I' ELSE 'U' END;
  END AFTER EACH ROW;

  AFTER STATEMENT IS BEGIN
    FOR i IN 1 .. g_rows.COUNT LOOP
      A$CRM$SYNC.ENQUEUE(g_rows(i).obj_id, g_rows(i).op);
    END LOOP;
    g_rows.DELETE;
  END AFTER STATEMENT;
END A$ADM$CRM_SYNC_TR;
/

CREATE OR REPLACE TRIGGER A$ADP$CRM_SYNC_TR
FOR INSERT OR UPDATE OR DELETE ON A$ADP
COMPOUND TRIGGER
  TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  g_ids t_ids;

  BEFORE STATEMENT IS BEGIN g_ids.DELETE; END BEFORE STATEMENT;

  AFTER EACH ROW IS
    v_key VARCHAR2(50);
  BEGIN
    IF A$CRM$SYNC.IS_MUTED THEN RETURN; END IF;
    v_key := UPPER(NVL(:NEW.KEY, :OLD.KEY));
    -- пароли наружу не отдаём, поэтому PASSWORD/ENCODED в список не входят
    IF v_key NOT IN ('USERNAME', 'ENABLED', 'ADMIN', 'POSITION', 'CRMROLE', 'USER_SC') THEN
      RETURN;
    END IF;
    g_ids(g_ids.COUNT + 1) := NVL(:NEW.OBJ_ID, :OLD.OBJ_ID);
  END AFTER EACH ROW;

  AFTER STATEMENT IS
    v_cnt NUMBER;
  BEGIN
    FOR i IN 1 .. g_ids.COUNT LOOP
      SELECT COUNT(*) INTO v_cnt
        FROM A$ADM WHERE OBJ_ID = g_ids(i) AND OBJ_TYPE = 7 AND OBJ_SUBTYPE = 0;
      IF v_cnt > 0 THEN A$CRM$SYNC.ENQUEUE(g_ids(i), 'U'); END IF;
    END LOOP;
    g_ids.DELETE;
  END AFTER STATEMENT;
END A$ADP$CRM_SYNC_TR;
/

-- Почта и телефоны сотрудника лежат в кадрах: их правка тоже должна
-- доехать до CRM. Ставим в очередь только тех, у кого есть узел
-- пользователя со свойством USER_SC.
CREATE OR REPLACE TRIGGER TMS_MUNC$CRM_SYNC_TR
FOR UPDATE OF EMAIL, KADR_TEL_CELL, KADR_TEL_WORK, FAMILIA, NUMELE ON TMS_MUNC
COMPOUND TRIGGER
  TYPE t_ids IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  g_ids t_ids;

  BEFORE STATEMENT IS BEGIN g_ids.DELETE; END BEFORE STATEMENT;

  AFTER EACH ROW IS BEGIN
    IF A$CRM$SYNC.IS_MUTED THEN RETURN; END IF;
    g_ids(g_ids.COUNT + 1) := :NEW.COD;
  END AFTER EACH ROW;

  AFTER STATEMENT IS
    v_obj NUMBER;
  BEGIN
    FOR i IN 1 .. g_ids.COUNT LOOP
      SELECT MAX(p.OBJ_ID) INTO v_obj
        FROM A$ADP p JOIN A$ADM m ON m.OBJ_ID = p.OBJ_ID
       WHERE UPPER(p.KEY) = 'USER_SC' AND p.SVALUE = TO_CHAR(g_ids(i))
         AND m.OBJ_TYPE = 7 AND m.OBJ_SUBTYPE = 0;
      IF v_obj IS NOT NULL THEN A$CRM$SYNC.ENQUEUE(v_obj, 'U'); END IF;
    END LOOP;
    g_ids.DELETE;
  END AFTER STATEMENT;
END TMS_MUNC$CRM_SYNC_TR;
/

-- ── 4. Проверка установки ────────────────────────────────────────────
--  SELECT OBJECT_NAME, STATUS FROM USER_OBJECTS
--   WHERE OBJECT_NAME IN ('A$CRM_SYNC','A$CRM$SYNC','A$ADM$CRM_SYNC_TR',
--                         'A$ADP$CRM_SYNC_TR','TMS_MUNC$CRM_SYNC_TR');
--  SELECT * FROM A$CRM_SYNC WHERE SENT_AT IS NULL ORDER BY ID;
--
--  Приём карточки вручную:
--  DECLARE r VARCHAR2(20); BEGIN
--    r := A$CRM$SYNC.APPLY_USER('ipopescu','Ion Popescu','Менеджер по продажам',
--         'Коммерческий','ion.popescu@demo.md','+373 69 100 101','1',NULL);
--    DBMS_OUTPUT.PUT_LINE(r); COMMIT;
--  END;
--  /
