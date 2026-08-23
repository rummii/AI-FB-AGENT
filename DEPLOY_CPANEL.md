# Deploy the AI Facebook Agent to cPanel

This agent is a **scheduled CLI script** (not a web app), so "deployment" on cPanel means:

1. Upload the code to your account.
2. Make sure a Python 3.10+ interpreter exists (the code uses `@dataclass(slots=True)`).
3. Create a `.env` file with your real API keys/tokens.
4. Test it once manually with a dry run.
5. Set up a **Cron Job** to run it on a schedule.

---

## Step 1 — Upload the code

1. Log in to cPanel.
2. Open **Files → File Manager**, navigate to your home directory (`/home/YOURUSERNAME`).
3. Click **Upload**, select `ai-facebook-agent-deploy.zip`, and upload it.
4. Back in File Manager, right-click the zip → **Extract**. If your Python App root is `/home/USERNAME/fb-agent`, upload the zip into `~/fb-agent/` and extract **in place** (this puts `app/`, `cron_agent.sh`, etc. directly into the app folder).
5. (Optional) If you have SSH, the equivalent is:
   ```bash
   cd ~
   unzip -o ai-facebook-agent-deploy-fixed.zip
   ```
6. **When re-uploading updated code, clear Python's bytecode cache** so the new `.py` files actually run (otherwise the old compiled `.pyc` files can be used and you'll see unchanged behavior/tracebacks):
   ```bash
   find ~/fb-agent/app -name '__pycache__' -type d -exec rm -rf {} +
   ```

> The zip intentionally does **not** contain `.env` (your secrets) or the SQLite history DB.

---

## Step 2 — Verify Python 3.10+ is available

The agent needs **Python 3.10 or newer**.

