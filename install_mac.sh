#!/bin/bash
set -euo pipefail

echo "=================================================="
echo "  EarendelX POS - Instalador y Conector macOS"
echo "=================================================="
echo ""

APP_DIR="$HOME/.earendelx"
mkdir -p "$APP_DIR"

# 1. Desbloquear apps descargadas (quitar cuarentena de Apple Gatekeeper)
echo "[1/4] Desbloqueando aplicaciones descargadas de EarendelX..."
for target in \
  "$HOME/Downloads/EarendelX.app" \
  "/Applications/EarendelX.app" \
  "$HOME/Downloads/Earendel X POS.app" \
  "/Applications/Earendel X POS.app" \
  "$HOME/Desktop/Earendel X POS.app"; do
  if [ -e "$target" ]; then
    xattr -cr "$target" 2>/dev/null || true
    echo "  ✓ Cuarentena removida: $target"
  fi
done

if [ -d "$HOME/Downloads/EarendelX.app" ] && [ ! -d "/Applications/EarendelX.app" ]; then
  echo "  → Copiando EarendelX.app a /Applications..."
  if ditto "$HOME/Downloads/EarendelX.app" "/Applications/EarendelX.app" 2>/dev/null; then
    xattr -cr "/Applications/EarendelX.app" 2>/dev/null || true
    codesign --force --deep --sign - "/Applications/EarendelX.app" 2>/dev/null || true
    echo "  ✓ Instalado y firmado en /Applications/EarendelX.app"
  else
    codesign --force --deep --sign - "$HOME/Downloads/EarendelX.app" 2>/dev/null || true
    echo "  ✓ Firmado en $HOME/Downloads/EarendelX.app"
  fi
elif [ -d "/Applications/EarendelX.app" ]; then
  codesign --force --deep --sign - "/Applications/EarendelX.app" 2>/dev/null || true
fi

# 2. Instalar servicio ligero nativo de impresión local (usa /usr/bin/python3 + CUPS)
echo "[2/4] Instalando puente de impresión local en 127.0.0.1:17864..."
BRIDGE_SCRIPT="$APP_DIR/print_bridge.py"

cat <<'PYEOF' > "$BRIDGE_SCRIPT"
#!/usr/bin/env python3
import base64
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = 17864
HOST = "127.0.0.1"
ALLOWED_ORIGINS = {
    "https://earendelx.com",
    "https://www.earendelx.com",
    "https://earendel-x.pages.dev",
    "http://localhost",
    "http://127.0.0.1",
}
APP_DIR = os.path.expanduser("~/.earendelx")
TOKEN_FILE = os.path.join(APP_DIR, "bridge_token")


def get_token() -> str:
    os.makedirs(APP_DIR, exist_ok=True)
    if os.path.exists(TOKEN_FILE):
        try:
            with open(TOKEN_FILE, "r", encoding="utf-8") as f:
                val = f.read().strip()
                if len(val) >= 32:
                    return val
        except OSError:
            pass
    token = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode("ascii")
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        f.write(token)
    try:
        os.chmod(TOKEN_FILE, 0o600)
    except OSError:
        pass
    return token


def is_origin_allowed(origin: str) -> bool:
    if not origin:
        return False
    if origin in ALLOWED_ORIGINS:
        return True
    parsed = urlparse(origin)
    if parsed.hostname in ("localhost", "127.0.0.1"):
        return True
    return False


