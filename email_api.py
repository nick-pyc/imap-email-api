import imaplib, email, re, uuid, sqlite3, time, string, random, os
from threading import Thread
from functools import wraps
from datetime import datetime
from flask import Flask, request, jsonify

app = Flask(__name__)

# ── Config ────────────────────────────────────────────────────────────────────

IMAP_HOST      = os.getenv("IMAP_HOST",      "m41l.example.com")
IMAP_PORT      = int(os.getenv("IMAP_PORT",  "993"))
IMAP_USER      = os.getenv("IMAP_USER",      "catch@example.com")
IMAP_PASS      = os.getenv("IMAP_PASS",      "")
DOMAIN         = os.getenv("DOMAIN",         "example.com")
API_KEY        = os.getenv("API_KEY",        "changeme")
DB_PATH        = os.getenv("DB_PATH",        "emailapi.db")
EMAIL_TTL      = int(os.getenv("EMAIL_TTL",      "600"))
POLL_INTERVAL  = int(os.getenv("POLL_INTERVAL",  "4"))
VERIFY_TIMEOUT = int(os.getenv("VERIFY_TIMEOUT", "90"))

# ── Logger ────────────────────────────────────────────────────────────────────

_R = '\033[0m'
_G = '\033[92m'
_C = '\033[96m'
_Y = '\033[93m'
_E = '\033[91m'

def _ts(): return datetime.now().strftime('%H:%M:%S')
def log_success(msg): print(f"[{_G}{_ts()}{_R}] {msg}")
def log_info(msg):    print(f"[{_C}{_ts()}{_R}] {msg}")
def log_warn(msg):    print(f"[{_Y}{_ts()}{_R}] {msg}")
def log_error(msg):   print(f"[{_E}{_ts()}{_R}] {msg}")

# ── DB ────────────────────────────────────────────────────────────────────────

def init_db():
    with sqlite3.connect(DB_PATH) as c:
        c.execute("""CREATE TABLE IF NOT EXISTS requests (
            id TEXT PRIMARY KEY, email TEXT NOT NULL, site TEXT,
            status TEXT DEFAULT 'waiting', code TEXT, subject TEXT,
            body TEXT, created_at REAL, expires_at REAL
        )""")
        c.execute("""CREATE TABLE IF NOT EXISTS mailboxes (
            email TEXT PRIMARY KEY, created_at REAL
        )""")

def db(): return sqlite3.connect(DB_PATH)

# ── Code extraction ───────────────────────────────────────────────────────────

CODE_PATTERNS = [
    r'(?:^|\n)\s*([0-9]{6})\s*(?:\n|$)',
    r'(?:code|Code|CODE)[^\w]*([0-9]{6})',
    r'(?:verify|Verify|verification)[^\w]*([0-9]{6})',
    r'(?:sign up|Sign up|signup)[^\w]*([0-9]{6})',
    r'(?:OTP|otp)[^\w]*([0-9]{6})',
    r'(?:is|:)\s*([0-9]{6})\b',
    r'<[^>]*>\s*([0-9]{6})\s*<',
    r'(?:code|Code|CODE)[^\w]*([A-Z0-9]{4,10})',
    r'(?:verify|Verify)[^\w]*([A-Z0-9]{4,10})',
    r'(?:token|Token)[^\w]*([a-zA-Z0-9]{8,32})',
    r'\b([0-9]{6})\b',
    r'\b([0-9]{4})\b',
    r'\b([0-9]{8})\b',
]

def extract_code(text):
    for p in CODE_PATTERNS:
        m = re.search(p, text, re.MULTILINE)
        if m: return m.group(1)
    return None

def get_body(msg):
    body = ""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() in ("text/plain", "text/html"):
                try: body += part.get_payload(decode=True).decode(errors="ignore")
                except: pass
    else:
        try: body = msg.get_payload(decode=True).decode(errors="ignore")
        except: pass
    return body

# ── IMAP ──────────────────────────────────────────────────────────────────────

def imap_connect(host=None, port=None, user=None, password=None):
    c = imaplib.IMAP4_SSL(host or IMAP_HOST, port or IMAP_PORT)
    c.login(user or IMAP_USER, password or IMAP_PASS)
    c.select("INBOX")
    return c

def search_inbox(target_email, since_ts, sender="ALL", location="body"):
    try:
        mail = imap_connect()
        since_str = time.strftime("%d-%b-%Y", time.localtime(since_ts - 86400))
        criteria = f'SINCE {since_str}'
        if sender and sender.upper() != "ALL":
            criteria += f' FROM "{sender}"'

        _, data = mail.search(None, criteria)
        ids = data[0].split()

        for num in reversed(ids):
            _, raw = mail.fetch(num, "(RFC822)")
            msg = email.message_from_bytes(raw[0][1])

            to_header = " ".join(filter(None, [
                msg.get("To", ""), msg.get("Delivered-To", ""), msg.get("X-Original-To", "")
            ]))
            if target_email.lower() not in to_header.lower():
                continue

            subject = msg.get("Subject", "")
            body    = get_body(msg)
            source  = subject if location == "subject" else body
            code    = extract_code(source)

            mail.logout()
            return code, subject, body[:4000]

        mail.logout()
    except Exception as e:
        log_error(f"[IMAP] {e}")

    return None, "", ""

