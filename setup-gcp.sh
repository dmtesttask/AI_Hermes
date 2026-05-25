#!/usr/bin/env bash
# ============================================================================
#  🚀 Automated GCP Deployment for Virtual Examination Commission
#  Based on Hermes Agent (https://github.com/nousresearch/hermes-agent)
# ============================================================================
#  Run this script in Google Cloud Shell:
#    git clone https://github.com/dmtesttask/AI_Hermes.git HermesCommission
#    cd HermesCommission
#    chmod +x setup-gcp.sh
#    ./setup-gcp.sh
# ============================================================================

set -euo pipefail

# ─── Colors & formatting ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_step() {
    echo -e "${GREEN}  ✅ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}  ℹ️  $1${NC}"
}

print_error() {
    echo -e "${RED}  ❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}  ⚠️  $1${NC}"
}

# ─── Configuration ──────────────────────────────────────────────────────────
VM_NAME="hermes-commission"
ZONE="us-central1-a"
MACHINE_TYPE="e2-medium"
IMAGE_FAMILY="ubuntu-2404-lts-amd64"
IMAGE_PROJECT="ubuntu-os-cloud"
BOOT_DISK_SIZE="30GB"
BOOT_DISK_TYPE="pd-standard"
SA_NAME="hermes-vm-sa"
SECRET_API_KEY="hermes-gemini-api-key"
SECRET_TG_TOKEN="hermes-telegram-bot-token"
REPO_URL="https://github.com/dmtesttask/AI_Hermes.git"

# ─── Step 0: Verify prerequisites ──────────────────────────────────────────
print_header "🔍 Перевірка передумов"

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    print_error "GCP-проєкт не налаштовано! Виконайте: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi
print_step "GCP-проєкт: ${BOLD}${PROJECT_ID}${NC}"

# Check billing
BILLING_ENABLED=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")
if [ "$BILLING_ENABLED" != "True" ]; then
    print_warning "Білінг може бути не підключено. Для Compute Engine потрібна платіжна картка."
    read -rp "  Продовжити? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Скасовано."
        exit 0
    fi
fi

# ─── Step 1: Collect secrets from user ──────────────────────────────────────
print_header "🔑 Введіть API-ключі"

# Check if secrets already exist
SECRET_API_KEY_EXISTS=false
SECRET_TG_TOKEN_EXISTS=false

if gcloud secrets versions describe latest --secret="$SECRET_API_KEY" --project="$PROJECT_ID" &>/dev/null; then
    SECRET_API_KEY_EXISTS=true
fi

if gcloud secrets versions describe latest --secret="$SECRET_TG_TOKEN" --project="$PROJECT_ID" &>/dev/null; then
    SECRET_TG_TOKEN_EXISTS=true
fi

USE_EXISTING_SECRETS="n"
if [ "$SECRET_API_KEY_EXISTS" = "true" ] && [ "$SECRET_TG_TOKEN_EXISTS" = "true" ]; then
    print_info "Знайдено існуючі ключі в Secret Manager."
    read -rp "  Використати існуючі ключі? (Y/n): " reuse_confirm
    reuse_confirm=${reuse_confirm:-Y}
    if [[ "$reuse_confirm" =~ ^[Yy]$ ]]; then
        USE_EXISTING_SECRETS="y"
    fi
fi

if [ "$USE_EXISTING_SECRETS" = "y" ]; then
    print_step "Використовуються існуючі API-ключі з Secret Manager"
else
    echo -e "${YELLOW}  Отримайте Gemini API Key на: https://aistudio.google.com/${NC}"
    read -rsp "  Введіть Gemini API Key: " GEMINI_KEY
    echo ""
    if [ -z "$GEMINI_KEY" ]; then
        print_error "Gemini API Key не може бути порожнім!"
        exit 1
    fi
    print_step "Gemini API Key отримано"

    echo ""
    echo -e "${YELLOW}  Створіть бота через @BotFather у Telegram${NC}"
    read -rsp "  Введіть Telegram Bot Token: " TG_TOKEN
    echo ""
    if [ -z "$TG_TOKEN" ]; then
        print_error "Telegram Bot Token не може бути порожнім!"
        exit 1
    fi
    print_step "Telegram Bot Token отримано"
fi

