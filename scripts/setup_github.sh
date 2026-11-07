#!/usr/bin/env bash
# Configura el repositorio de GitHub para el flujo de promocion por ramas.
# Requiere: gh CLI autenticado (gh auth login) con permisos de admin del repo.
#
#   - Variable AWS_ACCOUNT_ID (los ARNs de roles se derivan de ella; no hay secretos AWS)
#   - Environments: dev (solo rama develop), production (solo main + aprobacion), dr (solo main)
#   - Proteccion de ramas develop y main (PR obligatorio + checks en verde)
set -euo pipefail

REPO="${1:-guayara504/sundevs-sre-test}"
ACCOUNT_ID="${2:-624991055549}"
REVIEWER="${3:-$(gh api user --jq .login)}"
REVIEWER_ID=$(gh api "users/${REVIEWER}" --jq .id)

echo "==> Variable de repositorio AWS_ACCOUNT_ID"
gh variable set AWS_ACCOUNT_ID --repo "$REPO" --body "$ACCOUNT_ID"

create_env() {
  local env="$1" branch="$2" reviewers_json="$3"
  echo "==> Environment ${env} (rama ${branch})"
  gh api -X PUT "repos/${REPO}/environments/${env}" --input - <<EOF
{
  "wait_timer": 0,
  "reviewers": ${reviewers_json},
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
EOF
  gh api -X POST "repos/${REPO}/environments/${env}/deployment-branch-policies" \
    -f name="${branch}" -f type=branch >/dev/null 2>&1 || true
}

create_env dev develop '[]'
create_env production main "[{\"type\":\"User\",\"id\":${REVIEWER_ID}}]"
# dr sin revisores: el failover automatico no debe esperar a una persona.
create_env dr main '[]'

# Sin "linear history": las promociones develop -> main y el back-merge
# main -> develop se hacen con merge commit para que ambas ramas compartan
# historial (con squash los SHAs divergen y cada release genera conflictos).
protect_branch() {
  local branch="$1"; shift
  echo "==> Proteccion de rama ${branch}"
  local checks
  checks=$(printf '"%s",' "$@"); checks="[${checks%,}]"
  gh api -X PUT "repos/${REPO}/branches/${branch}/protection" --input - <<EOF
{
  "required_status_checks": { "strict": true, "contexts": ${checks} },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0, "require_code_owner_reviews": false },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
EOF
}

CHECKS=(
  "quality / Python - lint y pruebas"
  "quality / Terraform - fmt, validate, tflint"
  "quality / IaC - escaneo de seguridad (Checkov)"
  "quality / Escaneo de secretos (gitleaks)"
)
protect_branch develop "${CHECKS[@]}"
protect_branch main "${CHECKS[@]}" "Regla de promocion de ramas"

echo "Listo. Nota: la aprobacion en 'production' en repos privados requiere GitHub Pro/Team."
