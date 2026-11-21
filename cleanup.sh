#!/usr/bin/env bash
# ================================================================
# cleanup.sh — opérations de maintenance sur le conteneur de l'agent.
#
# Usage :
#   ./cleanup.sh --status             # état, IP, snapshots (défaut)
#   ./cleanup.sh --restore <snap>     # restaure un snapshot
#   ./cleanup.sh --shell              # shell dans le conteneur (user operator)
#   ./cleanup.sh --destroy            # supprime définitivement le conteneur
#   ./cleanup.sh --recreate           # destroy + init complet
#   ./cleanup.sh --config <fichier>   # autre fichier de config
# ================================================================
set -euo pipefail

# --- Résolution du fichier de config : --config > ./config.yaml > XDG ---
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pentest/config.yaml"
MODE=""
SNAP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --status)   MODE="status"; shift ;;
    --restore)  MODE="restore"; SNAP="$2"; shift 2 ;;
    --shell)    MODE="shell"; shift ;;
    --destroy)  MODE="destroy"; shift ;;
    --recreate) MODE="recreate"; shift ;;
    *) echo "Option inconnue : $1" >&2; exit 1 ;;
  esac
done
[ -f "./config.yaml" ] && CONFIG_FILE="./config.yaml"
[ -n "$MODE" ] || MODE="status"

# --- Lecture d'une clé plate du YAML (sed + nettoyage des quotes) ---
cfg() {
  [ -f "$CONFIG_FILE" ] || { echo ""; return; }
  local val
  val=$(sed -n "s/^${1}:[[:space:]]*//p" "$CONFIG_FILE" | head -1)
  # retire les quotes éventuelles autour de la valeur
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  echo "$val"
}

CONTAINER=$(cfg container); [ -n "$CONTAINER" ] || CONTAINER="pentest-agent"

case "$MODE" in
  status)
    echo "== Conteneur : $CONTAINER (config : $CONFIG_FILE) =="
    incus info "$CONTAINER" 2>/dev/null | head -20 || true
    incus list "$CONTAINER" 2>/dev/null || echo "  (conteneur introuvable)"
    echo "== Snapshots =="
    incus snapshot list "$CONTAINER" 2>/dev/null || echo "  (aucun)"
    ;;

  restore)
    [ -n "$SNAP" ] || { echo "Usage : $0 --restore <nom-du-snapshot>"; exit 1; }
    echo "== Restauration de $CONTAINER sur le snapshot '$SNAP' =="
    incus snapshot restore "$CONTAINER" "$SNAP"
    echo "== Conteneur remis au snapshot '$SNAP' =="
    ;;

  shell)
    incus exec "$CONTAINER" -- sudo -u operator bash -c 'cd /app && exec bash'
    ;;

  destroy)
    echo "!! Suppression DEFINITIVE de $CONTAINER (rapports et snapshots inclus) !!"
    read -p "Tape le nom exact du conteneur pour confirmer : " CONFIRM
    [ "$CONFIRM" = "$CONTAINER" ] || { echo "Confirmation echouee, abandon."; exit 1; }
    incus delete --force "$CONTAINER"
    echo "== $CONTAINER supprime =="
    ;;

  recreate)
    echo "== Recreation complete =="
    DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "-- Phase 1 : destroy (si le conteneur existe) --"
    if incus info "$CONTAINER" >/dev/null 2>&1; then
      bash "$DIR/cleanup.sh" --config "$CONFIG_FILE" \
        <<< "$CONTAINER" 2>/dev/null \
        || { echo "Le destroy demande une confirmation tapee. Fais-le manuellement :"; \
             echo "  ./cleanup.sh --destroy"; exit 1; }
    else
      echo "  (aucun conteneur a supprimer)"
    fi
    echo "-- Phase 2 : init --"
    bash "$DIR/init-container.sh" --config "$CONFIG_FILE"
    ;;

  *)
    echo "Mode inconnu : $MODE" >&2; exit 1 ;;
esac
