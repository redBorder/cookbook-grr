#!/usr/bin/env python3
"""Ajusta los instaladores de Windows subidos a GRR (REL_DB).

repack_clients sube a la base de datos de GRR dos binarios por plantilla de
Windows, ambos con extension .exe, aunque con Fleetspeak son MSI:

    windows/installers/GRR_<ver>_amd64.exe
    windows/installers/dbg_GRR_<ver>_amd64.exe

Este script:
  * renombra los .exe de windows/installers a .msi (reescribe la entrada con
    la misma referencia al contenido; no hay que volver a firmar ni a subir),
  * elimina los instaladores de depuracion (dbg_*), salvo KEEP_DBG=1.

Es idempotente. Por defecto NO modifica nada (dry-run): APPLY=1 para aplicar.

    APPLY=1 /opt/grr/venv/bin/python grr_fix_installers.py \\
        --config=/opt/grr/venv/install_data/etc/grr-server.yaml \\
        --secondary_configs=/opt/grr/venv/install_data/etc/server.local.yaml
"""

import os
import posixpath
import sys

APPLY = os.environ.get("APPLY") == "1"
KEEP_DBG = os.environ.get("KEEP_DBG") == "1"

WINDOWS_DIR = "windows/installers"


def plan(paths, keep_dbg=False):
  """Decide que hacer con cada path de binario firmado.

  Devuelve una lista de ("rename", old, new) y ("delete", old, None).
  Solo toca rutas bajo windows/installers.
  """
  actions = []
  for path in sorted(paths):
    if posixpath.dirname(path) != WINDOWS_DIR:
      continue
    base = posixpath.basename(path)
    if base.startswith("dbg_") and not keep_dbg:
      actions.append(("delete", path, None))
    elif base.lower().endswith(".exe"):
      new = posixpath.join(WINDOWS_DIR, base[:-len(".exe")] + ".msi")
      actions.append(("rename", path, new))
  return actions


def main():
  # Los imports de GRR van aqui para poder probar plan() sin GRR instalado.
  from absl import flags
  from grr_response_server import data_store
  from grr_response_server import server_startup

  if not flags.FLAGS.is_parsed():
    flags.FLAGS(sys.argv)
  server_startup.Init()
  db = data_store.REL_DB

  ids = {i.path: i for i in db.ReadIDsForAllSignedBinaries()}
  actions = plan(ids.keys(), keep_dbg=KEEP_DBG)

  print("Modo: %s" % ("APLICAR" if APPLY else "DRY-RUN"))
  if not actions:
    print("Nada que hacer.")
    return

  for action, old, new in actions:
    if action == "delete":
      print("borrar   %s" % old)
      if APPLY:
        db.DeleteSignedBinaryReferences(ids[old])
    else:
      print("renombrar %s -> %s" % (old, new))
      if APPLY:
        references, _ = db.ReadSignedBinaryReferences(ids[old])
        new_id = ids[old].Copy()
        new_id.path = new
        db.WriteSignedBinaryReferences(new_id, references)
        db.DeleteSignedBinaryReferences(ids[old])

  if not APPLY:
    print("Dry-run: no se ha modificado nada. Usa APPLY=1 para aplicar.")


if __name__ == "__main__":
  main()