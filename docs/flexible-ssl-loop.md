# The Flexible-SSL redirect loop — explained

This is the single most common "my site broke after moving to Cloudflare"
failure mode, especially on setups migrated from China-region VPS. If you're
reading this after `cfcn ssl diag` flagged it on your domain, this document
explains exactly what's happening and how to fix it properly.

## The setup

- Zone SSL mode: **Flexible**.
- DNS record: proxied (orange cloud).
- Origin nginx has something like this:

  ```nginx
  server {
      listen 80;
      server_name example.com;
      return 301 https://$host$request_uri;  # <-- the trap
  }

  server {
      listen 443 ssl;
      server_name example.com;
      ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
      ...
  }
  ```

## What actually happens on a request

1. Browser: `GET https://example.com/`
2. Cloudflare edge: serves on 443 (it has its universal cert on the edge).
3. Cloudflare → origin: since SSL mode is **Flexible**, CF talks to your
   origin over **plain HTTP on port 80**.
4. Origin nginx: sees HTTP/80 request, sends `301 → https://example.com/`.
5. Cloudflare passes the 301 back to the browser.
6. Browser follows the 301 — `GET https://example.com/` again.
7. GOTO 2.

That's a redirect loop. Modern browsers surface this as
`ERR_TOO_MANY_REDIRECTS`; `curl -I` shows identical 301s; if you're sitting
behind some CN ISPs or certain corporate networks, the upstream may bail
earlier and serve a misleading 403 / 502 / empty body.

## Why it's more common on CN/HK VPS

Two reasons:

1. **You can actually get Let's Encrypt working on CN/HK VPS without a
   CDN in front**, so people write nginx configs that force HTTPS at the
   origin level without thinking about it. Then they put CF in front later
   for the free WAF and the loop silently becomes active.
2. **"Flexible" is Cloudflare's default new-zone SSL mode** for zones
   migrated without a valid origin cert — which matches the common path
   of "I just got a VPS from Tencent, haven't set up certbot yet, let me
   turn on Cloudflare proxy for the free HTTPS".

## How to actually fix it

Two clean options. Pick one and commit.

### Option A: Full (strict) mode + origin cert

**Best for production.** End-to-end encryption. Origin cert is free.

1. On origin, make sure certbot is set up:
   ```bash
   sudo certbot --nginx -d example.com
   ```
2. On Cloudflare, switch SSL mode to **Full (strict)**:
   ```bash
   cfcn ssl mode example.com strict
   ```
3. Keep your `return 301 https://...` — everyone is happy.

### Option B: Flexible mode + drop the origin redirect

**Fine for low-stakes sites.** CF ↔ origin stays HTTP; CF ↔ browser is HTTPS.
Make sure you trust the network between CF and your origin (usually the
public internet, so... only use this when the content isn't sensitive).

1. Remove the 80→443 redirect block from nginx.
2. On Cloudflare, enable "Always Use HTTPS" (Rules → Redirect Rules, or
   SSL/TLS → Edge Certificates → Always Use HTTPS → On). This makes CF
   itself issue the redirect, which is where it belongs in Flexible mode.

## Why not just "use Full mode (not strict)"?

"Full" (non-strict) ignores origin cert validity. You won't get a loop, but
you also get zero protection against an attacker on the CF-to-origin path
serving a forged cert. For basically any production site, go **strict**
with a real cert (certbot or CF Origin CA).

## One-liner to prevent this in the future

Put this in your install runbook:

```bash
cfcn ssl diag example.com
```

before declaring a new deploy "done". `cfcn` now prints Cloudflare Edge and
Direct Origin probes separately, so you can tell whether a failure comes from
Cloudflare mode/edge path or from the origin's redirect/TLS setup. For proxied
A/AAAA records the origin IP is inferred from DNS; for CNAME or multi-origin
setups, pass it explicitly:

```bash
cfcn ssl diag example.com --origin-ip 203.0.113.10
```

It's ~2 seconds and catches every permutation of this trap I've seen.
