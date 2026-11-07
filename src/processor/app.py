"""Lambda processor: POST /process y GET /health (API Gateway HTTP API, payload v2).

Flujo (read-through cache):
    1. key = sha256(body canonico)
    2. Redis GET  -> HIT: responde con X-Cache: HIT
    3. MISS -> DynamoDB GetItem (fuente de verdad)
         - existe: se re-hidrata la cache, no se reprocesa
         - no existe: se procesa, se guarda en S3 + DynamoDB
    4. Redis SET con TTL (60s) -> responde con X-Cache: MISS
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
from datetime import UTC, datetime
from typing import Any

import boto3
from botocore.config import Config

import metrics
from cache import Cache
from store import ResultStore

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

CACHE_KEY_PREFIX = "process:v1"
MAX_BODY_BYTES = 64 * 1024


class ValidationError(Exception):
    """Error de entrada del cliente (HTTP 400)."""


# --- Dependencias (se crean una vez por entorno de ejecucion) ----------------
_deps: dict[str, Any] | None = None


def _build_dependencies() -> dict[str, Any]:
    region = os.environ.get("AWS_REGION", "us-east-1")
    boto_cfg = Config(
        connect_timeout=2,
        read_timeout=3,
        retries={"max_attempts": 3, "mode": "standard"},
    )
    cache = Cache(
        enabled=os.environ.get("REDIS_ENABLED", "false").lower() == "true",
        host=os.environ.get("REDIS_HOST", ""),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        user_id=os.environ.get("REDIS_USER_ID", ""),
        cache_name=os.environ.get("REDIS_CACHE_NAME", ""),
        region=region,
    )
    store = ResultStore(
        s3_client=boto3.client("s3", region_name=region, config=boto_cfg),
        dynamodb_client=boto3.client("dynamodb", region_name=region, config=boto_cfg),
        bucket=os.environ["RESULTS_BUCKET"],
        table=os.environ["RESULTS_TABLE"],
    )
    return {
        "cache": cache,
        "store": store,
        "ttl": int(os.environ.get("CACHE_TTL_SECONDS", "60")),
        "region": region,
    }


def _get_dependencies() -> dict[str, Any]:
    global _deps
    if _deps is None:
        _deps = _build_dependencies()
    return _deps


# --- Logica de negocio -------------------------------------------------------
def parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw = event.get("body")
    if raw is None or raw == "":
        raise ValidationError("El body es obligatorio y debe ser un JSON con el campo 'data'.")
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    if len(raw.encode("utf-8")) > MAX_BODY_BYTES:
        raise ValidationError(f"El body supera el maximo de {MAX_BODY_BYTES} bytes.")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"El body no es JSON valido: {exc.msg}.") from exc
    if not isinstance(payload, dict):
        raise ValidationError("El body debe ser un objeto JSON.")
    if not isinstance(payload.get("data"), str) or not payload["data"]:
        raise ValidationError("El campo 'data' es obligatorio y debe ser un string no vacio.")
    return payload


def cache_key_for(payload: dict[str, Any]) -> tuple[str, str]:
    """Clave determinista: el mismo JSON (sin importar orden de llaves) -> misma clave."""
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return f"{CACHE_KEY_PREFIX}:{digest}", digest


def transform(payload: dict[str, Any], result_id: str, region: str) -> dict[str, Any]:
    text = payload["data"]
    now = datetime.now(UTC)
    return {
        "id": result_id,
        "input": payload,
        "output": {
            "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "reversed": text[::-1],
            "uppercase": text.upper(),
            "length": len(text),
            "word_count": len(text.split()),
        },
        "processed_at": now.isoformat(timespec="milliseconds"),
        "s3_key": f"results/{now:%Y-%m-%d}/{result_id}.json",
        "region": region,
    }


def process(payload: dict[str, Any], deps: dict[str, Any]) -> tuple[dict[str, Any], str, str]:
    """Devuelve (resultado, X-Cache, origen)."""
    cache: Cache = deps["cache"]
    store: ResultStore = deps["store"]
    key, result_id = cache_key_for(payload)

    cached = cache.get(key)
    if cached is not None:
        metrics.emit(CacheHit=1)
        return json.loads(cached), "HIT", "redis"

    metrics.emit(CacheMiss=1)
    result = store.get(result_id)
    source = "dynamodb"
    if result is None:
        result = transform(payload, result_id, deps["region"])
        result = store.put(result, result["s3_key"])
        source = "processed"

    cache.set(key, json.dumps(result, separators=(",", ":")), ttl_seconds=deps["ttl"])
    return result, "MISS", source


# --- Adaptador HTTP ------------------------------------------------------------
def _response(status: int, body: dict[str, Any], headers: dict[str, str] | None = None) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", **(headers or {})},
        "body": json.dumps(body, ensure_ascii=False),
        "isBase64Encoded": False,
    }


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    request_id = getattr(context, "aws_request_id", "local")
    route = event.get("routeKey", "")
    base_headers = {"X-Request-Id": request_id}

    if route == "GET /health":
        return _response(200, {"status": "ok"}, base_headers)

    try:
        payload = parse_body(event)
        result, cache_status, source = process(payload, _get_dependencies())
        logger.info("request processed", extra={"cache": cache_status, "source": source, "id": result["id"]})
        return _response(200, result, {**base_headers, "X-Cache": cache_status, "X-Result-Source": source})

    except ValidationError as exc:
        logger.info("invalid request", extra={"reason": str(exc)})
        return _response(
            400,
            {"error": "BadRequest", "message": str(exc), "requestId": request_id},
            {**base_headers, "X-Cache": "MISS"},
        )

    except Exception as exc:  # noqa: BLE001 - frontera del handler: nada sale sin controlar
        logger.exception("unhandled error processing request", extra={"error_type": type(exc).__name__})
        metrics.emit(ProcessingErrors=1)
        return _response(
            500,
            {
                "error": "InternalServerError",
                "message": (
                    f"No fue posible procesar la solicitud ({type(exc).__name__}). "
                    "El error quedo registrado en CloudWatch con el requestId indicado."
                ),
                "requestId": request_id,
            },
            {**base_headers, "X-Cache": "MISS"},
        )