# ─── Step 2: Enable APIs ────────────────────────────────────────────────────
print_header "⚙️  Увімкнення API"

print_info "Увімкнення Compute Engine API..."
gcloud services enable compute.googleapis.com --project="$PROJECT_ID" --quiet
print_step "Compute Engine API увімкнено"

print_info "Увімкнення Secret Manager API..."
gcloud services enable secretmanager.googleapis.com --project="$PROJECT_ID" --quiet
print_step "Secret Manager API увімкнено"

# ─── Step 3: Store secrets ──────────────────────────────────────────────────
print_header "🔐 Налаштування Secret Manager"

# Function to create or update a secret
store_secret() {
    local secret_name="$1"
    local secret_value="$2"

    if gcloud secrets describe "$secret_name" --project="$PROJECT_ID" &>/dev/null; then
        print_info "Оновлення секрету '$secret_name'..."
        echo -n "$secret_value" | gcloud secrets versions add "$secret_name" \
            --project="$PROJECT_ID" \
            --data-file=- \
            --quiet
    else
        print_info "Створення секрету '$secret_name'..."
        echo -n "$secret_value" | gcloud secrets create "$secret_name" \
            --project="$PROJECT_ID" \
            --data-file=- \
            --replication-policy="automatic" \
            --quiet
    fi
    print_step "Секрет '$secret_name' збережено"
}

if [ "$USE_EXISTING_SECRETS" != "y" ]; then
    store_secret "$SECRET_API_KEY" "$GEMINI_KEY"
    store_secret "$SECRET_TG_TOKEN" "$TG_TOKEN"
    
    # Clear secrets from memory
    unset GEMINI_KEY
    unset TG_TOKEN
else
    print_step "Ключі вже збережено в Secret Manager"
fi

# ─── Step 4: Create Service Account ────────────────────────────────────────
print_header "👤 Налаштування сервісного акаунту"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
    print_info "Сервісний акаунт '$SA_NAME' вже існує"
else
    print_info "Створення сервісного акаунту '$SA_NAME'..."
    gcloud iam service-accounts create "$SA_NAME" \
        --project="$PROJECT_ID" \
        --display-name="Hermes Commission VM Service Account" \
        --quiet
fi
print_step "Сервісний акаунт: $SA_EMAIL"

# Grant access to secrets (resource-level, minimum privileges)
# Wait a moment for Service Account replication in IAM
print_info "Очікування реплікації сервісного акаунту в IAM..."
sleep 5

for secret in "$SECRET_API_KEY" "$SECRET_TG_TOKEN"; do
    print_info "Надання доступу до секрету '$secret'..."
    
    success=false
    for attempt in 1 2 3; do
        if gcloud secrets add-iam-policy-binding "$secret" \
            --project="$PROJECT_ID" \
            --member="serviceAccount:${SA_EMAIL}" \
            --role="roles/secretmanager.secretAccessor" \
            --quiet >/dev/null; then
            success=true
            break
        else
            print_warning "Спроба $attempt не вдалася. Очікування реплікації IAM..."
            sleep 5
        fi
    done

    if [ "$success" = "false" ]; then
        print_error "Не вдалося надати доступ до секрету '$secret' після кількох спроб."
        exit 1
    fi
done
print_step "Права доступу до секретів налаштовано (мінімальні привілеї)"

# ─── Step 5: Generate VM startup script ─────────────────────────────────────
print_header "📝 Генерація startup-скрипту для VM"

STARTUP_SCRIPT_PATH="/tmp/hermes-vm-startup.sh"

cat > "$STARTUP_SCRIPT_PATH" << 'STARTUP_SCRIPT_EOF'
#!/usr/bin/env bash
# ============================================================================
#  VM Startup Script — Hermes Agent Installation & Configuration
#  This script runs automatically when the VM boots for the first time.
# ============================================================================

set -euo pipefail
exec > >(tee -a /var/log/hermes-setup.log) 2>&1

echo "=========================================="
echo "  Hermes Agent VM Setup — $(date)"
echo "=========================================="

# ─── Guard: skip if already set up ───────────────────────────────────────────
SETUP_MARKER="/var/lib/hermes-setup-complete"
if [ -f "$SETUP_MARKER" ]; then
    echo "Setup already completed on $(cat $SETUP_MARKER). Skipping."
    exit 0
