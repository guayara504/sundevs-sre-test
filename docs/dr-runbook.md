# Runbook de DR: prod de us-east-1 a us-east-2

## Componentes siempre activos (en us-east-2, costo casi nulo)

| Componente | Función |
|---|---|
| `sundevs-sre-prod-use2-health-canary` | Cada minuto hace `GET /health` a la API primaria y publica `SundevsSRE/DR · PrimaryHealthy` (1 o 0) |
| Alarma `sundevs-sre-prod-use2-primary-region-down` | `PrimaryHealthy < 1` durante 3 de 3 minutos → SNS `dr-alarm` + correo |
| `sundevs-sre-prod-use2-dr-orchestrator` | Recibe la alarma, revisa la idempotencia (SSM `/sundevs-sre/prod/dr/status`) y envía `repository_dispatch: dr-failover` |
| Secreto `sundevs-sre-prod-use2-github-dispatch-token` | Fine-grained PAT, solo para el repo, con permiso **Contents: Read & write** (lo exige `repository_dispatch`) |
| S3 `sundevs-sre-prod-results-<acct>-use2` | Réplica CRR de `results/` |
| DynamoDB `sundevs-sre-prod-results` (réplica) | Global table con PITR |
| Bucket de estado `tfstate-sundevs-sre-<acct>-use2` | Estado de Terraform del entorno DR |

## Configuración inicial (una vez, tras el primer deploy de prod)

```bash
# Cargar el token (nunca pasa por Terraform ni por el repositorio)
aws secretsmanager put-secret-value --region us-east-2 \
  --secret-id sundevs-sre-prod-use2-github-dispatch-token \
  --secret-string 'github_pat_xxx'

# Simulacro sin efectos: valida permisos y presencia del token
aws lambda invoke --region us-east-2 --function-name sundevs-sre-prod-use2-dr-orchestrator \
  --payload '{"dry_run": true}' --cli-binary-format raw-in-base64-out /dev/stdout
```

## Failover automático

1. La región primaria deja de responder `/health` durante 3 minutos.
2. La alarma pasa a `ALARM` y llega un correo `[DR] ... ALARM`.
3. El orquestador marca `FAILOVER_TRIGGERED:<ts>` en SSM, dispara el workflow `dr` y envía el correo `[DR] Failover iniciado`.
4. El workflow `dr` (environment `dr`, rol `sundevs-sre-gha-dr`, todo en us-east-2):
   - `terraform apply -var-file=envs/dr.tfvars`: VPC, endpoints, Redis, Lambda y API, reutilizando la tabla y el bucket replicados.
   - Smoke test MISS/HIT contra la nueva URL.
   - Correo `[DR] Servicio restaurado en us-east-2` con la URL.
5. Se actualiza el cliente o el DNS hacia la nueva URL (con Route 53 failover este paso sería automático).

## Failover manual

GitHub → Actions → **dr** → *Run workflow* → `action = failover`.

Para revisar sin aplicar nada: `action = plan`.

## Failback (cuando us-east-1 se recupera)

1. Confirmar que la alarma volvió a `OK` (llega un correo de OK).
2. Datos: DynamoDB global table es multi-activa, así que lo escrito en us-east-2 ya está en us-east-1. En S3, los objetos creados en DR quedan en el bucket DR. Si hace falta, se sincronizan con `aws s3 sync` (o con replicación bidireccional, si se decide habilitarla).
3. Volver a apuntar los clientes a la URL primaria.
4. GitHub → Actions → **dr** → `action = teardown`. Esto destruye el cómputo DR y deja el SSM de nuevo en `STANDBY`.

## Probar el DR sin una caída real

- Simulacro del orquestador: `{"dry_run": true}` (ver arriba).
- Simulacro completo: `dr` → `failover` manual, verificar y luego `teardown`.
- Forzar la alarma (dispara el flujo real):
  ```bash
  aws cloudwatch set-alarm-state --region us-east-2 \
    --alarm-name sundevs-sre-prod-use2-primary-region-down \
    --state-value ALARM --state-reason "Game day"
  ```
