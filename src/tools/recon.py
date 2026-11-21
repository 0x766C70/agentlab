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
