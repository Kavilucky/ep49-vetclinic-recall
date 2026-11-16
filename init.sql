-- Схема возврата клиентов ветклиники (пример, эпизод 49). Выполняется один раз при первом запуске PostgreSQL.
-- Все данные в примерах вымышленные. Хранение телефонов, кличек и согласий это обработка персональных данных: условия по 152-ФЗ проверьте у юриста.

-- Приведение телефона РФ к формату E.164: 8XXXXXXXXXX, 7XXXXXXXXXX и 10 цифр превращаются в +7XXXXXXXXXX, иначе NULL.
CREATE OR REPLACE FUNCTION normalize_phone_e164(raw TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN d ~ '^8\d{10}$' THEN '+7' || substr(d, 2)
    WHEN d ~ '^7\d{10}$' THEN '+' || d
    WHEN d ~ '^\d{10}$' THEN '+7' || d
    ELSE NULL END
  FROM (SELECT regexp_replace(coalesce(raw, ''), '\D', '', 'g') AS d) t
$$;

CREATE TABLE IF NOT EXISTS owners (               -- владелец питомца
  id               BIGSERIAL PRIMARY KEY,
  phone_e164       TEXT NOT NULL UNIQUE CHECK (phone_e164 ~ '^\+7\d{10}$'),   -- единый формат: один номер = одна карточка
  name             TEXT,
  telegram_chat_id BIGINT UNIQUE,                 -- появляется, когда клиент нажал Start у бота по QR
  opt_in_status    TEXT NOT NULL DEFAULT 'pending' CHECK (opt_in_status IN ('pending', 'opted_in', 'opted_out')),
  opt_in_at        TIMESTAMPTZ,                   -- точное время согласия
  opt_in_text      TEXT,                          -- версия текста согласия
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS pets (                 -- питомец
  id        BIGSERIAL PRIMARY KEY,
  owner_id  BIGINT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
  name      TEXT NOT NULL,
  species   TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS pets_owner_name_uq ON pets (owner_id, lower(name));   -- защита от дублей: владелец + кличка
CREATE TABLE IF NOT EXISTS recall_schedule (      -- плановая прививка или процедура
  id          BIGSERIAL PRIMARY KEY,
  pet_id      BIGINT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
  procedure   TEXT NOT NULL,
  due_date    DATE NOT NULL,
  status      TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'queued', 'sent', 'booked', 'skipped')),
  notified_at TIMESTAMPTZ,
  UNIQUE (pet_id, procedure, due_date)
);
CREATE INDEX IF NOT EXISTS recall_due_idx ON recall_schedule (due_date, status);
CREATE TABLE IF NOT EXISTS free_slots (           -- свободные окна для записи (заполняет администратор или ваш скрипт)
  id         BIGSERIAL PRIMARY KEY,
  slot_start TIMESTAMPTZ NOT NULL UNIQUE,
  taken      BOOLEAN NOT NULL DEFAULT false
);
CREATE TABLE IF NOT EXISTS appointments (         -- запись по кнопке
  id         BIGSERIAL PRIMARY KEY,
  recall_id  BIGINT NOT NULL UNIQUE REFERENCES recall_schedule(id) ON DELETE CASCADE,
  slot_id    BIGINT NOT NULL REFERENCES free_slots(id),
  slot_start TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS send_queue (           -- антиспам-очередь исходящих сообщений
  id         BIGSERIAL PRIMARY KEY,
  recall_id  BIGINT NOT NULL UNIQUE REFERENCES recall_schedule(id) ON DELETE CASCADE,
  chat_id    BIGINT NOT NULL,
  text       TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending', 'sent', 'failed')),
  attempts   INT NOT NULL DEFAULT 0,
  send_after TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS send_queue_due_idx ON send_queue (status, send_after);

-- Импорт существующей базы: загрузите строки в owners_import, ночью их разберёт import_owners() (нормализация номера, склейка дублей).
CREATE TABLE IF NOT EXISTS owners_import (
  id         BIGSERIAL PRIMARY KEY,
  raw_phone  TEXT NOT NULL,
  owner_name TEXT,
  pet_name   TEXT NOT NULL,
  species    TEXT,
  done       BOOLEAN NOT NULL DEFAULT false
);
CREATE OR REPLACE FUNCTION import_owners() RETURNS INT LANGUAGE plpgsql AS $$
DECLARE r RECORD; oid BIGINT; n INT := 0;
BEGIN
  FOR r IN SELECT * FROM owners_import WHERE NOT done ORDER BY id LOOP
    IF normalize_phone_e164(r.raw_phone) IS NULL THEN CONTINUE; END IF;
    INSERT INTO owners (phone_e164, name) VALUES (normalize_phone_e164(r.raw_phone), r.owner_name)
      ON CONFLICT (phone_e164) DO UPDATE SET name = COALESCE(owners.name, EXCLUDED.name) RETURNING id INTO oid;
    INSERT INTO pets (owner_id, name, species) VALUES (oid, r.pet_name, r.species) ON CONFLICT (owner_id, lower(name)) DO NOTHING;
    UPDATE owners_import SET done = true WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
