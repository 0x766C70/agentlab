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
