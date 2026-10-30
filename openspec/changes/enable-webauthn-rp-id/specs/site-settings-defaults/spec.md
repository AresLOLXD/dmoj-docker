# Spec Delta

## Purpose
Defines what the settings template shipped with this repo turns on by default, so a new install gets those behaviors without editing the template and a reader can tell what the defaults are meant to be.

## ADDED Requirements

### Requirement: The settings template enables WebAuthn for the site hostname
The settings template SHALL set `WEBAUTHN_RP_ID` to the same `HOST` value it uses for `ALLOWED_HOSTS`, on a line after `HOST` is defined. An empty `HOST` leaves WebAuthn disabled.

#### Scenario: The template sets WebAuthn to the hostname
- **WHEN** the template is read
- **THEN** it contains the line `WEBAUTHN_RP_ID = HOST`
- **CHECK** `grep -Fx 'WEBAUTHN_RP_ID = HOST' local_settings.py` exits 0

#### Scenario: HOST is defined before it is used
- **WHEN** the template is read top to bottom
- **THEN** the line `HOST = ...` comes before the line `WEBAUTHN_RP_ID = HOST`
- **CHECK** `awk '/^HOST = /{h=NR} /^WEBAUTHN_RP_ID = HOST$/{w=NR} END{exit !(h && w && h<w)}' local_settings.py` exits 0

#### Scenario: The template evaluates to the configured hostname
- **WHEN** the part of the template before `# Optional apps` runs with the environment variable `HOST` set to `dmoj.example.org`
- **THEN** `WEBAUTHN_RP_ID` equals `dmoj.example.org`
- **CHECK** `HOST=dmoj.example.org python3 -I -c "import os; ns={'os':os,'INSTALLED_APPS':[]}; exec(open('local_settings.py').read().split('# Optional apps')[0], ns); assert ns['WEBAUTHN_RP_ID']=='dmoj.example.org'"` exits 0