- **Option A (recommended):** cPanel → **Software → Setup Python App** → **Create Application**.
  Choose Python 3.11 or 3.12, application root `/fb-agent`, application URL any (the URL doesn't matter for a CLI), and create it.
  This gives you a virtualenv at `~/virtualenv/fb-agent/3.11/` whose interpreter is
  `~/virtualenv/fb-agent/3.11/bin/python` — the cron wrapper auto-detects this layout.
- **Option B:** Open **Terminal** (in cPanel, under Advanced, if your host enables it) and run:
  ```bash
  python3 --version
  which -a python3 python3.10 python3.11 python3.12
  ```
  Pick any that reports 3.10+.

> If only Python 3.8/3.9 exists, the agent will crash on startup. Ask your host to enable a newer version or use the Setup Python App feature.

---

## Step 3 — Create the `.env` file

Inside `~/fb-agent/`, create a file named exactly `.env` with your real values.
You can copy your working local `.env` and upload it, or use File Manager → **+ File** → create `.env` and edit it.

Minimum required keys:

```env
AI_PROVIDER=gemini
AI_API_KEY=your_gemini_api_key
AI_MODEL=gemini-flash-latest

NEWS_PROVIDER=newsapi
NEWS_API_KEY=your_newsapi_key
NEWS_LANGUAGE=en
RSS_FEEDS=https://venturebeat.com/ai/feed/,https://openai.com/news/rss.xml,https://www.anthropic.com/news/rss.xml,https://techcrunch.com/category/artificial-intelligence/feed/

FACEBOOK_PAGE_ID=your_page_id
FACEBOOK_PAGE_ACCESS_TOKEN=your_page_access_token

POST_TONE=concise, useful, and founder-friendly
MAX_POST_CHARS=420
DRY_RUN=true

HISTORY_DB_PATH=data/posts.db
```

> Keep `DRY_RUN=true` for the first test. Set it to `false` only after the dry run looks good.

---

## Step 4 — Test manually

Using cPanel **Terminal** (or SSH):

```bash
cd ~/fb-agent
/home/vsmwrurd/virtualenv/fb-agent/3.11/bin/python -m app.main --dry-run --show-articles
```

(Or, with the venv activated: `source ~/virtualenv/fb-agent/3.11/bin/activate && cd ~/fb-agent && python -m app.main --dry-run --show-articles`.)

You should see article titles, a "Selected article" line, and the generated Facebook post.
The post is **not** published because `DRY_RUN=true`.

Once you're happy, edit `.env` and set `DRY_RUN=false`. Then run once more:
```bash
cd ~/fb-agent
/home/vsmwrurd/virtualenv/fb-agent/3.11/bin/python -m app.main
```
If it succeeds, you'll see `INFO Facebook response: {'id': '...'}` and the post will appear on your page.

---

## Step 5 — Schedule it with a Cron Job

cPanel → **Advanced → Cron Jobs** (or **Cron Jobs**).

1. Set an email for cron output (or blank).
2. Common schedule — every 4 hours:
   - Minute: `0`
   - Hour: `*/4`
   - Day: `*`
   - Month: `*`
   - Weekday: `*`
3. Command:
   ```
   /bin/bash /home/YOURUSERNAME/fb-agent/cron_agent.sh
   ```

The wrapper script `cron_agent.sh` changes to the right directory, then picks the best Python 3.10+ interpreter in this order: `AGENT_PYTHON` env var → project `venv` → cPanel virtualenv (`~/virtualenv/fb-agent/3.11/bin/python`) → system python3. All output is appended to `~/fb-agent/data/agent.log`.

> **Before relying on the cron, make sure `DRY_RUN=false` in `~/fb-agent/.env`.** While
> `DRY_RUN=true` the agent only *generates* posts and never publishes them — that is the
> most common reason "nothing is posted".

To adjust frequency, change the `*/4` to `*/2` (every 2 hours), `0 */6` isn't valid — use `0 */6` only in the Hour field style above; simplest alternatives:

- Every 2 hours: `0 */2 * * *`
- Every 6 hours: `0 */6 * * *`
- Twice daily (9am & 9pm): `0 9,21 * * *`

### Posting at exact local times regardless of server timezone

cPanel cron runs in the **server's** timezone (often UTC), so `0 9 * * *` may fire at a
different hour than you expect. Two ways to handle it:

1. **Set the timezone in cPanel** — under **Advanced → Cron Jobs**, some hosts expose a
   timezone dropdown; set it to your local zone and use the cron hours you want.
2. **Or let the app enforce the time** (recommended, works even if you can't change the
   cron timezone). In `~/fb-agent/.env`:
   ```env
   POST_TIMES=9,21                 # hours of the day (0-23) when posts are allowed
   POST_TIMEZONE=America/New_York  # your IANA zone; empty = server local time
   MIN_POST_INTERVAL_HOURS=6       # never post more often than every 6h
   ```
   Then set the cron job to run every few minutes instead of on an exact hour:
   - Minute: `*/5`, Hour: `*`, Day: `*`, Month: `*`, Weekday: `*`
   Every 5 minutes the agent checks whether the current hour is in `POST_TIMES`; outside
   the window it logs `Skipping: current time is ...` and exits without posting. The
   `MIN_POST_INTERVAL_HOURS` guard stops it posting twice inside the same hour.

### Dry runs polluted the history DB — reset it

`--dry-run` no longer records articles as posted, but runs you did *before* this update
may have saved articles to `data/posts.db` that were never actually published. The agent
skips anything already in that DB, so it may find "no unseen articles" and post nothing.
Fix it once on the server:

```bash
cd ~/fb-agent
/home/vsmwrurd/virtualenv/fb-agent/3.11/bin/python -m app.main --clear-history
```

or simply delete `~/fb-agent/data/posts.db` (it is recreated automatically).

---

## Checking logs

- Cron output/logs: `~/fb-agent/data/agent.log`
- The agent also writes a SQLite history DB at `~/fb-agent/data/posts.db` so it never reposts the same article URL.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ModuleNotFoundError: No module named 'app'` | Run as `python -m app.main` from inside `~/fb-agent` (the wrapper already does this). |
| `Cron doesn't seem to run` | Check `data/agent.log`; make sure the script path matches your home dir, and your host's cron runs as your user. |
| `TypeError: ... dataclass ... slots` | Your Python is < 3.10. Use Setup Python App (3.11/3.12) or ask your host. |
| `Facebook credentials are missing` | `FACEBOOK_PAGE_ID` / `FACEBOOK_PAGE_ACCESS_TOKEN` not set in `.env`. |
| `AI request failed: 401` | `AI_API_KEY` is wrong, or the client is hitting the wrong endpoint. The code reads `OPENAI_BASE_URL` / `GEMINI_BASE_URL` (or the `AI_BASE_URL` override) — a `AI_BASE_URL` value is used automatically, but if you use `OPENAI_BASE_URL` make sure it points at your provider (e.g. `https://api.groq.com/openai/v1` for Groq), and `AI_MODEL` is a model that provider supports. |
| Updated code uploaded but behavior/tracebacks unchanged | Stale bytecode cache: run `find ~/fb-agent/app -name '__pycache__' -type d -exec rm -rf {} +` and re-run. |
| `AI request failed: 403 ... error code: 1010` | Cloudflare blocks the default Python-urllib client. The code now sends a proper User-Agent and falls back to `curl` automatically — make sure you've re-uploaded the zip and cleared `__pycache__`. |
| Cron runs but nothing is ever posted | `DRY_RUN` is still `true` in `.env` (set it to `false`). |
| Cron runs but `agent.log` says `Nothing to post this run` | No unseen articles: run `python -m app.main --clear-history` (or delete `data/posts.db`) to reset history polluted by dry runs, and confirm the feeds are returning articles. |
| Cron runs but `agent.log` says `Skipping: current time is ...` | `POST_TIMES` is set and the current hour isn't in it — that's the schedule working as configured. |
| Post appears at the wrong hour | cPanel cron uses the server timezone; set `POST_TIMEZONE` + `POST_TIMES` (see Step 5) or change the cron timezone in cPanel. |
| Post never appears on Facebook | Set `DRY_RUN=false` in `.env` and rerun manually to see the error. |
