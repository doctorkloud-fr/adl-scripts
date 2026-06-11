#!/bin/bash
# =============================================================================
# Déploiement automatisé AGW WAF_v2 HTTPS — A2i Technologies
# Doctor Kloud Labs — Section 2 (scripting)
# =============================================================================

# === Variables ===
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
DOMAIN="shop.a2itechnologies.fr"
CERT_PASS="A2iLab2024!"
WAF_POLICY_NAME="wafpol-a2i-agw-cli"
VNET_CLI="vnet-a2i-agw-cli-westeu"
SNET_AGW_CLI="snet-agw-cli"
SNET_BE_CLI="snet-backend-cli"
PIP_CLI="pip-a2i-agw-cli"
AGW_CLI="agw-a2i-web-cli-westeu"
APP_PLAN_CLI="plan-a2i-cli-$(az account show --query id -o tsv | cut -c1-8)"
WEBAPP_CLI="webapp-a2i-cli-$(az account show --query id -o tsv | cut -c1-8)"

echo "=== Deploiement AGW WAF_v2 HTTPS A2i Technologies ==="
echo "RG : $RG"

# Fonction d'attente : bloque jusqu'à ce que l'AGW soit en état Succeeded
wait_agw() {
  while true; do
    S=$(az network application-gateway show --resource-group $RG --name $AGW_CLI --query provisioningState -o tsv 2>/dev/null)
    echo "$(date '+%H:%M:%S') - ${S:-En attente...}"
    [ "$S" = "Succeeded" ] && break
    [ "$S" = "Failed" ] && echo "ERREUR deploiement" && exit 1
    sleep 15
  done
}

# === Certificat SSL auto-signé ===
openssl req -x509 -newkey rsa:2048 -keyout shop-key.pem -out shop-cert.pem -days 365 -nodes -subj "/CN=shop.a2itechnologies.fr/O=A2i Technologies/C=FR"
openssl pkcs12 -export -out shop-cert.pfx -inkey shop-key.pem -in shop-cert.pem -passout pass:$CERT_PASS
echo "Certificat PFX cree !"

# === WAF Policy ===
az network application-gateway waf-policy create --resource-group $RG --name $WAF_POLICY_NAME --location $LOCATION
WAF_ID=$(az network application-gateway waf-policy show --resource-group $RG --name $WAF_POLICY_NAME --query id -o tsv)

# === VNet + Subnets ===
az network vnet create --resource-group $RG --name $VNET_CLI --address-prefix 10.41.0.0/16 --subnet-name $SNET_AGW_CLI --subnet-prefix 10.41.0.0/24
az network vnet subnet create --resource-group $RG --vnet-name $VNET_CLI --name $SNET_BE_CLI --address-prefix 10.41.10.0/26

# === IP Publique ===
az network public-ip create --resource-group $RG --name $PIP_CLI --sku Standard --allocation-method Static

# === App Service F1 Linux ===
az appservice plan create --resource-group $RG --name $APP_PLAN_CLI --sku F1 --is-linux --location $LOCATION
az webapp create --resource-group $RG --plan $APP_PLAN_CLI --name $WEBAPP_CLI --runtime "NODE:22-lts"
WEBAPP_URL=$(az webapp show --resource-group $RG --name $WEBAPP_CLI --query defaultHostName -o tsv)
echo "WebApp URL : $WEBAPP_URL"

# === AGW WAF_v2 (sans --servers, WAF liee directement) ===
az network application-gateway create --resource-group $RG --name $AGW_CLI --location $LOCATION --vnet-name $VNET_CLI --subnet $SNET_AGW_CLI --sku WAF_v2 --public-ip-address $PIP_CLI --priority 100 --min-capacity 2 --max-capacity 10 --frontend-port 80 --http-settings-port 80 --http-settings-protocol Http --waf-policy $WAF_ID --no-wait
echo "AGW WAF_v2 lancee..."
wait_agw

# === SSL Cert upload ===
az network application-gateway ssl-cert create --resource-group $RG --gateway-name $AGW_CLI --name ssl-shop-a2i --cert-file shop-cert.pfx --cert-password $CERT_PASS --no-wait
wait_agw

# === Port 443 ===
az network application-gateway frontend-port create --resource-group $RG --gateway-name $AGW_CLI --name port-https --port 443 --no-wait
wait_agw

# === Health Probe ===
az network application-gateway probe create --resource-group $RG --gateway-name $AGW_CLI --name probe-shop --protocol Http --host-name-from-http-settings true --path "/" --interval 30 --timeout 30 --threshold 3 --no-wait
wait_agw

# === Backend Settings avec probe ===
az network application-gateway http-settings create --resource-group $RG --gateway-name $AGW_CLI --name bs-default-http --port 80 --protocol Http --host-name-from-backend-pool true --timeout 30 --probe probe-shop --no-wait
wait_agw

# === Backend Pool ===
az network application-gateway address-pool create --resource-group $RG --gateway-name $AGW_CLI --name bp-app-service-web --servers $WEBAPP_URL --no-wait
wait_agw

# === Listener HTTPS ===
az network application-gateway http-listener create --resource-group $RG --gateway-name $AGW_CLI --name lst-https-shop --frontend-port port-https --frontend-ip appGatewayFrontendIP --ssl-cert ssl-shop-a2i --host-name $DOMAIN --no-wait
wait_agw

# === Routing Rule HTTPS ===
az network application-gateway rule create --resource-group $RG --gateway-name $AGW_CLI --name rl-route-shop --priority 200 --http-listener lst-https-shop --address-pool bp-app-service-web --http-settings bs-default-http --no-wait
wait_agw

# === Host Header fix ===
az network application-gateway http-settings update --resource-group $RG --gateway-name $AGW_CLI --name appGatewayBackendHttpSettings --host-name-from-backend-pool true --no-wait
wait_agw

# === Test HTTPS ===
IP_CLI=$(az network public-ip show --resource-group $RG --name $PIP_CLI --query ipAddress -o tsv)
echo "=== Deploiement termine ==="
echo "IP AGW : $IP_CLI"
HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --resolve $DOMAIN:443:$IP_CLI https://$DOMAIN/)
echo "HTTPS Code : $HTTP_CODE"
