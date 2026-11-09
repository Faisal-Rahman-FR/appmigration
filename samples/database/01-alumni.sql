CREATE DATABASE IF NOT EXISTS alumni CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS drupal CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE alumni.profiles (
  uid VARCHAR(64) PRIMARY KEY,
  display_name VARCHAR(128) NOT NULL,
  email VARCHAR(254) NOT NULL UNIQUE,
  graduation_year SMALLINT NOT NULL,
  biography TEXT NOT NULL
);
INSERT INTO alumni.profiles VALUES
('alice','Alice Avery','alice@demo.test',2010,'Synthetic faculty member and alum.'),
('erin','Erin Ellis','erin@demo.test',2018,'Synthetic alum coordinating the reunion.');
CREATE TABLE alumni.cas_sessions (
  ticket_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
  revoked BOOLEAN NOT NULL DEFAULT FALSE,
  expires_at TIMESTAMP NOT NULL,
  INDEX (expires_at)
);
