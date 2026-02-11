#!/usr/bin/env bash
# docker-deploy.sh — One-click deploy OpenClaw Gateway behind nginx-proxy + letsencrypt
#
# Prerequisites:
#   - Docker + Docker Compose installed
#   - nginx-proxy + letsencrypt-companion running on the "shared" network
#
# Usage:
#   bash scripts/docker-deploy.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'

info()  { echo -e "${CYAN}ℹ${RESET}  $*"; }
ok()    { echo -e "${GREEN}✓${RESET}  $*"; }
warn()  { echo -e "${YELLOW}⚠${RESET}  $*" >&2; }
err()   { echo -e "${RED}✗${RESET}  $*" >&2; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    err "Required command not found: $1"
    exit 1
  fi
}

read_required() {
  local prompt="$1" var=""
  while [[ -z "$var" ]]; do
    printf "${BOLD}%s${RESET}: " "$prompt" >&2
    read -r var
    [[ -z "$var" ]] && warn "This field is required."
  done
  echo "$var"
}

read_optional() {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    printf "${BOLD}%s${RESET} [${DIM}%s${RESET}]: " "$prompt" "$default" >&2
  else
    printf "${BOLD}%s${RESET} (Enter to skip): " "$prompt" >&2
  fi
  local var=""
  read -r var
  echo "${var:-$default}"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_cmd docker
require_cmd openssl

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -f "$PROJECT_DIR/Dockerfile" ]]; then
  err "Dockerfile not found in $PROJECT_DIR"
  exit 1
fi

echo ""
echo -e "${BOLD}${CYAN}🦞 OpenClaw Gateway — Deploy Setup${RESET}"
echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Interactive input
# ---------------------------------------------------------------------------
DOMAIN=$(read_required "Domain (e.g. claw.example.com)")
LETSENCRYPT_EMAIL=$(read_required "Let's Encrypt email")
TELEGRAM_BOT_TOKEN=$(read_optional "Telegram Bot Token")
OPENAI_API_KEY=$(read_required "OpenAI API Key")
OPENAI_BASE_URL=$(read_optional "OpenAI Base URL" "https://api.openai.com/v1")
OPENAI_MODEL=$(read_optional "Default model" "gpt-5.2")

OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)

echo ""
ok "Gateway token generated: ${DIM}${OPENCLAW_GATEWAY_TOKEN:0:16}...${RESET}"

# ---------------------------------------------------------------------------
# Generate .env
# ---------------------------------------------------------------------------
ENV_FILE="$PROJECT_DIR/.env"

cat > "$ENV_FILE" <<EOF
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENAI_API_KEY=${OPENAI_API_KEY}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
EOF

ok "Generated ${DIM}.env${RESET}"

# ---------------------------------------------------------------------------
# Generate docker-compose.deploy.yml
# ---------------------------------------------------------------------------
COMPOSE_FILE="$PROJECT_DIR/docker-compose.deploy.yml"

cat > "$COMPOSE_FILE" <<EOF
services:
  openclaw-gateway:
    image: openclaw:local
    build: .
    restart: unless-stopped
    env_file:
      - .env
    environment:
      HOME: /home/node
      NODE_ENV: production
      TERM: xterm-256color
      VIRTUAL_HOST: ${DOMAIN}
      VIRTUAL_PORT: "18789"
      LETSENCRYPT_HOST: ${DOMAIN}
      LETSENCRYPT_EMAIL: ${LETSENCRYPT_EMAIL}
    volumes:
      - ./data:/home/node/.openclaw
      - ./data/workspace:/home/node/.openclaw/workspace
    init: true
    command:
      - node
      - dist/index.js
      - gateway
      - --bind
      - lan
      - --port
      - "18789"
      - --allow-unconfigured

networks:
  default:
    name: shared
    external: true
EOF

ok "Generated ${DIM}docker-compose.deploy.yml${RESET}"

# ---------------------------------------------------------------------------
# Create data directory + openclaw.json
# ---------------------------------------------------------------------------
DATA_DIR="$PROJECT_DIR/data"
mkdir -p "$DATA_DIR/workspace"

# Build openclaw.json
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  cat > "$DATA_DIR/openclaw.json" <<EOF
{
  "agent": {
    "model": "openai/${OPENAI_MODEL}"
  },
  "models": {
    "providers": {
      "openai": {
        "baseUrl": "${OPENAI_BASE_URL}"
      }
    }
  },
  "channels": {
    "telegram": {
      "botToken": "\${TELEGRAM_BOT_TOKEN}"
    }
  }
}
EOF
else
  cat > "$DATA_DIR/openclaw.json" <<EOF
{
  "agent": {
    "model": "openai/${OPENAI_MODEL}"
  },
  "models": {
    "providers": {
      "openai": {
        "baseUrl": "${OPENAI_BASE_URL}"
      }
    }
  }
}
EOF
fi

# Ensure the node user (uid 1000) can write to data dir
chmod -R 777 "$DATA_DIR"

ok "Generated ${DIM}data/openclaw.json${RESET}"

# ---------------------------------------------------------------------------
# Build & start
# ---------------------------------------------------------------------------
echo ""
info "Building Docker image..."
docker compose -f "$COMPOSE_FILE" build

echo ""
info "Starting containers..."
docker compose -f "$COMPOSE_FILE" up -d

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}🦞 OpenClaw Gateway deployed!${RESET}"
echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  URL:   ${BOLD}https://${DOMAIN}${RESET}"
echo -e "  Token: ${DIM}${OPENCLAW_GATEWAY_TOKEN:0:16}...${RESET}"
echo -e "  Model: ${DIM}openai/${OPENAI_MODEL}${RESET}"
[[ -n "$TELEGRAM_BOT_TOKEN" ]] && echo -e "  Telegram: ${GREEN}configured${RESET}"
echo ""
echo -e "  Logs:    ${DIM}docker compose -f docker-compose.deploy.yml logs -f${RESET}"
echo -e "  Restart: ${DIM}docker compose -f docker-compose.deploy.yml restart${RESET}"
echo -e "  Stop:    ${DIM}docker compose -f docker-compose.deploy.yml down${RESET}"
echo ""
