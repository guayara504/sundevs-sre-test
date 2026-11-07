# Evidencia de funcionamiento (ambiente dev, us-east-1)

Capturada el 2026-11-07 (UTC) contra `https://vx3q89jg9d.execute-api.us-east-1.amazonaws.com`, desplegado con `terraform apply -var-file=envs/dev.tfvars`. La IP del cliente está enmascarada (`x.x.x.x`).

| Archivo | Qué demuestra |
|---|---|
| [01-request-miss.txt](01-request-miss.txt) | **Primera llamada → `X-Cache: MISS`** (`X-Result-Source: processed`) |
| [02-request-hit.txt](02-request-hit.txt) | **Mismo request → `X-Cache: HIT`** (`X-Result-Source: redis`) |
| [03-s3-objects.txt](03-s3-objects.txt) | **Objetos en S3** bajo `results/<fecha>/<id>.json`, con versionado |
| [04-errors-health-cors.txt](04-errors-health-cors.txt) | `GET /health` 200, entradas inválidas → 400, preflight CORS con cualquier origen |
| [05-s3-security.txt](05-s3-security.txt) | Block Public Access x4, versionado, **un administrador recibe 403 al leer objetos** (solo el rol de la Lambda, vía VPC endpoint), bucket policy |
| [06-network-redis-api.txt](06-network-redis-api.txt) | Gateway endpoints S3/DynamoDB, SGs (Redis solo desde el SG de Lambda en 6379), Lambda en subnets privadas, Redis con TLS + cifrado en reposo + usuario con **auth IAM**, throttling y access logs de la API |
| [07-ttl-expiry.txt](07-ttl-expiry.txt) | A los 65 s (TTL de 60 s vencido) → `MISS` servido desde **DynamoDB sin reprocesar**; la siguiente llamada vuelve a ser `HIT` |
| [08-error-500.txt](08-error-500.txt) | Excepción no controlada → **HTTP 500** con mensaje descriptivo y `requestId`, más la traza en **CloudWatch Logs** |
| [09-observability.txt](09-observability.txt) | Métricas EMF (CacheHit/CacheMiss), alarmas conectadas a SNS, suscripción de correo, access logs JSON |
| [10-degraded-mode.txt](10-degraded-mode.txt) | Tras apagar NAT y Redis (ahorro de costos), el servicio sigue respondiendo 200 en modo degradado |
