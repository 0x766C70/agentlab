# AgentLab — agent de pentest offensif piloté par LLM (Mistral)

Agent éducatif : une boucle **ReAct** (Réflexion → Action → Observation) où un LLM Mistral  
choisit et enchaîne des outils de reconnaissance (`nmap`, `dig`, `curl`) pour produire un  
rapport de reconnaissance sur une cible **que vous êtes autorisé à tester**.

> ⚠️ **Avertissement légal**  
> Utilisez cet outil uniquement sur des systèmes qui vous appartiennent, ou pour  
> lesquels vous disposez d'une autorisation écrite explicite. Tester un système sans  
> autorisation est illégal (en France : art. 323-1 et suivants du Code pénal).  
> La whitelist de cibles est là pour ça, et le mode dry-run pour garder la main.

## Architecture

- **Conteneur Incus** (Debian) : hôte de l'agent, outils de recon installés, non-root.
- **Boucle ReAct** : Mistral + function calling. L'agent propose, vous approuvez (dry-run)  
ou agit seul (`dry_run: false`).
- **Whitelist** : toute action sur un hôte absent de `config/targets.yaml` est refusée,  
à la fois par le script hôte et par le garde-fou de l'agent.
- **Snapshots Incus** : avant chaque mission et après l'init, rollback en une commande.  
Créés en asynchrone via l'API (voir Dépannage).
- **Livraison des rapports** : envoi automatique par mail (`report_email`), aucune copie  
conservée sur l'hôte en cas de succès.
- **Mode planifié** : `pentest-monthly.sh` + crontab pour des recons récurrentes.

## Prérequis

