#!/usr/bin/env bash
# =============================================================================
#  waf-attacks.sh — Batterie d'attaques contrôlées (chapitre 9, Étape 12)
#  Envoie 5 attaques + 1 requête légitime vers le shop A2i et affiche les
#  codes HTTP. En Detection : tout en 200. En Prevention : attaques en 403.
#  Payloads URL-encodés pour que curl ne rejette pas l'URL ; le WAF les
#  décode et matche les règles DRS quand même.
# =============================================================================

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

PIP="pip-a2i-waf"
DOMAIN="shop.a2itechnologies.fr"
IP=$(az network public-ip show -g "$RG" -n "$PIP" --query ipAddress -o tsv 2>/dev/null)
if [ -z "$IP" ]; then
  echo "IP de l'AGW introuvable. La plateforme est-elle déployée (waf-base-cli.sh) ?"
  exit 1
fi

# Mode courant de la WAF Policy (pour rappel à l'écran)
MODE=$(az network application-gateway waf-policy show -g "$RG" -n wafpol-a2i-shop \
        --query "policySettings.mode" -o tsv 2>/dev/null || echo "?")

echo "============================================================"
echo " Cible   : http://$DOMAIN  ($IP)"
echo " WAF mode : $MODE"
echo "============================================================"

probe () {
  local label="$1"; local path="$2"
  local code
  code=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 15 \
           --resolve "$DOMAIN:80:$IP" "http://$DOMAIN$path")
  printf "  %-26s -> HTTP %s\n" "$label" "$code"
}

probe "Trafic légitime"        "/"
probe "SQLi (tautologie)"      "/api/v1/products?id=1'%20OR%20'1'='1"
probe "SQLi (UNION SELECT)"    "/api/v1/products?id=1%20UNION%20SELECT%20password%20FROM%20users"
probe "XSS"                    "/contact?msg=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
probe "Path traversal"         "/api/v1/files?path=..%2F..%2F..%2F..%2Fetc%2Fpasswd"
probe "Command injection"      "/api/v1/render?cmd=test%3Bcat%20%2Fetc%2Fpasswd"

echo "------------------------------------------------------------"
echo " Detection  : trafic légitime ET attaques en 200 (tracées)."
echo " Prevention : trafic légitime en 200, attaques en 403 (bloquées)."
echo "============================================================"
