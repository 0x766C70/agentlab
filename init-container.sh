#!/usr/bin/env bash
# ================================================================
# init-container.sh — provisionne le conteneur Incus hôte de l'agent.
# Idempotent et reprenable : chaque étape se relance sans casser.
#
# Configuration : ~/.config/pentest/config.yaml (ou ./config.yaml,
# ou --config <chemin>). Voir config.yaml.example dans le repo.
# ================================================================
set -euo pipefail

# --- Résolution du fichier de config : --config > ./config.yaml > XDG ---
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pentest/config.yaml"
if [ "${1:-}" = "--config" ]; then CONFIG_FILE="$2"; shift 2; fi
[ -f "./config.yaml" ] && CONFIG_FILE="./config.yaml"
[ -f "$CONFIG_FILE" ] || {
  echo "ERREUR : config introuvable ($CONFIG_FILE)."
  echo "Copie config.yaml.example vers ce chemin et adapte tes valeurs." >&2
  exit 1
}

cfg() {  # lecture d'une clé plate du YAML : sed + nettoyage des quotes
  local val
  val=$(sed -n "s/^${1}:[[:space:]]*//p" "$CONFIG_FILE" | head -1)
  val="${val#\"}"; val="${val%\"}"
  val="${val#\'}"; val="${val%\'}"
  echo "$val"
}

CONTAINER=$(cfg container); [ -n "$CONTAINER" ] || CONTAINER="pentest-agent"
BRIDGE=$(cfg bridge);        [ -n "$BRIDGE" ] || BRIDGE="incusbr1"
GATEWAY=$(cfg gateway);      [ -n "$GATEWAY" ] || GATEWAY="192.168.101.1"
DNS=$(cfg dns);              [ -n "$DNS" ] || DNS="9.9.9.9"
OS_IMAGE=$(cfg image);       [ -n "$OS_IMAGE" ] || OS_IMAGE="images:debian/12"
PROJECT_DIR=$(cfg project_dir); [ -n "$PROJECT_DIR" ] || PROJECT_DIR="."
MISTRAL_MODEL=$(cfg mistral_model); [ -n "$MISTRAL_MODEL" ] || MISTRAL_MODEL="mistral-large-latest"

step() { echo; echo "== $1 =="; }
die()  { echo "ERREUR : $1" >&2; exit 1; }

echo "Config : $CONFIG_FILE (conteneur=$CONTAINER, bridge=$BRIDGE)"

# ----------------------------------------------------------------
step "[ETAPE A] Conteneur : creation si absent"
# ----------------------------------------------------------------
if incus info "$CONTAINER" >/dev/null 2>&1; then
  echo "  $CONTAINER existe deja, on le reutilise."
else
  incus init "$OS_IMAGE" "$CONTAINER"
fi

# Device eth0 : recree proprement, attaché au bridge, DHCP
if incus config device get "$CONTAINER" eth0 parent >/dev/null 2>&1 || \
   incus config device show "$CONTAINER" | grep -q eth0; then
  incus config device remove "$CONTAINER" eth0 || true
fi
incus config device add "$CONTAINER" eth0 nic \
  nictype=bridged parent="$BRIDGE" name=eth0
echo "  eth0 attache a $BRIDGE (DHCP)."

incus start "$CONTAINER" 2>/dev/null || echo "  (deja demarre)"
sleep 8

# ----------------------------------------------------------------
step "[ETAPE B] Reseau : DHCP + verification"
# ----------------------------------------------------------------
CUR_IP=""
for i in 1 2 3; do
  CUR_IP=$(incus exec "$CONTAINER" -- bash -c \
    "ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet )[\d.]+'" | tr -d '\r') || true
  [ -n "$CUR_IP" ] && break
  incus exec "$CONTAINER" -- dhclient eth0 2>/dev/null || true
done
[ -n "$CUR_IP" ] || die "aucune IP obtenue sur $BRIDGE (DHCP muet ?)"
echo "  IP obtenue via DHCP : $CUR_IP"

