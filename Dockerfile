# 使用轻量级的 Alpine Linux 作为基础镜像
FROM alpine:3.23

# 作者信息
LABEL maintainer="Your Name <your.email@example.com>"
LABEL description="A Docker container to perform scheduled backups of a PostgreSQL database using pg_dumpall."

# 安装依赖: postgresql-client 提供了 pg_dumpall, pg_isready 等工具
# tzdata 用于设置时区，确保 cron 的执行时间符合预期
RUN apk update --no-cache && apk add --no-cache postgresql-client tzdata rsync gzip bash curl

# 将备份脚本复制到镜像中
COPY backup.sh /usr/local/bin/backup.sh

# 给予脚本执行权限
RUN chmod +x /usr/local/bin/backup.sh

# 创建 crontab 配置文件
# 默认设置为每天凌晨2点执行备份
# 格式: 分 时 日 月 周 命令
# '0 2 * * *' 表示每天的 02:00
RUN echo "0 2 * * * /usr/local/bin/backup.sh >> /var/log/cron.log 2>&1" > /etc/crontabs/root

# 创建日志文件，以便 cron 输出可以重定向到这里
RUN touch /var/log/cron.log

# 容器启动时执行的命令
# crond -f: 在前台运行 cron 服务
# -l 2: 设置日志级别
# tail -f /var/log/cron.log: 持续输出日志，这样 'docker logs' 才能看到 cron 的执行记录
CMD ["sh", "-c", "crond -f -l 2 & tail -f /var/log/cron.log"]
