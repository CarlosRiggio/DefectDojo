#!/usr/bin/env python3
"""
Create the two local .env files this repo needs, without manual editing.

  init-env.py deployment   -> deployment/.env from .env.example, every CHANGE_ME
                              replaced with a freshly generated secret (the DB
                              password is reused in DD_DATABASE_URL so the two
                              stay consistent). Skipped if the file exists.
  init-env.py sample-app   -> sample-app/.env from .env.example, DD_PASSWORD
                              filled in from the DefectDojo initializer logs.
                              Skipped if the file exists with a real password.

Never overwrites an existing, filled-in .env. Standard library only.
"""

import re
import secrets
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def init_deployment():
    target = ROOT / "deployment" / ".env"
    if target.exists():
        print(f"deployment/.env already exists - leaving it untouched")
        return
    text = (ROOT / "deployment" / ".env.example").read_text()
    db_password = secrets.token_hex(24)
    text = text.replace("DD_DATABASE_PASSWORD=CHANGE_ME", f"DD_DATABASE_PASSWORD={db_password}")
    text = text.replace("postgresql://defectdojo:CHANGE_ME@", f"postgresql://defectdojo:{db_password}@")
    text = text.replace("DD_SECRET_KEY=CHANGE_ME", f"DD_SECRET_KEY={secrets.token_urlsafe(48)}")
    text = text.replace("DD_CREDENTIAL_AES_256_KEY=CHANGE_ME",
                        f"DD_CREDENTIAL_AES_256_KEY={secrets.token_urlsafe(48)}")
    leftover = [l for l in text.splitlines() if "CHANGE_ME" in l and not l.lstrip().startswith("#")]
    if leftover:
        sys.exit("deployment/.env.example has a CHANGE_ME this script does not know how to fill")
    target.write_text(text)
    target.chmod(0o600)
    print("Created deployment/.env with freshly generated secrets")


def admin_password_from_logs():
    out = subprocess.run(
        ["docker", "compose", "logs", "--no-color", "initializer"],
        cwd=ROOT / "deployment", capture_output=True, text=True, check=False,
    ).stdout
    found = re.findall(r"Admin password:\s*(\S+)", out)
    return found[-1] if found else None


def init_sample_app():
    target = ROOT / "sample-app" / ".env"
    if target.exists() and "DD_PASSWORD=CHANGE_ME" not in target.read_text():
        print("sample-app/.env already exists with a password - leaving it untouched")
        return
    password = admin_password_from_logs()
    if not password:
        sys.exit("Could not find 'Admin password:' in the initializer logs. Is the stack up "
                 "(make up)? If the initializer logs were pruned, set DD_PASSWORD in "
                 "sample-app/.env by hand.")
    text = (target if target.exists() else ROOT / "sample-app" / ".env.example").read_text()
    target.write_text(text.replace("DD_PASSWORD=CHANGE_ME", f"DD_PASSWORD={password}"))
    target.chmod(0o600)
    print("Wrote sample-app/.env with the admin password from the initializer logs")


if __name__ == "__main__":
    actions = {"deployment": init_deployment, "sample-app": init_sample_app}
    if len(sys.argv) != 2 or sys.argv[1] not in actions:
        sys.exit(f"usage: {sys.argv[0]} {{{'|'.join(actions)}}}")
    actions[sys.argv[1]]()
