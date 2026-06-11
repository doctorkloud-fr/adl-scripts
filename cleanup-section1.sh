#!/bin/bash
# ===================================================================
# A2i Technologies — Nettoyage Section 1 (lab AGW guidé)
# Supprime TOUTES les ressources créées en CLI, dans le bon ordre
# de dépendances. Le Resource Group est CONSERVÉ.
# Usage : curl -fsSL <url>/cleanup-section1.sh -o cleanup-section1.sh && bash cleanup-section1.sh
# ===================================================================
set -uo pipefail

# --- Détection robuste du Resource Group ---
# On n'utilise PAS 'az configure --list-defaults' : il dépend d'une config
# locale (~/.azure/config) absente du Cloud Shell natif ou d'une ACI recyclée.
# 'az group list' interroge Azure directement : marche dans tous les contextes.
# On cible spécifiquement le RG cohorte de l'étudiant et on prend le premier.
RG=$(az group list --query "[?starts_with(name,'rg-adl-cohort')].name | [0]" -o tsv)
# Repli : si aucun RG cohorte trouvé, prendre le premier RG visible.
if [ -z "$RG" ]; then
  RG=$(az group list --query "[0].name" -o tsv)
fi

if [ -z "$RG" ]; then
  echo "ERREUR : Resource Group introuvable (aucun RG visible). Abandon."
  exit 1
fi

echo "=== Nettoyage Section 1 — RG : $RG ==="
echo ""

# Variables de ressources (Section 1 CLI)
WAF_POLICY_NAME="wafpol-a2i-agw"
VNET_NAME="vnet-a2i-prod"
PIP_NAME="pip-a2i-agw"
AGW_NAME="agw-a2i-prod"
SUB8=$(az account show --query id -o tsv | cut -c1-8)
APP_PLAN="plan-a2i-$SUB8"
WEBAPP_NAME="webapp-a2i-$SUB8"

# 1. Application Gateway EN PREMIER (elle référence PIP, VNet et WAF Policy)
echo "[1/6] Suppression Application Gateway (étape bloquante, ~2-3 min)..."
az network application-gateway delete --resource-group "$RG" --name "$AGW_NAME" 2>/dev/null \
  && echo "      AGW supprimée" || echo "      AGW déjà absente"

# 2. WAF Policy — supprimable une fois l'AGW partie.
#    On supprime TOUTE WAF Policy wafpol-a2i-* présente (couvre wafpol-a2i-agw
#    ET les variantes comme wafpol-a2i-agw-challenge), car une WAF Policy
#    orpheline non référencée doit être nettoyée.
echo "[2/6] Suppression WAF Policy/Policies (wafpol-a2i-*)..."
WAF_POLICIES=$(az network application-gateway waf-policy list --resource-group "$RG" \
  --query "[?starts_with(name,'wafpol-a2i-')].name" -o tsv 2>/dev/null)
if [ -n "$WAF_POLICIES" ]; then
  while IFS= read -r POL; do
    [ -z "$POL" ] && continue
    az network application-gateway waf-policy delete --resource-group "$RG" --name "$POL" 2>/dev/null \
      && echo "      WAF Policy supprimée : $POL" || echo "      WAF Policy non supprimée : $POL"
  done <<< "$WAF_POLICIES"
else
  echo "      Aucune WAF Policy wafpol-a2i-* — déjà propre"
fi

# 3. IP publique
echo "[3/6] Suppression IP publique..."
az network public-ip delete --resource-group "$RG" --name "$PIP_NAME" 2>/dev/null \
  && echo "      IP publique supprimée" || echo "      IP publique déjà absente"

# 4. VNet
echo "[4/6] Suppression VNet..."
az network vnet delete --resource-group "$RG" --name "$VNET_NAME" 2>/dev/null \
  && echo "      VNet supprimé" || echo "      VNet déjà absent"

# 5. Web App
echo "[5/6] Suppression Web App..."
az webapp delete --resource-group "$RG" --name "$WEBAPP_NAME" 2>/dev/null \
  && echo "      Web App supprimée" || echo "      Web App déjà absente"

# 6. App Service Plan (ne se supprime qu'une fois vide)
echo "[6/6] Suppression App Service Plan..."
az appservice plan delete --resource-group "$RG" --name "$APP_PLAN" --yes 2>/dev/null \
  && echo "      App Service Plan supprimé" || echo "      App Service Plan déjà absent"

echo ""
echo "=== Nettoyage terminé — le Resource Group est conservé ==="
echo "Ressources restantes dans $RG :"
az resource list --resource-group "$RG" --output table