def list_cups_printers():
    printers = []
    default_printer = None

    try:
        res_def = subprocess.run(
            ["/usr/bin/lpstat", "-d"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if res_def.returncode == 0 and res_def.stdout:
            # Matches English ("system default destination: X") or Spanish ("destino predeterminado del sistema: X")
            m = re.search(r":\s*(.+)$", res_def.stdout.strip())
            if m:
                default_printer = m.group(1).strip()
    except Exception:
        pass

    try:
        res = subprocess.run(
            ["/usr/bin/lpstat", "-p"],
            capture_output=True,
            text=True,
            timeout=8,
        )
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # "printer <queue> is idle..." or Spanish "la impresora <queue> ..."
            m = re.match(r"^(?:printer|la impresora)\s+([^\s]+)\s+", line, re.IGNORECASE)
            if m:
                queue = m.group(1).strip()
                if not any(p["url"] == queue for p in printers):
                    display_name = queue.replace("_", " ")
                    printers.append({
                        "name": display_name,
                        "url": queue,
                        "default": queue == default_printer,
                    })
    except Exception:
        pass

    return printers


class BridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def _set_cors(self, origin: str):
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        if origin and is_origin_allowed(origin):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Private-Network", "true")

    def _send_json(self, status: int, payload: dict, origin: str = ""):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self._set_cors(origin)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _check_origin(self):
        origin = self.headers.get("Origin", "")
        if not is_origin_allowed(origin):
            self._send_json(403, {"error": "Origen no autorizado"}, origin)
            return None
        return origin

    def do_OPTIONS(self):
        origin = self._check_origin()
        if origin is None:
            return
        self.send_response(204)
        self._set_cors(origin)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        origin = self._check_origin()
        if origin is None:
            return

        path = urlparse(self.path).path
        if path == "/health":
            self._send_json(200, {"ready": True, "platform": "macos", "raw": True}, origin)
            return

        if path == "/pair":
            self._send_json(
                200,
                {"ready": True, "token": get_token(), "platform": "macos", "raw": True},
                origin,
            )
            return

        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {get_token()}":
            self._send_json(401, {"error": "Código de vinculación incorrecto"}, origin)
            return

        if path == "/printers":
            printers = list_cups_printers()
            self._send_json(200, {"printers": printers, "raw": True}, origin)
            return

        self._send_json(404, {"error": "Ruta no encontrada"}, origin)

    def do_POST(self):
        origin = self._check_origin()
        if origin is None:
            return

        path = urlparse(self.path).path
        if path == "/pair":
            self._send_json(
                200,
                {"ready": True, "token": get_token(), "platform": "macos", "raw": True},
                origin,
            )
            return

        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {get_token()}":
            self._send_json(401, {"error": "Código de vinculación incorrecto"}, origin)
            return

        if path != "/print":
            self._send_json(404, {"error": "Ruta no encontrada"}, origin)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": "Content-Length inválido"}, origin)
            return

        if length <= 0 or length > 6 * 1024 * 1024:
            self._send_json(413, {"error": "Ticket inválido o demasiado grande"}, origin)
            return

        try:
            raw_body = self.rfile.read(length)
            data = json.loads(raw_body.decode("utf-8"))
        except Exception as exc:
            self._send_json(400, {"error": f"JSON inválido: {exc}"}, origin)
            return

        printer_url = str(data.get("printer") or "").strip()
        fmt = str(data.get("format") or "").strip().lower()
        b64_data = str(data.get("data") or "")

        printers = list_cups_printers()
        if not any(p["url"] == printer_url for p in printers):
            self._send_json(404, {"error": "Impresora no disponible"}, origin)
            return

        try:
            raw_bytes = base64.b64decode(b64_data)
        except Exception:
            self._send_json(400, {"error": "Datos base64 inválidos"}, origin)
            return

        if not raw_bytes or len(raw_bytes) > 4 * 1024 * 1024:
            self._send_json(400, {"error": "Ticket vacío o excede el límite"}, origin)
            return

        if fmt not in ("escpos", "pdf"):
            self._send_json(400, {"error": "Formato no compatible"}, origin)
            return

        suffix = ".bin" if fmt == "escpos" else ".pdf"
        tmp_path = None
        try:
            with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
                tmp.write(raw_bytes)
                tmp_path = tmp.name

            cmd = ["/usr/bin/lp", "-d", printer_url]
            if fmt == "escpos":
                cmd.extend(["-o", "raw"])
            cmd.append(tmp_path)

            res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if res.returncode != 0:
                err_msg = (res.stderr or res.stdout or "Error de CUPS").strip()
                self._send_json(500, {"error": f"No se pudo imprimir: {err_msg}"}, origin)
                return

            self._send_json(200, {"printed": True}, origin)
        except Exception as exc:
            self._send_json(500, {"error": f"Error al imprimir: {exc}"}, origin)
        finally:
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass


def main():
    get_token()
    server = ThreadingHTTPServer((HOST, PORT), BridgeHandler)

    def handle_sig(signum, frame):
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_sig)
    signal.signal(signal.SIGINT, handle_sig)
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

chmod +x "$BRIDGE_SCRIPT"

# 3. Registrar LaunchAgent si el puerto no está ocupado por otra instancia (o recargar el nuestro)
echo "[3/4] Activando servicio en segundo plano (LaunchAgent)..."
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.earendelx.printbridge.plist"
mkdir -p "$PLIST_DIR"

PYTHON_BIN="/usr/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [ -z "$PYTHON_BIN" ]; then
  echo "  ⚠ No se encontró python3 para el conector ligero; usa EarendelX.app desbloqueado."
else
  PORT_IN_USE=0
  if lsof -nP -iTCP:17864 -sTCP:LISTEN >/dev/null 2>&1; then
    # Si el que escucha es otro proceso (e.g. EarendelX.app), no lo pisamos
    if ! pgrep -f "$BRIDGE_SCRIPT" >/dev/null 2>&1; then
      PORT_IN_USE=1
    fi
  fi

  cat <<PLISTEOF > "$PLIST_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.earendelx.printbridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PYTHON_BIN}</string>
    <string>${BRIDGE_SCRIPT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${APP_DIR}/bridge.log</string>
  <key>StandardErrorPath</key>
  <string>${APP_DIR}/bridge.err.log</string>
</dict>
</plist>
PLISTEOF

  if [ "$PORT_IN_USE" -eq 0 ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load -w "$PLIST_PATH" 2>/dev/null || true
    sleep 1
    if lsof -nP -iTCP:17864 -sTCP:LISTEN >/dev/null 2>&1; then
      echo "  ✓ Servicio EarendelX Print Bridge activo en http://127.0.0.1:17864"
    else
      echo "  ⚠ No se pudo verificar el puerto 17864 automáticamente; revisa $APP_DIR/bridge.err.log"
    fi
  else
    echo "  ✓ El puerto 17864 ya está activo por otra instancia de EarendelX; LaunchAgent registrado para futuros reinicios."
  fi
fi

# 4. Crear acceso directo "Earendel X POS.app" sin cuarentena para Chrome Kiosk
echo "[4/4] Creando acceso directo de Chrome Impresión Rápida (sin avisos de seguridad)..."
create_kiosk_app() {
  local DEST_APP="$1"
  local TEMP_SCRIPT
  TEMP_SCRIPT="$(mktemp /tmp/earendel_pos_XXXX.applescript)"
  cat <<'ASEOF' > "$TEMP_SCRIPT"
do shell script "open -a 'Google Chrome' --args --kiosk-printing --app=https://earendelx.com"
ASEOF
  rm -rf "$DEST_APP"
  if osacompile -o "$DEST_APP" "$TEMP_SCRIPT" >/dev/null 2>&1; then
    if [ -d "/Applications/EarendelX.app/Contents/Resources" ] && [ -f "/Applications/EarendelX.app/Contents/Resources/AppIcon.icns" ]; then
      cp "/Applications/EarendelX.app/Contents/Resources/AppIcon.icns" "$DEST_APP/Contents/Resources/applet.icns" 2>/dev/null || true
    fi
    xattr -cr "$DEST_APP" 2>/dev/null || true
    codesign --force --deep --sign - "$DEST_APP" 2>/dev/null || true
    echo "  ✓ Acceso directo creado: $DEST_APP"
  fi
  rm -f "$TEMP_SCRIPT"
}

create_kiosk_app "$HOME/Desktop/Earendel X POS.app" || true
if [ -w "/Applications" ]; then
  create_kiosk_app "/Applications/Earendel X POS.app" || true
fi

echo ""
echo "=================================================="
echo "  ✓ Instalación completada en macOS"
echo "  Vuelve a earendelx.com en Ajustes → Impresoras"
echo "  y pulsa \"COMPROBAR SI YA ESTÁ ABIERTO\"."
echo "=================================================="
