#!/bin/bash
# =============================================================================
# PostgreSQL Initialization Script for GCP Compute Engine
# =============================================================================
# This script runs on first boot to install and configure PostgreSQL with
# optional pgvector extension.
#
# Usage: This script is called by the Terraform metadata_startup_script.
# All configuration comes from Terraform template variables.
#
# =============================================================================

set -e
set -x

LOG_FILE="/var/log/postgres-setup.log"
DB_NAME="${db_name}"
DB_USER="${db_user}"
POSTGRES_VERSION="${postgres_version}"
BACKUP_BUCKET="${backup_bucket}"
DATA_DISK_DEVICE="${data_disk_device}"
PGVECTOR_ENABLED="${pgvector_enabled}"
INIT_SQL="${init_sql}"
MAX_CONNECTIONS="${max_connections}"
SHARED_BUFFERS="${shared_buffers}"
WORK_MEM="${work_mem}"
MAINTENANCE_WORK_MEM="${maintenance_work_mem}"
MOUNT_POINT="/mnt/postgres-data"

echo "========================================="
echo "PostgreSQL Setup Starting"
echo "========================================="
echo "Timestamp: $(date)"
echo "DB_NAME: $DB_NAME"
echo "DB_USER: $DB_USER"
echo "POSTGRES_VERSION: $POSTGRES_VERSION"
echo "BACKUP_BUCKET: $BACKUP_BUCKET"
echo "DATA_DISK_DEVICE: /dev/$DATA_DISK_DEVICE"
echo "PGVECTOR_ENABLED: $PGVECTOR_ENABLED"
echo ""

# ============================================
# Step 1: System Updates
# ============================================
echo "===== Step 1: System Updates ====="
apt-get update
apt-get upgrade -y
apt-get install -y wget ca-certificates gnupg lsb-release curl

# ============================================
# Step 2: Mount Persistent Data Disk
# ============================================
echo ""
echo "===== Step 2: Mount Persistent Data Disk ====="

DISK_PATH="/dev/$DATA_DISK_DEVICE"

# Retry logic: disk might not be immediately available during startup
RETRY_COUNT=0
MAX_RETRIES=30
RETRY_DELAY=2

