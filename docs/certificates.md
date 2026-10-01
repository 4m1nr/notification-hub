# Certificates: single, multi-name and wildcard

Every certificate on this box is issued with `issue-cert.sh`, renewed by
`cert-renew-check.timer`, copied to its consumers by `distribute-certs.sh` and
applied at `CERT_RESTART_TIME`. That pipeline is the same for all three kinds
below; what differs is how Let's Encrypt checks that you control the names.

| Kind | Example | Validation | Extra setup |
|---|---|---|---|
| Single name | `ntfy.example.com` | HTTP-01, through HAProxy on :80 | none |
| Multi-name (SAN) | `ntfy.example.com rss.example.com` | HTTP-01 for every name | none |
| Wildcard | `*.example.com` | **DNS-01** only — Let's Encrypt's rule | a DNS API token, once |

DNS-01 also suits names that do not point at this VPS (internal hosts, or a
domain served elsewhere): pass `--dns` and no HTTP request is ever made.

## Commands

```bash
B=/opt/notification-hub/bin

sudo $B/issue-cert.sh ntfy.example.com                        # single
sudo $B/issue-cert.sh ntfy.example.com rss.example.com        # multi-name, lineage "ntfy.example.com"
sudo $B/issue-cert.sh '*.example.com' example.com             # wildcard + apex, lineage "example.com"
sudo $B/issue-cert.sh --cert-name hub ntfy.example.com rss.example.com   # choose the lineage name
sudo $B/issue-cert.sh --dns internal.example.com              # DNS-01 without a wildcard

sudo $B/issue-cert.sh --list            # lineages, names, challenge, days left, in domains.map?
sudo $B/issue-cert.sh --remove <lineage>
```

**Always quote a wildcard** (`'*.example.com'`). Unquoted, the shell may expand
`*` against files in the current directory.

The **lineage** is certbot's name for a certificate, and it is what goes in the
first column of `/etc/notification-hub/domains.map`. It is the first name given,
with any leading `*.` removed — so `*.example.com` becomes `example.com` — or
whatever `--cert-name` says. `--list` shows it if you are unsure. Never put a
`*` in `domains.map`; `distribute-certs.sh` refuses it.

A wildcard covers exactly one label: `*.example.com` matches `ntfy.example.com`
but neither `example.com` nor `a.b.example.com`. Add the apex as a second name
if you need it, as above.

## One-time setup for wildcards (DNS-01)

### 1. Create a DNS API credential

certbot creates a `_acme-challenge` TXT record through your DNS provider's API
and deletes it afterwards, on every issuance and every renewal. It needs a
credential that can do that — and, ideally, nothing else.

**Cloudflare** (recommended; the hub already supports Cloudflare-proxied
domains, and DNS-01 works the same whether a record is proxied or not):

1. Cloudflare dashboard → *My Profile* → *API Tokens* → *Create Token* →
   *Edit zone DNS* template.
