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
