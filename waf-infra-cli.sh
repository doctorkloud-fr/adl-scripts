#!/usr/bin/env bash
# =============================================================================
#  waf-infra-cli.sh — Plomberie pour le lab WAF guidé (azure-waf-guided-02)
#  Déploie UNIQUEMENT : VNet + subnets + IP publique + App Service F1 (shop).
#  PAS de WAF, PAS d'Application Gateway : c'est l'apprenant qui créera
#  la WAF Policy à la main, puis l'AGW WAF_v2 (waf-gateway-cli.sh).
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
SUBNET_APP="snet-app"
PIP="pip-a2i-waf"
SUB8=$(az account show --query id -o tsv | cut -c1-8)
APP_PLAN="plan-a2i-waf-$SUB8"
WEBAPP="webapp-a2i-waf-$SUB8"

echo "============================================================"
echo " RG=$RG | WEBAPP=$WEBAPP"
echo " Plomberie : réseau + App Service (ni WAF, ni AGW)"
echo "============================================================"

# ---- 1. Réseau --------------------------------------------------------------
echo ">> [1/2] Réseau (VNet + subnets + IP publique)"
az network vnet create -g "$RG" -n "$VNET" --address-prefix 10.40.0.0/16 \
  -l "$LOCATION" --subnet-name "$SUBNET_AGW" --subnet-prefix 10.40.0.0/24 -o none
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$SUBNET_APP" \
  --address-prefix 10.40.10.0/26 -o none
az network public-ip create -g "$RG" -n "$PIP" --sku Standard \
  --allocation-method Static -l "$LOCATION" -o none
echo "   Réseau OK (subnet AGW $SUBNET_AGW réservé pour la future passerelle)"

# ---- 2. Backend App Service (F1) + boutique shop ---------------------------
echo ">> [2/2] App Service F1 + déploiement de la boutique"
RUNTIME=$(az webapp list-runtimes --os-type linux -o tsv 2>/dev/null \
            | grep -i '^NODE:' | head -1 || true)
[ -z "$RUNTIME" ] && RUNTIME="NODE:22-lts"
echo "   Runtime : $RUNTIME"
az appservice plan create -g "$RG" -n "$APP_PLAN" --sku F1 --is-linux \
  -l "$LOCATION" -o none
az webapp create -g "$RG" --plan "$APP_PLAN" -n "$WEBAPP" --runtime "$RUNTIME" -o none
WEBAPP_URL=$(az webapp show -g "$RG" -n "$WEBAPP" --query defaultHostName -o tsv)
[ -n "$WEBAPP_URL" ] || { echo "ERREUR : WEBAPP_URL vide"; exit 1; }
mkdir -p ~/site-shop && cd ~/site-shop
curl -fsSL https://raw.githubusercontent.com/doctorkloud-fr/adl-scripts/main/shop-index.html -o index.html
python3 -c "import zipfile; zipfile.ZipFile('site.zip','w').write('index.html')"
az webapp deploy -g "$RG" -n "$WEBAPP" --src-path site.zip --type zip -o none
az webapp config set -g "$RG" -n "$WEBAPP" \
  --startup-file "pm2 serve /home/site/wwwroot --no-daemon --spa" -o none
az webapp restart -g "$RG" -n "$WEBAPP" -o none
cd ~
echo "============================================================"
echo " Plomberie prête. Backend : https://$WEBAPP_URL"
echo " Prochaine étape : créer VOUS-MÊME la WAF Policy (à la main),"
echo " puis lancer waf-gateway-cli.sh pour l'Application Gateway."
echo "============================================================"