fi

# ─── Retrieve project metadata ──────────────────────────────────────────────
PROJECT_ID=$(curl -s "http://metadata.google.internal/computeMetadata/v1/project/project-id" -H "Metadata-Flavor: Google")
echo "Project ID: $PROJECT_ID"

# ─── Update system packages ─────────────────────────────────────────────────
echo "[1/9] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y curl git jq

echo "[2/9] Installing Node.js 22 LTS..."
# Install Node.js 22 LTS via NodeSource
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"

# ─── Create hermes system user ──────────────────────────────────────────────
echo "[3/9] Creating 'hermes' system user..."
if ! id "hermes" &>/dev/null; then
    useradd --system --create-home --shell /bin/bash --home-dir /home/hermes hermes
fi

# ─── Install Hermes Agent ────────────────────────────────────────────────────
echo "[4/9] Installing Hermes Agent..."
su - hermes -c 'curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash'

# Ensure hermes binary is on PATH for the hermes user
HERMES_BIN_DIR="/home/hermes/.local/bin"
if [ -d "$HERMES_BIN_DIR" ]; then
    echo "export PATH=\"$HERMES_BIN_DIR:\$PATH\"" >> /home/hermes/.bashrc
fi

# Also ensure it works via sudo
HERMES_BIN=$(su - hermes -c 'which hermes 2>/dev/null || echo ""')
if [ -z "$HERMES_BIN" ]; then
    # Try common locations
    for candidate in /home/hermes/.local/bin/hermes /home/hermes/.hermes/bin/hermes /usr/local/bin/hermes; do
        if [ -x "$candidate" ]; then
            HERMES_BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$HERMES_BIN" ]; then
    echo "ERROR: Could not find hermes binary after installation!"
    exit 1
fi
echo "Hermes binary found at: $HERMES_BIN"

# ─── Retrieve secrets from Secret Manager ────────────────────────────────────
echo "[5/9] Retrieving secrets from Secret Manager..."
GEMINI_KEY=$(gcloud secrets versions access latest --secret="hermes-gemini-api-key" --project="$PROJECT_ID")
TG_TOKEN=$(gcloud secrets versions access latest --secret="hermes-telegram-bot-token" --project="$PROJECT_ID")

if [ -z "$GEMINI_KEY" ] || [ -z "$TG_TOKEN" ]; then
    echo "ERROR: Failed to retrieve secrets from Secret Manager!"
    exit 1
fi
echo "Secrets retrieved successfully."

# ─── Configure Hermes Agent ──────────────────────────────────────────────────
echo "[6/9] Configuring Hermes Agent..."

HERMES_HOME="/home/hermes/.hermes"

# Create required directories
su - hermes -c "mkdir -p ${HERMES_HOME}/{cron,sessions,logs,memories,skills}"

# Create .env with API keys and workspace config
cat > "${HERMES_HOME}/.env" << ENV_EOF
GOOGLE_API_KEY=${GEMINI_KEY}
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
MESSAGING_CWD=/home/hermes/workspace
ENV_EOF
chown hermes:hermes "${HERMES_HOME}/.env"
chmod 600 "${HERMES_HOME}/.env"

# Clear secrets from memory
unset GEMINI_KEY
unset TG_TOKEN

# Run non-interactive setup to bootstrap config structure
su - hermes -c "hermes setup --non-interactive" || true

# Write complete config.yaml from scratch (avoids YAML section duplication)
HERMES_CONFIG="${HERMES_HOME}/config.yaml"
cat > "$HERMES_CONFIG" << 'YAML_EOF'
# Hermes Agent Configuration — Virtual Examination Commission
# Auto-generated by setup-gcp.sh

model:
  default: "gemini-3.1-flash-lite"
  provider: "gemini"
  base_url: "https://generativelanguage.googleapis.com/v1beta"

agent:
  disabled_toolsets:
    - terminal
    - file
    - web
    - memory
    - code
    - browser
    - image_gen
    - video
    - tts
    - skills
    - code_execution

delegation:
  orchestrator_enabled: true
  max_concurrent_children: 1
  max_spawn_depth: 1
  child_timeout_seconds: 120
YAML_EOF
chown hermes:hermes "$HERMES_CONFIG"