incus exec "$CONTAINER" -- bash -c "
  # DNS du bridge (dnsmasq d Incus, IP = gateway) par defaut ;
  # le dns: de la config ne sert que si on veut FORCER un resolver externe.
  if [ -n \"$(cfg dns)\" ]; then echo 'nameserver $DNS' > /etc/resolv.conf;
  else echo 'nameserver $GATEWAY' > /etc/resolv.conf; fi
  ping -c 2 -W 3 $GATEWAY >/dev/null || { echo 'ERREUR : gateway $GATEWAY injoignable.'; exit 1; }
  ping -c 2 -W 3 9.9.9.9   >/dev/null || { echo 'ERREUR : sortie Internet KO. Verifie ipv4.nat sur le bridge.'; exit 1; }
  # Validation du DNS AVANT l apt (sinon apt bloque sans message)
  if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo 'ERREUR : resolution DNS KO (resolver joignable mais muet ?).'; exit 1
  fi
" || die "reseau du conteneur injoignable (voir messages ci-dessus)"
echo "  Reseau OK : gateway + Internet + DNS."

# ----------------------------------------------------------------
step "[ETAPE C] Outils de recon"
# ----------------------------------------------------------------
incus exec "$CONTAINER" -- bash -c '
  apt-get update -qq &&
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    python3 python3-pip python3-venv python3-yaml nmap curl whois dnsutils netcat-openbsd &&
  apt-get clean
' || die "apt a echoue dans le conteneur"
echo "  Outils installes (nmap, curl, dig...)"

# ----------------------------------------------------------------
step "[ETAPE D] Utilisateur operator + /app"
# ----------------------------------------------------------------
incus exec "$CONTAINER" -- bash -c '
  if ! getent passwd operator >/dev/null; then
    if getent group operator >/dev/null; then
      useradd -m -s /bin/bash -g operator operator
    else
      useradd -m -s /bin/bash operator
    fi
  fi
  mkdir -p /app/reports /app/logs
  chown -R operator:operator /app
'
echo "  Utilisateur operator + /app prets."

# ----------------------------------------------------------------
step "[ETAPE E] Code du projet : generation si absent"
# ----------------------------------------------------------------
if [ -f "$PROJECT_DIR/src/agent.py" ]; then
  echo "  Code existant conserve (supprime src/ pour regenerer)."
else
  mkdir -p "$PROJECT_DIR"/{src/tools,config,reports,logs}

  cat > "$PROJECT_DIR"/config/targets.yaml.example <<'EOF'
# Copie ce fichier en config/targets.yaml et liste TES cibles autorisees.
# L'agent refusera toute cible absente de cette liste.
# N engage de pentest que sur des infrastructures qui t appartiennent
# ou avec autorisation ecrite.
authorized_targets:
  - name: "Exemple : mon serveur (ma propriete)"
    host: exemple.mondomaine.tld

agent:
  max_steps: 15     # budget max d actions par mission
  dry_run: true     # true = chaque commande attend l approbation (y/N)
  web_port: 8080    # port de l UI web dans le conteneur
EOF

  cat > "$PROJECT_DIR"/requirements.txt <<'EOF'
mistralai>=1.0.0,<2.0.0
pyyaml>=6.0
flask>=3.0
EOF

  echo "  (Le README du projet est fourni a part : README.md, script 4)"

  cat > "$PROJECT_DIR"/src/agent.py <<'EOF'
"""
Agent de pentest : boucle ReAct.
Objective cible -> le LLM choisit un outil -> execution -> observation -> boucle.
En dry_run, chaque commande attend la confirmation (y/N).
"""
import os, json, yaml
from mistralai import Mistral
from src.tools.base import ToolRegistry

MODEL = os.environ.get("MISTRAL_MODEL", "mistral-large-latest")

def load_config():
    with open("config/targets.yaml") as f:
        return yaml.safe_load(f)

def run_mission(objective: str, approve=None):
    config = load_config()
    registry = ToolRegistry(config)
    if approve is not None:
        registry.approve = approve
    client = Mistral(api_key=os.environ["MISTRAL_API_KEY"])
    tools = registry.to_mistral_tools()

    system = (
        "Tu es un agent de pentest offensif, autorise UNIQUEMENT sur les cibles "
        "de la whitelist fournie. Tu procedes methodiquement (recon d abord). "
        "Quand ta mission est accomplie, appelle submit_report avec un resume Markdown."
    )
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": objective},
    ]
    trace = []

    for step in range(config["agent"]["max_steps"]):
        resp = client.chat.complete(
            model=MODEL, messages=messages,
            tools=tools, tool_choice="auto",
        )
        msg = resp.choices[0].message

        # content peut etre une liste de fragments (ThinkChunk/ContentChunk)
        def _txt(content):
            if isinstance(content, str):
                return content
            if isinstance(content, list):
                # on ne garde que le texte, le raisonnement (ThinkChunk) est ecarte
                return "".join(getattr(c, "text", "") or "" for c in content)
            return str(content or "")

        if not msg.tool_calls:
            trace.append({"step": step+1, "type": "final", "text": _txt(msg.content)})
            break

        messages.append(msg)
        for call in msg.tool_calls:
            args = json.loads(call.function.arguments)
            trace.append({"step": step+1, "type": "action",
                          "tool": call.function.name, "args": args})
            try:
                result = registry.execute(call.function.name, args)
            except Exception as e:
                result = f"ERREUR: {e}"
            trace[-1]["result"] = str(result)[:500]
            messages.append({
                "role": "tool",
                "tool_call_id": call.id,
                "content": str(result),
            })

    for t in trace:
        print(json.dumps(t, ensure_ascii=False, default=str))
    return trace

