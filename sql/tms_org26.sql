-- Спутниковая таблица к справочнику организаций una.md.
--
-- Хранит нормализованные признаки, которых нет в TMS_ORG: тип предприятия и
-- юридическую форму. Признаки независимы — «ICS … SRL» это одновременно
-- предприятие с иностранным капиталом и общество с ограниченной
-- ответственностью, поэтому одним полем не обойтись.
--
-- Ключи повторяют схему TMS_ORG / TMS_ORG_ACCOUNTS: COD — первичный ключ и
-- одновременно внешний ключ на TMS_UNIVERS.

CREATE TABLE PARALAX.TMS_ORG26 (
  COD             NUMBER(10)    NOT NULL,
  TIP_ENTITATE    VARCHAR2(10),          -- ICS, IM, II, IP, IS, OCN, OMF, REP, SUC, FIL
  FORMA_JURIDICA  VARCHAR2(10),          -- SRL, SA, SC, CP, CI, CA, GT, COOP, CSV, …
  DENUMIRE        VARCHAR2(80),          -- название без организационно-правовой формы
  SURSA           VARCHAR2(30),          -- источник данных (date.gov.md)
  DATA_IMPORT     DATE DEFAULT SYSDATE,
  CONSTRAINT PK_TMS_ORG26 PRIMARY KEY (COD),
  CONSTRAINT CRFK1$TMS_ORG26 FOREIGN KEY (COD) REFERENCES PARALAX.TMS_UNIVERS (COD)
);

CREATE INDEX PARALAX.IX_TMS_ORG26_FORMA ON PARALAX.TMS_ORG26 (FORMA_JURIDICA);
CREATE INDEX PARALAX.IX_TMS_ORG26_TIP   ON PARALAX.TMS_ORG26 (TIP_ENTITATE);

COMMENT ON TABLE  PARALAX.TMS_ORG26                IS 'Нормализованные признаки организации: тип и юридическая форма';
COMMENT ON COLUMN PARALAX.TMS_ORG26.COD            IS 'Код организации, = TMS_UNIVERS.COD';
COMMENT ON COLUMN PARALAX.TMS_ORG26.TIP_ENTITATE   IS 'Тип предприятия: ICS, IM, II, OCN, OMF, REP …';
COMMENT ON COLUMN PARALAX.TMS_ORG26.FORMA_JURIDICA IS 'Юридическая форма: SRL, SA, CP, CI, GT …';
COMMENT ON COLUMN PARALAX.TMS_ORG26.DENUMIRE       IS 'Название без организационно-правовой формы';
COMMENT ON COLUMN PARALAX.TMS_ORG26.SURSA          IS 'Источник данных';
