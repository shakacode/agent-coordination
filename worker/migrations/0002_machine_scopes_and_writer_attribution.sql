ALTER TABLE state ADD COLUMN updated_by TEXT;

ALTER TABLE machines ADD COLUMN read_prefixes TEXT NOT NULL DEFAULT '[""]';

ALTER TABLE machines ADD COLUMN write_prefixes TEXT NOT NULL DEFAULT '[""]';
