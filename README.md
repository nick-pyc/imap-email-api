# imap email api

catch-all email API for fetching verification codes from sites. drop-in compatible with [Bluyx/email-api](https://github.com/Bluyx/email-api) so it works with Kick.com account generators and similar tools.

uses your own domain + IMAP server instead of a paid service like kopeechka.

---

## what it does

- receives mail sent to any address on your domain (catch-all)
- exposes a simple API to create email addresses and wait for a verification code
- automatically pulls the code out of the email body or subject
- supports both the Bluyx-style endpoints and a Kopeechka-style `/api/*` set

---

## requirements

- a VPS or dedicated server running Ubuntu 20.04 or 22.04
- a domain you control
- **port 25 must be unblocked by your provider** — most block it by default, you need to contact support and request it open. without this, no mail will reach your server, nothing will work

---

## versions

| folder | language |
|--------|----------|
| `/` (root) | python |
| `/node` | node.js |

both versions are identical in functionality and endpoints. pick whichever you prefer.

---

## setup

**1. check port 25 first**

before anything else, run this from your VPS:
```
telnet gmail-smtp-in.l.google.com 25
```
if you see `220 mx.google.com ESMTP` it's open. if it hangs or times out, contact your provider.

**2. DNS records**

add these in your domain's DNS panel (Cloudflare, etc.):
```
A    m41l    ->  <your VPS IP>
MX   @   10  ->  m41l.yourdomain.com
```

**3. run the setup script**

```bash
scp email_api.py full_setup.sh root@yourVPS:~
ssh root@yourVPS
sudo bash full_setup.sh
```

it'll ask for your domain and a password for the catch inbox, then sets everything up automatically (Postfix, Dovecot, SSL, firewall rules).

**4. start the API**

**with docker (recommended — auto-starts on reboot):**
```bash
cp .env.example .env
# fill in your IMAP creds in .env
docker compose up -d
```

**without docker:**
```bash
cd /root/emailapi
bash start.sh
```

runs on port 6060 by default.

---

## config

all settings are env vars, just set them before running:

| var | default | description |
|-----|---------|-------------|
| `IMAP_HOST` | `m41l.example.com` | your mail server hostname |
| `IMAP_PORT` | `993` | IMAP SSL port |
| `IMAP_USER` | `catch@example.com` | catch-all inbox login |
| `IMAP_PASS` | *(required)* | IMAP password |
| `DOMAIN` | `example.com` | your domain |
| `API_KEY` | `changeme` | key for `/api/*` routes |
| `VERIFY_TIMEOUT` | `90` | seconds to wait for a code |
| `POLL_INTERVAL` | `4` | seconds between IMAP checks |
| `EMAIL_TTL` | `600` | seconds until a slot expires |

---

## endpoints

**Bluyx-compatible (used by account generators):**

`POST /create_email` — registers the address so the API knows when to start watching for mail
```json
// success
"someuser@yourdomain.com"

// error
{ "error": "email required" }
```

`POST /get_verification` — blocks until a code arrives or timeout is hit
```json
// success — returns the code as a plain string
"123456"

// timeout
{ "error": "timeout", "message": "no email in 90s" }

// error
{ "error": "email required" }
```

---

**Kopeechka-style (require API key):**

`GET /api/getEmail?apiKey=xxx&site=example.com`
```json
// success
{ "status": "OK", "id": "uuid-here", "email": "abc123@yourdomain.com" }

// bad key
{ "status": "error", "message": "invalid key" }
```

`GET /api/getEmailResult?apiKey=xxx&id=xxx`
```json
// code arrived
{ "status": "OK", "email": "abc123@yourdomain.com", "code": "123456", "subject": "Your verification code" }

// still waiting
{ "status": "wait" }

// not found
{ "status": "error", "message": "not found" }
```

`GET /api/cancelEmail?apiKey=xxx&id=xxx`
```json
{ "status": "OK" }
```

`GET /api/status`
```json
{
  "status": "OK",
  "domain": "yourdomain.com",
  "imap": "m41l.yourdomain.com",
  "requests": { "waiting": 2, "ready": 5, "cancelled": 1 }
}
```

---

## account generator config.json

```json
"imap": {
  "apiURL": "http://m41l.yourdomain.com:6060",
  "imap":   "m41l.yourdomain.com",
  "domain": "yourdomain.com"
}
```

---

## notes

- the catch-all setup means every email sent to `*@yourdomain.com` lands in one inbox. the API filters by the `To:` header to find the right message
- SSL is self-signed by default, use Let's Encrypt if you want a trusted cert (the setup script asks)
- logs go to `/root/emailapi/emailapi.log`
