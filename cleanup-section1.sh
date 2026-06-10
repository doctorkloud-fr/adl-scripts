#!/bin/bash
# ===================================================================
# A2i Technologies — Nettoyage Section 1 (lab AGW guidé)
# Supprime TOUTES les ressources créées en CLI, dans le bon ordre
# de dépendances. Le Resource Group est CONSERVÉ.
# Usage : curl -fsSL <url>/cleanup-section1.sh | bash
# ===================================================================
set -uo pipefail

# --- Redéfinition des variables (le script est autonome) ---
RG=$(az configure --list-defaults --query "[?name=='group'].value" -o tsv)
WAF_POLICY_NAME="wafpol-a2i-agw"
VNET_NAME="vnet-a2i-prod"
PIP_NAME="pip-a2i-agw"
AGW_NAME="agw-a2i-prod"
SUB8=$(az account show --query id -o tsv | cut -c1-8)
APP_PLAN="plan-a2i-$SUB8"
WEBAPP_NAME="webapp-a2i-$SUB8"

if [ -z "$RG" ]; then
  echo "ERREUR : Resource Group introuvable (variable RG vide). Abandon."
  exit 1
fi

echo "=== Nettoyage Section 1 — RG : $RG ==="
echo ""

echo "[1/6] Suppression Application Gateway (étape bloquante, ~2-3 min)..."
az network application-gateway delete --resource-group "$RG" --name "$AGW_NAME" 2>/dev/null \
  && echo "      AGW supprimée" || echo "      AGW déjà absente"

echo "[2/6] Suppression WAF Policy..."
az network application-gateway waf-policy delete --resource-group "$RG" --name "$WAF_POLICY_NAME" 2>/dev/null \
  && echo "      WAF Policy supprimée" || echo "      WAF Policy déjà absente"

echo "[3/6] Suppression IP publique..."
az network public-ip delete --resource-group "$RG" --name "$PIP_NAME" 2>/dev/null \
  && echo "      IP publique supprimée" || echo "      IP publique déjà absente"

echo "[4/6] Suppression VNet..."
az network vnet delete --resource-group "$RG" --name "$VNET_NAME" 2>/dev/null \
  && echo "      VNet supprimé" || echo "      VNet déjà absent"

echo "[5/6] Suppression Web App..."
az webapp delete --resource-group "$RG" --name "$WEBAPP_NAME" 2>/dev/null \
  && echo "      Web App supprimée" || echo "      Web App déjà absente"

echo "[6/6] Suppression App Service Plan..."
az appservice plan delete --resource-group "$RG" --name "$APP_PLAN" --yes 2>/dev/null \
  && echo "      App Service Plan supprimé" || echo "      App Service Plan déjà absent"

echo ""
echo "=== Nettoyage terminé — le Resource Group est conservé ==="
echo "Ressources restantes dans $RG :"
az resource list --resource-group "$RG" --output table
