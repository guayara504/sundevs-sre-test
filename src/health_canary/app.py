"""Health canary: corre en la region DR y sondea GET /health de la region primaria.

Publica PrimaryHealthy=1|0 via EMF. La alarma (3 minutos seguidos en 0)
es la "senal de caida" que recibe el orquestador de DR.
"""

from __future__ import annotations

import json
import logging
import os
import time
import urllib.error
import urllib.request

logger = logging.getLogger()
logger.setLevel("INFO")

TIMEOUT_SECONDS = 5


def probe(url: str) -> tuple[bool, str]:
    request = urllib.request.Request(url, method="GET", headers={"User-Agent": "sundevs-sre-dr-canary"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:  # noqa: S310 - URL fija de config
            return response.status == 200, f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code}"
    except Exception as exc:  # noqa: BLE001
        return False, f"{type(exc).__name__}: {exc}"


def handler(event, context):
    url = os.environ["TARGET_URL"]
    started = time.time()
    healthy, detail = probe(url)
    latency_ms = int((time.time() - started) * 1000)

    print(
        json.dumps(
            {
                "_aws": {
                    "Timestamp": int(time.time() * 1000),
                    "CloudWatchMetrics": [
                        {
                            "Namespace": os.environ.get("METRICS_NAMESPACE", "SundevsSRE/DR"),
                            "Dimensions": [["Environment", "PrimaryRegion"]],
                            "Metrics": [
                                {"Name": "PrimaryHealthy", "Unit": "Count"},
                                {"Name": "PrimaryProbeLatency", "Unit": "Milliseconds"},
                            ],
                        }
                    ],
                },
                "Environment": os.environ.get("ENVIRONMENT", "prod"),
                "PrimaryRegion": os.environ.get("PRIMARY_REGION", "us-east-1"),
                "PrimaryHealthy": 1 if healthy else 0,
                "PrimaryProbeLatency": latency_ms,
            }
        ),
        flush=True,
    )
    log = logger.info if healthy else logger.warning
    log("primary probe", extra={"healthy": healthy, "detail": detail, "latency_ms": latency_ms})
    return {"healthy": healthy, "detail": detail, "latency_ms": latency_ms}
