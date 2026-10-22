#!/usr/bin/env python3
"""Add (idempotently) a host to the zone-runner's TOTP `exempt` list.

The kluser.me zone puts a TOTP gate in front of every route. That gate is built for
browsers (it renders a form and sets ``__cfx_totp``), so a machine client — the
Apple Watch — is answered 401 on every non-GET request. The fix is not to disable
TOTP: it is to exempt this one host, because the hub enforces its own TOTP on every
request (``X-Watch-TOTP``).

Usage: exempt-host.py <zone-dir> <host> [--remove]
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import sys
import time


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("Erro: faltam argumentos — Solução: exempt-host.py <zone-dir> <host> [--remove]", file=sys.stderr)
        return 2
    zone_dir = pathlib.Path(argv[1])
    host = argv[2]
    remove = "--remove" in argv[3:]

    path = zone_dir / "auth.json"
    if not path.exists():
        print(f"  sem {path.name}: o overlay TOTP não está ligado, nada a fazer")
        return 0

    data = json.loads(path.read_text(encoding="utf-8"))
    exempt = list(data.get("exempt") or [])

    if remove:
        if host not in exempt:
            print(f"  {host} não estava isento")
            return 0
        exempt.remove(host)
    else:
        if host in exempt:
            print(f"  {host} já isento")
            return 0
        exempt.append(host)

    backup = zone_dir / f"auth.json.bak-{time.strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(path, backup)
    data["exempt"] = exempt
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    verb = "removido de" if remove else "adicionado a"
    print(f"  {host} {verb} exempt (hot-reload em 500 ms) · backup: {backup.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
