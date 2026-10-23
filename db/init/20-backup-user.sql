-- Read-only account for the backup job. Not the MariaDB root user.
-- --single-transaction does not need RELOAD, and this user cannot write.
CREATE USER IF NOT EXISTS 'backup'@'%' IDENTIFIED BY 'backup-pass-2026';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES ON wordpress.* TO 'backup'@'%';
FLUSH PRIVILEGES;
