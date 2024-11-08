#!/bin/bash
# 定时任务配置
JOB_NAME="Lifeisgood-Backup"

# 配置变量
RCLONE_PATH="/home/rclone/rclone"
CONFIG_FILE="/home/rclone/rclone.conf"
SOURCE_DIR="/mnt/crypt/lifeisgood"
DEST_DIR="Crypt-Onedrive:"
# 排除列表，使用逗号分隔
EXCLUDE_LIST=""

LOG_DIR="/home/log/rclone"

# 每月一个日志文件
TIMESTAMP=$(date +%Y%m)
LOG_FILE="$LOG_DIR/$JOB_NAME""_""$TIMESTAMP.log" 

# 发送webhook通知
function send_webhook() {
    # 构建错误消息
    local MESSAGE="$1"
    local WEBHOOK_URL="https://push.smy.me/push/smy116?token="  # Webhook完整URL，不包含参数部分

    # 构建POST数据
    local POST_DATA="content=${MESSAGE}&title=${JOB_NAME}&channel=email"

    # 发送Webhook通知
    if curl -s -o /dev/null -X POST -d "${POST_DATA}" "$WEBHOOK_URL"; then
            echo "已发送Webhook通知。" >> "$LOG_FILE"
    else
            echo "Webhook通知发送失败。" >> "$LOG_FILE"
    fi

}


# 添加开始时间戳到日志
echo "==================== start at $(date '+%Y-%m-%d %H:%M:%S') ====================" >> "$LOG_FILE"

# 执行rclone同步，并将输出捕获到变量
$RCLONE_PATH --config "$CONFIG_FILE" sync "$SOURCE_DIR" "$DEST_DIR" --bwlimit 2M --timeout 60m --exclude "$EXCLUDE_LIST" --delete-excluded --log-level INFO --log-file "$LOG_FILE" 2>&1
RCLONE_EXIT_CODE=$?


# 检查rclone命令是否成功
if [ $RCLONE_EXIT_CODE -ne 0 ]; then
    MESSAGE="任务：$JOB_NAME 同步失败！目录: $SOURCE_DIR 同步到 $DEST_DIR ，退出码: $RCLONE_EXIT_CODE"
    # 发送Webhook通知
    send_webhook "$MESSAGE"
    
else
    MESSAGE="任务：$JOB_NAME 同步成功！目录: $SOURCE_DIR 同步到 $DEST_DIR ，退出码: $RCLONE_EXIT_CODE"

fi

echo "$MESSAGE" >> "$LOG_FILE"

# 添加结束时间戳到日志
echo "==================== end at $(date '+%Y-%m-%d %H:%M:%S') =========" >> "$LOG_FILE"
