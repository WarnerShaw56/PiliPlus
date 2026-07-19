# PiliPlus AI recommendation generator

This trusted-server prototype generates the same backward-compatible
`schema_version: 1` JSON that the PiliPlus client can also create locally. The
phone downloads `feed.json` and manages preference groups through a private
loopback API exposed only below the secret feed URL. Bilibili cookies and the AI
key stay on the VPS.

Pipeline:

1. Load up to 12 independent preference groups.
2. For each group, fetch the logged-in Bilibili home recommendation feed, Bilibili
   search results, or a deduplicated hybrid of both.
3. Rotate explicit search queries, sort modes, and secondary result pages by
   group and date. Never append random garbage to search terms.
4. Prefer videos not recommended to that group during the configured history
   window, then enforce its duration floor and metadata shortlist.
5. Ask an OpenAI-compatible model to rank metadata in bounded batches.
6. Download Chinese subtitles only for AI-approved finalists.
7. Rerank each group independently and atomically replace `feed.json`.

The example configuration fetches up to 2,000 candidates, rejects anything under
15 minutes, heuristically keeps up to 400, ranks them in batches of 40,
downloads subtitles for up to 60 AI-approved finalists, and publishes up to 8
results per group. `fill_results` may fill a missing final slot only from candidates that
the model already approved during metadata screening; every such item is
explicitly labeled `备选`. It never uses unrelated high-engagement metadata to
force the feed to a fixed size. Set it to `false` to disable even these screened
backups.

The top-level `items` array remains a score-sorted, deduplicated compatibility
view for older PiliPlus builds. New clients use the additional `groups` array.

## Preference group management API

`server.py` binds to `127.0.0.1:8787` through
`piliplus-ai-api.service`. Put it behind the same unguessable Nginx path as the
feed:

```nginx
location /ai/SECRET/api/ {
    proxy_pass http://127.0.0.1:8787/;
    proxy_set_header Host $host;
}
```

The API supports:

- `GET /groups`
- `POST /groups/expand` to turn a short intent into an editable scoring prompt
  and explicit search queries
- `POST /groups`, `PUT /groups/{id}`, and `DELETE /groups/{id}`
- `POST /generate` and `GET /status`

The secret URL is the authentication boundary for this single-user prototype.
Do not expose port 8787 publicly. For a shared deployment, add real
authentication and per-user configuration before use.

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

Never commit `.env`, `config.json`, `history.json`, or a generated feed
containing private preference text. `redact_preference` defaults to `true` in
the example. Store mutable `config.json` and `history.json` under
`/var/lib/piliplus-ai`; keep executable code under read-only
`/opt/piliplus-ai`.

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
two-hour upper bound for multi-group runs. Both services use the shared
`/var/lib/piliplus-ai/generation.lock`, so the lock still coordinates a manual
API run with the timer even though each service has a private `/tmp`. Its
read-only system sandbox grants write access only to the state and feed
directories.
Enable the management API with:

```bash
sudo systemctl enable --now piliplus-ai-api.service
```

The prototype does not run ASR when subtitles are missing. The reusable next
step is to plug in the audio-download and ASR path from
`jackwener/bilibili-summary` before the final AI ranking stage; that keeps the
expensive path on the VPS and avoids mobile background/runtime limits.
