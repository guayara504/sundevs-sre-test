"""Metricas de negocio con CloudWatch Embedded Metric Format (EMF).

EMF escribe la metrica como una linea JSON en stdout; CloudWatch Logs la
extrae de forma asincrona. Ventajas en este diseno: cero llamadas de red
(la Lambda no tiene salida a internet ni endpoint de CloudWatch) y cero
latencia anadida al request.
"""

from __future__ import annotations

import json
import os
import time

NAMESPACE = os.environ.get("METRICS_NAMESPACE", "SundevsSRE/Processor")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "local")
SERVICE = "processor"


def emit(**counts: int) -> None:
    """Publica uno o varios contadores (unidad Count) con dimensiones fijas."""
    if not counts:
        return
    document = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": NAMESPACE,
                    "Dimensions": [["Environment", "Service"]],
                    "Metrics": [{"Name": name, "Unit": "Count"} for name in counts],
                }
            ],
        },
        "Environment": ENVIRONMENT,
        "Service": SERVICE,
        **counts,
    }
    print(json.dumps(document), flush=True)
