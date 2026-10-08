CREATE SCHEMA IF NOT EXISTS $SCHEMA$;
--SPLIT--
CREATE TABLE $SCHEMA$.rulesets (
  id BIGSERIAL PRIMARY KEY,
  key TEXT NOT NULL,
  name TEXT,
  version TEXT,
  description TEXT,
  normalize JSONB NOT NULL DEFAULT '{"downcase": [], "dates": []}'::jsonb,
  rosters JSONB NOT NULL DEFAULT '{}'::jsonb,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  inserted_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL,
  updated_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL
);
--SPLIT--
CREATE UNIQUE INDEX rulesets_key_index ON $SCHEMA$.rulesets (key);
--SPLIT--
CREATE TABLE $SCHEMA$.rules (
  id BIGSERIAL PRIMARY KEY,
  ruleset_id BIGINT NOT NULL,
  rule_id TEXT NOT NULL,
  description TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  position INTEGER NOT NULL,
  conditions JSONB[] NOT NULL DEFAULT ARRAY[]::jsonb[],
  outcome JSONB NOT NULL DEFAULT '{}'::jsonb,
  tags TEXT[] NOT NULL DEFAULT ARRAY[]::text[],
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  inserted_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL,
  updated_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL,
  CONSTRAINT rules_ruleset_id_fkey FOREIGN KEY (ruleset_id)
    REFERENCES $SCHEMA$.rulesets (id) ON DELETE CASCADE,
  CONSTRAINT rules_position_nonnegative CHECK (position >= 0)
);
--SPLIT--
CREATE UNIQUE INDEX rules_ruleset_id_rule_id_index ON $SCHEMA$.rules (ruleset_id, rule_id);
--SPLIT--
CREATE INDEX rules_ruleset_id_position_id_index ON $SCHEMA$.rules (ruleset_id, position, id);
