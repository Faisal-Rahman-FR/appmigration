#!/bin/bash
# Direct mode: serve the Windows handoff package to the Windows VM over TLS on the private network, then stop (handoff-stop.sh).
# Reachable only from the Windows VM's private address (NSG rule DemoHandoffFromWindows) and only under an unguessable path.
set -euo pipefail
umask 077
trap 'echo "DEMO_STAGE_FAILED: handoff server could not start; inspect: journalctl -u idpdemo-handoff" >&2' ERR
: "${DEMO_DOMAIN:?}" "${DEMO_HANDOFF_TOKEN:?}"
test "${#DEMO_HANDOFF_TOKEN}" -ge 32
tls=/srv/idpdemo/source/samples/.local/tls
test -s /srv/idpdemo/windows-package.tgz
test -s /var/tmp/idpdemo-upload/student-bin.zip
test -s "$tls/gateway.crt"
systemctl stop idpdemo-handoff 2>/dev/null || true
systemctl reset-failed idpdemo-handoff 2>/dev/null || true
rm -rf /srv/idpdemo/handoff
mkdir -p "/srv/idpdemo/handoff/$DEMO_HANDOFF_TOKEN"
cp /srv/idpdemo/windows-package.tgz "/srv/idpdemo/handoff/$DEMO_HANDOFF_TOKEN/windows-package.tgz"
cp /var/tmp/idpdemo-upload/student-bin.zip "/srv/idpdemo/handoff/$DEMO_HANDOFF_TOKEN/student-bin.zip"
cat > /srv/idpdemo/handoff-server.py <<'PY'
import functools, http.server, ssl, sys

token, root, cert, key = sys.argv[1:5]

class Handler(http.server.SimpleHTTPRequestHandler):
    def _allowed(self):
        return self.path.startswith('/' + token + '/') and '..' not in self.path

    def do_GET(self):
        if self._allowed():
            super().do_GET()
        else:
            self.send_error(404)

    def do_HEAD(self):
        if self._allowed():
            super().do_HEAD()
        else:
            self.send_error(404)

    def list_directory(self, path):
        self.send_error(404)
        return None

    def log_message(self, *args):
        pass  # request lines contain the secret path

server = http.server.ThreadingHTTPServer(('0.0.0.0', 8443), functools.partial(Handler, directory=root))
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
systemd-run --quiet --unit=idpdemo-handoff --collect --property=RuntimeMaxSec=3600 \
  /usr/bin/python3 /srv/idpdemo/handoff-server.py "$DEMO_HANDOFF_TOKEN" /srv/idpdemo/handoff "$tls/gateway.crt" "$tls/gateway.key"
# Self-test with normal certificate verification against the public name, exactly as the Windows VM will connect.
ok=0
for attempt in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "idp.$DEMO_DOMAIN:8443:127.0.0.1" \
    "https://idp.$DEMO_DOMAIN:8443/$DEMO_HANDOFF_TOKEN/windows-package.tgz" || true)
  if test "$code" = 200; then ok=1; break; fi
  sleep 2
done
test "$ok" = 1
wrong=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "idp.$DEMO_DOMAIN:8443:127.0.0.1" "https://idp.$DEMO_DOMAIN:8443/wrong/windows-package.tgz" || true)
test "$wrong" = 404
echo 'DEMO_STAGE_OK: private handoff server is up (TLS verified, wrong path rejected).'
