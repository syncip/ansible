#!/usr/bin/env bash
# =============================================================================
# server-setup – Ersteinrichtung für Debian- und Ubuntu-Server mit Ansible
#
# Aufruf auf dem frischen Server als root:
#   curl -fsSL https://raw.githubusercontent.com/syncip/ansible/main/setup.sh | bash
#
# Ablauf:
#   1. System prüfen, Ansible + git installieren, Repository holen
#   2. Menü: Keys, Hostname, SSH-Port, Firewall-Ports, Komponenten
#   3. Phase "prepare":  alles einrichten, SSH hört auf altem UND neuem Port,
#                        Login-Einstellungen bleiben (noch) unverändert
#   4. Du testest den Key-Login in einem zweiten Terminal
#   5. Phase "finalize": nur noch Key-Login, alter SSH-Port wird geschlossen
#
# Optionen: siehe ./setup.sh --help
# =============================================================================
set -Eeuo pipefail

REPO_URL="${SETUP_REPO_URL:-https://github.com/syncip/ansible.git}"
REF="${SETUP_REF:-main}"
INSTALL_DIR="/opt/server-setup"
STATE_DIR="/etc/server-setup"
CONFIG_FILE="$STATE_DIR/config.yml"
FINALIZED_MARKER="$STATE_DIR/finalized"
LOG_FILE="/var/log/server-setup.log"

# Ports außerhalb des Linux-Ephemeral-Bereichs (32768–60999), damit der
# SSH-Port nicht mit ausgehenden Verbindungen kollidieren kann.
RANDOM_PORT_MIN=10000
RANDOM_PORT_MAX=32767

OPT_LOCAL=0
OPT_YES=0
OPT_CONFIG=""
REPO_DIR=""

# ----------------------------------------------------------------------------
# Hilfsfunktionen
# ----------------------------------------------------------------------------
if [[ -t 2 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_BOLD="" C_RESET=""
fi

info() { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%sWARNUNG:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sFEHLER:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Nie kommentarlos abbrechen: unerwartete Fehler mit Zeile und Befehl melden.
trap 'die "Unerwarteter Fehler in Zeile $LINENO: $BASH_COMMAND (Protokoll: $LOG_FILE)"' ERR

usage() {
  cat <<'EOF'
Aufruf: setup.sh [Optionen]

  --ref REF       Git-Branch, -Tag oder -Commit, der verwendet wird (Standard: main,
                  alternativ Umgebungsvariable SETUP_REF)
  --config DATEI  Keine Abfragen, stattdessen diese Konfigurationsdatei verwenden
  --yes           Keine Rückfragen (auch nicht nach dem Login-Test!) – nur für
                  Automatisierung/CI gedacht
  --local         Das Repository verwenden, in dem dieses Script liegt, statt es
                  nach /opt/server-setup zu holen (Entwicklung/CI)
  -h, --help      Diese Hilfe
EOF
}

# whiptail liest vom Terminal (auch bei "curl | bash") und schreibt das
# Ergebnis auf stdout.
wt() {
  whiptail --backtitle "server-setup" "$@" 2>&1 >/dev/tty </dev/tty
}

# Mehrzeilige Ausgabe (z. B. von --separate-output) in ein Array übernehmen.
lines_to_array() {
  local -n _arr="$1"
  local line
  _arr=()
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      _arr+=("$line")
    fi
  done <<<"$2"
  # Eine leere Auswahl ist gültig (z. B. keine zusätzlichen Ports) und darf
  # wegen "set -e" nicht als Fehler zurückkommen.
  return 0
}

wt_yesno() {
  whiptail --backtitle "server-setup" "$@" >/dev/tty </dev/tty
}

# Ja/Nein-Dialog für längere Texte: Höhe passend zum Inhalt, Scrollen nur
# wenn das Terminal zu klein ist (bei --scrolltext reagiert Enter erst nach Tab).
# Aufruf: wt_confirm_text TITEL JA-KNOPF NEIN-KNOPF TEXT
wt_confirm_text() {
  local title="$1" yes="$2" no="$3" text="$4" rows height lines
  rows="$(stty size </dev/tty 2>/dev/null | awk '{print $1}')"
  lines="$(printf '%b\n' "$text" | wc -l)"
  height=$((lines + 7))
  if [[ -n "$rows" ]] && ((height > rows - 2)); then
    wt_yesno --title "$title" --yes-button "$yes" --no-button "$no" --scrolltext --yesno "$text" $((rows - 2)) 78
  else
    wt_yesno --title "$title" --yes-button "$yes" --no-button "$no" --yesno "$text" "$height" 78
  fi
}

# ----------------------------------------------------------------------------
# Vorprüfungen und Installation
# ----------------------------------------------------------------------------
parse_args() {
  while (($#)); do
    case "$1" in
      --ref)    REF="${2:?--ref braucht einen Wert}"; shift 2 ;;
      --config) OPT_CONFIG="${2:?--config braucht einen Wert}"; shift 2 ;;
      --yes)    OPT_YES=1; shift ;;
      --local)  OPT_LOCAL=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Unbekannte Option: $1" ;;
    esac
  done
}

# shellcheck disable=SC1091 # /etc/os-release existiert nur auf dem Zielsystem
check_system() {
  [[ $EUID -eq 0 ]] || die "Bitte als root ausführen."

  [[ -r /etc/os-release ]] || die "/etc/os-release fehlt – unbekanntes System."
  local id version
  id="$(. /etc/os-release && echo "${ID:-}")"
  version="$(. /etc/os-release && echo "${VERSION_ID:-}")"

  case "$id:$version" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
    *) die "Nicht unterstütztes System: ${id:-?} ${version:-?} (unterstützt: Debian 12/13, Ubuntu 22.04/24.04/26.04)." ;;
  esac
  info "System: $id $version"

  if [[ -z "$OPT_CONFIG" && ! -r /dev/tty ]]; then
    die "Kein Terminal für die Abfragen verfügbar. Mit --config DATEI ohne Abfragen starten."
  fi
}