- Un hôte Linux avec [Incus](https://linuxcontainers.org/incus/) installé et un bridge  
réseau managé (ex. `incusbr1`). Testé sur NixOS et Debian 13.
- Python 3 uniquement à l'intérieur du conteneur (rien à installer sur l'hôte).
- Une clé API Mistral ([console Mistral](https://console.mistral.ai/)).
- Pour l'envoi des rapports : `bsd-mailx` + un MTA léger (`msmtp` + `msmtp-mta`).

## Installation

```bash
# 1. Configuration
mkdir -p ~/.config/pentest
cp config.yaml.example ~/.config/pentest/config.yaml
#    → adapte : bridge, conteneur, report_email (destinataire des rapports)

# 2. Envoi des rapports par mail (msmtp)
#    ~/.msmtprc  → host SMTP, identifiants, chmod 600 (voir doc msmtp)
#    test : echo test | mail -s test monitoring@mondomaine.tld

# 3. Cibles autorisées (jamais committées)
cp config/targets.yaml.example config/targets.yaml
#    → liste uniquement TES cibles ; dry_run et max_steps vivent aussi ici

# 4. Provision du conteneur
./init-container.sh
```

## Utilisation

```bash
export MISTRAL_API_KEY="..."        # requis, jamais dans un fichier

# Mission de recon par défaut (dry_run: true → chaque commande demande y/N)
./pentest.sh mon-serveur.mondomaine.tld

# Mission personnalisée
./pentest.sh mon-serveur.mondomaine.tld "Focus sur les services web exposés"

# Interface web
./pentest.sh --web
```

À la fin de chaque mission, le rapport est **envoyé par mail** à l'adresse de  
`report_email` (config.yaml). Aucune copie n'est conservée sur l'hôte ; en cas d'échec  
d'envoi, une copie de secours reste dans `/tmp` avec son chemin affiché.

### `dry_run: false` (autonomie complète)

En passant `dry_run: false` dans `config/targets.yaml` (section `agent`), l'agent exécute  
toutes ses commandes **sans approbation**. À réserver à des cibles que vous possédez :  
la whitelist devient votre seule barrière. Repoussez la config avec `./init-container.sh`  
après modification (l'agent lit sa copie dans le conteneur).

### Audits mensuels automatiques

```bash
# Wrapper multi-cibles : pentest-monthly.sh (dans le repo)
# Clé API pour cron : ~/.config/pentest/env (chmod 600)
echo 'export MISTRAL_API_KEY="..."' > ~/.config/pentest/env
chmod 600 ~/.config/pentest/env

# Test manuel d'abord
./pentest-monthly.sh

# Puis crontab -e :
0 4 1 * * flock -n /tmp/pentest-monthly.lock /home/moi/agentlab/pentest-monthly.sh >> /home/moi/agentlab/logs/cron.log 2>&1
```

## Maintenance

```bash
./cleanup.sh --status              # état, IP, snapshots
./cleanup.sh --restore avant-mission-20260101-120000   # rollback
./cleanup.sh --shell               # shell dans le conteneur
./cleanup.sh --recreate            # destroy + init complet
./cleanup.sh --destroy             # suppression définitive (avec confirmation)
```

## Sécurité intégrée


| Garde-fou             | Rôle                                                                       |
| --------------------- | -------------------------------------------------------------------------- |
| `config/targets.yaml` | Uniquement ces hôtes, refus en amont (script) et en aval (agent)           |
| `dry_run: true`       | Chaque commande est proposée, vous approuvez par `y`                       |
| Budget `max_steps`    | La mission s'arrête au bout de N actions                                   |
| Snapshots Incus       | Rollback complet de l'hôte de l'agent                                      |
| Utilisateur non-root  | L'agent tourne en `operator` dans le conteneur                             |
| Clé API               | Uniquement dans l'environnement ou un fichier `chmod 600`, jamais commitée |


Rappels d'hygiène : `reports/` et `logs/` sont dans `.gitignore` (les rapports sont  
contextuels et potentiellement sensibles, jamais versionnés), et la whitelist de cibles  
n'est jamais committée.

## Dépannage (versions terrain)

- **La mission pend silencieusement, conteneur FROZEN** : un snapshot client a perdu la  
notification de fin (bug observé sur CLI Incus 6.0.4/Debian). Le script contourne en  
créant les snapshots **en asynchrone via l'API** (`incus query`) + vérification  
d'existence. Pour un daemon déjà coincé : `sudo systemctl restart incus`.
- **Le conteneur n'obtient pas d'IP / le DNS échoue** : si l'hôte a un firewall  
`policy drop` (nftables), le trafic DHCP/DNS venant du bridge est droppé malgré les  
règles qu'Incus installe (deux tables, même priorité : le drop l'emporte). Acceptez le  
bridge en entrée (DHCP 67, DNS 53) dans votre propre chaîne input.
- **pip échoue au premier essai puis réussit** : course au démarrage entre le resolver  
du bridge et la première requête ; les retries de pip s'en chargent, vérifiez  
l'`imports OK` final.
- **Rapport non envoyé** : vérifiez `report_email` dans le config.yaml lu (pas  
`targets.yaml`), la présence de `mail` (bsd-mailx/msmtp-mta), et `~/.msmtp.log`.  
Sans SPF/DKIM sur votre domaine d'envoi, surveillez aussi le dossier spam.

## Ajouter un outil à l'agent

1. Écris une fonction dans `src/tools/recon.py` (ou un nouveau module).
2. Déclare-la dans `register()` : nom, description, schéma JSON, handler.
3. Passe ET sur la whitelist via `_shell()` — jamais de `subprocess` direct.

## Feuille de route (v1)

- Outil `fetch_url` (GET avec corps de réponse) : suivre les recommandations des rapports
- `scan_ports` paramétrable : IPv6, UDP/QUIC, plages de ports personnalisées
- `tls_audit` : certificats, SANs, versions TLS (testssl/openssl)
- Mode `dry_run: "sensible"` : auto-approbation des outils passifs uniquement
- Approbation des actions dans l'UI web (endpoint `/approve`)
- Mémoire de mission (observations persistées entre les étapes)

## Licence

À définir par l'auteur (MIT recommandé pour un outil éducatif).

## Disclaimer final

Ce projet est fourni à des fins **éducatives**. Les auteurs déclinent toute  
responsabilité d'un usage non autorisé. Restez dans le cadre légal.
