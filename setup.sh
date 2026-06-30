#!/bin/bash
set -e

# .envファイルからhostnameを読み込む
ENV_FILE=".env"
DEFAULT_HOSTNAME="gitlab.local"
HOSTNAME=$DEFAULT_HOSTNAME

if [ -f "$ENV_FILE" ]; then
    # .envからhostname=xxxの行を抽出し、値を取得する
    PARSED_HOSTNAME=$(grep -E "^hostname=" "$ENV_FILE" | cut -d'=' -f2 | tr -d '\r' | xargs)
    if [ -n "$PARSED_HOSTNAME" ]; then
        HOSTNAME=$PARSED_HOSTNAME
    fi
fi

echo "=========================================="
echo "GitLab Docker Setup Assistant"
echo "Hostname to use: $HOSTNAME"
echo "=========================================="

# 必要なディレクトリの作成
echo "Creating volume directories..."
for dir in config logs data ssl gitlab-runner; do
    if [ ! -d ".volumes/$dir" ]; then
        if ! mkdir -p ".volumes/$dir" 2>/dev/null; then
            echo "Error: Cannot create directory .volumes/$dir due to permission issues."
            echo "Please run: sudo chown -R \$(id -u):\$(id -g) .volumes"
            echo "Or run this script with sudo: sudo ./setup.sh"
            exit 1
        fi
    fi
done

# 自己署名証明書の生成
SSL_DIR=".volumes/ssl"
KEY_FILE="$SSL_DIR/$HOSTNAME.key"
CRT_FILE="$SSL_DIR/$HOSTNAME.crt"

if [ -f "$KEY_FILE" ] && [ -f "$CRT_FILE" ]; then
    echo "SSL Certificate for $HOSTNAME already exists. Skipping generation."
else
    echo "Generating SSL self-signed certificate for $HOSTNAME..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
      -keyout "$KEY_FILE" \
      -out "$CRT_FILE" \
      -subj "/C=JP/ST=Tokyo/L=Tokyo/O=MyOrg/OU=Dev/CN=$HOSTNAME"
    echo "Certificate generated successfully."
fi

echo ""
echo "=========================================="
echo "Next Steps to Complete Setup:"
echo "=========================================="
echo "1. Register hosts entry (if not already done):"
echo "   Run the following command to map $HOSTNAME to 127.0.0.1:"
echo "   echo \"127.0.0.1 $HOSTNAME\" | sudo tee -a /etc/hosts"
echo ""
echo "2. Trust the SSL certificate locally (Debian/Ubuntu):"
echo "   sudo cp $CRT_FILE /usr/local/share/ca-certificates/$HOSTNAME.crt"
echo "   sudo update-ca-certificates"
echo ""
echo "3. Trust the SSL certificate in Docker (for Container Registry on :5050):"
echo "   sudo mkdir -p /etc/docker/certs.d/$HOSTNAME:5050"
echo "   sudo cp $CRT_FILE /etc/docker/certs.d/$HOSTNAME:5050/ca.crt"
echo "   sudo systemctl restart docker"
echo ""
echo "4. Start GitLab using Docker Compose:"
echo "   docker compose up -d"
echo "=========================================="
