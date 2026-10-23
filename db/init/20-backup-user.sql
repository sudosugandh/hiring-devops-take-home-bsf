-- Read-only backup account for the wordpress database.
CREATE USER IF NOT EXISTS 'backup'@'%' IDENTIFIED BY 'backup-pass-2026';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES ON wordpress.* TO 'backup'@'%';
FLUSH PRIVILEGES;