if __name__ == "__main__":
    target = os.environ.get("TARGET", "")
    mission = os.environ.get("MISSION") or (
        f"Reconnaissance complete de {target} : DNS, ports ouverts, services "
        "et versions, puis un rapport Markdown des surfaces d attaque."
        if target else "Aucune cible fournie (TARGET).")
    run_mission(mission)
EOF

  cat > "$PROJECT_DIR"/src/tools/base.py <<'EOF'
"""
Le garde-fou : TOUTE action passe par ici.
1. La cible doit etre dans la whitelist (pas d exception).
2. En dry_run, chaque commande attend une approbation.
"""
import subprocess

class NotAuthorizedError(Exception): pass

class Tool:
    def __init__(self, name, description, parameters, handler):
        self.name, self.description = name, description
        self.parameters, self.handler = parameters, handler

    def to_schema(self):
        return {"type": "function", "function": {
            "name": self.name, "description": self.description,
            "parameters": self.parameters}}

class ToolRegistry:
    def __init__(self, config):
        self.config = config
        self.allowed = [t["host"] for t in config["authorized_targets"]]
        self.dry_run = bool(config["agent"].get("dry_run", True))
        self.approve = None  # override possible depuis l UI web
        self.tools = {}
        from src.tools.recon import register
        register(self)

    def register(self, tool: Tool):
        self.tools[tool.name] = tool

    def _check_host(self, host):
        if host not in self.allowed:
            raise NotAuthorizedError(f"{host} n est PAS dans la whitelist. Action bloquee.")

    def _shell(self, cmd: list[str]) -> str:
        if self.dry_run:
            if self.approve is not None:
                ok = self.approve(cmd)
            else:
                ok = input(f"[DRY-RUN] Executer ? {' '.join(cmd)} [y/N] ").lower() == "y"
            if not ok:
                return "SKIP: refuse par l operateur (dry-run)."
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        return (r.stdout or r.stderr)[:8000]

    def to_mistral_tools(self):
        return [t.to_schema() for t in self.tools.values()]

    def execute(self, name, args):
        return self.tools[name].handler(self, **args)
EOF

  cat > "$PROJECT_DIR"/src/tools/recon.py <<'EOF'
"""Outils : reconnaissance passive/active NON destructive."""
from src.tools.base import Tool

def register(reg):
    reg.register(Tool(
        "scan_ports",
        "Scan nmap des ports TCP les plus courants sur un hote autorise.",
        {"type": "object",
         "properties": {"host": {"type": "string"},
                        "top_ports": {"type": "integer", "enum": [100, 1000]},
                        "service_version": {"type": "boolean"}},
         "required": ["host"]},
        scan_ports,
    ))
    reg.register(Tool(
        "http_headers",
        "Recupere les en-tetes HTTP d une URL (empreinte serveur, technos).",
        {"type": "object",
         "properties": {"url": {"type": "string"}},
         "required": ["url"]},
        http_headers,
    ))
    reg.register(Tool(
        "dns_lookup",
        "Resolution DNS d un domaine (A, AAAA, MX, TXT, NS).",
        {"type": "object",
         "properties": {"domain": {"type": "string"}},
         "required": ["domain"]},
        dns_lookup,
    ))
    reg.register(Tool(
        "submit_report",
        "Termine la mission et rend le rapport Markdown final.",
        {"type": "object",
         "properties": {"report_md": {"type": "string"}},
         "required": ["report_md"]},
        lambda reg, report_md: _save(reg, report_md),
    ))

def scan_ports(reg, host, top_ports=1000, service_version=True):
    reg._check_host(host)
    cmd = ["nmap", "-Pn", "--top-ports", str(top_ports)]
    if service_version:
        cmd.append("-sV")
    cmd.append(host)
    return reg._shell(cmd)

