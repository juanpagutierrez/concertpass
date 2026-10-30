"""ticket-checkout: simula un procesador de pagos externo (tipo Stripe/PayPal). Siempre autoriza."""

import logging
import os
import uuid

from fastapi import FastAPI
from pydantic import BaseModel, Field

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-checkout")

app = FastAPI(title="ticket-checkout")


class CheckoutRequest(BaseModel):
    reservation_id: uuid.UUID
    quantity: int = Field(gt=0)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/checkout")
def checkout(req: CheckoutRequest):
    authorization_id = f"auth_{uuid.uuid4().hex[:16]}"
    log.info("Pago autorizado %s para reservación %s (qty=%s)", authorization_id, req.reservation_id, req.quantity)
    return {
        "status": "authorized",
        "authorization_id": authorization_id,
        "reservation_id": str(req.reservation_id),
        "quantity": req.quantity,
    }