2. Permissions: **Zone → DNS → Edit** (the template's default). Zone
   resources: **Include → Specific zone → example.com**. Do not use the
   Global API Key — it can do anything to your whole account.
3. Optionally restrict *Client IP Address Filtering* to this VPS's address.
4. Copy the token; it is shown once.

Other providers: install the matching certbot plugin and read its docs for the
credential format — `digitalocean`, `linode`, `ovh`, `google`, `rfc2136` (your
own BIND/Knot via TSIG), `route53` (uses the AWS credential chain, no file),
and more. On Ubuntu/Debian the package is `python3-certbot-dns-<plugin>`, which
`70-certs.sh` installs for you.

### 2. Store it on the VPS

```bash
sudo install -d -m 0700 /etc/letsencrypt/dns
sudo install -m 0600 /dev/null /etc/letsencrypt/dns/cloudflare.ini
sudo "${EDITOR:-vi}" /etc/letsencrypt/dns/cloudflare.ini
```

Contents for Cloudflare:

```ini
dns_cloudflare_api_token = <the token>
```

Keep it at this path for the life of the certificate: certbot records the path
in the lineage's renewal config and reads it again on every renewal. The file
must be root-only (`0600`); `issue-cert.sh` and `70-certs.sh` enforce that.

### 3. Tell the hub, and install the plugin

In `/etc/notification-hub/hub.env`:

```bash
ACME_DNS_PLUGIN=cloudflare
# Only if you stored the credential somewhere other than /etc/letsencrypt/dns/<plugin>.ini:
#ACME_DNS_CREDENTIALS=/etc/letsencrypt/dns/cloudflare.ini
# Only if validation fails because the TXT record had not propagated yet:
#ACME_DNS_PROPAGATION_SECONDS=60
```

then:

```bash
sudo ./bootstrap.sh 70-certs.sh      # installs python3-certbot-dns-cloudflare
```

### 4. Check DNS CAA records

If your zone has CAA records, one must allow `letsencrypt.org`. For wildcards
specifically, an `issuewild` record overrides `issue` — if one exists it must
name `letsencrypt.org` too. No CAA records at all means any CA may issue.

```bash
dig +short CAA example.com
```

## Issuing a wildcard and using it

```bash
# 1. Issue (needs no DNS record for the names themselves, only the API token).
sudo /opt/notification-hub/bin/issue-cert.sh '*.example.com' example.com

# 2. Tell the distributor where it goes — lineage "example.com".
sudo "${EDITOR:-vi}" /etc/notification-hub/domains.map
```

```
# domain       dest                         owner:group    format  service
example.com    /etc/certs/proxy/wildcard    root:haproxy   both    haproxy
```

```bash
# 3. Distribute and apply now rather than at CERT_RESTART_TIME.
sudo /opt/notification-hub/bin/distribute-certs.sh
sudo /opt/notification-hub/bin/apply-pending-restarts.sh
```

If you add the `domains.map` line *before* issuing, step 3 happens
automatically (the reload is still queued for `CERT_RESTART_TIME`).

**One certificate, several consumers.** A lineage may appear on several lines
of `domains.map` — for instance the wildcard served by HAProxy *and* copied to a
tunnel service:

```
example.com    /etc/certs/proxy/wildcard    root:haproxy   both    haproxy
example.com    /etc/certs/tunnel/wildcard   root:tunnel    split   tunnel
```

Each consumer gets its own copy with its own ownership, and each gets its
restart queued on renewal. The renewal checker renews the lineage once.

**HAProxy and overlapping certificates.** HAProxy loads every PEM in
`/etc/certs/proxy/combined/` and picks by SNI, preferring an exact name over a
wildcard. So you can replace the per-domain hub certificates with one wildcard,
or keep both — an exact certificate keeps winning for its own name. To retire
the per-domain ones after switching, see *Removing a certificate*.

`passthrough.sh` recognises wildcards when it checks that a `terminate` domain
has a certificate, so `*.example.com` satisfies `app.example.com`.

## Renewal — nothing to do

Renewal is automatic for every kind. `check-cert-renewal.sh` runs every 6 hours
and force-renews any lineage within `CERT_RENEW_THRESHOLD_DAYS` (default 3) of
expiry. HTTP-01 lineages renew on `ACME_HTTP_PORT` behind HAProxy; DNS-01
lineages renew with the plugin and credential recorded at issuance. Either way
the deploy hook copies the result and queues the restart.

What can break a DNS-01 renewal, and what to do:

| Symptom in `journalctl -u cert-renew-check` | Cause | Fix |
|---|---|---|
| `Error determining zone_id` / `403` / `Invalid request headers` | token revoked, expired, or scoped to the wrong zone | issue a new token, overwrite the `.ini` |
| `No such file` for the `.ini` | credential moved or deleted | put it back at the recorded path (`grep credentials /etc/letsencrypt/renewal/<lineage>.conf`) |
| `Incorrect TXT record` / `NXDOMAIN` on `_acme-challenge` | slow propagation | set `ACME_DNS_PROPAGATION_SECONDS=60` for new issuances, and add `dns_<plugin>_propagation_seconds = 60` under `[renewalparams]` in `/etc/letsencrypt/renewal/<lineage>.conf` for existing ones |
| `CAA record ... prevents issuance` | CAA / `issuewild` | allow `letsencrypt.org` |

Test without touching the live certificate:

```bash
sudo certbot renew --cert-name example.com --dry-run      # uses Let's Encrypt staging
sudo /opt/notification-hub/bin/check-cert-renewal.sh --dry-run   # expiry table only
```

## Changing the names on a certificate

Re-run `issue-cert.sh` with the **same lineage** and the **complete new list**.
The certificate is reissued with exactly those names — names you leave out are
dropped.

```bash
# add rss.example.com to the lineage ntfy.example.com
sudo /opt/notification-hub/bin/issue-cert.sh ntfy.example.com rss.example.com

# turn a multi-name certificate into a wildcard, keeping the lineage name "hub"
sudo /opt/notification-hub/bin/issue-cert.sh --cert-name hub '*.example.com' example.com
```

Adding a wildcard to an HTTP-01 lineage switches it to DNS-01 for good; that is
recorded in its renewal config and future renewals follow it.

## Removing a certificate

```bash
sudo "${EDITOR:-vi}" /etc/notification-hub/domains.map    # delete or comment its line(s)
sudo /opt/notification-hub/bin/issue-cert.sh --remove ntfy.example.com
```

`--remove` refuses while the lineage is still in `domains.map` (or the renewal
checker would keep complaining about it), and refuses to delete the last PEM
HAProxy has (it cannot start with none). It deletes the lineage with
`certbot delete`, removes `/etc/certs/proxy/combined/<lineage>.pem` and queues
an HAProxy reload. Split copies elsewhere are left for you to delete. Nothing
is revoked; the old certificate simply expires.

## After a restore

`hub.env` and `domains.map` are in the backup; private keys and the DNS
credential file are not, by design. On the new VPS, recreate
`/etc/letsencrypt/dns/<plugin>.ini` (step 2 above — a fresh token is better
than the old one), run `70-certs.sh`, then re-issue each lineage with the same
names and `--cert-name` it had. `issue-cert.sh --list` on the old box, or
`domains.map`, tells you what they were.

## A lineage marked BROKEN

`issue-cert.sh --list` shows `(BROKEN: live links lead nowhere …)` when a
lineage's files in `/etc/letsencrypt/live/<name>/` are links into an archive
that no longer exists. That typically happens when they pointed into *another*
lineage's archive (after a hand repair or an old rename) and that lineage was
deleted. While it is broken, nothing can renew it, `distribute-certs.sh` stops
refreshing its copies (and says so), and certbot would issue a replacement
under a different name (`<name>-0001`) that nothing here reads.

`issue-cert.sh` refuses to issue over a broken lineage and prints the commands
to clear it: back up `/etc/letsencrypt`, remove the lineage's `live`,
`archive` and `renewal` entries, then issue again under the same name. If
certbot still saves the certificate under another name, `issue-cert.sh` stops
and says so rather than reporting success.

To prevent it, `--remove` refuses to delete a lineage whose archive another
lineage's links still lead into.

## Rate limits worth knowing

Let's Encrypt allows 5 certificates per week for the *exact same set of names*,
and 50 per registered domain per week. Changing names, or the 3-day renewal
window, never comes close; a loop of failed manual retries can. Use
`certbot ... --dry-run` (staging) while experimenting.
