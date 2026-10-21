set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p /opt/piliplus-ai /var/lib/piliplus-ai /var/www/piliplus-ai
id piliplus-ai >/dev/null 2>&1 || useradd --system --home-dir /var/lib/piliplus-ai --shell /usr/sbin/nologin piliplus-ai
python3 -m venv /opt/piliplus-ai/.venv
/opt/piliplus-ai/.venv/bin/pip install -q -i https://mirrors.aliyun.com/pypi/simple -r "$source_dir/requirements.txt"
cd "$source_dir"
/opt/piliplus-ai/.venv/bin/python checks.py
/opt/piliplus-ai/.venv/bin/python server_checks.py
if [ "$source_dir" != /opt/piliplus-ai ]; then
  cp ./*.py requirements.txt config.example.json ./*.service ./*.timer /opt/piliplus-ai/
fi
cd /opt/piliplus-ai
test -s /var/lib/piliplus-ai/config.json || cp config.example.json /var/lib/piliplus-ai/config.json
if ! test -s .env; then
  printf 'BILI_COOKIE=\nAI_BASE_URL=\nAI_API_KEY=\nAI_MODEL=\n' > .env
fi
chown root:piliplus-ai .env
chmod 640 .env
chown -R piliplus-ai:piliplus-ai /var/lib/piliplus-ai /var/www/piliplus-ai
chmod 750 /var/lib/piliplus-ai
chmod 755 /var/www/piliplus-ai
cp piliplus-ai*.service piliplus-ai.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now piliplus-ai-api.service piliplus-ai.timer
systemctl restart piliplus-ai-api.service
python3 - <<'PY'
import pathlib,secrets
path=pathlib.Path('/var/lib/piliplus-ai/feed-path')
if not path.exists():
    path.write_text(secrets.token_urlsafe(32))
path.chmod(0o600)
secret=path.read_text().strip()
config="""server {
 listen 80;
 server_name 60-204-209-218.sslip.io;
 access_log off;
 location / { return 404; }
 location /ai/SECRET/api/ {
  proxy_pass http://127.0.0.1:8787/;
  proxy_read_timeout 180s;
  client_max_body_size 64k;
 }
 location = /ai/SECRET/feed.json {
  alias /var/www/piliplus-ai/feed.json;
  default_type application/json;
  add_header Cache-Control "no-store";
 }
}
""".replace('SECRET',secret)
nginx_path = pathlib.Path('/etc/nginx/sites-available/piliplus-ai')
if not nginx_path.exists():
    nginx_path.write_text(config)
PY
ln -sf /etc/nginx/sites-available/piliplus-ai /etc/nginx/sites-enabled/piliplus-ai
nginx -t
systemctl enable --now nginx
systemctl reload nginx
curl --retry 10 --retry-connrefused --retry-delay 1 -fsS http://127.0.0.1:8787/health
