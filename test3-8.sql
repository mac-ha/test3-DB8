CREATE SCHEMA fleet_lab;

CREATE TABLE fleet_lab.vehicles (
    vehicle_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration VARCHAR(20) UNIQUE NOT NULL,

    current_odometer NUMERIC(10,2) NOT NULL
        CHECK (current_odometer >= 0),

    last_service_odometer NUMERIC(10,2) NOT NULL
        CHECK (last_service_odometer >= 0),

    CONSTRAINT chk_service_position
    CHECK (
        last_service_odometer <= current_odometer
    )
);

CREATE TABLE fleet_lab.trips (
    trip_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    vehicle_id INTEGER NOT NULL,

    trip_on DATE NOT NULL,

    start_odometer NUMERIC(10,2) NOT NULL
        CHECK (start_odometer >= 0),

    end_odometer NUMERIC(10,2) NOT NULL
        CHECK (end_odometer >= 0),

    CONSTRAINT fk_trip_vehicle
        FOREIGN KEY (vehicle_id)
        REFERENCES fleet_lab.vehicles(vehicle_id)
);

CREATE TABLE fleet_lab.service_alerts (
    vehicle_id INTEGER PRIMARY KEY,

    km_since_service NUMERIC(10,2) NOT NULL,

    flagged_on DATE NOT NULL,

    CONSTRAINT fk_alert_vehicle
        FOREIGN KEY (vehicle_id)
        REFERENCES fleet_lab.vehicles(vehicle_id)
);

--seed vehicles

INSERT INTO fleet_lab.vehicles
(
 registration,
 current_odometer,
 last_service_odometer
)
VALUES
('ABC123',10000,6000),
('DEF456',25000,22000),
('GHI789',50000,45000);


CALL fleet_lab.pr_record_trip(1,'2026-11-01',10000,10500);
CALL fleet_lab.pr_record_trip(1,'2026-11-05',10500,11000);

CALL fleet_lab.pr_record_trip(2,'2026-11-01',25000,26000);
CALL fleet_lab.pr_record_trip(2,'2026-11-10',26000,27250);

CALL fleet_lab.pr_record_trip(3,'2026-11-02',50000,51000);
CALL fleet_lab.pr_record_trip(3,'2026-11-15',51000,52500);

--B
CREATE OR REPLACE FUNCTION
fleet_lab.fn_service_due(
    p_vehicle_id INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC;
    v_service NUMERIC;
BEGIN

    SELECT
        current_odometer,
        last_service_odometer
    INTO
        v_current,
        v_service
    FROM fleet_lab.vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Unknown vehicle';
    END IF;

    RETURN (v_current - v_service) >= 5000;

END;
$$;

--C

CREATE OR REPLACE PROCEDURE
fleet_lab.pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on DATE,
    p_start NUMERIC,
    p_end NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF NOT EXISTS
    (
        SELECT 1
        FROM fleet_lab.vehicles
        WHERE vehicle_id = p_vehicle_id
    )
    THEN
        RAISE EXCEPTION
        'Vehicle does not exist';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION
        'End odometer must exceed start odometer';
    END IF;

    INSERT INTO fleet_lab.trips
    (
        vehicle_id,
        trip_on,
        start_odometer,
        end_odometer
    )
    VALUES
    (
        p_vehicle_id,
        p_trip_on,
        p_start,
        p_end
    );

END;
$$;

--D

CREATE OR REPLACE FUNCTION
fleet_lab.fn_validate_trip()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC;
BEGIN

    SELECT current_odometer
    INTO v_current
    FROM fleet_lab.vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Vehicle not found';
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION
        'Invalid odometer values';
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION
        'Trip must start at current vehicle odometer';
    END IF;

    UPDATE fleet_lab.vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;

END;
$$;

--trigger

CREATE TRIGGER trg_validate_trip
BEFORE INSERT
ON fleet_lab.trips
FOR EACH ROW
EXECUTE FUNCTION fleet_lab.fn_validate_trip();

--E

CREATE OR REPLACE VIEW
fleet_lab.v_service_due AS
SELECT
    registration,

    current_odometer
    - last_service_odometer
    AS km_since_service

FROM fleet_lab.vehicles

WHERE
(
    current_odometer
    - last_service_odometer
) >= 5000;

--F

CREATE INDEX idx_trip_vehicle_date
ON fleet_lab.trips
(
    vehicle_id,
    trip_on
);

EXPLAIN

SELECT *
FROM fleet_lab.trips
WHERE vehicle_id = 1
AND trip_on BETWEEN
    DATE '2026-11-01'
AND DATE '2026-11-30';

--G

CREATE OR REPLACE PROCEDURE
fleet_lab.pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN

    INSERT INTO fleet_lab.service_alerts
    (
        vehicle_id,
        km_since_service,
        flagged_on
    )
    SELECT
        vehicle_id,
        current_odometer
          - last_service_odometer,
        CURRENT_DATE
    FROM fleet_lab.vehicles
    WHERE current_odometer
          - last_service_odometer >= 5000

    ON CONFLICT (vehicle_id)
    DO UPDATE
    SET
        km_since_service =
            EXCLUDED.km_since_service,
        flagged_on =
            EXCLUDED.flagged_on;

    DELETE FROM fleet_lab.service_alerts sa
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM fleet_lab.vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
        AND (
            v.current_odometer
            - v.last_service_odometer
        ) >= 5000
    );

END;
$$;

