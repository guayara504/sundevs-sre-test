"""Cliente de cache Redis (ElastiCache) con TLS y autenticacion IAM.

- Sin passwords: el token de autenticacion es una URL prefirmada con SigV4
  usando las credenciales del rol de la Lambda (se genera localmente, no
  requiere red). Valido 15 min; se regenera antes de expirar.
- Toda escritura lleva TTL explicito (SET ... EX ttl). No existe un metodo
  para escribir sin TTL.
- Fallas de Redis NO tumban el request: se registran, se emite la metrica
  CacheErrors y el servicio continua en modo degradado (DynamoDB).
"""

from __future__ import annotations

import logging
import threading
import time
from urllib.parse import ParseResult, urlencode, urlunparse

import botocore.session
from botocore.model import ServiceId
from botocore.signers import RequestSigner

import metrics

logger = logging.getLogger(__name__)

TOKEN_TTL_SECONDS = 900
TOKEN_REFRESH_MARGIN_SECONDS = 60

try:  # redis solo existe en el paquete desplegado / entorno de pruebas
    import redis
    from redis.credentials import CredentialProvider
except ImportError:  # pragma: no cover
    redis = None
    CredentialProvider = object  # type: ignore[assignment,misc]


class ElastiCacheIAMProvider(CredentialProvider):  # type: ignore[misc]
    """Genera el par (usuario, token IAM) que redis-py usa en AUTH."""

    def __init__(self, user_id: str, cache_name: str, region: str) -> None:
        self.user_id = user_id
        self.cache_name = cache_name
        self.region = region
        session = botocore.session.get_session()
        self._signer = RequestSigner(
            ServiceId("elasticache"),
            region,
            "elasticache",
            "v4",
            session.get_credentials(),
            session.get_component("event_emitter"),
        )
        self._lock = threading.Lock()
        self._token: str | None = None
        self._expires_at = 0.0

    def get_credentials(self) -> tuple[str, str]:
        with self._lock:
            now = time.time()
            if self._token is None or now >= self._expires_at - TOKEN_REFRESH_MARGIN_SECONDS:
                self._token = self._sign()
                self._expires_at = now + TOKEN_TTL_SECONDS
            return self.user_id, self._token

    def _sign(self) -> str:
        query = urlencode({"Action": "connect", "User": self.user_id})
        url = urlunparse(ParseResult("https", self.cache_name, "/", "", query, ""))
        signed = self._signer.generate_presigned_url(
            {"method": "GET", "url": url, "body": {}, "headers": {}, "context": {}},
            operation_name="connect",
            expires_in=TOKEN_TTL_SECONDS,
            region_name=self.region,
        )
        return signed.removeprefix("https://")


class Cache:
    """Cache de lectura (read-through) tolerante a fallas."""

    def __init__(
        self,
        *,
        enabled: bool,
        host: str = "",
        port: int = 6379,
        user_id: str = "",
        cache_name: str = "",
        region: str = "",
        socket_timeout: float = 1.0,
        client=None,
    ) -> None:
        self.enabled = enabled and (bool(host) or client is not None)
        self._client = client
        self._params = dict(
            host=host,
            port=port,
            user_id=user_id,
            cache_name=cache_name,
            region=region,
            socket_timeout=socket_timeout,
        )

    def _get_client(self):
        if self._client is None:
            p = self._params
            self._client = redis.Redis(
                host=p["host"],
                port=p["port"],
                ssl=True,
                ssl_cert_reqs="required",
                credential_provider=ElastiCacheIAMProvider(p["user_id"], p["cache_name"], p["region"]),
                socket_timeout=p["socket_timeout"],
                socket_connect_timeout=p["socket_timeout"],
                health_check_interval=30,
                retry_on_timeout=False,
                decode_responses=True,
                lib_name=None,
                lib_version=None,
            )
        return self._client

    def get(self, key: str) -> str | None:
        if not self.enabled:
            return None
        try:
            return self._get_client().get(key)
        except Exception as exc:  # noqa: BLE001 - cualquier falla de cache es no fatal
            self._on_error("get", exc)
            return None

    def set(self, key: str, value: str, ttl_seconds: int) -> bool:
        if not self.enabled:
            return False
        if ttl_seconds <= 0:
            raise ValueError("Toda key de cache debe tener TTL positivo")
        try:
            return bool(self._get_client().set(key, value, ex=ttl_seconds))
        except Exception as exc:  # noqa: BLE001
            self._on_error("set", exc)
            return False

    def _on_error(self, operation: str, exc: Exception) -> None:
        logger.warning(
            "Cache no disponible, modo degradado",
            extra={"operation": operation, "error_type": type(exc).__name__, "error": str(exc)},
        )
        metrics.emit(CacheErrors=1)
        # Fuerza reconexion limpia en la siguiente invocacion.
        self._client = None if self._params["host"] else self._client
