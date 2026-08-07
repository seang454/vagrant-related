#!/bin/bash
# interactive_deploy_service.sh
# Fully automated script to deploy a systemd service with interactive prompts

set -e  # Exit if any command fails

# ------------------------------
# Function to prompt user with default value
# ------------------------------
prompt() {
    local var_name=$1
    local default_value=$2
    read -p "$var_name [$default_value]: " input
    echo "${input:-$default_value}"
}

# ------------------------------
# Prompt for service details
# ------------------------------
SERVICE_NAME=$(prompt "Service name" "myapp")
EXEC_START=$(prompt "Executable path" "/usr/local/bin/$SERVICE_NAME")
USER_NAME=$(prompt "User to run service as" "vagrant")
WORKING_DIR=$(prompt "Working directory" "/home/vagrant")

# ------------------------------
# Check for root
# ------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

# ------------------------------
# Create the executable if it doesn't exist
# ------------------------------
if [[ ! -f $EXEC_START ]]; then
    echo "Creating default executable at $EXEC_START..."
    mkdir -p $(dirname "$EXEC_START")  # create parent directories if missing
    cat <<EOL > $EXEC_START
#!/bin/bash
while true; do
    echo "\$(date) - $SERVICE_NAME is running..." >> $WORKING_DIR/${SERVICE_NAME}.log
    sleep 10
done
EOL
    chmod +x $EXEC_START
    echo "Executable created and made executable."
fi

# ------------------------------
# Create systemd service
# ------------------------------
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Backup existing service file if it exists
if [[ -f $SERVICE_FILE ]]; then
    echo "Backing up existing service file..."
    cp "$SERVICE_FILE" "${SERVICE_FILE}.bak.$(date +%F_%T)"
fi

# Create the service file
echo "Creating systemd service at $SERVICE_FILE..."
cat <<EOF > $SERVICE_FILE
[Unit]
Description=Service $SERVICE_NAME
After=network.target

[Service]
Type=simple
ExecStart=$EXEC_START
WorkingDirectory=$WORKING_DIR
Restart=on-failure
User=$USER_NAME
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------
# Reload systemd, enable, start service
# ------------------------------
echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Enabling $SERVICE_NAME to start on boot..."
systemctl enable $SERVICE_NAME

echo "Starting $SERVICE_NAME..."
systemctl restart $SERVICE_NAME

# ------------------------------
# Show status
# ------------------------------
echo "Service $SERVICE_NAME status:"
systemctl status $SERVICE_NAME --no-pager

