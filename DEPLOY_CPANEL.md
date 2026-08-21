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
   unzip ai-facebook-agent-deploy.zip
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

To adjust frequency, change the `*/4` to `*/2` (every 2 hours), `0 */6` isn't valid — use `0 */6` only in the Hour field style above; simplest alternatives:

- Every 2 hours: `0 */2 * * *`
- Every 6 hours: `0 */6 * * *`
- Twice daily (9am & 9pm): `0 9,21 * * *`

---

## Checking logs

- Cron output/logs: `~/fb-agent/data/agent.log`
- The agent also writes a SQLite history DB at `~/fb-agent/data/posts.db` so it never reposts the same article URL.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ModuleNotFoundError: No module named 'app'` | Run as `python -m app.main` from inside `~/fb-agent` (the wrapper already does this). |
| `TypeError: ... dataclass ... slots` | Your Python is < 3.10. Use Setup Python App (3.11/3.12) or ask your host. |
| `Facebook credentials are missing` | `FACEBOOK_PAGE_ID` / `FACEBOOK_PAGE_ACCESS_TOKEN` not set in `.env`. |
| `AI request failed: 401` | `AI_API_KEY` is wrong, or `AI_MODEL` isn't available for your key. |
| `Cron doesn't seem to run` | Check `data/agent.log`; make sure the script path matches your home dir, and your host's cron runs as your user. |
| Post never appears on Facebook | Set `DRY_RUN=false` in `.env` and rerun manually to see the error. |
