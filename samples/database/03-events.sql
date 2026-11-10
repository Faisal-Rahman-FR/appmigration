CREATE DATABASE IF NOT EXISTS events CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS events.event_staff (
  uid VARCHAR(64) PRIMARY KEY,
  display_name VARCHAR(128) NOT NULL,
  role ENUM('organizer','admin') NOT NULL
);
CREATE TABLE IF NOT EXISTS events.events (
  id INT AUTO_INCREMENT PRIMARY KEY,
  title VARCHAR(160) NOT NULL,
  starts_on DATE NOT NULL,
  venue VARCHAR(128) NOT NULL,
  organizer_uid VARCHAR(64) NOT NULL,
  status ENUM('approved','pending','cancelled') NOT NULL DEFAULT 'pending'
);
INSERT IGNORE INTO events.event_staff VALUES
('alice','Alice Avery','admin'),
('bob','Bob Bennett','organizer');
INSERT INTO events.events (title, starts_on, venue, organizer_uid, status)
SELECT * FROM (
  SELECT 'Spring Open House' AS title, DATE '2026-12-02' AS starts_on, 'Main Hall' AS venue, 'bob' AS organizer_uid, 'approved' AS status
  UNION ALL SELECT 'Robotics Showcase', DATE '2026-12-09', 'Engineering Atrium', 'bob', 'approved'
  UNION ALL SELECT 'Alumni Mixer', DATE '2026-12-15', 'Faculty Club', 'alice', 'pending'
) seed WHERE NOT EXISTS (SELECT 1 FROM events.events);
