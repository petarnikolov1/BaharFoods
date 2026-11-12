# Bahar Foods — how this repo is worked on

The owner (petarnikolov1) builds this site only by prompting Claude. Claude makes the change, tests it,
puts it live, and asks before touching the database.

## What lives where
- `public/index.html` — the whole site: customer menu and ordering, and the staff area at `/#admin`
  (inline CSS and JS, the logo embedded as base64, about 190 KB). Customer texts are in Bulgarian.
- `supabase/migrations/NNN_name.sql` — every database change, numbered in the order it was applied.
- `wrangler.jsonc` — tells Cloudflare to publish only `public/` (never the notes or the SQL).
- Live site: Cloudflare Worker `baharfoods` (Workers Builds, connected to this repo). Every push to `main`
  redeploys it in a minute or two, and Cloudflare posts a check run on the commit.
  Address: https://baharfoods.95cwm7hk47.workers.dev (staff: add `#admin`). The shell can't reach it; check it with WebFetch.
- Database: Supabase project ref `nflhpskibjwpgnufnbod` (https://nflhpskibjwpgnufnbod.supabase.co).
  Claude reaches it only through the Supabase connector (`mcp__Supabase__*`); the shell cannot reach supabase.co.
  The connector reaches one Supabase organization at a time. If `get_project` says "You do not have permission",
  ask the owner to reconnect it (claude.ai › Settings › Connectors › Supabase) and pick the Bahar Foods organization.
- `SUPABASE_URL` / `SUPABASE_ANON_KEY` near the top of the script in `public/index.html` hold the project URL and the
  publishable key. Both are public by design.

## Every change
1. **Make and test it.** Page changes: run the page in headless Chrome (Playwright) at phone and desktop width;
   demo mode (empty keys) runs fully in the browser, so test there. SQL: on a fresh local Postgres, run every file
   in `supabase/migrations` in order, then the new one; re-run it to be sure it is safe twice.
2. **Database change?** Write `supabase/migrations/<next number>_<snake_name>.sql`. Tell the owner in plain words
   what it changes and ask with AskUserQuestion ("Apply to the database" / "Not yet"). Only after a yes:
   `apply_migration` with name = the file name without `.sql`, then `get_advisors` (security) and fix anything new.
   Apply the database part **before** pushing the site that needs it. Keep changes compatible with the site that is
   live right now: add, don't rename or drop; drop old things in a later migration once nothing uses them.
3. **Put it live straight away** (the owner chose this): commit on `main` with a short plain-English message,
   `git fetch origin main`, rebase if `main` moved, `git push origin HEAD:main`. Never force-push.
4. **Check it:** before pushing, write today's date and a few words about the change into `public/version.txt`.
   After the push, `git ls-remote origin main` must equal `git rev-parse HEAD`; then the Cloudflare check run on the
   commit (`gh api repos/petarnikolov1/BaharFoods/commits/<sha>/check-runs`) should succeed, and WebFetch of
   `<live address>/version.txt` should show the new line (WebFetch drops scripts, so the page itself can't prove it).
5. **Report** in one or two lines with the commit link `https://github.com/petarnikolov1/BaharFoods/commit/<sha>`.

## Never
- Never commit emails, passwords, the database password, the secret/service-role key, or Telegram tokens.
  **The repo is public.**
- Staff logins: add an email with `execute_sql`:
  `insert into public.admin_emails (email) values ('…') on conflict do nothing;` (delete the row to remove someone).
  The person creates their own login in Supabase › Authentication › Users › Add user (tick "Auto Confirm User").
  Never put staff emails in a migration file.
- Dishes, prices, today's menu, settings, logo and orders are the restaurant's live data, changed in the admin.
  Don't overwrite them from migrations, and never delete orders or dishes in bulk unless the owner says so.

## Security report: expected findings
`get_advisors` (security) always lists these on purpose; don't "fix" them:
- `place_order` and `track_order` callable without signing in: they are how customers order and follow an order.
- `is_admin` callable: the row level security rules call it for every visitor; it only says whether the caller is staff.
- `admin_emails` and `private_config` have row level security with no policies: nobody outside the database may read them.

## What has been applied
Compare `list_migrations` on the project with the files in `supabase/migrations`.