# ─── Deploy workspace files (SOUL.md + AGENTS.md) ───────────────────────────
echo "[7/9] Deploying agent configuration files..."

WORKSPACE_DIR="/home/hermes/workspace"
mkdir -p "$WORKSPACE_DIR"

# Clone the repository to get config files
REPO_TMP="/tmp/hermes-repo"
rm -rf "$REPO_TMP"
git clone https://github.com/dmtesttask/AI_Hermes.git "$REPO_TMP"

# SOUL.md goes to HERMES_HOME (that's where Hermes loads it from)
cp "$REPO_TMP/config/workspace/SOUL.md" "${HERMES_HOME}/SOUL.md"
echo "SOUL.md deployed to ${HERMES_HOME}/SOUL.md"

# AGENTS.md goes to workspace (loaded from CWD / MESSAGING_CWD)
cp "$REPO_TMP/config/workspace/AGENTS.md" "$WORKSPACE_DIR/AGENTS.md"
echo "AGENTS.md deployed to $WORKSPACE_DIR/AGENTS.md"

# Set ownership
chown -R hermes:hermes "$WORKSPACE_DIR"
chown -R hermes:hermes "$HERMES_HOME"

# Cleanup
rm -rf "$REPO_TMP"

# ─── Configure Telegram gateway ─────────────────────────────────────────────
echo "[8/9] Configuring Telegram gateway..."

# MESSAGING_CWD is already set in .env (step 6)
# This ensures AGENTS.md is loaded from /home/hermes/workspace
echo "MESSAGING_CWD configured via .env"

# ─── Install and start systemd service ───────────────────────────────────────
echo "[9/9] Installing systemd service..."

# Install as system-wide service (runs from root, the startup script is root)
sudo hermes gateway install --system 2>/dev/null || {
    echo "Auto-install failed, creating systemd service manually..."
    
    cat > /etc/systemd/system/hermes-gateway.service << SYSTEMD_EOF
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hermes
Group=hermes
WorkingDirectory=/home/hermes/workspace
ExecStart=${HERMES_BIN} gateway
Restart=always
RestartSec=10
Environment=HOME=/home/hermes
Environment=HERMES_HOME=${HERMES_HOME}
Environment=MESSAGING_CWD=/home/hermes/workspace

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

    systemctl daemon-reload
}

systemctl enable hermes-gateway
systemctl start hermes-gateway

# ─── Create convenience alias ────────────────────────────────────────────────
cat > /etc/profile.d/hermes-alias.sh << 'ALIAS_EOF'
# Hermes Agent convenience alias — runs commands as the hermes user
if [ "$(id -u -n)" != "hermes" ]; then
    hermes() {
        sudo -u hermes -i hermes "$@"
    }
    export -f hermes 2>/dev/null || true
fi
ALIAS_EOF
chmod +x /etc/profile.d/hermes-alias.sh

# ─── Mark setup as complete (prevents re-run on VM reboot) ──────────────────
date > "$SETUP_MARKER"

echo ""
echo "=========================================="
echo "  ✅ Hermes Agent setup complete!"
echo "  📋 Logs: /var/log/hermes-setup.log"
echo "  🔍 Status: systemctl status hermes-gateway"
echo "  📝 Gateway logs: journalctl -u hermes-gateway -f"
echo "=========================================="

STARTUP_SCRIPT_EOF

chmod +x "$STARTUP_SCRIPT_PATH"
print_step "Startup-скрипт згенеровано"

# ─── Step 6: Create VM ──────────────────────────────────────────────────────
print_header "🖥️  Створення віртуальної машини"

# Check if VM already exists
if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
    print_warning "VM '$VM_NAME' вже існує!"
    read -rp "  Видалити та створити заново? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Видалення існуючої VM..."
        gcloud compute instances delete "$VM_NAME" \
            --zone="$ZONE" \
            --project="$PROJECT_ID" \
            --quiet
        print_step "Існуючу VM видалено"
    else
        print_info "Залишаємо існуючу VM. Оновлюємо startup-скрипт..."
        gcloud compute instances add-metadata "$VM_NAME" \
            --zone="$ZONE" \
            --project="$PROJECT_ID" \
            --metadata-from-file startup-script="$STARTUP_SCRIPT_PATH" \
            --quiet
        print_step "Startup-скрипт оновлено. Перезапустіть VM для застосування."
        
        # Cleanup
        rm -f "$STARTUP_SCRIPT_PATH"
        
        print_header "🎉 Готово!"
        echo -e "${GREEN}  VM вже існує. Для застосування нових налаштувань:${NC}"
        echo -e "  ${CYAN}gcloud compute instances reset $VM_NAME --zone=$ZONE${NC}"
        exit 0
    fi
