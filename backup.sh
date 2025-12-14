#!/bin/sh

# ==============================================================================
#  PostgreSQL 自动化备份脚本
#
#  功能:
#  1. 备份所有 PostgreSQL 数据库.
#  2. 使用 7z 进行压缩，并可选地使用 AES-256 加密.
#  3. 通过 rsync 将备份文件上传到远程服务器 (支持 ssh 和 daemon 两种模式).
#  4. 自动清理本地的旧备份文件.
# ==============================================================================

# --- 脚本行为设置 ---
# -e: 如果任何命令返回非零退出状态（表示错误），脚本将立即退出。
# -o pipefail: 如果管道中的任何命令失败，则整个管道的退出状态将为失败。
set -e -o pipefail

# ==============================================================================
#  配置项 (从环境变量读取)
# ==============================================================================

# --- PostgreSQL & 本地备份配置 ---
PGHOST=${PGHOST:-"postgresql"}
PGPORT=${PGPORT:-"5432"}
PGUSER=${PGUSER:-"postgres"}
PGPASSWORD=${PGPASSWORD} # 必须通过环境变量设置
BACKUP_DIR="/backups"
BACKUP_FILENAME="pg_backup_$(date +%Y%m%d_%H%M%S).sql.7z"
BACKUP_FILE_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"

# --- 7z 加密配置 ---
# 如果设置了此密码，备份文件将被加密。如果为空，则只压缩不加密。
ENCRYPTION_PASSWORD=${ENCRYPTION_PASSWORD}

# --- Rsync 远程上传配置 ---
RSYNC_ENABLED=${RSYNC_ENABLED:-"true"}
# 上传协议: "ssh" (默认) 或 "rsync" (daemon 模式)
RSYNC_PROTOCOL=${RSYNC_PROTOCOL:-"ssh"}
RSYNC_HOST=${RSYNC_HOST}
RSYNC_USER=${RSYNC_USER}
# 对于 ssh 模式, 这是远程的完整路径, e.g., /data/backups
# 对于 rsync 模式, 这是 rsync 模块名, e.g., pg_backups
RSYNC_REMOTE_PATH=${RSYNC_REMOTE_PATH}

# -- SSH 模式专用配置 --
RSYNC_PORT_SSH=${RSYNC_PORT_SSH:-"22"}
SSH_PRIVATE_KEY_PATH="/root/.ssh/id_rsa"

# -- Daemon 模式专用配置 --
RSYNC_PORT_DAEMON=${RSYNC_PORT_DAEMON:-"873"}
RSYNC_PASSWORD=${RSYNC_PASSWORD} # rsync 模块的密码

# ==============================================================================
#  函数定义
# ==============================================================================

# 函数: 打印带时间戳的日志
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - INFO - $1"
}

# 函数: 打印错误日志并退出
fail() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ERROR - $1" >&2
    exit 1
}

# 函数: 执行本地数据库备份、压缩和加密
perform_local_backup() {
    log "--- [Step 1/3] Starting Local Backup and Compression ---"

    log "Checking connection to PostgreSQL at ${PGHOST}:${PGPORT}..."
    if ! pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -q; then
        fail "Unable to connect to PostgreSQL. Please check connection settings."
    fi
    log "PostgreSQL connection successful."

    # 准备 pg_dumpall 命令
    DUMP_CMD="pg_dumpall --clean --if-exists -h \"$PGHOST\" -p \"$PGPORT\" -U \"$PGUSER\""

    # 根据是否存在加密密码，准备 7z 命令
    if [ -n "$ENCRYPTION_PASSWORD" ]; then
        log "Dumping and ENCRYPTING all databases to ${BACKUP_FILE_PATH}..."
        # -p: 设置密码. -mhe=on: 加密文件头, 增强安全性.
        COMPRESS_CMD="7z a -si -t7z -mhe=on -p${ENCRYPTION_PASSWORD} \"${BACKUP_FILE_PATH}\""
    else
        log "Dumping and COMPRESSING all databases to ${BACKUP_FILE_PATH} (encryption is OFF)..."
        COMPRESS_CMD="7z a -si -t7z \"${BACKUP_FILE_PATH}\""
    fi

    # 使用管道连接 dump 和 compress 命令
    # 使用 eval 来正确处理命令中的引号
    log "Executing: pg_dumpall | 7z ..."
    if ! eval "$DUMP_CMD | $COMPRESS_CMD"; then
        fail "The backup command (pg_dumpall | 7z) failed."
    fi

    # 验证备份文件是否已成功创建且不为空
    if [ -s "${BACKUP_FILE_PATH}" ]; then
        log "Local backup file created successfully: ${BACKUP_FILE_PATH}"
        log "File size: $(ls -lh ${BACKUP_FILE_PATH} | awk '{print $5}')"
    else
        # 如果文件为空或不存在，则清理并失败
        rm -f "${BACKUP_FILE_PATH}"
        fail "Local backup failed. Output file is empty or was not created."
    fi
    log "--- [Step 1/3] Local Backup Finished ---"
}

