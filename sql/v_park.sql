-- =============================================================================================
-- v-park schema
--
-- OPTIONAL. `Config.Database.autoSchema` is on by default and creates all of this on first
-- start. This file is here for operators who would rather import a schema by hand, and for
-- anyone who wants to read the shape before installing the resource.
--
-- The prefix is `v_park_` and it is configurable in `Config.Database.prefix`. If you change it
-- there, change it here too before importing, or import this and let the resource create a
-- second, empty set under your prefix.
--
-- WHY THE UNDERSCORE AND NOT `v-park_`. A hyphen is legal in a MySQL identifier only inside
-- backticks, so every hand-typed query against `v-park_vehicles` - in Adminer, in a backup
-- script, in a support thread - fails with a syntax error until somebody works out why.
-- `v_park_` is the same namespace with none of that. Every identifier the resource emits is
-- backticked, so a hyphenated prefix does work if you prefer it; you are only choosing what
-- your own queries will have to look like.
--
-- Requires MySQL 5.7 or MariaDB 10.2. `LONGTEXT` rather than `JSON` on purpose: the JSON type
-- is not available on MariaDB 10.1 or MySQL 5.6, both of which are still under FiveM servers,
-- and nothing here queries into the document.
-- =============================================================================================

-- ---------------------------------------------------------------------------------------------
-- The vehicles.
--
-- Notes on the columns that are not self-explanatory:
--
--   id            CHAR(16), not an AUTO_INCREMENT. It is generated before the row exists, which
--                 is what lets a vehicle carry its own identity in a statebag from the moment
--                 it is created. An auto-increment would mean a round trip to the database in
--                 the middle of spawning a car.
--
--   cell          The spatial grid key, computed on write from x and y. Indexed, and the reason
--                 the streaming pass is a lookup rather than a scan: `WHERE cell IN (...)` with
--                 nine values instead of a distance computation over every row.
--
--   hash          The delta-detection hash. A vehicle is written when this moves and not
--                 otherwise, so a server with three thousand parked cars writes nothing.
--                 Stored so that a restart does not have to re-write every row to learn what
--                 it already knew.
--
--   touched_at    When ANYTHING last happened to the vehicle: a save, a repair, a passing car
--                 nudging it. Answers "is this abandoned".
--
--   last_used_at  When a person last GOT IN it. Nothing else moves this. Answers "does anybody
--                 still drive this", which is a different question - a car parked outside its
--                 owner's house is touched constantly and has not been driven since March.
--
--   offline_secs  Seconds the owner has been offline WHILE THE SERVER WAS UP. The
--                 semi-persistence countdown. A counter and not a timestamp, because a
--                 timestamp would count a nightly restart as absence and clear every job
--                 vehicle at boot.
--
--   last_garage   The garage the vehicle was last taken out of, learned from the framework's
--                 own column at the moment we mark it as out. Where the idle cleanup sends it
--                 back to.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `v_park_vehicles` (
    `id`             CHAR(16)     NOT NULL,
    `plate`          VARCHAR(12)  DEFAULT NULL,
    `model`          BIGINT       NOT NULL,
    `model_name`     VARCHAR(64)  DEFAULT NULL,
    `class`          TINYINT      NOT NULL DEFAULT 0,

    `owner`          VARCHAR(64)  DEFAULT NULL,
    `owner_type`     VARCHAR(16)  NOT NULL DEFAULT 'unowned',
    `owner_name`     VARCHAR(64)  DEFAULT NULL,
    `job`            VARCHAR(48)  DEFAULT NULL,

    `pos_x`          DOUBLE       NOT NULL,
    `pos_y`          DOUBLE       NOT NULL,
    `pos_z`          DOUBLE       NOT NULL,
    `rot_x`          FLOAT        NOT NULL DEFAULT 0,
    `rot_y`          FLOAT        NOT NULL DEFAULT 0,
    `rot_z`          FLOAT        NOT NULL DEFAULT 0,

    `cell`           INT          NOT NULL DEFAULT 0,
    `bucket`         INT          NOT NULL DEFAULT 0,
    `interior`       INT          NOT NULL DEFAULT 0,
    `room`           BIGINT       NOT NULL DEFAULT 0,

    `properties`     LONGTEXT     DEFAULT NULL,
    `statebags`      TEXT         DEFAULT NULL,
    `trailer_id`     CHAR(16)     DEFAULT NULL,

    `body_health`    FLOAT        NOT NULL DEFAULT 1000,
    `engine_health`  FLOAT        NOT NULL DEFAULT 1000,
    `fuel`           FLOAT        DEFAULT NULL,
    `wrecked`        TINYINT(1)   NOT NULL DEFAULT 0,

    `offline_secs`   INT          NOT NULL DEFAULT 0,
    `rental_until`   INT          NOT NULL DEFAULT 0,

    `hash`           BIGINT       NOT NULL DEFAULT 0,
    `source`         VARCHAR(24)  NOT NULL DEFAULT 'auto',

    `created_at`     INT          NOT NULL DEFAULT 0,
    `updated_at`     INT          NOT NULL DEFAULT 0,
    `touched_at`     INT          NOT NULL DEFAULT 0,
    `last_used_at`   INT          NOT NULL DEFAULT 0,
    `last_garage`    VARCHAR(64)  DEFAULT NULL,

    PRIMARY KEY (`id`),

    -- The streaming pass. Every other index on this table is convenience; this one is the
    -- difference between a lookup and a table scan once a second per player.
    KEY `idx_cell`    (`cell`, `bucket`),

    KEY `idx_owner`   (`owner`, `owner_type`),
    KEY `idx_plate`   (`plate`),
    KEY `idx_touched` (`touched_at`),
    KEY `idx_model`   (`model`),

    -- The semi-persistence sweep queries by ownership type and offline counter together.
    KEY `idx_semi`    (`owner_type`, `offline_secs`),

    -- The idle cleanup sweep queries by ownership type and last use together.
    KEY `idx_used`    (`owner_type`, `last_used_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------------------------
-- The trash.
--
-- Every removed vehicle lands here first, for `Config.Database.trashRetentionDays` days, and
-- `/vparkrestore <id>` brings one back exactly as it was - modifications, damage and dents
-- included, which is why the whole record is stored rather than a summary of it.
--
-- An admin deleting the wrong car is a mistake. Without this table it is a catastrophe.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `v_park_trash` (
    `id`          CHAR(16)    NOT NULL,
    `deleted_at`  INT         NOT NULL DEFAULT 0,
    `deleted_by`  VARCHAR(64) DEFAULT NULL,
    `reason`      VARCHAR(48) DEFAULT NULL,
    `payload`     LONGTEXT    NOT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_deleted` (`deleted_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------------------------
-- The audit log.
--
-- One row per destructive or administrative action, never one per save. It is what answers
-- "who deleted forty cars last Tuesday", and it stays small: a busy server writes a few dozen
-- rows a day.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `v_park_audit` (
    `id`         INT AUTO_INCREMENT,
    `at`         INT         NOT NULL DEFAULT 0,
    `actor`      VARCHAR(64) DEFAULT NULL,
    `actor_name` VARCHAR(64) DEFAULT NULL,
    `action`     VARCHAR(32) NOT NULL,
    `vehicle_id` CHAR(16)    DEFAULT NULL,
    `detail`     TEXT        DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `idx_at` (`at`),
    KEY `idx_vehicle` (`vehicle_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------------------------
-- Resource metadata: the schema version, the migration record, and nothing else.
-- ---------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `v_park_meta` (
    `key`   VARCHAR(48) NOT NULL,
    `value` TEXT        DEFAULT NULL,
    PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `v_park_meta` (`key`, `value`) VALUES ('schema_version', '1')
    ON DUPLICATE KEY UPDATE `value` = `value`;

-- ---------------------------------------------------------------------------------------------
-- NOT CREATED HERE: `v_park_migration_backup`.
--
-- The Advanced Parking migration creates it, as a copy of your source table, immediately
-- before it writes anything. Its shape is whatever your source table's shape is, so there is
-- nothing sensible to declare in advance.
-- ---------------------------------------------------------------------------------------------