fi

print_info "Створення VM '$VM_NAME' (${MACHINE_TYPE}, ${ZONE})..."
gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$BOOT_DISK_SIZE" \
    --boot-disk-type="$BOOT_DISK_TYPE" \
    --service-account="$SA_EMAIL" \
    --scopes="cloud-platform" \
    --metadata-from-file startup-script="$STARTUP_SCRIPT_PATH" \
    --tags=hermes-server \
    --quiet

print_step "VM '$VM_NAME' створено та запущено"

# Cleanup temp file
rm -f "$STARTUP_SCRIPT_PATH"

# ─── Step 7: Wait for initialization ────────────────────────────────────────
print_header "⏳ Очікування ініціалізації VM"

print_info "Startup-скрипт виконується на VM (це може зайняти 3-5 хвилин)..."
print_info "Ви можете слідкувати за прогресом через SSH:"
echo -e "  ${CYAN}gcloud compute ssh $VM_NAME --zone=$ZONE --command='tail -f /var/log/hermes-setup.log'${NC}"

echo ""
print_info "Очікуємо завершення (перевірка кожні 30 секунд)..."

MAX_RETRIES=20
RETRY=0
while [ $RETRY -lt $MAX_RETRIES ]; do
    sleep 30
    RETRY=$((RETRY + 1))
    
    # Check if setup log contains completion message
    SETUP_DONE=$(gcloud compute ssh "$VM_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID" \
        --command="grep -c 'setup complete' /var/log/hermes-setup.log 2>/dev/null || echo 0" \
        --quiet 2>/dev/null || echo "0")
    
    if [ "$SETUP_DONE" != "0" ]; then
        print_step "Ініціалізація VM завершена!"
        break
    fi
    
    echo -e "  ${YELLOW}  ... ще працює (${RETRY}/${MAX_RETRIES})${NC}"
done

if [ $RETRY -eq $MAX_RETRIES ]; then
    print_warning "Час очікування вичерпано. VM може ще ініціалізуватись."
    print_info "Перевірте стан вручну:"
    echo -e "  ${CYAN}gcloud compute ssh $VM_NAME --zone=$ZONE${NC}"
    echo -e "  ${CYAN}cat /var/log/hermes-setup.log${NC}"
fi

# ─── Final instructions ─────────────────────────────────────────────────────
print_header "🎉 Розгортання завершено!"

echo ""
echo -e "${BOLD}  Наступні кроки:${NC}"
echo ""
echo -e "  ${CYAN}1.${NC} Знайдіть вашого бота в Telegram і надішліть будь-яке повідомлення."
echo -e "  ${CYAN}2.${NC} Бот відповість кодом сполучення (Pairing Code)."
echo -e "  ${CYAN}3.${NC} Підключіться до VM:"
echo -e "     ${CYAN}gcloud compute ssh $VM_NAME --zone=$ZONE${NC}"
echo -e "  ${CYAN}4.${NC} Активуйте бота (введіть код з кроку 2):"
echo -e "     ${CYAN}hermes pairing approve telegram <ВАШ_КОД>${NC}"
echo ""
echo -e "${BOLD}  Корисні команди:${NC}"
echo -e "  ${CYAN}journalctl -u hermes-gateway -f${NC}        # Логи gateway"
echo -e "  ${CYAN}hermes doctor${NC}                          # Діагностика"
echo -e "  ${CYAN}systemctl status hermes-gateway${NC}        # Статус сервісу"
echo -e "  ${CYAN}sudo systemctl restart hermes-gateway${NC}  # Перезапуск"
echo ""
echo -e "${YELLOW}  ⚠️  Після pairing бот готовий до роботи!${NC}"
echo -e "${YELLOW}  📄 Студент надсилає PDF-файл роботи → захист починається автоматично.${NC}"
echo ""
