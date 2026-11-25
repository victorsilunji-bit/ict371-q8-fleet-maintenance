-- ============================================================================
-- ICT371 Advanced Database - Question 8: Transport Fleet Maintenance
-- ============================================================================

-- (a) Database and seed data (Tables & Constraints)
CREATE TABLE vehicles (
    vehicle_id           SERIAL PRIMARY KEY,
    registration         VARCHAR(30) NOT NULL UNIQUE,
    current_odometer     NUMERIC(12, 1) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12, 1) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_odo_le_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(12, 1) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(12, 1) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12, 1) NOT NULL CHECK (km_since_service >= 5000),
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) Function: fn_service_due
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC(12, 1);
    v_last    NUMERIC(12, 1);
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_current, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

-- (c) Procedure: pr_record_trip
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      NUMERIC(12, 1),
    p_end        NUMERIC(12, 1)
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date cannot be NULL.';
    END IF;

    IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) must exceed start_odometer (%).', p_end, p_start;
    END IF;

    -- Insert trip only; vehicle current_odometer is updated by the BEFORE INSERT trigger
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger: BEFORE INSERT row trigger on trips
CREATE OR REPLACE FUNCTION trg_fn_validate_and_advance_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo NUMERIC(12, 1);
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) must be greater than start_odometer (%).',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    SELECT current_odometer
      INTO v_curr_odo
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'Odometer mismatch: trip start (%) does not match vehicle current odometer (%).',
            NEW.start_odometer, v_curr_odo;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_validate_and_advance_odometer();

-- (a continued) Seed Data: 3 vehicles and 6 trips added through procedure after trigger
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAA 4512', 14200.0, 10000.0), -- Will cross 5,000 km after trips
    ('BAD 8890', 30000.0, 29500.0), -- Recently serviced
    ('BAF 1104', 54800.0, 50000.0); -- Near threshold, will cross 5,000 km

CALL pr_record_trip(1, CURRENT_DATE - 3, 14200.0, 14650.0);
CALL pr_record_trip(1, CURRENT_DATE - 1, 14650.0, 15100.0); -- 5,100 km since service (DUE)
CALL pr_record_trip(2, CURRENT_DATE - 2, 30000.0, 30400.0);
CALL pr_record_trip(2, CURRENT_DATE,     30400.0, 30950.0); -- 1,450 km since service (NOT due)
CALL pr_record_trip(3, CURRENT_DATE - 2, 54800.0, 55000.0); -- Exactly 5,000 km (DUE)
CALL pr_record_trip(3, CURRENT_DATE,     55000.0, 55320.0); -- 5,320 km (DUE)

-- (e) View: v_service_due
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       (current_odometer - last_service_odometer) AS km_since_service
  FROM vehicles
 WHERE fn_service_due(vehicle_id) = TRUE;

-- (f) Index, Query, EXPLAIN and Justification
-- Justification: A composite index on (vehicle_id, trip_on) allows PostgreSQL to jump
-- directly to the specified vehicle's entries and scan the trip_on date range sequentially.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

EXPLAIN ANALYZE
SELECT trip_id, trip_on, start_odometer, end_odometer
  FROM trips
 WHERE vehicle_id = 1
   AND trip_on BETWEEN CURRENT_DATE - INTERVAL '7 days' AND CURRENT_DATE;

-- (g) Scheduled Job: pr_refresh_service_alerts
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Remove alerts for vehicles no longer due (e.g., after servicing)
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (
         SELECT 1
           FROM vehicles v
          WHERE v.vehicle_id = sa.vehicle_id
            AND (v.current_odometer - v.last_service_odometer) >= 5000
     );

    -- Insert or update alerts for all due vehicles
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           (current_odometer - last_service_odometer),
           CURRENT_DATE
      FROM vehicles
     WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
       SET km_since_service = EXCLUDED.km_since_service,
           flagged_on       = EXCLUDED.flagged_on;
END;
$$;

-- Schedule every Monday at 06:00
SELECT cron.schedule(
    'weekly_fleet_service_alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts();$$
);