install_dependencies() {
  info "Installiere Ansible, git und whiptail …"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >>"$LOG_FILE" 2>&1 || die "apt-get update fehlgeschlagen (siehe $LOG_FILE)."
  apt-get install -y -q --no-install-recommends \
    ansible-core git whiptail python3-apt ca-certificates openssh-server iproute2 \
    >>"$LOG_FILE" 2>&1 || die "Paketinstallation fehlgeschlagen (siehe $LOG_FILE)."
}

fetch_repository() {
  if ((OPT_LOCAL)); then
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "$REPO_DIR/site.yml" ]] || die "--local: site.yml nicht gefunden in $REPO_DIR."
    info "Verwende lokales Repository: $REPO_DIR"
    return
  fi

  info "Hole $REPO_URL ($REF) nach $INSTALL_DIR …"
  if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    install -d -m 0700 "$INSTALL_DIR"
    git -C "$INSTALL_DIR" init -q
    git -C "$INSTALL_DIR" remote add origin "$REPO_URL"
  fi
  git -C "$INSTALL_DIR" fetch -q --depth 1 origin "$REF" \
    || die "Konnte '$REF' nicht aus $REPO_URL holen."
  git -C "$INSTALL_DIR" checkout -q -f FETCH_HEAD
  REPO_DIR="$INSTALL_DIR"
  info "Stand: $(git -C "$REPO_DIR" log -1 --format='%h %s')"
}

# ----------------------------------------------------------------------------
# Werte ermitteln und prüfen
# ----------------------------------------------------------------------------
current_ssh_port() {
  install -d -m 0755 /run/sshd
  /usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }'
}

port_in_use() {
  [[ -n "$(ss -Htln "sport = :$1" 2>/dev/null)" ]]
}

random_free_port() {
  local port
  for _ in $(seq 1 50); do
    port=$((RANDOM_PORT_MIN + RANDOM % (RANDOM_PORT_MAX - RANDOM_PORT_MIN + 1)))
    port_in_use "$port" || { echo "$port"; return; }
  done
  die "Kein freier Port gefunden."
}

