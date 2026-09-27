# SSH Public Keys

Jede Datei `<name>.pub` in diesem Verzeichnis erscheint in `setup.sh` als
Auswahl. Die gewählten Keys bekommen root-Zugang, alle anderen Keys in
`/root/.ssh/authorized_keys` werden entfernt.

```bash
# Auf deinem Rechner – Key anzeigen (oder neu erzeugen: ssh-keygen -t ed25519)
cat ~/.ssh/id_ed25519.pub

# Als Datei hier ablegen, z. B.:
keys/martin-laptop.pub
```

- Nur **Public Keys** (`.pub`) – niemals den privaten Key hochladen.
- Empfohlen: `ed25519` mit Passphrase oder ein Hardware-Key (`ssh-keygen -t ed25519-sk`).
- Wird ein Key hier gelöscht, verliert er beim nächsten Lauf von `setup.sh`
  den Zugang auf dem jeweiligen Server.
