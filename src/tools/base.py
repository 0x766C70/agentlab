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
