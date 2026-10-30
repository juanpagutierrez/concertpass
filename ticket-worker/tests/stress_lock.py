"""Llama try_book() del worker desde N hilos a la vez (sin SQS) y verifica que no haya sobreventa.
Con --no-advisory quita el advisory lock para comprobar que FOR UPDATE solo no basta.

Uso (con las mismas variables de entorno que el worker y la tabla reservations ya creada):
    python tests/stress_lock.py src/main.py
    python tests/stress_lock.py src/main.py --no-advisory
"""
import importlib.util
import sys
import threading
import uuid

import psycopg

spec = importlib.util.spec_from_file_location("worker", sys.argv[1])
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

if "--no-advisory" in sys.argv:
    real_execute = psycopg.Connection.execute
    def execute(self, query, params=None, **kw):
        if "pg_advisory_xact_lock" in query:
            return real_execute(self, "SELECT 1")
        return real_execute(self, query, params, **kw)
    psycopg.Connection.execute = execute

N, CAP, CONCERT = 40, 10, f"stress-{uuid.uuid4().hex[:6]}"
admin = psycopg.connect(worker.CONNINFO, autocommit=True)
ids = [str(uuid.uuid4()) for _ in range(N)]
for rid in ids:
    admin.execute("INSERT INTO reservations VALUES (%s,%s,'u','vip',1,'pending',NOW(),NOW())", (rid, CONCERT))

barrier = threading.Barrier(N)
results = []
def run(rid):
    conn = psycopg.connect(worker.CONNINFO, autocommit=True)
    barrier.wait()
    try:
        worker.try_book(conn, {"reservation_id": rid, "concert_id": CONCERT, "ticket_type": "vip", "quantity": 1}, CAP)
        results.append("booked")
    except worker.NoCapacity:
        results.append("rejected")
    conn.close()

threads = [threading.Thread(target=run, args=(rid,)) for rid in ids]
[t.start() for t in threads]
[t.join() for t in threads]
sold = admin.execute("SELECT COUNT(*) FROM reservations WHERE concert_id=%s AND status='booked'", (CONCERT,)).fetchone()[0]
print(f"{'SIN advisory lock' if '--no-advisory' in sys.argv else 'CON advisory lock'}: "
      f"{N} hilos, capacidad {CAP} -> booked en BD = {sold} {'OK' if sold <= CAP else 'SOBREVENTA'}")
