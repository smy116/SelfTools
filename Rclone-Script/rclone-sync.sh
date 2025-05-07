#!/bin/bash

#===============================================================================
# 描述: 使用 rclone 将数据同步，并发送 Webhook 通知。
# 作者: SMY
#===============================================================================

# --- 配置变量 ---
# 任务名称，用于日志和通知
JOB_NAME="Sync-Minio-To-E5"

# rclone 可执行文件路径
# 建议将 rclone 添加到系统 PATH 中，然后可以直接使用 "rclone"
RCLONE_PATH="/mnt/ssdpool/appdata/rclone/rclone"
# rclone 配置文件路径
CONFIG_FILE="/mnt/ssdpool/appdata/rclone/rclone.conf"

# 源目录 (rclone 远程或本地路径)
# 示例: "minio_remote:bucket_name/path/" 或 "/local/data/"
SOURCE_DIR="minio:"
# 目标目录 (rclone 远程或本地路径)
DEST_DIR="E5-MinioBackup-Crypt:"

# 排除列表，使用逗号分隔的模式。
# 例如: "Public/**,*.tmp,cache/"
# 如果为空，则不排除任何文件。
EXCLUDE_LIST=""
# EXCLUDE_LIST="Public/**,*.log,temp_files/"

# 日志文件目录
LOG_DIR="/mnt/ssdpool/appdata/rclone/log"
WEBHOOK_URL="https://push.smy.me/push/smy116?token=<YOUR TOKEN HERE>"

# --- 全局变量 ---
# 每月一个日志文件
TIMESTAMP=$(date +%Y%m)
LOG_FILE="${LOG_DIR}/${JOB_NAME}_${TIMESTAMP}.log"

# --- 函数定义 ---

# 函数：记录日志消息
# 参数1: 日志级别 (INFO, ERROR, WARNING)
# 参数2: 日志消息
log_message() {
    local level="$1"
    local message="$2"
    printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${message}" >> "${LOG_FILE}"
}

# 函数：发送 Webhook 通知
# 参数1: 通知消息
send_webhook() {
    local message="$1"

    # 构建 POST 数据 (URL编码消息内容)
    # 使用 curl 的 --data-urlencode 选项可以更好地处理特殊字符
    local encoded_message
    encoded_message=$(curl -Gso /dev/null -w %{url_effective} --data-urlencode "content=${message}" "" | cut -c 3-) # 提取编码后的部分

    local post_data="${encoded_message}&title=${JOB_NAME}&channel=email"

    log_message "INFO" "正在发送 Webhook 通知..."
    # 发送 Webhook 通知，记录 curl 的输出和错误
    if curl_response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST -d "${post_data}" "${WEBHOOK_URL}" 2>&1); then
        http_status=$(echo "${curl_response}" | grep "HTTP_STATUS:" | cut -d':' -f2)
        if [[ "${http_status}" == "200" ]]; then
            log_message "INFO" "Webhook 通知发送成功。"
        else
            log_message "ERROR" "Webhook 通知发送失败。HTTP 状态码: ${http_status}. 响应: $(echo "${curl_response}" | sed '$d')"
        fi
    else
        log_message "ERROR" "Webhook 通知发送失败 (curl 命令执行错误): ${curl_response}"
    fi
}

# 函数：主同步逻辑
main() {
    # 检查并创建日志目录 (如果不存在)
    if [[ ! -d "${LOG_DIR}" ]]; then
        mkdir -p "${LOG_DIR}"
        if [[ $? -ne 0 ]]; then
            # 如果无法创建日志目录，则直接输出到 stderr 并退出
            >&2 printf "[%s] [CRITICAL] 无法创建日志目录: %s. 请检查权限。\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_DIR}"
            exit 1
        fi
        log_message "INFO" "日志目录 ${LOG_DIR} 已创建。"
    fi

    log_message "INFO" "==================== 任务 '${JOB_NAME}' 开始于 $(date '+%Y-%m-%d %H:%M:%S') ===================="

    # 构建 rclone 命令参数
    local rclone_opts=(
        "--config" "${CONFIG_FILE}"
        "sync"
        "${SOURCE_DIR}"
        "${DEST_DIR}"
        "--no-check-certificate" # 如果你的 SSL 证书是自签名的或有其他问题，可能需要此选项。生产环境请谨慎使用。
        "--timeout" "60m"         # 单个文件传输超时时间
        "--retries" "3"           # 失败重试次数
        "--retries-sleep" "5s"   # 重试间隔时间
        "--delete-excluded"       # 删除目标端被排除规则匹配到的文件
        "--stats" "1m"            # 每分钟输出一次传输状态
        "--fast-list"             # 对于支持的后端 (如 Minio, S3, Onedrive)，可以显著加快大目录的列表速度
        "--log-level" "INFO"      # rclone 自身的日志级别
        "--log-file" "${LOG_FILE}" # rclone 将其日志也输出到我们的主日志文件
        # 性能调优参数 (根据实际情况调整)
        # "--checkers=8"          # 并发检查文件数量 (默认为 8)
        # "--transfers=4"         # 并发传输文件数量 (默认为 4)
        # "--buffer-size=16M"     # 内存缓冲区大小 (默认为 16M)
        # "--bwlimit" "2M"        # 限速2M
    )

    # 处理排除列表
    if [[ -n "${EXCLUDE_LIST}" ]]; then
        IFS=',' read -ra exclude_array <<< "${EXCLUDE_LIST}" # 将逗号分隔的字符串转换为数组
        for item in "${exclude_array[@]}"; do
            # 去除可能存在的前后空格
            trimmed_item=$(echo "$item" | sed 's/^[ \t]*//;s/[ \t]*$//')
            if [[ -n "${trimmed_item}" ]]; then
                rclone_opts+=("--exclude" "${trimmed_item}")
            fi
        done
    fi

    # 输出将要执行的 rclone 命令 (用于调试)
    log_message "INFO" "执行 rclone 命令: ${RCLONE_PATH} ${rclone_opts[*]}"

    # 执行 rclone 同步
    # 使用 eval 来正确处理带空格的参数和数组展开 (谨慎使用 eval)
    # 或者不使用 eval，直接传递数组: "${RCLONE_PATH}" "${rclone_opts[@]}"
    # eval "${RCLONE_PATH} \"${rclone_opts[@]}\"" # eval 方式
    "${RCLONE_PATH}" "${rclone_opts[@]}" # 推荐的数组展开方式
    local rclone_exit_code=$?

    local message # 用于通知的消息

    # 检查 rclone 命令是否成功
    if [[ ${rclone_exit_code} -eq 0 ]]; then
        message="任务 '${JOB_NAME}' 同步成功！源: '${SOURCE_DIR}' -> 目标: '${DEST_DIR}'."
        log_message "INFO" "${message}"
    else
        message="任务 '${JOB_NAME}' 同步失败！源: '${SOURCE_DIR}' -> 目标: '${DEST_DIR}'. rclone 退出码: ${rclone_exit_code}."
        log_message "ERROR" "${message}"
        # 仅在失败时发送 Webhook 通知
        send_webhook "${message}"
    fi

    log_message "INFO" "==================== 任务 '${JOB_NAME}' 结束于 $(date '+%Y-%m-%d %H:%M:%S') (退出码: ${rclone_exit_code}) ================"
    echo "" >> "${LOG_FILE}" # 添加一个空行，便于区分不同的任务执行记录
}

# --- 脚本执行入口 ---
main "$@"
