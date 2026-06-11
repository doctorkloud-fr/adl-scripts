#!/usr/bin/env bash
# =============================================================================
#  waf-gateway-cli.sh — Application Gateway WAF_v2 pour le lab WAF guidé
#  Crée l'AGW WAF_v2 qui RÉFÉRENCE la WAF Policy que VOUS avez créée
#  à l'étape précédente (wafpol-a2i-shop). Prérequis : waf-infra-cli.sh
#  exécuté + WAF Policy créée. Opération longue : --no-wait + wait_agw().
# =============================================================================
set -euo pipefail

# Détection robuste du Resource Group :
# 'az group list' interroge Azure directement (marche dans le terminal ACI,
# le Cloud Shell natif, ou une ACI recyclée), contrairement à
# 'az configure --list-defaults' qui dépend d'une config locale parfois absente.
RG=$(az group list --query "[?starts_with(name,'rg-adl-cohort')].name | [0]" -o tsv)
if [ -z "$RG" ]; then
  RG=$(az group list --query "[0].name" -o tsv)
fi
if [ -z "$RG" ]; then
  echo "ERREUR : Resource Group introuvable (aucun RG visible). Abandon."
  exit 1
fi

LOCATION="westeurope"
VNET="vnet-a2i-waf-westeu"
SUBNET_AGW="snet-agw"
PIP="pip-a2i-waf"
WAF_POLICY="wafpol-a2i-shop"
AGW="agw-a2i-shop-prod"
SUB8=$(az account show --query id -o tsv | cut -c1-8)
WEBAPP="webapp-a2i-waf-$SUB8"

# ---- Prérequis : la WAF Policy doit exister (créée par l'apprenant) --------
WAF_ID=$(az network application-gateway waf-policy show -g "$RG" -n "$WAF_POLICY" \
          --query id -o tsv 2>/dev/null || true)
if [ -z "$WAF_ID" ]; then
  echo "ERREUR : WAF Policy '$WAF_POLICY' introuvable."
  echo "Créez-la d'abord (étape « Créer la WAF Policy »), puis relancez ce script."
  exit 1
fi

WEBAPP_URL=$(az webapp show -g "$RG" -n "$WEBAPP" --query defaultHostName -o tsv 2>/dev/null || true)
if [ -z "$WEBAPP_URL" ]; then
  echo "ERREUR : App Service introuvable. Lancez waf-infra-cli.sh d'abord."
  exit 1
fi

echo "============================================================"
echo " WAF Policy référencée : $WAF_ID"
echo " Backend               : $WEBAPP_URL"
echo "============================================================"

# ---- wait_agw : poll l'état (les ops AGW > 30 s cassent l'ACI en direct) ---
wait_agw () {
  local STATUS=""
  while true; do
    STATUS=$(az network application-gateway show -g "$RG" -n "$AGW" \
              --query provisioningState -o tsv 2>/dev/null || true)
    echo "  $(date '+%H:%M:%S') - ${STATUS:-...}"
    [ "$STATUS" = "Succeeded" ] && break
    [ "$STATUS" = "Failed" ] && { echo "ERREUR : provisioning AGW Failed"; exit 1; }
    sleep 20
  done
}

# ---- AGW WAF_v2 liée à la WAF Policy (12-18 min) ---------------------------
echo ">> [1/2] Application Gateway WAF_v2 (référence la WAF Policy)"
az network application-gateway create -g "$RG" -n "$AGW" -l "$LOCATION" \
  --sku WAF_v2 --public-ip-address "$PIP" --vnet-name "$VNET" --subnet "$SUBNET_AGW" \
  --min-capacity 1 --max-capacity 2 \
  --frontend-port 80 --http-settings-port 80 --http-settings-protocol Http \
  --servers "$WEBAPP_URL" --priority 100 --waf-policy "$WAF_ID" --no-wait
echo "   AGW lancée, attente Succeeded..."
wait_agw

# ---- Sonde de santé + host header (backend App Service) --------------------
echo ">> [2/2] Sonde de santé + host header"
az network application-gateway probe create -g "$RG" --gateway-name "$AGW" \
  -n probe-shop --protocol Http --host-name-from-http-settings true --path "/" \
  --interval 30 --timeout 30 --threshold 3 --no-wait
wait_agw

az network application-gateway http-settings update -g "$RG" --gateway-name "$AGW" \
  -n appGatewayBackendHttpSettings --host-name-from-backend-pool true \
  --probe probe-shop --no-wait
wait_agw

AGW_IP=$(az network public-ip show -g "$RG" -n "$PIP" --query ipAddress -o tsv)
echo "============================================================"
echo " AGW WAF_v2 prête. IP : $AGW_IP"
echo " Le WAF est en Detection (hérité de VOTRE WAF Policy)."
echo " Test : curl -k -s -o /dev/null -w '%{http_code}\\n' \\"
echo "          --resolve shop.a2itechnologies.fr:80:$AGW_IP \\"
echo "          http://shop.a2itechnologies.fr/"
