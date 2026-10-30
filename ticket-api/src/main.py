"""ticket-api: recibe reservaciones, las guarda en RDS como pending y las encola en SQS FIFO."""

import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

import boto3
from fastapi import FastAPI, HTTPException, status
from psycopg.conninfo import make_conninfo
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-api")


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Falta la variable de entorno requerida: {name}")
    return value


AWS_REGION = env("AWS_REGION")
SQS_QUEUE_URL = env("SQS_QUEUE_URL")

CONNINFO = make_conninfo(
    host=env("DB_HOST"),
    port=env("DB_PORT"),
    dbname=env("DB_NAME"),
    user=env("DB_USER"),
    password=env("DB_PASSWORD"),
    sslmode=os.environ.get("DB_SSLMODE", "prefer"),
    connect_timeout=5,
)

SCHEMA_SQL = (Path(__file__).parent / "schema.sql").read_text()
# Llave arbitraria para que solo una réplica cree el schema a la vez.
SCHEMA_LOCK_KEY = 7_311_2026

pool = ConnectionPool(CONNINFO, min_size=1, max_size=int(os.environ.get("DB_POOL_SIZE", "10")), open=False)
sqs = boto3.client("sqs", region_name=AWS_REGION)


def init_schema() -> None:
    with pool.connection() as conn, conn.transaction():
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (SCHEMA_LOCK_KEY,))
        conn.execute(SCHEMA_SQL)
    log.info("Schema de reservations listo")


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open(wait=True, timeout=60)
    init_schema()
    yield
    pool.close()


app = FastAPI(title="ticket-api", lifespan=lifespan)


class ReserveRequest(BaseModel):
    concert_id: str = Field(min_length=1, max_length=100)
    user_id: str = Field(min_length=1, max_length=100)
    ticket_type: str = Field(min_length=1, max_length=50)
    quantity: int = Field(gt=0)


def serialize(row: dict) -> dict:
    row = dict(row)
    row["reservation_id"] = str(row["reservation_id"])
    row["created_at"] = row["created_at"].isoformat()
    row["updated_at"] = row["updated_at"].isoformat()
    return row


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/ready")
def ready():
    with pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ready"}


@app.post("/reserve", status_code=status.HTTP_202_ACCEPTED)
def reserve(req: ReserveRequest):
    reservation_id = uuid.uuid4()
    with pool.connection() as conn:
        conn.execute(
            """
            INSERT INTO reservations
                (reservation_id, concert_id, user_id, ticket_type, quantity, status, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s, 'pending', NOW(), NOW())
            """,
            (reservation_id, req.concert_id, req.user_id, req.ticket_type, req.quantity),
        )

    message = {
        "reservation_id": str(reservation_id),
        "concert_id": req.concert_id,
        "user_id": req.user_id,
        "ticket_type": req.ticket_type,
        "quantity": req.quantity,
    }
    try:
        # MessageGroupId = concert_id: todas las reservaciones de un concierto se procesan en orden.
        sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(message),
            MessageGroupId=req.concert_id,
            MessageDeduplicationId=str(reservation_id),
        )
    except Exception:
        log.exception("No se pudo encolar la reservación %s", reservation_id)
        with pool.connection() as conn:
            conn.execute("DELETE FROM reservations WHERE reservation_id = %s", (reservation_id,))
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "No se pudo encolar la reservación")

    log.info("Reservación %s encolada (concert=%s type=%s qty=%s)",
             reservation_id, req.concert_id, req.ticket_type, req.quantity)
    return {"reservation_id": str(reservation_id), "status": "pending"}


@app.get("/reservation/{reservation_id}")
def get_reservation(reservation_id: uuid.UUID):
    with pool.connection() as conn:
        row = conn.cursor(row_factory=dict_row).execute(
            "SELECT * FROM reservations WHERE reservation_id = %s", (reservation_id,)
        ).fetchone()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Reservación no encontrada")
    return serialize(row)


@app.get("/concerts/{concert_id}/summary")
def concert_summary(concert_id: str):
    """Endpoint auxiliar para pruebas: reservaciones y boletos por tipo y estado."""
    with pool.connection() as conn:
        rows = conn.cursor(row_factory=dict_row).execute(
            """
            SELECT ticket_type, status, COUNT(*) AS reservations, SUM(quantity) AS tickets
            FROM reservations
            WHERE concert_id = %s
            GROUP BY ticket_type, status
            ORDER BY ticket_type, status
            """,
            (concert_id,),
        ).fetchall()
    summary: dict[str, dict] = {}
    for r in rows:
        summary.setdefault(r["ticket_type"], {})[r["status"]] = {
            "reservations": r["reservations"],
            "tickets": int(r["tickets"]),
        }
    return {"concert_id": concert_id, "by_ticket_type": summary}