while [ ! -b "$DISK_PATH" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "Disk $DISK_PATH not found (attempt $((RETRY_COUNT+1))/$MAX_RETRIES). Waiting \${RETRY_DELAY}s..."
    sleep \${RETRY_DELAY}
    RETRY_COUNT=$((RETRY_COUNT+1))
done

if [ ! -b "$DISK_PATH" ]; then
    echo "WARNING: Disk $DISK_PATH not found after $MAX_RETRIES retries"
    echo "PostgreSQL will use boot disk (data will be lost on VM recreation!)"
else
    echo "Disk found after $RETRY_COUNT retries"
    mkdir -p "$MOUNT_POINT"

    if blkid "$DISK_PATH" > /dev/null 2>&1; then
        DISK_UUID=$(blkid -s UUID -o value "$DISK_PATH")
    else
        mkfs.ext4 -F "$DISK_PATH"
        DISK_UUID=$(blkid -s UUID -o value "$DISK_PATH")
    fi

    if ! grep -q "$DISK_UUID" /etc/fstab; then
        echo "UUID=$DISK_UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
    fi

    mount "$MOUNT_POINT" || mount "$DISK_PATH" "$MOUNT_POINT"

    if mountpoint -q "$MOUNT_POINT"; then
        echo "Disk successfully mounted to $MOUNT_POINT"
    else
        echo "WARNING: Disk mount failed - continuing with boot disk"
    fi
fi

# ============================================
# Step 3: Install PostgreSQL
# ============================================
echo ""
echo "===== Step 3: Install PostgreSQL $POSTGRES_VERSION ====="

apt-get update
apt-get install -y "postgresql-${POSTGRES_VERSION}" "postgresql-contrib-${POSTGRES_VERSION}" || {
    # Fallback: try PostgreSQL official repo
    sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
    apt-get update
    apt-get install -y "postgresql-${POSTGRES_VERSION}" "postgresql-contrib-${POSTGRES_VERSION}"
}

if ! command -v psql &> /dev/null; then
    echo "ERROR: psql not found after installation"
    exit 1
fi

echo "PostgreSQL installed successfully"
psql --version

# ============================================
# Step 4: Install pgvector (Optional)
# ============================================
echo ""
echo "===== Step 4: Install pgvector Extension ====="

if [ "$PGVECTOR_ENABLED" = "true" ]; then
    apt-get update
    apt-get install -y "postgresql-${POSTGRES_VERSION}-pgvector"
    systemctl restart postgresql
    sleep 2

    PGVERSION_NUM=$(pg_lsclusters -h | awk '{print $1}' | head -1)
    if [ -n "$PGVERSION_NUM" ]; then
        PGVECTOR_OUT=$(sudo -u postgres psql -p "$PGVERSION_NUM" -d postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>&1)
        if echo "$PGVECTOR_OUT" | grep -qE '(ERROR|error)' && ! echo "$PGVECTOR_OUT" | grep -q "already exists"; then
            echo "WARNING: pgvector creation returned output: $PGVECTOR_OUT"
        else
            echo "✓ pgvector extension enabled"
        fi
    fi
else
    echo "pgvector disabled (PGVECTOR_ENABLED=false)"
fi

# ============================================
# Step 5: Configure PostgreSQL Data Directory
# ============================================
echo ""
echo "===== Step 5: Configure PostgreSQL Data Directory ====="

systemctl stop postgresql || true

if [ -d "$MOUNT_POINT" ]; then
    PGVERSION_NUM=$(pg_lsclusters -h | awk '{print $1}' | head -1)
    mkdir -p "$MOUNT_POINT/postgresql/$PGVERSION_NUM/main"
    chown -R postgres:postgres "$MOUNT_POINT"
    chmod 700 "$MOUNT_POINT/postgresql/$PGVERSION_NUM/main"

    PG_DATA_DIR="/var/lib/postgresql/$PGVERSION_NUM/main"
    if [ -d "$PG_DATA_DIR" ] && [ ! -L "$PG_DATA_DIR" ]; then
        rm -rf "$PG_DATA_DIR"
    fi
    mkdir -p "$(dirname "$PG_DATA_DIR")"
    ln -s "$MOUNT_POINT/postgresql/$PGVERSION_NUM/main" "$PG_DATA_DIR" 2>/dev/null || true
fi

if [ ! -f "/var/lib/postgresql/$PGVERSION_NUM/main/PG_VERSION" ]; then
    sudo -u postgres /usr/lib/postgresql/$PGVERSION_NUM/bin/initdb -D "/var/lib/postgresql/$PGVERSION_NUM/main"
fi

# ============================================
# Step 6: Configure PostgreSQL
# ============================================
echo ""
echo "===== Step 6: Configure PostgreSQL ====="

PGVERSION_NUM=$(pg_lsclusters -h | awk '{print $1}' | head -1)
PG_CONF="/etc/postgresql/$PGVERSION_NUM/main/postgresql.conf"
PG_HBA="/etc/postgresql/$PGVERSION_NUM/main/pg_hba.conf"

# Backup originals
[ -f "$PG_CONF" ] && cp "$PG_CONF" "${PG_CONF}.backup"
[ -f "$PG_HBA" ] && cp "$PG_HBA" "${PG_HBA}.backup"

# Configure pg_hba.conf
cat > "$PG_HBA" <<'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             10.0.0.0/8              scram-sha-256
EOF

chmod 600 "$PG_HBA"
chown postgres:postgres "$PG_HBA"

# Configure postgresql.conf
sed -i "/^#*listen_addresses/d" "$PG_CONF"

cat >> "$PG_CONF" <<EOF

# Connection Settings
listen_addresses = '*'
max_connections = ${MAX_CONNECTIONS}
superuser_reserved_connections = 3

# Memory Settings
shared_buffers = ${SHARED_BUFFERS}
effective_cache_size = 768MB
maintenance_work_mem = ${MAINTENANCE_WORK_MEM}
work_mem = ${WORK_MEM}

# Write-Ahead Log
wal_buffers = 8MB
max_wal_size = 1GB
min_wal_size = 80MB
checkpoint_completion_target = 0.9

# Query Planning
random_page_cost = 1.1
effective_io_concurrency = 200

# Logging
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %u@%d '
log_timezone = 'UTC'

# Autovacuum
autovacuum = on
autovacuum_max_workers = 2
autovacuum_naptime = 30s

# Locale and Timezone
datestyle = 'iso, mdy'
timezone = 'UTC'
lc_messages = 'en_US.UTF-8'
lc_monetary = 'en_US.UTF-8'
lc_numeric = 'en_US.UTF-8'
lc_time = 'en_US.UTF-8'
default_text_search_config = 'pg_catalog.english'
EOF

# ============================================
# Step 7: Start PostgreSQL and Create Database
# ============================================
echo ""
echo "===== Step 7: Start PostgreSQL and Create Database ====="

if ! mountpoint -q "$MOUNT_POINT" && [ -b "$DISK_PATH" ]; then
    mount "$MOUNT_POINT" || mount "$DISK_PATH" "$MOUNT_POINT"
fi

PGVERSION_NUM=$(pg_lsclusters -h | awk '{print $1}' | head -1)
pg_ctlcluster $PGVERSION_NUM main stop 2>/dev/null || true

PG_DATA_DIR="/var/lib/postgresql/$PGVERSION_NUM/main"
PG_LOG_DIR="$PG_DATA_DIR/log"
mkdir -p "$PG_LOG_DIR"
chown postgres:postgres "$PG_LOG_DIR"

sudo -u postgres /usr/lib/postgresql/$PGVERSION_NUM/bin/pg_ctl -D "$PG_DATA_DIR" -l "$PG_LOG_DIR/startup.log" start -o "-c config_file=$PG_CONF"

echo "Waiting for PostgreSQL to be ready..."
for i in $(seq 1 60); do
    if sudo -u postgres psql -p "$PGVERSION_NUM" -c "SELECT 1;" >/dev/null 2>&1; then
        echo "PostgreSQL ready (attempt $i/60)"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "ERROR: PostgreSQL did not become ready"
        cat "$PG_LOG_DIR/startup.log" || true
        exit 1
    fi
    sleep 2
done

# Create database and user
echo "Creating database and user..."
sudo -u postgres psql -p "$PGVERSION_NUM" <<SQL
CREATE USER $DB_USER WITH PASSWORD '$DB_USER';
CREATE DATABASE $DB_NAME OWNER $DB_USER;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
\\c $DB_NAME
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
SQL

# ============================================
# Step 8: Run Custom SQL (Schema Injection)
# ============================================
echo ""
echo "===== Step 8: Run Custom Schema (if provided) ====="

if [ -n "$INIT_SQL" ] && [ "$INIT_SQL" != "" ]; then
    echo "Running custom schema SQL..."
    echo "$INIT_SQL" | sudo -u postgres psql -p "$PGVERSION_NUM" -d "$DB_NAME" || {
        echo "WARNING: Custom SQL failed - continuing anyway"
    }
else
    echo "No custom SQL provided (INIT_SQL is empty)"
fi

# ============================================
# Step 9: Enable Auto-Restart and Systemd Override
# ============================================
echo ""
echo "===== Step 9: Configure Startup ====="

systemctl enable postgresql

sudo -u postgres psql -p "$PGVERSION_NUM" -c "ALTER SYSTEM SET listen_addresses = '*';"

mkdir -p /etc/systemd/system/postgresql.service.d
cat > /etc/systemd/system/postgresql.service.d/override.conf <<'OVERRIDE'
[Unit]
After=local-fs.target
Before=postgresql.service
OVERRIDE

systemctl daemon-reload

# ============================================
# Step 10: Setup Backup Cron
# ============================================
echo ""
echo "===== Step 10: Setup Automated Backups ====="

BACKUP_SCRIPT_DIR="/opt/postgres-backup"
mkdir -p "$BACKUP_SCRIPT_DIR"

cat > "$BACKUP_SCRIPT_DIR/backup.sh" <<'BACKUP'
#!/bin/bash
set -e
BACKUP_BUCKET="${BACKUP_BUCKET}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
BACKUP_DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILE="pgbackup_${DB_NAME}_${BACKUP_DATE}.sql.gz"
PGVERSION=$(pg_lsclusters -h | awk '{print $1}' | head -1)

echo "Starting PostgreSQL backup to gs://${BACKUP_BUCKET}..."

sudo -u postgres pg_dump -p "$PGVERSION" -d ${DB_NAME} | gzip > /tmp/${BACKUP_FILE}
gsutil cp /tmp/${BACKUP_FILE} gs://${BACKUP_BUCKET}/${BACKUP_FILE}
rm -f /tmp/${BACKUP_FILE}

echo "Backup complete: gs://${BACKUP_BUCKET}/${BACKUP_FILE}"
BACKUP

chmod +x "$BACKUP_SCRIPT_DIR/backup.sh"

# Install google-cloud-sdk for gsutil if not present
if ! command -v gsutil &> /dev/null; then
    apt-get install -y python3-pip
    pip3 install google-cloud-storage --quiet
fi

# Add to crontab (daily at 2am UTC)
CRON_ENTRY="0 2 * * * $BACKUP_SCRIPT_DIR/backup.sh >> /var/log/postgres-backup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "postgres-backup"; echo "$CRON_ENTRY") | crontab -

echo "✓ Backup cron configured (daily at 2am UTC)"

# ============================================
# Done
# ============================================
echo ""
echo "========================================="
echo "PostgreSQL Setup Completed"
echo "========================================="
echo "Database: $DB_NAME"
echo "User: $DB_USER"
echo "Version: $POSTGRES_VERSION"
echo "pgvector: $PGVECTOR_ENABLED"
echo "Timestamp: $(date)"
echo ""
echo "Connection (internal):"
echo "  psql -h <internal_ip> -U $DB_USER -d $DB_NAME"
echo ""
echo "========================================="
