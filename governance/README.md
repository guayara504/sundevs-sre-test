# Gobierno: guardrails sin AWS Organizations

La cuenta `624991055549` es una **cuenta independiente** (no pertenece a AWS Organizations), así que no hay Service Control Policies. Los controles preventivos que normalmente daría una SCP se implementan con **IAM dentro de la cuenta**, como código en [bootstrap/main.tf](../bootstrap/main.tf):

| Guardrail (equivalente a SCP) | Implementación en la cuenta | Dónde |
|---|---|---|
| Solo regiones aprobadas (`us-east-1`, `us-east-2`) | `Deny` con `NotAction` sobre servicios globales y condición `aws:RequestedRegion` | Política de los roles `sundevs-sre-gha-*` y permissions boundary |
| Sin escalamiento de privilegios desde CI/CD | `iam:CreateRole` solo se permite si el rol nace con `sundevs-sre-workload-boundary` (`iam:PermissionsBoundary`) | Política de despliegue |
| Techo de permisos de la carga de trabajo | Permissions boundary: S3/DynamoDB del proyecto, logs, `elasticache:Connect`, ENIs, X-Ray, SNS/SSM/Secrets del proyecto | `aws_iam_policy.boundary` |
| Proteger los guardrails | `Deny` explícito para modificar el boundary, quitarlo de un rol o alterar los roles `sundevs-sre-gha-*` | `DenyTamperingWithGuardrails` |
| Aislamiento entre ambientes | Cada rol solo gestiona `sundevs-sre-<env>-*` y solo su llave de estado de Terraform | `ScopedServices`, `TerraformState*` |
| Sin llaves estáticas en CI | OIDC con `sub` anclado a repo + environment de GitHub | `modules/github-role` |
| Sin lectura de datos de negocio en planes | El rol de plan niega `s3:GetObject` (fuera del estado), lecturas de DynamoDB y `GetSecretValue` | `DenyBusinessDataReads` |
| Control de costos | AWS Budgets con alertas por correo | `aws_budgets_budget.project` |

## Alcance y diferencia con una SCP

- Una SCP limita a **todos** los principales de la cuenta. Estos guardrails limitan a los **roles del pipeline** y a los **roles de la carga de trabajo**, que son los únicos que crean y operan los recursos de este proyecto.
- Los usuarios administradores de la cuenta (por ejemplo, el usuario usado para el bootstrap) no quedan restringidos. Recomendación: MFA obligatorio, sin access keys de larga duración y uso puntual solo para el bootstrap.
