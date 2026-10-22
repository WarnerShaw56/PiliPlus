set -eu
mkdir -p /etc/nginx/ssl
bash /opt/acme/acme.sh --install-cert -d 60.204.209.218 --ecc --key-file /etc/nginx/ssl/piliplus.key --fullchain-file /etc/nginx/ssl/piliplus.pem --reloadcmd "systemctl reload nginx"
python3 - <<'PY'
from pathlib import Path
p=Path('/etc/nginx/sites-available/piliplus-ai')
text=p.read_text().replace(' listen 80;', ' listen 443 ssl;\n ssl_certificate /etc/nginx/ssl/piliplus.pem;\n ssl_certificate_key /etc/nginx/ssl/piliplus.key;\n ssl_protocols TLSv1.2 TLSv1.3;')
text=text.replace('server_name 60-204-209-218.sslip.io;', 'server_name 60.204.209.218;')
p.write_text(text)
PY
cat > /etc/systemd/system/piliplus-tls-renew.service <<'EOF'
[Unit]
Description=Renew PiliPlus IP TLS certificate
[Service]
Type=oneshot
ExecStart=/bin/bash /opt/acme/acme.sh --cron --home /root/.acme.sh
EOF
cat > /etc/systemd/system/piliplus-tls-renew.timer <<'EOF'
[Unit]
Description=Check PiliPlus TLS certificate every 12 hours
[Timer]
OnBootSec=15min
OnUnitActiveSec=12h
[Install]
WantedBy=timers.target
EOF
nginx -t
systemctl reload nginx
systemctl daemon-reload
systemctl enable --now piliplus-tls-renew.timer
