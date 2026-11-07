"""Orquestador de DR (backup & restore automatizado).

Se dispara por SNS cuando la alarma "primary-region-down" pasa a ALARM.
  1. Verifica que el failover automatico este habilitado.
  2. Idempotencia: si el parametro SSM ya indica FAILOVER_TRIGGERED, no repite.
  3. Lee el token de GitHub desde Secrets Manager (nunca en codigo/variables).
  4. Envia repository_dispatch "dr-failover" -> workflow dr.yml hace el
     terraform apply en la region DR usando los datos ya replicados.
  5. Notifica por SNS (correo) el resultado.

Invocacion manual de prueba (no dispara nada): {"dry_run": true}
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel("INFO")

STANDBY = "STANDBY"
TRIGGERED_PREFIX = "FAILOVER_TRIGGERED"

ssm = boto3.client("ssm")
secrets = boto3.client("secretsmanager")
sns = boto3.client("sns")


def _notify(subject: str, message: str) -> None:
    sns.publish(TopicArn=os.environ["NOTIFY_TOPIC_ARN"], Subject=subject[:100], Message=message)


def _alarm_messages(event: dict[str, Any]) -> list[dict[str, Any]]:
    messages = []
    for record in event.get("Records", []):
        try:
            messages.append(json.loads(record["Sns"]["Message"]))
        except (KeyError, json.JSONDecodeError):
            logger.warning("mensaje SNS no reconocido", extra={"record": str(record)[:500]})
    return messages


def _get_token() -> str | None:
    try:
        value = secrets.get_secret_value(SecretId=os.environ["TOKEN_SECRET_ID"])["SecretString"].strip()
    except secrets.exceptions.ResourceNotFoundException:
        return None
    except Exception:  # noqa: BLE001 - p.ej. secreto sin version cargada
        logger.exception("no fue posible leer el token de GitHub")
        return None
    return value or None


def _primary_is_healthy(attempts: int = 3, wait_seconds: float = 5.0) -> bool:
    """True si GET /health de la primaria responde 200 en alguno de los intentos."""
    url = os.environ.get("PRIMARY_HEALTH_URL")
    if not url:
        return False
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "sundevs-sre-dr-orchestrator"})
            with urllib.request.urlopen(request, timeout=5) as response:
                if response.status == 200:
                    return True
        except Exception:  # noqa: BLE001, S110 - cualquier falla cuenta como no saludable
            pass
        if attempt < attempts - 1:
            time.sleep(wait_seconds)
    return False


def _dispatch(token: str, reason: str) -> int:
    url = f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/dispatches"
    body = json.dumps(
        {
            "event_type": "dr-failover",
            "client_payload": {
                "reason": reason,
                "primary_region": os.environ.get("PRIMARY_REGION"),
                "dr_region": os.environ.get("DR_REGION"),
            },
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "sundevs-sre-dr-orchestrator",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:  # noqa: S310
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code


def failover(reason: str, dry_run: bool = False) -> dict[str, Any]:
    parameter = os.environ["STATUS_PARAMETER"]
    status = ssm.get_parameter(Name=parameter)["Parameter"]["Value"]
    if status.startswith(TRIGGERED_PREFIX):
        logger.info("failover ya disparado previamente; se ignora", extra={"status": status})
        return {"action": "skipped", "status": status}

    # Segunda verificacion independiente: un failover es costoso y disruptivo,
    # no se decide solo con la metrica (protege contra falsos positivos).
    if not dry_run and _primary_is_healthy():
        _notify(
            "[DR] Falsa alarma - la region primaria responde",
            f"{reason}\n\nLa re-verificacion de {os.environ.get('PRIMARY_HEALTH_URL')} respondio 200. "
            "No se dispara el failover.",
        )
        return {"action": "false-alarm", "status": status}

    if os.environ.get("AUTO_FAILOVER", "false").lower() != "true":
        _notify(
            "[DR] Caida detectada - failover automatico DESHABILITADO",
            f"{reason}\n\nEjecute manualmente el workflow 'dr' (action=failover) en GitHub.",
        )
        return {"action": "manual-required", "status": status}

    token = _get_token()
    if not token:
        _notify(
            "[DR] Caida detectada - falta token de GitHub",
            f"{reason}\n\nNo hay token en {os.environ['TOKEN_SECRET_ID']}. "
            "Ejecute manualmente el workflow 'dr' (action=failover).",
        )
        return {"action": "manual-required", "status": status}

    if dry_run:
        return {"action": "dry-run", "status": status, "token_present": True}

    http_status = _dispatch(token, reason)
    if http_status != 204:
        _notify(
            "[DR] ERROR disparando failover",
            f"GitHub respondio HTTP {http_status}. Ejecute el workflow manualmente.",
        )
        raise RuntimeError(f"repository_dispatch fallo con HTTP {http_status}")

    new_status = f"{TRIGGERED_PREFIX}:{datetime.now(UTC).isoformat(timespec='seconds')}"
    ssm.put_parameter(Name=parameter, Value=new_status, Type="String", Overwrite=True)
    _notify(
        "[DR] Failover iniciado hacia " + os.environ.get("DR_REGION", "region DR"),
        f"{reason}\n\nSe disparo el workflow de restauracion (repository_dispatch dr-failover). "
        "Recibira la URL de la API restaurada al finalizar el pipeline.",
    )
    return {"action": "dispatched", "status": new_status}


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    if event.get("dry_run"):
        return failover("Prueba manual (dry run)", dry_run=True)

    for message in _alarm_messages(event):
        if message.get("NewStateValue") != "ALARM":
            continue
        reason = f"Alarma {message.get('AlarmName')}: {message.get('NewStateReason')}"
        logger.warning("caida de region primaria detectada", extra={"reason": reason})
        return failover(reason)

    return {"action": "ignored"}
