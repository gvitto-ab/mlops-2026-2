#!/usr/bin/env bash
# ---------------------------------------------------------------
# Lab4 - Parte 2 pelo Azure Cloud Shell (bash), em vez de clicar no portal.
#
# Cria, no resource group mlops-2026-2:
#   - Container Apps Environment + Container App "intent-clf"
#     (imagem ghcr.io/gvitto-ab/mlops-2026-2:v1.0.0, 2 vCPU / 4 GiB,
#      ingress externo na porta 8000, startup probe TCP 8000 10 s x 60)
#   - Identidade gerenciada "user-assigned-identity-1" com papel
#     Contributor no resource group
#   - Credencial federada para repo:gvitto-ab/mlops-2026-2:environment:production
# No fim imprime Client ID, Tenant ID, Subscription ID e a Application Url.
#
# Uso (no Cloud Shell, modo Bash):
#   curl -sL https://raw.githubusercontent.com/gvitto-ab/mlops-2026-2/main/infra/azure-setup.sh -o setup.sh
#   bash setup.sh
#
# O script pede MONGO_URL e WANDB_API_KEY no terminal (não ficam no arquivo
# nem no histórico). Nada secreto vai para o GitHub.
# ---------------------------------------------------------------
set -euo pipefail

RG=mlops-2026-2
APP=intent-clf
ENV_NAME=intent-clf-env
IDENTITY=user-assigned-identity-1
IMAGE=ghcr.io/gvitto-ab/mlops-2026-2:v1.0.0
GH_SUBJECT=repo:gvitto-ab/mlops-2026-2:environment:production

echo "== Assinatura"
az account show --query "{nome:name, id:id}" -o table

echo "== Registrando provedores (pode levar 1-2 min na primeira vez)"
for p in Microsoft.App Microsoft.OperationalInsights Microsoft.ManagedIdentity; do
  az provider register --namespace "$p" --wait
done

# --- Região: o plano Students só libera algumas (Policy > Allowed locations)
ALLOWED=$(az policy assignment list --disable-scope-strict-match \
  --query "[].parameters.listOfAllowedLocations.value[]" -o tsv 2>/dev/null | sort -u || true)
PREF="brazilsouth eastus eastus2 westus2 westus3 centralus southcentralus northeurope westeurope canadacentral"
CANDS=""
for cand in $PREF; do
  if [ -z "$ALLOWED" ] || echo "$ALLOWED" | grep -qx "$cand"; then CANDS="$CANDS $cand"; fi
done
[ -n "$CANDS" ] || CANDS=$(echo "$ALLOWED" | tr '\n' ' ')
echo "== Regiões permitidas pela política: ${ALLOWED:-(não encontrada, vou testar uma a uma)}"
echo "== Candidatas: $CANDS"
LOC=$(echo $CANDS | awk '{print $1}')

echo "== Segredos do app (o texto não aparece ao colar)"
read -rsp "MONGO_URL: " MONGO_URL; echo
read -rsp "WANDB_API_KEY (Enter para deixar vazio): " WANDB_API_KEY; echo
[ -n "$MONGO_URL" ] || { echo "MONGO_URL vazio"; exit 1; }
[ -n "$WANDB_API_KEY" ] || WANDB_API_KEY="nao-usado"

echo "== Resource group $RG"
if ! az group show -n "$RG" -o none 2>/dev/null; then
  for cand in $CANDS; do
    az group create -n "$RG" -l "$cand" -o none 2>/dev/null && break
  done
fi
az group show -n "$RG" --query "{nome:name, regiao:location}" -o table

echo "== Container Apps Environment $ENV_NAME (cria também um Log Analytics; ~3 min)"
if az containerapp env show -n "$ENV_NAME" -g "$RG" -o none 2>/dev/null; then
  # rodando de novo: reaproveita o Environment e a região dele
  LOC=$(az containerapp env show -n "$ENV_NAME" -g "$RG" --query location -o tsv | tr -d ' ' | tr '[:upper:]' '[:lower:]')
  echo "   já existe, reaproveitando"
else
  ENV_OK=""
  for cand in $CANDS; do
    echo "   tentando $cand..."
    if az containerapp env create -n "$ENV_NAME" -g "$RG" -l "$cand" -o none 2>/tmp/env.err; then
      LOC=$cand; ENV_OK=1; break
    fi
    if grep -qiE "RequestDisallowedByPolicy|LocationNotAvailable|not available|disallowed" /tmp/env.err; then
      echo "   $cand não permitida, próxima"; continue
    fi
    cat /tmp/env.err; exit 1
  done
  [ -n "$ENV_OK" ] || { echo "Nenhuma região aceitou o Environment"; cat /tmp/env.err; exit 1; }
fi
echo "== Região usada: $LOC"
ENV_ID=$(az containerapp env show -n "$ENV_NAME" -g "$RG" --query id -o tsv)
SUB_ID=$(az account show --query id -o tsv)
APP_URI="https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.App/containerApps/$APP?api-version=2024-03-01"

