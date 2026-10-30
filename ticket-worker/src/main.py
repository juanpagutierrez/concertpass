"""ticket-worker: consume SQS FIFO, decide disponibilidad (DynamoDB + RDS) y confirma con ticket-checkout."""

import json
import logging
import os
import signal
import time

import boto3
import psycopg
import requests
from psycopg.conninfo import make_conninfo

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-worker")


def env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Falta la variable de entorno requerida: {name}")
    return value


AWS_REGION = env("AWS_REGION")
SQS_QUEUE_URL = env("SQS_QUEUE_URL")
DYNAMODB_TABLE = env("DYNAMODB_TABLE")
CHECKOUT_URL = env("CHECKOUT_URL").rstrip("/")
CHECKOUT_TIMEOUT = float(os.environ.get("CHECKOUT_TIMEOUT_SECONDS", "5"))

CONNINFO = make_conninfo(
    host=env("DB_HOST"),
    port=env("DB_PORT"),
    dbname=env("DB_NAME"),
    user=env("DB_USER"),
    password=env("DB_PASSWORD"),
    sslmode=os.environ.get("DB_SSLMODE", "prefer"),
    connect_timeout=5,
)

sqs = boto3.client("sqs", region_name=AWS_REGION)
events_table = boto3.resource("dynamodb", region_name=AWS_REGION).Table(DYNAMODB_TABLE)
http = requests.Session()

running = True


def stop(signum, _frame):
    global running
    log.info("Señal %s recibida, terminando después del mensaje actual", signum)
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


class NoCapacity(Exception):
    pass


def get_capacity(concert_id: str, ticket_type: str) -> int | None:
    """Capacidad máxima de la sección según la definición del evento en DynamoDB."""
    item = events_table.get_item(Key={"concert_id": concert_id}).get("Item")
    if item is None:
        return None
    capacity = item.get("capacity", {}).get(ticket_type)
    return int(capacity) if capacity is not None else None


def get_status(conn: psycopg.Connection, reservation_id: str) -> str | None:
    row = conn.execute("SELECT status FROM reservations WHERE reservation_id = %s", (reservation_id,)).fetchone()
    return row[0] if row else None


def try_book(conn: psycopg.Connection, r: dict, capacity: int) -> int:
    """Marca la reservación como booked si cabe. Regresa los boletos vendidos antes de esta reservación.

    Lanza NoCapacity (y la transacción hace ROLLBACK) si no hay espacio.
    """
    with conn.transaction():
        # Serializa a todos los workers que venden el mismo concierto + tipo de boleto.
        # FOR UPDATE por sí solo solo bloquea filas que ya existen como booked/confirmed; no
        # impide que otro worker cambie una fila pending a booked en paralelo (o la primera venta,
        # cuando aún no hay filas que bloquear). El advisory lock cubre ese hueco.
        conn.execute(
            "SELECT pg_advisory_xact_lock(hashtext(%s))",
            (f"{r['concert_id']}:{r['ticket_type']}",),
        )
        # Bloquea la fila de la reservación para que no la procese otro worker al mismo tiempo.
        row = conn.execute(
            "SELECT status FROM reservations WHERE reservation_id = %s FOR UPDATE",
            (r["reservation_id"],),
        ).fetchone()
        if row is None or row[0] != "pending":
            raise RuntimeError(f"La reservación ya no está pending: {row}")

        # PostgreSQL no permite FOR UPDATE junto con SUM(), así que se bloquean las filas
        # vendidas en una subconsulta y se suman afuera.
        sold = conn.execute(
            """
            SELECT COALESCE(SUM(quantity), 0)
            FROM (
                SELECT quantity
                FROM   reservations
                WHERE  concert_id  = %s
                AND    ticket_type = %s
                AND    status IN ('booked', 'confirmed')
                FOR UPDATE
            ) AS sold
            """,
            (r["concert_id"], r["ticket_type"]),
        ).fetchone()[0]

        if sold + r["quantity"] > capacity:
            raise NoCapacity(sold)  # sale del bloque -> ROLLBACK

        conn.execute(
            "UPDATE reservations SET status = 'booked', updated_at = NOW() WHERE reservation_id = %s",
            (r["reservation_id"],),
        )
        return sold


