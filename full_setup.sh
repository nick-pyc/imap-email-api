#!/bin/bash
# Full IMAP + Mail Server Setup
# Sets up a catch-all inbox + API for fetching verification codes from sites
# Run as root on Ubuntu 20.04/22.04: sudo bash full_setup.sh
#
# !! PORT 25 WARNING !!
#   Most VPS providers (Vultr, Linode, AWS, etc.) and home ISPs block outbound
#   port 25 by default. You MUST contact your provider and request it be unblocked
#   BEFORE running this — without it, no mail will ever reach your server.
#   Test it first: telnet gmail-smtp-in.l.google.com 25
#   If it connects and shows "220 mx.google.com ESMTP" you're good to go.
#   If it hangs or times out, contact your provider to unblock port 25.
#
# Before running:
#   1. Get port 25 unblocked (see above)
#   2. DNS A record:  m41l -> <this VPS IP>
#   3. DNS MX record: @ -> m41l.yourdomain.com  (priority 10)

set -e

# ── Config ────────────────────────────────────────────────────────────────────

API_DIR="/root/emailapi"
API_PORT="6060"

# ── Prompt ────────────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  IMAP + Mail Server Setup"
echo "  (catch-all inbox for site verification code fetching)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  !! IMPORTANT: Port 25 must be unblocked !!"
echo "  Most VPS providers block it by default — you need to"
echo "  contact your provider and request it be opened first."
echo "  Test: telnet gmail-smtp-in.l.google.com 25"
echo "  Expected: '220 mx.google.com ESMTP' — if it hangs, stop here."
echo ""
read -rp "Has your provider confirmed port 25 is unblocked? [y/N]: " PORT25_OK
if [[ "${PORT25_OK,,}" != "y" ]]; then
    echo "Get port 25 unblocked first, then re-run this script."
    exit 1
fi
echo ""

read -rp "Your domain (e.g. example.com): " DOMAIN
MAIL_HOST="m41l.${DOMAIN}"
CATCH_EMAIL="catch@${DOMAIN}"
MAIL_DIR="/var/mail/vhosts/${DOMAIN}"
VMAIL_USER="vmail"

echo ""
read -rsp "Set password for ${CATCH_EMAIL} (IMAP inbox): " CATCH_PASS
echo ""
read -rsp "Confirm password: " CATCH_PASS2
echo ""
if [[ "${CATCH_PASS}" != "${CATCH_PASS2}" ]]; then
    echo "Passwords don't match. Exiting."
    exit 1
fi

read -rp "Use Let's Encrypt SSL? Requires port 80 open. [y/N]: " USE_LE
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Starting setup for ${DOMAIN}..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Step 1: Install packages ──────────────────────────────────────────────────

echo "[1/7] Installing packages..."
apt-get update -qq

debconf-set-selections <<< "postfix postfix/mailname string ${MAIL_HOST}"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    postfix dovecot-core dovecot-imapd dovecot-lmtpd \
    openssl python3-pip ufw curl

pip3 install flask --quiet

# ── Step 2: Create vmail user + dirs ─────────────────────────────────────────

echo "[2/7] Creating vmail user and directories..."
if ! id "${VMAIL_USER}" &>/dev/null; then
    useradd -r -u 5000 -d /var/mail -s /sbin/nologin "${VMAIL_USER}"
fi
mkdir -p "${MAIL_DIR}/catch"
chown -R "${VMAIL_USER}:${VMAIL_USER}" /var/mail/vhosts
chmod -R 700 /var/mail/vhosts

# ── Step 3: SSL ───────────────────────────────────────────────────────────────

echo "[3/7] Configuring SSL..."
mkdir -p /etc/dovecot/ssl

if [[ "${USE_LE,,}" == "y" ]]; then
    apt-get install -y certbot -qq
    certbot certonly --standalone -d "${MAIL_HOST}" --agree-tos --register-unsafely-without-email
    SSL_CERT="/etc/letsencrypt/live/${MAIL_HOST}/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/${MAIL_HOST}/privkey.pem"
    echo "  Let's Encrypt cert obtained."
else
    SSL_CERT="/etc/dovecot/ssl/dovecot.pem"
    SSL_KEY="/etc/dovecot/ssl/dovecot.key"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${SSL_KEY}" -out "${SSL_CERT}" \
        -subj "/CN=${MAIL_HOST}" 2>/dev/null
    echo "  Self-signed cert generated."
fi
chmod 600 "${SSL_KEY}"

# ── Step 4: Configure Dovecot ─────────────────────────────────────────────────

echo "[4/7] Configuring Dovecot..."

cat > /etc/dovecot/dovecot.conf <<EOF
protocols = imap lmtp

mail_location = maildir:/var/mail/vhosts/%d/%n
mail_uid = ${VMAIL_USER}
mail_gid = ${VMAIL_USER}
mail_privileged_group = ${VMAIL_USER}

