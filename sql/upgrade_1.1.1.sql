-- Author: vyrriox
-- EN: Optional repair when Config.Database.autoSchema is false. Back up first.
-- Change BOTH occurrences of v_park_vehicles if Config.Database.prefix is customized.
-- FR: Correction optionnelle si Config.Database.autoSchema est false. Sauvegarder avant.
-- Adapter les DEUX occurrences de v_park_vehicles si le prefixe est personnalise.
SET @vpark_has_vehicle_type = (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'v_park_vehicles'
      AND COLUMN_NAME = 'vehicle_type'
);
SET @vpark_upgrade_sql = IF(@vpark_has_vehicle_type = 0,
    'ALTER TABLE `v_park_vehicles` ADD COLUMN `vehicle_type` VARCHAR(24) DEFAULT NULL AFTER `class`',
    'SELECT 1'
);
PREPARE vpark_upgrade FROM @vpark_upgrade_sql;
EXECUTE vpark_upgrade;
DEALLOCATE PREPARE vpark_upgrade;
