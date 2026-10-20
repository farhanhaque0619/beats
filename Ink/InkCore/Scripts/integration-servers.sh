#!/bin/bash
# Real mail servers for the InkSync integration tests (IMAPMailServiceIntegrationTests,
# MailStoreIntegrationTests), which plain `swift test` skips.
#
#   Scripts/integration-servers.sh start   # GreenMail, Dovecot and Postfix in Docker
#   Scripts/integration-servers.sh env     # prints the INK_IT_* variables the tests read
#   Scripts/integration-servers.sh test    # start, run the integration tests, stop
#   Scripts/integration-servers.sh stop
#
#   GreenMail 2.1.0  SMTP 3025, IMAP 3143; authentication off, users made on first use; INBOX only.
#   Dovecot 2.4      IMAP 31143, submission 31587, LMTP 31025; any user, password "pass".
#   Postfix          127.0.0.1:587; Dovecot's submission relays through it, and it delivers
#                    example.org / example.com back into Dovecot over LMTP.
#
# Needs Docker with host networking (Linux). `test` runs `swift test` on this machine; set
# SWIFT_TEST to run it another way, e.g. inside a swift:6.2 container started with --network host.
set -euo pipefail
cd "$(dirname "$0")/.."

CONF_DIR="${TMPDIR:-/tmp}/ink-it"
ENV_VARS=(INK_IT_HOST=127.0.0.1 INK_IT_GREENMAIL_IMAP_PORT=3143 INK_IT_GREENMAIL_SMTP_PORT=3025
          INK_IT_DOVECOT_IMAP_PORT=31143 INK_IT_DOVECOT_SMTP_PORT=31587 INK_IT_DOVECOT_PASSWORD=pass)

stop() { docker rm -f ink-greenmail ink-dovecot ink-postfix >/dev/null 2>&1 || true; }

start() {
  stop
  mkdir -p "$CONF_DIR"
  cat > "$CONF_DIR/ink.conf" <<'CONF'
# Plaintext LMTP for test delivery; special-use folders created on login (no Archive on purpose).
listen = *
auth_allow_cleartext = yes
service lmtp {
  inet_listener lmtp {
    port = 31025
  }
}
namespace inbox {
  mailbox Drafts {
    auto = subscribe
  }
  mailbox Sent {
    auto = subscribe
  }
  mailbox Junk {
    auto = subscribe
  }
  mailbox Trash {
    auto = subscribe
  }
}
submission_relay_host = 127.0.0.1
submission_relay_port = 587
submission_relay_trusted = yes
submission_relay_ssl = no
CONF
  docker run -d --name ink-greenmail -p 3025:3025 -p 3143:3143 \
    -e GREENMAIL_OPTS='-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.auth.disabled' \
    greenmail/standalone:2.1.0 >/dev/null
  docker run -d --name ink-dovecot --network host -e USER_PASSWORD=pass \
    -v "$CONF_DIR/ink.conf:/etc/dovecot/conf.d/ink.conf:ro" dovecot/dovecot:latest >/dev/null
  docker run -d --name ink-postfix --network host -e ALLOWED_SENDER_DOMAINS="example.org example.com" \
    -e POSTFIX_inet_interfaces=127.0.0.1 -e "POSTFIX_virtual_mailbox_domains=example.org example.com" \
    -e POSTFIX_virtual_transport=lmtp:inet:127.0.0.1:31025 -e POSTFIX_smtpd_reject_unlisted_recipient=no \
    -e "POSTFIX_smtpd_recipient_restrictions=permit_mynetworks,reject" -e "POSTFIX_mydestination=" \
    boky/postfix:latest >/dev/null
  for _ in $(seq 1 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/3143) 2>/dev/null && (exec 3<>/dev/tcp/127.0.0.1/31143) 2>/dev/null \
       && (exec 3<>/dev/tcp/127.0.0.1/587) 2>/dev/null; then
      sleep 3
      echo "servers up"
      return 0
    fi
    sleep 1
  done
  echo "servers did not come up" >&2
  return 1
}

case "${1:-}" in
  start) start ;;
  stop) stop; echo "stopped" ;;
  env) printf '%s\n' "${ENV_VARS[@]}" ;;
  test)
    start
    trap stop EXIT
    env "${ENV_VARS[@]}" ${SWIFT_TEST:-swift test} --filter 'IntegrationTests'
    ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
