CREATE TABLE IF NOT EXISTS reservations (
    reservation_id  UUID       PRIMARY KEY,
    concert_id      VARCHAR    NOT NULL,
    user_id         VARCHAR    NOT NULL,
    ticket_type     VARCHAR    NOT NULL,
    quantity        INTEGER    NOT NULL CHECK (quantity > 0),
    status          VARCHAR    NOT NULL CHECK (status IN ('pending', 'booked', 'confirmed', 'rejected')),
    created_at      TIMESTAMP  NOT NULL,
    updated_at      TIMESTAMP  NOT NULL
);

-- Acelera el SUM de boletos vendidos por concierto y tipo que hace ticket-worker.
CREATE INDEX IF NOT EXISTS idx_reservations_inventory
    ON reservations (concert_id, ticket_type, status);
