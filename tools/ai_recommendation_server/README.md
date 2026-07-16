# PiliPlus AI recommendation generator

This trusted-server prototype generates the same `schema_version: 1` JSON that
the PiliPlus client can also create locally. The phone only downloads
`feed.json`; Bilibili cookies and the AI key stay on the VPS.

Pipeline:

1. Fetch the signed, logged-in Bilibili home recommendation feed.
2. Cheaply shortlist candidates by engagement metadata.
3. Download Chinese subtitles where available.
4. Ask an OpenAI-compatible model to score and explain the shortlist.
5. Atomically replace a static `feed.json` for Nginx or Caddy to serve.

## Run once

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
cp config.example.json config.json
cp .env.example .env
set -a; . ./.env; set +a
python generate.py --output public/feed.json
```

Never commit `.env`, `config.json`, or a generated feed containing private
preference text. `redact_preference` defaults to `true` in the example.

Serve `public/feed.json` over HTTPS, then select “从 VPS 拉取已生成 JSON” in
PiliPlus. A long random URL path is the minimum protection for a private feed;
IP allow-listing or authenticated reverse-proxy access is better.

## Daily systemd timer

Copy the directory to `/opt/piliplus-ai`, create a locked-down `piliplus-ai`
user, and make `/var/www/piliplus-ai` writable by that user. Then copy the two
unit files to `/etc/systemd/system/` and run:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now piliplus-ai.timer
sudo systemctl start piliplus-ai.service
journalctl -u piliplus-ai.service -n 100 --no-pager
```

The prototype does not run ASR when subtitles are missing. The reusable next
step is to plug in the audio-download and ASR path from
`jackwener/bilibili-summary` before the final AI ranking stage; that keeps the
expensive path on the VPS and avoids mobile background/runtime limits.