valid_port()     { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; }
valid_fw_rule()  { [[ "$1" =~ ^[0-9]{1,5}(:[0-9]{1,5})?/(tcp|udp)$ ]]; }
valid_time()     { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

list_keys() {
  local f
  for f in "$REPO_DIR"/keys/*.pub; do
    [[ -e "$f" ]] || continue
    basename "$f" .pub
  done
}

key_fingerprint() {
  ssh-keygen -lf "$REPO_DIR/keys/$1.pub" 2>/dev/null
}

# ----------------------------------------------------------------------------
# Menü
# ----------------------------------------------------------------------------
ask_config() {
  local -a keys items selected_keys fw_items selected_components selected_ports
  local key fp hostname timezone ssh_port cur_port extra rule out ok
  local want_fw=false want_f2b=false want_updates=false want_docker=false
  local auto_reboot=false reboot_time="04:00"

  # --- SSH-Keys ---------------------------------------------------------------
  mapfile -t keys < <(list_keys)
  ((${#keys[@]})) || die "Keine Public Keys in $REPO_DIR/keys/ gefunden. Lege zuerst deinen Key als keys/<name>.pub im Repository ab (siehe README)."

  items=()
  for key in "${keys[@]}"; do
    fp="$(key_fingerprint "$key")" || die "keys/$key.pub ist kein gültiger SSH Public Key."
    items+=("$key" "$(awk '{print $2, "(" $NF ")"}' <<<"$fp")" ON)
  done
  out="$(wt --title "SSH-Keys" --separate-output --checklist \
    "Welche Keys sollen root-Zugang bekommen?\n\nAchtung: /root/.ssh/authorized_keys wird komplett ersetzt – andere Keys (z. B. vom Hoster) werden entfernt." \
    20 78 10 "${items[@]}")" || die "Abgebrochen."
  lines_to_array selected_keys "$out"
  ((${#selected_keys[@]})) || die "Mindestens ein Key muss ausgewählt werden."

  # --- Hostname / Zeitzone ---------------------------------------------------
  while :; do
    hostname="$(wt --title "Hostname" --inputbox "Hostname (kurz oder FQDN):" 10 60 "$(hostname -f 2>/dev/null || hostname)")" || die "Abgebrochen."
    valid_hostname "$hostname" && break
    wt_yesno --title "Ungültig" --msgbox "'$hostname' ist kein gültiger Hostname." 8 60
  done

  while :; do
    timezone="$(wt --title "Zeitzone" --inputbox "Zeitzone:" 10 60 "Europe/Berlin")" || die "Abgebrochen."
    [[ -f "/usr/share/zoneinfo/$timezone" ]] && break
    wt_yesno --title "Ungültig" --msgbox "Unbekannte Zeitzone: '$timezone'." 8 60
  done

  # --- SSH-Port --------------------------------------------------------------
  cur_port="$(current_ssh_port)"
  cur_port="${cur_port:-22}"
  ssh_port="$cur_port"
  if wt_yesno --title "SSH-Port" --yesno "SSH läuft aktuell auf Port $cur_port.\n\nSSH-Port ändern?\n\n(Bringt kaum zusätzliche Sicherheit, reduziert aber Log-Rauschen durch Bots deutlich.)" 13 70; then
    while :; do
      ssh_port="$(wt --title "SSH-Port" --inputbox "Neuer SSH-Port (Vorschlag: zufällig, frei, außerhalb des Ephemeral-Bereichs):" 10 70 "$(random_free_port)")" || die "Abgebrochen."
      if ! valid_port "$ssh_port"; then
        wt_yesno --title "Ungültig" --msgbox "'$ssh_port' ist kein gültiger Port." 8 60
      elif [[ "$ssh_port" != "$cur_port" ]] && port_in_use "$ssh_port"; then
        wt_yesno --title "Belegt" --msgbox "Port $ssh_port wird bereits verwendet." 8 60
      else
        ssh_port=$((10#$ssh_port))
        break
      fi
    done
  fi

  # --- Komponenten ------------------------------------------------------------
  out="$(wt --title "Komponenten" --separate-output --checklist \
    "Was soll eingerichtet werden?\n(Basis-System und SSH-Härtung werden immer eingerichtet.)" 16 78 4 \
    firewall     "Firewall (ufw)"                            ON \
    fail2ban     "fail2ban (Schutz vor Brute-Force)"         ON \
    auto_updates "Automatische Sicherheitsupdates"           ON \
    docker       "Docker (offizielles Docker-Repository)"    OFF)" || die "Abgebrochen."
  lines_to_array selected_components "$out"

  for key in "${selected_components[@]}"; do
    case "$key" in
      firewall) want_fw=true ;;
      fail2ban) want_f2b=true ;;
      auto_updates) want_updates=true ;;
      docker) want_docker=true ;;
    esac
  done

  # --- Firewall-Ports ---------------------------------------------------------
  selected_ports=()
  if [[ $want_fw == true ]]; then
    fw_items=(
      "80/tcp"   "HTTP"                OFF
      "443/tcp"  "HTTPS"               OFF
      "443/udp"  "HTTP/3 (QUIC)"       OFF
    )
    out="$(wt --title "Firewall" --separate-output --checklist \
      "Eingehend wird alles blockiert.\n\nDer SSH-Port $ssh_port/tcp wird IMMER als erste Regel freigegeben.\n\nWelche Ports sollen zusätzlich offen sein?" \
      17 70 5 "${fw_items[@]}")" || die "Abgebrochen."
    lines_to_array selected_ports "$out"

    while :; do
      extra="$(wt --title "Firewall" --inputbox "Weitere Ports (Leerzeichen-getrennt, z. B. 8080/tcp 51820/udp 6000:6010/tcp), leer lassen für keine:" 10 78 "")" || die "Abgebrochen."
      ok=1
      for rule in $extra; do
        valid_fw_rule "$rule" || { ok=0; wt_yesno --title "Ungültig" --msgbox "'$rule' ist ungültig. Format: PORT/tcp, PORT/udp oder VON:BIS/tcp" 8 70; break; }
      done
      ((ok)) && break
    done
    # shellcheck disable=SC2206 # gewollte Wort-Trennung, Werte sind validiert
    selected_ports+=($extra)
  fi

  # --- Automatische Updates ---------------------------------------------------
  if [[ $want_updates == true ]]; then
    if wt_yesno --title "Automatische Updates" --defaultno --yesno "Server automatisch neu starten, wenn ein Update (z. B. Kernel) das erfordert?" 10 70; then
      auto_reboot=true
      while :; do
        reboot_time="$(wt --title "Automatische Updates" --inputbox "Uhrzeit für den automatischen Neustart (HH:MM):" 10 60 "04:00")" || die "Abgebrochen."
        valid_time "$reboot_time" && break
      done
    fi
  fi

  # --- Konfiguration schreiben -------------------------------------------------
  install -d -m 0700 "$STATE_DIR"
  {
    echo "# Erzeugt von setup.sh am $(date -Is) – kann von Hand angepasst werden."
    echo "setup_hostname: \"$hostname\""
    echo "setup_timezone: \"$timezone\""
    echo "setup_ssh_port: $ssh_port"
    echo "setup_ssh_keys:"
    for key in "${selected_keys[@]}"; do echo "  - \"$key\""; done
    echo "setup_firewall: $want_fw"
    echo "setup_firewall_ports:"
    ((${#selected_ports[@]})) || echo "  []"
    for rule in "${selected_ports[@]}"; do echo "  - \"$rule\""; done
    echo "setup_fail2ban: $want_f2b"
    echo "setup_auto_updates: $want_updates"
    echo "setup_auto_reboot: $auto_reboot"
    echo "setup_auto_reboot_time: \"$reboot_time\""
    echo "setup_docker: $want_docker"
  } >"$CONFIG_FILE.new"
  chmod 0600 "$CONFIG_FILE.new"
  mv "$CONFIG_FILE.new" "$CONFIG_FILE"
}

confirm_config() {
  local summary fps="" key
  while read -r key; do
    fps+="  $(key_fingerprint "$key")\n"
  done < <(sed -n '/^setup_ssh_keys:/,/^[^ ]/ s/^  - "\(.*\)"$/\1/p' "$CONFIG_FILE")

  summary="$(grep -v '^#' "$CONFIG_FILE")"
  wt_confirm_text "Zusammenfassung: jetzt ausführen?" "Ausführen" "Abbrechen" \
    "$summary\n\nKey-Fingerprints:\n$fps"
}

# ----------------------------------------------------------------------------
# Ansible ausführen
# ----------------------------------------------------------------------------
run_playbook() {
  local phase="$1" finalized=false
  [[ -f "$FINALIZED_MARKER" ]] && finalized=true
  info "Starte Ansible (Phase: $phase) – Protokoll: $LOG_FILE"
  ANSIBLE_CONFIG="$REPO_DIR/ansible.cfg" ansible-playbook \
    -i localhost, -c local \
    -e "@$CONFIG_FILE" \
    -e "setup_phase=$phase" -e "setup_finalized=$finalized" \
    "$REPO_DIR/site.yml" 2>&1 | tee -a "$LOG_FILE"
}

login_test_ok() {
  local port ip
  port="$(awk '/^setup_ssh_port:/{print $2}' "$CONFIG_FILE")"
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  if ((OPT_YES)); then
    warn "--yes: Login-Test wird übersprungen."
    return 0
  fi

  cat >&2 <<EOF

${C_BOLD}Jetzt den Login testen – dieses Terminal NICHT schließen!${C_RESET}

  Öffne ein zweites Terminal und verbinde dich mit:

      ssh -p $port root@${ip:-<server-ip>}

  SSH lauscht gerade auf dem alten UND dem neuen Port. Erst wenn du den
  Login bestätigst, wird der alte Port geschlossen und nur noch Key-Login
  erlaubt.

EOF
  wt_yesno --title "Login-Test" --defaultno --yesno \
    "Hat der Login mit\n\n  ssh -p $port root@${ip:-<server-ip>}\n\nin einem zweiten Terminal funktioniert?" 12 70
}

main() {
  parse_args "$@"
  # Minimal-Installationen haben oft keine UTF-8-Locale – dann zeigt whiptail
  # Umlaute falsch an. C.UTF-8 ist auf Debian und Ubuntu immer vorhanden.
  if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  fi
  touch "$LOG_FILE" && chmod 0600 "$LOG_FILE"
  check_system
  install_dependencies
  fetch_repository

  if [[ -n "$OPT_CONFIG" ]]; then
    [[ -r "$OPT_CONFIG" ]] || die "Konfigurationsdatei nicht lesbar: $OPT_CONFIG"
    install -d -m 0700 "$STATE_DIR"
    [[ "$(realpath "$OPT_CONFIG")" == "$CONFIG_FILE" ]] || install -m 0600 "$OPT_CONFIG" "$CONFIG_FILE"
  elif [[ -f "$CONFIG_FILE" ]] && wt_confirm_text "Konfiguration vom letzten Lauf verwenden?" \
      "Verwenden" "Neu abfragen" "$(grep -v '^#' "$CONFIG_FILE")"; then
    info "Verwende vorhandene Konfiguration $CONFIG_FILE"
  else
    ask_config
  fi

  if [[ -z "$OPT_CONFIG" ]] && ! ((OPT_YES)); then
    confirm_config || die "Abgebrochen – es wurde nichts verändert."
  fi

  run_playbook prepare || die "Phase 'prepare' fehlgeschlagen (siehe $LOG_FILE). Der bisherige SSH-Zugang ist unverändert."

  if ! login_test_ok; then
    warn "Login nicht bestätigt. Der alte SSH-Port bleibt offen, die Login-Einstellungen sind unverändert."
    warn "Fehler beheben und setup.sh erneut starten."
    exit 1
  fi

  run_playbook finalize || die "Phase 'finalize' fehlgeschlagen (siehe $LOG_FILE)."
  touch "$FINALIZED_MARKER"

  info "Fertig. Konfiguration: $CONFIG_FILE – erneuter Lauf jederzeit mit:"
  info "  curl -fsSL https://raw.githubusercontent.com/syncip/ansible/main/setup.sh | bash"
  if [[ -f /var/run/reboot-required ]]; then
    warn "Ein Neustart ist erforderlich (z. B. wegen eines Kernel-Updates): reboot"
  fi
}

# Alles steht in Funktionen und main wird erst in der letzten Zeile aufgerufen:
# So führt "curl | bash" nie ein halb heruntergeladenes Script aus.
main "$@"; exit $?