def set_status(conn: psycopg.Connection, reservation_id: str, new_status: str, expected: str) -> None:
    with conn.transaction():
        conn.execute(
            "UPDATE reservations SET status = %s, updated_at = NOW() WHERE reservation_id = %s AND status = %s",
            (new_status, reservation_id, expected),
        )


def checkout(r: dict) -> None:
    resp = http.post(
        f"{CHECKOUT_URL}/checkout",
        json={"reservation_id": r["reservation_id"], "quantity": r["quantity"]},
        timeout=CHECKOUT_TIMEOUT,
    )
    resp.raise_for_status()


def process(conn: psycopg.Connection, r: dict) -> None:
    rid = r["reservation_id"]
    current = get_status(conn, rid)

    if current is None:
        log.warning("Reservación %s no existe en RDS, se descarta el mensaje", rid)
        return

    if current == "pending":
        capacity = get_capacity(r["concert_id"], r["ticket_type"])
        if capacity is None:
            set_status(conn, rid, "rejected", "pending")
            log.info("%s -> rejected (concierto o tipo de boleto inexistente: %s/%s)",
                     rid, r["concert_id"], r["ticket_type"])
            return
        try:
            sold = try_book(conn, r, capacity)
        except NoCapacity as e:
            # Transacción separada: solo cambia esta fila.
            set_status(conn, rid, "rejected", "pending")
            log.info("%s -> rejected (%s/%s vendidos %s + %s > capacidad %s)",
                     rid, r["concert_id"], r["ticket_type"], e.args[0], r["quantity"], capacity)
            return
        log.info("%s -> booked (%s/%s vendidos %s + %s <= capacidad %s)",
                 rid, r["concert_id"], r["ticket_type"], sold, r["quantity"], capacity)
        current = "booked"

    if current == "booked":
        # Si checkout falla, la excepción deja el mensaje en SQS y se reintenta (sigue booked).
        checkout(r)
        set_status(conn, rid, "confirmed", "booked")
        log.info("%s -> confirmed (checkout autorizado)", rid)
        return

    log.info("%s ya estaba en estado %s, se descarta el mensaje duplicado", rid, current)


def connect() -> psycopg.Connection:
    while running:
        try:
            conn = psycopg.connect(CONNINFO, autocommit=True)
            log.info("Conectado a PostgreSQL")
            return conn
        except psycopg.OperationalError as e:
            log.warning("No se pudo conectar a PostgreSQL (%s), reintentando en 5s", e)
            time.sleep(5)
    raise SystemExit(0)


def main() -> None:
    log.info("ticket-worker escuchando %s", SQS_QUEUE_URL)
    conn = connect()

    while running:
        resp = sqs.receive_message(
            QueueUrl=SQS_QUEUE_URL,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=20,
            AttributeNames=["MessageGroupId"],
        )
        blocked_groups: set[str] = set()

        for msg in resp.get("Messages", []):
            group = msg["Attributes"]["MessageGroupId"]
            if group in blocked_groups:
                # Un mensaje anterior del mismo concierto falló: no procesar los siguientes
                # para respetar el orden FIFO. Se vuelven a entregar al vencer el visibility timeout.
                continue
            try:
                r = json.loads(msg["Body"])
            except json.JSONDecodeError:
                log.error("Mensaje inválido, se descarta: %s", msg["Body"])
                sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
                continue

            try:
                process(conn, r)
            except psycopg.OperationalError:
                log.exception("Se perdió la conexión a PostgreSQL procesando %s", r.get("reservation_id"))
                blocked_groups.add(group)
                conn.close()
                conn = connect()
                continue
            except Exception:
                log.exception("Error procesando %s, se reintentará", r.get("reservation_id"))
                blocked_groups.add(group)
                continue

            sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])

    conn.close()
    log.info("ticket-worker detenido")


if __name__ == "__main__":
    main()
