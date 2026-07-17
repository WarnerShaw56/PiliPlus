# PiliPlus AI recommendation generator

This trusted-server prototype generates the same `schema_version: 1` JSON that
the PiliPlus client can also create locally. The phone only downloads
`feed.json`; Bilibili cookies and the AI key stay on the VPS.

Pipeline:

1. Fetch multiple signed pages from the logged-in Bilibili home recommendation feed and deduplicate them.
2. Discard videos below the configured duration floor, then cheaply shortlist
   the remaining candidates by engagement metadata with a modest long-form bonus.
3. Ask an OpenAI-compatible model to rank metadata in bounded batches.
4. Download Chinese subtitles only for the cross-batch finalists.
5. Ask the model for a final rerank and allow only AI-approved preliminary
   candidates to fill missing final slots, labeled as backups.
6. Atomically replace a static `feed.json` for Nginx or Caddy to serve.

The example configuration fetches up to 800 candidates, rejects anything under
15 minutes, heuristically keeps up to 200, ranks them in batches of 40,
downloads subtitles for up to 40 AI-approved finalists, and publishes up to 8
results. `fill_results` may fill a missing final slot only from candidates that
the model already approved during metadata screening; every such item is
explicitly labeled `备选`. It never uses unrelated high-engagement metadata to
force the feed to a fixed size. Set it to `false` to disable even these screened
backups.

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

The supplied timer runs at 07:30 in `Asia/Shanghai`. The oneshot service has a
15-minute startup timeout and a read-only system sandbox, with write access
limited to `/var/www/piliplus-ai`.

The prototype does not run ASR when subtitles are missing. The reusable next
step is to plug in the audio-download and ASR path from
`jackwener/bilibili-summary` before the final AI ranking stage; that keeps the
expensive path on the VPS and avoids mobile background/runtime limits.
