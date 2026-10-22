#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

MODE="setup"
case "${1:-}" in
    "") ;;
    --check) MODE="check" ;;
    --renew-cert) MODE="renew" ;;
    --help|-h)
        echo "Usage: ./setup.sh [--check | --renew-cert]"
        echo "  --check       Check configuration, certificates and the running GitLab (read-only)."
        echo "  --renew-cert  Back up and replace the current self-signed certificate."
        exit 0
        ;;
    *) fail "Unknown option: $1. Use --help." ;;
esac
[[ $# -le 1 ]] || fail "Specify only one option."

for command in docker openssl; do
    command -v "$command" >/dev/null || fail "$command is required."
done
docker compose version >/dev/null || fail "Docker Compose is required."
docker compose config --quiet || fail "Invalid Compose configuration. Set hostname in .env."

# Use Compose's dotenv parsing and environment-variable precedence for both tools.
GITLAB_HOST=$(docker compose config --environment | sed -n 's/^hostname=//p')
[[ ${#GITLAB_HOST} -le 253 && "$GITLAB_HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]] \
    || fail "hostname must be a DNS hostname without a scheme, port or path."
[[ ! "$GITLAB_HOST" =~ ^[0-9.]+$ ]] || fail "Use a DNS hostname, not an IP address."
IFS='.' read -r -a labels <<< "$GITLAB_HOST"
for label in "${labels[@]}"; do
    [[ ${#label} -le 63 ]] || fail "Each hostname label must be 63 characters or shorter."
done

SSL_DIR=".volumes/ssl"
KEY_FILE="$SSL_DIR/$GITLAB_HOST.key"
CRT_FILE="$SSL_DIR/$GITLAB_HOST.crt"
RUNNER_CERT_DIR=".volumes/gitlab-runner/certs"

validate_certificate() {
    [[ -f "$KEY_FILE" && -f "$CRT_FILE" ]] || { echo "Certificate or key is missing." >&2; return 1; }
    openssl x509 -in "$CRT_FILE" -noout -ext subjectAltName 2>/dev/null \
        | tr ', ' '\n' | grep -Fxiq "DNS:$GITLAB_HOST" \
        || { echo "Certificate needs a DNS SAN for $GITLAB_HOST." >&2; return 1; }
    openssl x509 -in "$CRT_FILE" -noout -checkend 2592000 >/dev/null \
        || { echo "Certificate expires within 30 days or is invalid." >&2; return 1; }
    openssl verify -CAfile "$CRT_FILE" -verify_hostname "$GITLAB_HOST" "$CRT_FILE" >/dev/null \
        || { echo "Certificate validation failed." >&2; return 1; }
    local cert_public key_public
    cert_public=$(openssl x509 -in "$CRT_FILE" -noout -pubkey) || return 1
    key_public=$(openssl pkey -in "$KEY_FILE" -passin pass: -pubout) || return 1
    [[ "$cert_public" == "$key_public" ]] \
        || { echo "Certificate and private key do not match." >&2; return 1; }
}

echo "GitLab hostname: $GITLAB_HOST"
if [[ "$MODE" == "check" ]]; then
    command -v curl >/dev/null || fail "curl is required for --check."
    validate_certificate || fail "Run ./setup.sh --renew-cert, then trust the new certificate."
    openssl x509 -in "$CRT_FILE" -noout -enddate
    docker info >/dev/null || fail "Cannot access Docker. Check daemon status and your permissions."
    docker compose ps -a
    container_id=$(docker compose ps -a -q gitlab)
    [[ -n "$container_id" ]] || fail "GitLab has not been created. Run docker compose up -d."
    docker inspect --format 'State: {{.State.Status}}; health: {{if .State.Health}}{{.State.Health.Status}}{{else}}not defined{{end}}' "$container_id"
    # Check dependencies from inside the container, where localhost is allowlisted.
    docker compose exec -T gitlab curl --fail --silent --show-error --max-time 10 \
        --cacert "/etc/gitlab/ssl/$GITLAB_HOST.crt" \
        --resolve "$GITLAB_HOST:8929:127.0.0.1" \
        "https://$GITLAB_HOST:8929/-/readiness?all=1" \
        || fail "GitLab is not ready. Check docker compose logs --tail=100 gitlab."
    echo
    curl --fail --silent --show-error --output /dev/null --connect-timeout 5 --max-time 15 \
        --cacert "$CRT_FILE" "https://$GITLAB_HOST/users/sign_in" \
        || fail "Cannot reach GitLab from this host. Check DNS or /etc/hosts, port 443 and GitLab logs."
    # An unauthenticated registry should respond with an authentication challenge.
    registry_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 5 --max-time 15 --cacert "$CRT_FILE" "https://$GITLAB_HOST:5050/v2/") \
        || fail "Cannot reach the Container Registry. Check port 5050 and certificate configuration."
    [[ "$registry_status" == "401" || "$registry_status" == "200" ]] \
        || fail "Unexpected Container Registry HTTP status: $registry_status."
    echo "OK: configuration, certificate, readiness, HTTPS and Container Registry."
    exit 0
fi

for dir in config logs data ssl gitlab-runner/certs; do
    mkdir -p -- ".volumes/$dir" \
        || fail "Cannot create .volumes/$dir. Check ownership of this path; do not recursively chown GitLab data."
done

if [[ "$MODE" == "renew" || ( ! -e "$KEY_FILE" && ! -e "$CRT_FILE" ) ]]; then
    # Generate in a temporary directory so an OpenSSL failure preserves existing files.
    umask 077
    certificate_tmp=$(mktemp -d "$SSL_DIR/.certificate.XXXXXX")
    trap 'rm -rf -- "$certificate_tmp"' EXIT
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "$certificate_tmp/server.key" -out "$certificate_tmp/server.crt" \
        -subj "/CN=$GITLAB_HOST" -addext "subjectAltName=DNS:$GITLAB_HOST"
    chmod 600 "$certificate_tmp/server.key"
    chmod 644 "$certificate_tmp/server.crt"
    if [[ -e "$KEY_FILE" || -e "$CRT_FILE" ]]; then
        certificate_backup=$(mktemp -d "$SSL_DIR/backup.XXXXXX")
        for file in "$KEY_FILE" "$CRT_FILE"; do
            if [[ -e "$file" ]]; then cp -p -- "$file" "$certificate_backup/"; fi
        done
        echo "Previous certificate saved in $certificate_backup"
    fi
    mv -- "$certificate_tmp/server.key" "$KEY_FILE"
    mv -- "$certificate_tmp/server.crt" "$CRT_FILE"
    echo "Certificate generated. Trust this certificate on each client."
else
    echo "Checking the existing certificate..."
fi
validate_certificate || fail "Run ./setup.sh --renew-cert to replace the certificate."
# Runner receives only the public certificate, never the server's private key.
cp -- "$CRT_FILE" "$RUNNER_CERT_DIR/$GITLAB_HOST.crt"
chmod 644 "$RUNNER_CERT_DIR/$GITLAB_HOST.crt"

cat <<EOF

1. Add the hostname to /etc/hosts if DNS does not resolve it:
   127.0.0.1 $GITLAB_HOST
   Use the server's LAN IP instead of 127.0.0.1 on other machines.

2. Trust the certificate (Debian/Ubuntu):
   sudo cp '$PWD/$CRT_FILE' '/usr/local/share/ca-certificates/$GITLAB_HOST.crt'
   sudo update-ca-certificates

3. Trust the Container Registry on each Docker host:
   sudo mkdir -p '/etc/docker/certs.d/$GITLAB_HOST:5050'
   sudo cp '$PWD/$CRT_FILE' '/etc/docker/certs.d/$GITLAB_HOST:5050/ca.crt'
   sudo systemctl restart docker

4. Start GitLab, wait for it to become healthy, then check connectivity:
   docker compose up -d --wait --wait-timeout 600
   ./setup.sh --check

If you renewed a certificate on a running instance, reload NGINX:
   docker compose exec gitlab gitlab-ctl hup nginx
   docker compose --profile ci restart gitlab-runner  # if the Runner is running
EOF
