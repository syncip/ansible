# server-setup

Ersteinrichtung und Härtung von **Debian- und Ubuntu-Servern** mit Ansible –
gestartet mit einem einzigen Befehl, gesteuert über ein Auswahlmenü.

Unterstützt: Debian 12 / 13, Ubuntu 22.04 / 24.04 / 26.04 LTS.

## Schnellstart

**1. Einmalig:** deinen SSH Public Key in [`keys/`](keys/) ablegen, z. B. als
`keys/martin-laptop.pub` (siehe [keys/README.md](keys/README.md)).

**2. Auf dem neuen Server als root:**

```bash
curl -fsSL https://raw.githubusercontent.com/syncip/ansible/main/setup.sh | bash
```

Nicht als root angemeldet? Dann `… | sudo bash`.

Das Script installiert Ansible, holt dieses Repository nach `/opt/server-setup`
und fragt dann ab:

| Abfrage | Standard |
|---|---|
| Welche Keys aus `keys/` root-Zugang bekommen | alle |
| Hostname | aktueller Hostname |
| Zeitzone | Europe/Berlin |
| SSH-Port ändern? | Vorschlag: zufälliger freier Port (10000–32767) |
| Komponenten: Firewall, fail2ban, automatische Updates, Docker | alle außer Docker |
| Firewall-Ports (Mehrfachauswahl + eigene) – **SSH-Port ist immer die erste Regel** | nur SSH |
| Automatischer Neustart nach Updates + Uhrzeit | aus / 04:00 |

Danach siehst du eine Zusammenfassung mit den Fingerprints der gewählten Keys
und bestätigst mit „Ausführen“.

## Ablauf – warum man sich nicht aussperren kann

```
Phase "prepare"                          Phase "finalize"
─────────────────────────────            ─────────────────────────────
Keys eintragen                           nur noch Key-Login
SSH lauscht auf ALTEM + NEUEM Port   →   (PasswordAuthentication no,
Firewall erlaubt beide Ports             PermitRootLogin prohibit-password)
Login-Regeln noch unverändert            alter Port geschlossen (sshd + ufw)
        │                                        ▲
        └── du testest in einem 2. Terminal: ────┘
            ssh -p <neuer-port> root@<server>
```

- Die laufende SSH-Sitzung bleibt immer bestehen.
- Jede sshd-Änderung wird vorher mit `sshd -t` geprüft und bei einem Fehler
  zurückgenommen.
- Bestätigst du den Login-Test nicht, bleibt der alte Zugang offen.
- Notfall: Web-Konsole deines Hosters.

## Was eingerichtet wird

| Bereich | Details |
|---|---|
| **Basis** (immer) | Vollständiges Update, Basispakete, Hostname (auch gegen cloud-init geschützt), Zeitzone, Zeitsynchronisation, Journal auf 500 MB begrenzt |
| **SSH** (immer) | Nur Key-Login, auch für root. Einstellungen in `/etc/ssh/sshd_config.d/00-server-setup.conf`. `authorized_keys` enthält **genau** die gewählten Keys. Kryptografie bleibt bewusst auf den OpenSSH-Vorgaben |
| **Firewall** | ufw: eingehend alles blockiert, SSH-Port zuerst, dann die gewählten Ports. Abgewählte Ports werden beim nächsten Lauf wieder geschlossen |
| **fail2ban** | SSH-Schutz, liest aus dem systemd-Journal, sperrt über ufw, Sperrzeit steigt bei Wiederholung |
| **Automatische Updates** | unattended-upgrades (nur Sicherheitsupdates laut Distribution), needrestart startet Dienste neu, optional automatischer Neustart |
| **Docker** | Offizielles Docker-Repository (deb822, `signed-by`), Docker CE + Compose-Plugin, Log-Rotation |

> **Achtung Docker + Firewall:** Docker umgeht ufw. Ein mit `-p 8080:80`
> veröffentlichter Container-Port ist öffentlich erreichbar, auch wenn ufw ihn
> nicht freigibt. Nur lokal veröffentlichen (`-p 127.0.0.1:8080:80`) und einen
> Reverse-Proxy davorschalten.

## Erneut ausführen

Einfach denselben Befehl noch einmal starten. Die Antworten liegen in
`/etc/server-setup/config.yml`; das Script bietet an, sie wiederzuverwenden
(„Verwenden“) oder neu abzufragen. So lassen sich auch Keys austauschen,
Ports öffnen/schließen oder Docker nachinstallieren.

Protokoll aller Läufe: `/var/log/server-setup.log`

## Optionen

```bash
curl -fsSL https://raw.githubusercontent.com/syncip/ansible/main/setup.sh | bash -s -- [Optionen]
```

| Option | Bedeutung |
|---|---|
| `--ref REF` | Bestimmten Branch, Tag oder Commit verwenden (Standard: `main`) |
| `--config DATEI` | Keine Abfragen, diese Konfiguration verwenden (Format wie `ci/config.yml`) |
| `--yes` | Keine Rückfragen – auch keinen Login-Test. Nur für Automatisierung |
| `--local` | Das Repository verwenden, in dem `setup.sh` liegt (Entwicklung) |

**Empfehlung:** Für produktive Server eine feste Version verwenden, damit eine
spätere (oder fremde) Änderung an `main` nicht ungeprüft auf deinen Servern
landet:

```bash
curl -fsSL https://raw.githubusercontent.com/syncip/ansible/v1.0.0/setup.sh | bash -s -- --ref v1.0.0
```

## Sicherheit des Repositorys

Wer in dieses Repository schreiben kann, bekommt beim nächsten Lauf root auf
deinen Servern (z. B. durch einen zusätzlichen Key in `keys/`). Deshalb:

- Zwei-Faktor-Anmeldung auf GitHub aktivieren.
- `main` schützen (Änderungen nur per Pull Request, CI muss grün sein).
- Keine Geheimnisse (Tokens, Webhooks, Passwörter) ins Repository – es ist öffentlich.

## Entwicklung und Tests

Jeder Pull Request wird automatisch geprüft ([CI](.github/workflows/ci.yml)):

- `shellcheck`, `yamllint`, `ansible-lint` (Profil *production*)
- Kompletter Lauf von `setup.sh` (beide Phasen, zweimal hintereinander) in
  Containern mit systemd für jede unterstützte Version, danach Prüfung von
  SSH-Port, Login-Regeln, Firewall, fail2ban und Docker

Lokal ausführen (ohne Menü):

```bash
sudo ./setup.sh --local --config meine-config.yml
```

## Aufbau

```
setup.sh              Einstieg: Prüfungen, Installation, Menü, Phasen
site.yml              Playbook
group_vars/all.yml    Standardwerte aller Einstellungen
keys/                 SSH Public Keys zur Auswahl
roles/
  base/               Updates, Pakete, Hostname, Zeit, Journal
  ssh/                Keys, sshd-Härtung, Portwechsel
  firewall/           ufw
  fail2ban/
  auto_updates/       unattended-upgrades, needrestart
  docker/
ci/                   Testkonfiguration und Test-Container
basic/                Ältere Einzel-Playbooks (Update, Benachrichtigungen)
```