def http_headers(reg, url):
    host = url.split("//")[-1].split("/")[0].split(":")[0]
    reg._check_host(host)
    return reg._shell(["curl", "-sI", "-m", "15", url])

def dns_lookup(reg, domain):
    reg._check_host(domain)
    out = []
    for t in ["A", "AAAA", "MX", "TXT", "NS"]:
        out.append(f"--- {t} ---\n" + reg._shell(["dig", "+noall", "+answer", t, domain]))
    return "\n".join(out)

def _save(reg, report_md):
    from datetime import datetime
    path = f"reports/rapport_{datetime.now():%Y%m%d_%H%M%S}.md"
    with open(path, "w") as f:
        f.write(report_md)
    return f"Rapport sauvegarde : {path}"
EOF

  cat > "$PROJECT_DIR"/src/web.py <<'EOF'
"""
Mini interface web : saisie de mission, deroule step par step.
A proteger imperativement (basic auth TLS ou VPN).
Lancement : python3 -m src.web  (ecoute sur 8080 dans le conteneur)
"""
import os
from flask import Flask, request, jsonify, render_template_string
from src.agent import run_mission

app = Flask(__name__)
PAGE = """
<!doctype html><html><head><title>AgentLab</title></head><body>
<h1>AgentLab (Mistral)</h1>
<p>Cibles autorisees : uniquement celles de config/targets.yaml.</p>
<form id="f"><input name="target" placeholder="cible autorisee" size="30"><br>
<textarea name="mission" rows="3" style="width:80%">Reconnaissance complete de la cible ...</textarea><br>
<button>Lancer la mission</button></form>
<pre id="out"></pre>
<script>
document.getElementById('f').onsubmit = async (e) => {
  e.preventDefault();
  const body = JSON.stringify({target: e.target.target.value, mission: e.target.mission.value});
  const r = await fetch('/run', {method:'POST', headers:{'Content-Type':'application/json'}, body});
  document.getElementById('out').textContent = JSON.stringify(await r.json(), null, 2);
};
</script></body></html>
"""

@app.get("/")
def home():
    return render_template_string(PAGE)

@app.post("/run")
def run():
    target = request.json.get("target", "")
    mission = request.json.get("mission") or f"Reconnaissance complete de {target}."
    trace = run_mission(mission, approve=lambda cmd: True)  # approbation auto : v1 = vrai bouton
    return jsonify(trace)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("WEB_PORT", 8080)))
EOF

  touch "$PROJECT_DIR"/src/__init__.py "$PROJECT_DIR"/src/tools/__init__.py
  echo "  Code genere dans $PROJECT_DIR"

  if [ ! -f "$PROJECT_DIR/config/targets.yaml" ]; then
    echo "  ATTENTION : copie ton fichier de cibles :"
    echo "      cp $PROJECT_DIR/config/targets.yaml.example $PROJECT_DIR/config/targets.yaml"
  fi
fi

# ----------------------------------------------------------------
step "[ETAPE F] Push du code + dependances Python"
# ----------------------------------------------------------------
incus file push -r "$PROJECT_DIR"/. "$CONTAINER"/app/ \
  || die "push a echoue : project_dir=$PROJECT_DIR est-il correct dans la config ?"
incus exec "$CONTAINER" -- chown -R operator:operator /app
# Venv dédié (évite les collisions pip --user / modules apt, cause de l' ImportError mistralai)
incus exec "$CONTAINER" -- sudo -u operator bash -c '
  python3 -m venv /app/venv &&
  /app/venv/bin/pip install -q -r /app/requirements.txt &&
  PYTHONNOUSERSITE=1 /app/venv/bin/python -c "import mistralai, flask, yaml; print(\"imports OK\")"
' || die "installation du venv ou des dependances a echoue"
echo "  Code pousse dans /app, venv + dependances OK."

# ----------------------------------------------------------------
step "[ETAPE G] Snapshot propre + recap"
# ----------------------------------------------------------------
if incus snapshot list "$CONTAINER" 2>/dev/null | grep -q propre; then
  incus snapshot delete "$CONTAINER" propre
fi
incus snapshot create "$CONTAINER" propre
incus list "$CONTAINER"

echo
echo "INIT TERMINE."
echo "  Conteneur : $CONTAINER, IP actuelle : $CUR_IP (DHCP), snapshot 'propre' cree."
echo "  Prochaine etape : ./pentest.sh <cible> \"mission\""
