# ntfy topics, tokens, and the phone

## The topics

| Topic | Source | Typical priority |
|---|---|---|
| `mail` | Office IMAP watcher | 3 (default) |
| `mattermost` | Office Mattermost watcher | 3, or 4 for a mention |
| `rss` | Miniflux via the relay | 3 |
| `syslog` | rsyslog, severity ≤ warning | 4 |
| `site-changes` | changedetection.io | 3 |
| `system` | healthchecks.io — a watcher went quiet | 4–5 |
| `backup` | The daily backup job, on failure only | 5 |

## Why the topics are locked down

Topic names are not secrets — they are guessable, and on a public ntfy server
anyone who guesses one can read it. These topics carry mail subjects, work chat
and infrastructure alerts, so the server runs with `auth-default-access: deny-all`
and nothing is readable or writable without credentials.

Two accounts exist, with deliberately asymmetric access:

- **`phone`** — read-only on every topic. This is what your phone logs in as. If
  the phone is lost, whoever has it can read notifications but cannot forge them.
- **`publisher`** — write-only on every topic. Everything that sends
  notifications authenticates as this account, using its own token. A publisher
  token that leaks from, say, the office PC cannot be used to read back your mail.

Each source gets its own token (`NTFY_TOKEN_MAIL`, `NTFY_TOKEN_MATTERMOST`, …) so
any single one can be revoked without touching the others.

## Setting up the Android app

1. Install **ntfy** from F-Droid or the Play Store.
2. **Settings → General → Default server**: `https://ntfy.example.com`
   (your `NTFY_DOMAIN`).
3. **Settings → General → Manage users → Add user**:
   - Username: `phone`
   - Password: the value of `NTFY_PHONE_PASSWORD` in
     `/etc/notification-hub/hub.env`
4. Subscribe to each topic: **+ → Subscribe to topic**, enter the name, and pick
   your server. Repeat for all seven.
5. Per-topic settings are worth adjusting once you have live traffic — `syslog`
   and `system` deserve a louder sound than `rss`.

### Battery

ntfy holds one long-lived connection to your server. Exclude it from battery
optimisation (**Settings → Apps → ntfy → Battery → Unrestricted**), or Android
will kill the connection and notifications will arrive in unpredictable batches.

HAProxy is already configured with a 12-hour timeout on ntfy's backend for the
same reason — the default 60 seconds would sever the subscription every minute.

## Reading the credentials back

```bash
sudo grep -E '^NTFY_(PHONE_PASSWORD|TOKEN_)' /etc/notification-hub/hub.env
```

## Testing a topic

```bash
source /etc/notification-hub/hub.env

# Should arrive on the phone.
curl -H "Authorization: Bearer $NTFY_TOKEN_MAIL" \
     -H "Content-Type: application/json" \
     -d '{"topic":"mail","title":"Test","message":"Hello from the VPS"}' \
     "$NTFY_URL"

# Should return 403 — the topics are not publicly readable.
curl -s -o /dev/null -w '%{http_code}\n' "$NTFY_URL/mail/json?poll=1"
```

## Adding or revoking access

```bash
# A new token for a new source
sudo ntfy token add --expires=never --label=NTFY_TOKEN_NEWTHING publisher

# List and revoke
sudo ntfy token list publisher
sudo ntfy token remove publisher tk_xxxxxxxx

# Change the phone's password
sudo ntfy user change-pass phone
```

Tokens and ACLs live in the shared PostgreSQL `ntfy` database, so they are
included in the daily backup.