echo "== Container App $APP (direto na API do Azure; ~2 min)"
# O corpo é montado com jq (escapa a MONGO_URL corretamente) num arquivo
# temporário só legível por você, apagado logo depois.
umask 077
BODY=$(mktemp)
jq -n --arg loc "$LOC" --arg env "$ENV_ID" --arg app "$APP" --arg img "$IMAGE" \
      --arg mongo "$MONGO_URL" --arg wandb "$WANDB_API_KEY" '{
  location: $loc,
  properties: {
    managedEnvironmentId: $env,
    configuration: {
      activeRevisionsMode: "Single",
      ingress: { external: true, targetPort: 8000, transport: "auto" },
      secrets: [ { name: "mongo-url", value: $mongo },
                 { name: "wandb-api-key", value: $wandb } ]
    },
    template: {
      containers: [ {
        name: $app, image: $img,
        resources: { cpu: 2.0, memory: "4Gi" },
        env: [
          { name: "WANDB_PROJECT", value: "mlops-2026-2" },
          { name: "WANDB_MODELS", value: "/app/src/modules/intent_classifier/artifacts/confusion-clf.keras" },
          { name: "MONGO_DB", value: "intent_classifier" },
          { name: "APP_VERSION", value: "v1.0.0" },
          { name: "OTEL_SDK_DISABLED", value: "true" },
          { name: "MONGO_URL", secretRef: "mongo-url" },
          { name: "WANDB_API_KEY", secretRef: "wandb-api-key" }
        ],
        probes: [ { type: "Startup", tcpSocket: { port: 8000 },
                    periodSeconds: 10, failureThreshold: 60 } ]
      } ],
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}' > "$BODY"
az rest --method put --url "$APP_URI" --body @"$BODY" -o none
rm -f "$BODY"
umask 022

STATE=""
for i in $(seq 1 40); do
  STATE=$(az rest --method get --url "$APP_URI" --query properties.provisioningState -o tsv)
  echo "   estado: $STATE"
  [ "$STATE" = "Succeeded" ] && break
  [ "$STATE" = "Failed" ] && { echo "Falhou ao criar o Container App"; exit 1; }
  sleep 15
done
FQDN=$(az rest --method get --url "$APP_URI" --query properties.configuration.ingress.fqdn -o tsv)

echo "== Identidade gerenciada $IDENTITY"
az identity create -n "$IDENTITY" -g "$RG" -l "$LOC" -o none
CLIENT_ID=$(az identity show -n "$IDENTITY" -g "$RG" --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show -n "$IDENTITY" -g "$RG" --query principalId -o tsv)
RG_ID=$(az group show -n "$RG" --query id -o tsv)

echo "== Papel Contributor no resource group (tenta de novo se a identidade ainda não propagou)"
for i in 1 2 3 4 5 6; do
  if az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
       --assignee-principal-type ServicePrincipal --role Contributor \
       --scope "$RG_ID" -o none 2>/tmp/role.err; then break; fi
  if grep -q "RoleAssignmentExists" /tmp/role.err; then break; fi
  echo "   aguardando propagação... ($i)"; sleep 15
done

# O GitHub passou a mandar o subject com os IDs numéricos do dono e do repo
# (repo:dono@ID/repo@ID:environment:...). Cadastramos os dois formatos.
GH_IDS=$(curl -s https://api.github.com/repos/gvitto-ab/mlops-2026-2 | jq -r '"\(.owner.id) \(.id)"')
GH_SUBJECT_IDS="repo:gvitto-ab@${GH_IDS% *}/mlops-2026-2@${GH_IDS#* }:environment:production"
for par in "github-production|$GH_SUBJECT" "github-production-ids|$GH_SUBJECT_IDS"; do
  nome=${par%%|*}; subj=${par#*|}
  echo "== Credencial federada $nome ($subj)"
  if az identity federated-credential show --name "$nome" \
       --identity-name "$IDENTITY" -g "$RG" -o none 2>/dev/null; then
    echo "   já existe"
  else
    az identity federated-credential create --name "$nome" \
      --identity-name "$IDENTITY" -g "$RG" \
      --issuer https://token.actions.githubusercontent.com \
      --subject "$subj" \
      --audiences api://AzureADTokenExchange -o none
  fi
done

cat <<EOF

===============================================================
PRONTO. Copie estes valores (não são senhas):

AZURE_CLIENT_ID       = $CLIENT_ID
AZURE_TENANT_ID       = $(az account show --query tenantId -o tsv)
AZURE_SUBSCRIPTION_ID = $(az account show --query id -o tsv)
APP_URL               = https://$FQDN
===============================================================
Abra a APP_URL daqui a alguns minutos (o app carrega o modelo na
primeira subida): deve aparecer {"status":"ok","version":"v1.0.0"}
EOF