# ── Background poll ───────────────────────────────────────────────────────────

def poll_loop():
    while True:
        try:
            with db() as conn:
                rows = conn.execute(
                    "SELECT id, email, created_at FROM requests "
                    "WHERE status='waiting' AND expires_at > ?", (time.time(),)
                ).fetchall()

            for req_id, target_email, created_at in rows:
                code, subject, body = search_inbox(target_email, created_at)
                if code:
                    with db() as conn:
                        conn.execute(
                            "UPDATE requests SET status='ready', code=?, subject=?, body=? WHERE id=?",
                            (code, subject, body, req_id)
                        )
                    log_success(f"[poll] {target_email} → {code}")
        except Exception as e:
            log_error(f"[poll] {e}")
        time.sleep(POLL_INTERVAL)

# ── Auth ──────────────────────────────────────────────────────────────────────

def require_key(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        key = request.args.get("apiKey") or request.headers.get("X-API-Key", "")
        if key != API_KEY:
            return jsonify({"status": "error", "message": "invalid key"}), 401
        return f(*args, **kwargs)
    return wrapper

# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/create_email", methods=["POST"])
def create_email():
    prefix = request.form.get("email", "").strip().lower()
    if not prefix:
        return jsonify({"error": "email required"}), 400

    addr = prefix if "@" in prefix else f"{prefix}@{DOMAIN}"
    with db() as conn:
        conn.execute("INSERT OR REPLACE INTO mailboxes VALUES (?, ?)", (addr, time.time()))

    log_success(f"[create_email] {addr}")
    return app.response_class(response=f'"{addr}"', status=200, mimetype="application/json")


@app.route("/get_verification", methods=["POST"])
def get_verification():
    addr     = request.form.get("email", "").strip().lower()
    sender   = request.form.get("sender", "ALL")
    location = request.form.get("verification_location", "body")

    if not addr:
        return jsonify({"error": "email required"}), 400

    with db() as conn:
        row = conn.execute("SELECT created_at FROM mailboxes WHERE email=?", (addr,)).fetchone()
    since_ts = row[0] if row else time.time() - 300

    log_info(f"[get_verification] waiting for {addr}...")
    deadline = time.time() + VERIFY_TIMEOUT
    while time.time() < deadline:
        code, _, _ = search_inbox(addr, since_ts, sender, location)
        if code:
            log_success(f"[get_verification] {addr} → {code}")
            return app.response_class(response=f'"{code}"', status=200, mimetype="application/json")
        time.sleep(POLL_INTERVAL)

    log_warn(f"[get_verification] {addr} → timeout after {VERIFY_TIMEOUT}s")
    return jsonify({"error": "timeout", "message": f"no email in {VERIFY_TIMEOUT}s"})


def _random_addr():
    prefix = "".join(random.choices(string.ascii_lowercase + string.digits, k=12))
    return f"{prefix}@{DOMAIN}"


@app.route("/api/getEmail")
@require_key
def api_get_email():
    site   = request.args.get("site", "")
    req_id = str(uuid.uuid4())
    addr   = _random_addr()
    now    = time.time()
    with db() as conn:
        conn.execute("INSERT INTO requests VALUES (?,?,?,?,?,?,?,?,?)",
            (req_id, addr, site, "waiting", None, None, None, now, now + EMAIL_TTL))
        conn.execute("INSERT OR REPLACE INTO mailboxes VALUES (?,?)", (addr, now))
    log_info(f"[getEmail] {addr}")
    return jsonify({"status": "OK", "id": req_id, "email": addr})


@app.route("/api/getEmailResult")
@require_key
def api_get_result():
    req_id = request.args.get("id", "")
    with db() as conn:
        row = conn.execute(
            "SELECT status, code, email, subject FROM requests WHERE id=?", (req_id,)
        ).fetchone()

    if not row:
        return jsonify({"status": "error", "message": "not found"}), 404

    status, code, addr, subject = row
    if status == "ready":   return jsonify({"status": "OK", "email": addr, "code": code, "subject": subject})
    if status == "waiting": return jsonify({"status": "wait"})
    return jsonify({"status": "error", "message": status})


@app.route("/api/cancelEmail")
@require_key
def api_cancel():
    req_id = request.args.get("id", "")
    with db() as conn:
        conn.execute("UPDATE requests SET status='cancelled' WHERE id=?", (req_id,))
    return jsonify({"status": "OK"})


@app.route("/api/status")
def api_status():
    with db() as conn:
        counts = {s: conn.execute("SELECT COUNT(*) FROM requests WHERE status=?", (s,)).fetchone()[0]
                  for s in ("waiting", "ready", "cancelled")}
    return jsonify({"status": "OK", "domain": DOMAIN, "imap": IMAP_HOST, "requests": counts})


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    init_db()
    Thread(target=poll_loop, daemon=True).start()
    print(f"\n  {_C}imap email api  (python){_R}")
    print(f"  {'─' * 32}")
    log_info(f"domain: {DOMAIN}  imap: {IMAP_HOST}:{IMAP_PORT}")
    log_info(f"poll: {POLL_INTERVAL}s  timeout: {VERIFY_TIMEOUT}s  ttl: {EMAIL_TTL}s")
    log_success(f"listening on :6060\n")
    app.run(host="0.0.0.0", port=6060, debug=False)