ssl = required
ssl_cert = <${SSL_CERT}
ssl_key  = <${SSL_KEY}

service imap-login {
  inet_listener imap  { port = 143 }
  inet_listener imaps { port = 993; ssl = yes }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

auth_mechanisms = plain login

passdb {
  driver = passwd-file
  args   = /etc/dovecot/users
}

userdb {
  driver = static
  args   = uid=${VMAIL_USER} gid=${VMAIL_USER} home=/var/mail/vhosts/%d/%n
}

protocol lmtp {
  postmaster_address = postmaster@${DOMAIN}
}
EOF

echo "[5/7] Creating catch-all mail account..."
HASHED_PASS=$(doveadm pw -s SHA512-CRYPT -p "${CATCH_PASS}")
echo "${CATCH_EMAIL}:${HASHED_PASS}" > /etc/dovecot/users
chmod 640 /etc/dovecot/users
chown root:dovecot /etc/dovecot/users

# ── Step 5: Configure Postfix ─────────────────────────────────────────────────

echo "[6/7] Configuring Postfix..."

postconf -e "myhostname = ${MAIL_HOST}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "mydestination = localhost"
postconf -e "mynetworks = 127.0.0.0/8"
postconf -e "virtual_mailbox_domains = ${DOMAIN}"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
postconf -e "smtpd_tls_cert_file = ${SSL_CERT}"
postconf -e "smtpd_tls_key_file = ${SSL_KEY}"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtp_tls_security_level = may"
postconf -e "smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"

# catch-all: route everything @domain -> catch@domain
cat > /etc/postfix/virtual <<EOF
@${DOMAIN}    ${CATCH_EMAIL}
EOF
postmap /etc/postfix/virtual
postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual"

# ── Step 6: Firewall + start services ─────────────────────────────────────────

echo "[7/7] Opening firewall ports and starting services..."
for port in 22 25 80 443 587 993 "${API_PORT}"; do
    iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -p tcp --dport "${port}" -j ACCEPT
done

systemctl enable dovecot postfix
systemctl restart dovecot postfix

# ── Deploy email API ──────────────────────────────────────────────────────────

echo ""
echo "Deploying email API..."
mkdir -p "${API_DIR}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/email_api.py" ]]; then
    cp "${SCRIPT_DIR}/email_api.py" "${API_DIR}/email_api.py"
    echo "  email_api.py copied to ${API_DIR}"
else
    echo "  NOTE: Copy email_api.py to ${API_DIR}/ manually."
fi

cat > "${API_DIR}/start.sh" <<'STARTEOF'
#!/bin/bash
# Set IMAP_PASS before running: export IMAP_PASS="yourpassword"
if [[ -z "${IMAP_PASS}" ]]; then
    read -rsp "IMAP password for catch inbox: " IMAP_PASS
    echo ""
    export IMAP_PASS
fi

export IMAP_HOST="__MAIL_HOST__"
export IMAP_PORT="993"
export IMAP_USER="__CATCH_EMAIL__"
export DOMAIN="__DOMAIN__"

cd "$(dirname "$0")"
nohup python3 email_api.py > emailapi.log 2>&1 &
echo "Email API started. PID: $!  |  Log: $(dirname "$0")/emailapi.log"
STARTEOF

# Substitute placeholders
sed -i "s/__MAIL_HOST__/${MAIL_HOST}/g" "${API_DIR}/start.sh"
sed -i "s/__CATCH_EMAIL__/${CATCH_EMAIL}/g" "${API_DIR}/start.sh"
sed -i "s/__DOMAIN__/${DOMAIN}/g" "${API_DIR}/start.sh"
chmod +x "${API_DIR}/start.sh"

# ── Done ──────────────────────────────────────────────────────────────────────

VPS_IP=$(curl -s ifconfig.me 2>/dev/null || echo "<your VPS IP>")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete!"
echo ""
echo "  IMAP login:"
echo "    Host:  ${MAIL_HOST}:993 (SSL)"
echo "    User:  ${CATCH_EMAIL}"
echo "    Pass:  (what you entered above)"
echo ""
echo "  Email API:"
echo "    cd ${API_DIR} && bash start.sh"
echo "    Runs on http://${MAIL_HOST}:${API_PORT}"
echo ""
echo "  Required DNS records:"
echo "    A   m41l   ->  ${VPS_IP}"
echo "    MX  @  10  ->  ${MAIL_HOST}"
echo ""
echo "  config.json for account generator:"
echo "    \"imap\": {"
echo "      \"apiURL\": \"http://${MAIL_HOST}:${API_PORT}\","
echo "      \"imap\":   \"${MAIL_HOST}\","
echo "      \"domain\": \"${DOMAIN}\""
echo "    }"
echo ""
echo "  IMPORTANT: test port 25 is open:"
echo "    telnet gmail-smtp-in.l.google.com 25"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
