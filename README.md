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
- **Boucle ReAct** : Mistral + function calling. L'agent propose, vous approuvez.
- **Whitelist** : toute action sur un hôte absent de `config/targets.yaml` est refusée.
- **Snapshots Incus** : avant chaque mission et après l'init, rollback en une commande.

## Prérequis

- Un hôte Linux avec [Incus](https://linuxcontainers.org/incus/) installé et un bridge  
réseau managé (ex. `incusbr1`).
- Python 3 uniquement à l'intérieur du conteneur (rien à installer sur l'hôte).
- Une clé API Mistral ([console Mistral](https://console.mistral.ai/)).

## Installation

```bash
# 1. Configuration
mkdir -p ~/.config/pentest
cp config.yaml.example ~/.config/pentest/config.yaml
#    → adapte : bridge, gateway, éventuellement le nom du conteneur

# 2. Cibles autorisées (jamais committées)
cp src/config/targets.yaml.example src/config/targets.yaml
#    → liste uniquement TES cibles

# 3. Provision du conteneur
./init-container.sh
```

## Utilisation

```bash
export MISTRAL_API_KEY="..."        # requis, jamais dans un fichier

# Mission de recon par défaut (dry-run : chaque commande demande y/N)
./pentest.sh mon-serveur.mondomaine.tld

# Mission personnalisée
./pentest.sh mon-serveur.mondomaine.tld "Focus sur les services web exposés"

# Interface web
./pentest.sh --web
```

Le rapport généré est rapatrié dans le répertoire courant à la fin de la mission.

## Maintenance

```bash
./cleanup.sh --status              # état, IP, snapshots
./cleanup.sh --restore avant-mission-20260101-120000   # rollback
./cleanup.sh --shell               # shell dans le conteneur
./cleanup.sh --recreate            # destroy + init complet
./cleanup.sh --destroy             # suppression définitive (avec confirmation)
```

## Sécurité intégrée


| Garde-fou             | Rôle                                                             |
| --------------------- | ---------------------------------------------------------------- |
| `config/targets.yaml` | Uniquement ces hôtes, refus en amont (script) et en aval (agent) |
| `dry_run: true`       | Chaque commande est proposée, vous approuvez par `y`             |
| Budget `max_steps`    | La mission s'arrête au bout de N actions                         |
| Snapshots Incus       | Rollback complet de l'hôte de l'agent                            |
| Utilisateur non-root  | L'agent tourne en `operator` dans le conteneur                   |


## Ajouter un outil à l'agent

1. Écris une fonction dans `src/tools/recon.py` (ou un nouveau module).
2. Déclare-la dans `register()` : nom, description, schéma JSON, handler.
3. Passe ET sur la whitelist via `_shell()` — jamais de `subprocess` direct.

## Feuille de route (v1)

- Approbation des actions dans l'UI web (endpoint `/approve`)
- Mémoire de mission (observations persistées entre les étapes)
- Nouveaux outils : `nikto`, `ffuf`, `testssl.sh`
- Mode "pause-on-finding" : l'agent s'arrête sur toute découverte intéressante

## Licence

À définir par l'auteur (MIT recommandé pour un outil éducatif).

## Disclaimer final

Ce projet est fourni à des fins **éducatives**. Les auteurs déclinent toute  
responsabilité d'un usage non autorisé. Restez dans le cadre légal.
