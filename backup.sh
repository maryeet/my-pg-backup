#!/bin/sh

# 设置 -e，脚本中任何命令执行失败则立即退出
set -e

# --- 配置项 ---
# 目标 PostgreSQL 主机名或IP地址
# 如果备份容器和PostgreSQL容器在同一个docker network中，这里可以直接用容器名，如 'postgresql'
PGHOST=${PGHOST:-"postgresql"}

# PostgreSQL 端口
PGPORT=${PGPORT:-"5432"}

# PostgreSQL 用户名 (拥有备份权限的用户)
# Bitnami 默认的超级用户是 'postgres'
PGUSER=${PGUSER:-"postgres"}

# PostgreSQL 密码
# 强烈建议通过环境变量或 Docker Secrets 传入，而不是硬编码在脚本里
PGPASSWORD=${PGPASSWORD}

# 备份文件存储目录
BACKUP_DIR="/backups"

# 备份文件名格式 (例如: pg_backup_20231027_103000.sql.gz)
BACKUP_FILENAME="pg_backup_$(date +%Y%m%d_%H%M%S).sql.gz"
BACKUP_FILE_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"

# --- 健康检查 ---
echo "---"
echo "$(date): Starting PostgreSQL backup..."
echo "---"
echo "Checking connection to ${PGHOST}:${PGPORT}..."

# 使用 pg_isready 检查数据库是否可连接
pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -q
if [ $? -ne 0 ]; then
    echo "$(date): ERROR: Unable to connect to PostgreSQL at ${PGHOST}:${PGPORT}. Please check connection details and network."
    exit 1
fi
echo "Connection successful."

# --- 执行备份 ---
echo "Dumping all databases to ${BACKUP_FILE_PATH}..."

# 使用 pg_dumpall 进行全量备份，并通过 gzip 压缩
# --clean: 在恢复前删除已存在的对象
# --if-exists: 配合 --clean 使用，避免对象不存在时报错
pg_dumpall --clean --if-exists -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" | gzip > "${BACKUP_FILE_PATH}"

# 检查备份文件是否成功创建且非空
if [ -s "${BACKUP_FILE_PATH}" ]; then
    echo "Backup file created successfully: ${BACKUP_FILE_PATH}"
    echo "Size: $(ls -lh ${BACKUP_FILE_PATH} | awk '{print $5}')"
else
    echo "$(date): ERROR: Backup failed. Output file is empty or was not created."
    # 清理可能产生的空文件
    rm -f "${BACKUP_FILE_PATH}"
    exit 1
fi

# --- 清理旧备份 (可选) ---
# 保留最近7天的备份文件
KEEP_DAYS=7
echo "Cleaning up old backups, keeping last ${KEEP_DAYS} days..."
find "${BACKUP_DIR}" -name "pg_backup_*.sql.gz" -mtime +${KEEP_DAYS} -exec rm -f {} \;

echo "---"
echo "$(date): Backup process completed successfully."
echo "---"

exit 0