# 函数: 将备份文件上传到远程 rsync 服务器
upload_to_rsync() {
    if [ "${RSYNC_ENABLED}" != "true" ]; then
        log "--- [Step 2/3] Rsync upload is disabled. Skipping. ---"
        return
    fi

    log "--- [Step 2/3] Starting Rsync Upload (Protocol: ${RSYNC_PROTOCOL}) ---"

    if [ "${RSYNC_PROTOCOL}" = "ssh" ]; then
        # SSH 模式
        if [ -z "$RSYNC_HOST" ] || [ -z "$RSYNC_USER" ] || [ -z "$RSYNC_REMOTE_PATH" ]; then
            fail "For SSH mode, RSYNC_HOST, RSYNC_USER, and RSYNC_REMOTE_PATH must be set."
        fi
        if [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
            fail "SSH private key not found at ${SSH_PRIVATE_KEY_PATH}. Please mount it correctly."
        fi
        chmod 600 "$SSH_PRIVATE_KEY_PATH"

        RSYNC_TARGET="${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_REMOTE_PATH}"
        log "Uploading via SSH to ${RSYNC_TARGET}..."
        rsync -avz \
          -e "ssh -p ${RSYNC_PORT_SSH} -i ${SSH_PRIVATE_KEY_PATH} -o StrictHostKeyChecking=no -o ConnectTimeout=30" \
          "${BACKUP_FILE_PATH}" \
          "${RSYNC_TARGET}"

    elif [ "${RSYNC_PROTOCOL}" = "rsync" ]; then
        # Daemon 模式
        if [ -z "$RSYNC_HOST" ] || [ -z "$RSYNC_USER" ] || [ -z "$RSYNC_REMOTE_PATH" ]; then
            fail "For rsync daemon mode, RSYNC_HOST, RSYNC_USER, and RSYNC_REMOTE_PATH (module name) must be set."
        fi
        if [ -z "$RSYNC_PASSWORD" ]; then
            fail "RSYNC_PASSWORD must be set for rsync daemon mode."
        fi

        export RSYNC_PASSWORD
        RSYNC_TARGET="rsync://${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_PORT_DAEMON}/${RSYNC_REMOTE_PATH}"
        log "Uploading via rsync daemon to ${RSYNC_TARGET}..."
        rsync -avz \
          "${BACKUP_FILE_PATH}" \
          "${RSYNC_TARGET}/"
    else
        fail "Invalid RSYNC_PROTOCOL specified: '${RSYNC_PROTOCOL}'. Use 'ssh' or 'rsync'."
    fi

    log "Rsync upload completed successfully."
    log "--- [Step 2/3] Rsync Upload Finished ---"
}

# 函数: 清理本地旧的备份文件
cleanup_local_backups() {
    KEEP_DAYS=${KEEP_DAYS:-7}
    log "--- [Step 3/3] Cleaning up old local backups, keeping last ${KEEP_DAYS} days... ---"

    if ! find "${BACKUP_DIR}" -name "pg_backup_*.sql.7z" -mtime +${KEEP_DAYS} -print -exec rm -f {} \; ; then
        log "Warning: Cleanup command encountered an issue, but the backup process is still considered successful."
    fi
    log "--- [Step 3/3] Cleanup Finished ---"
}

# ==============================================================================
#  主程序执行逻辑
# ==============================================================================

log "================================================="
log "Starting PostgreSQL Backup Process..."
log "================================================="

# 捕获退出信号，以便在脚本意外终止时进行清理（如果需要）
# trap 'echo "Backup script interrupted."; exit 1' INT TERM

# 执行核心流程
perform_local_backup
upload_to_rsync
cleanup_local_backups

log "================================================="
log "Backup Process Completed Successfully."
log "================================================="

exit 0
