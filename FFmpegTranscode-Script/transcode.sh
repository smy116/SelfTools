#!/bin/bash
# ====================================================
#
#   Author        : SMY (Optimized version)
#   File Name     : transcode.sh
#   Description   : A script to transcode videos using ffmpeg with user-selected configurations including
#                   source directory, destination directory, video codec, decoder, video size, and video bitrate.
#
# ====================================================


# 初始化变量
IFS=$'\t\n'
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
video_file_paths=()
sub_file_paths=()
other_file_paths=()
silent_mode=0
origin_path=""
dest_path=""
ffmpeg_decode=""
ffmpeg_videosize_cmd=()
ffmpeg_rc_cmd=()
ffmpeg_decode_cmd=()
ffmpeg_audio_cmd=(-c:a copy)
ffmpeg_encode_cmd=()
video_format=("mp4" "mkv" "avi" "wmv" "flv" "mov" "m4v" "rm" "rmvb" "3gp" "vob" "MP4" "MKV" "AVI" "WMV" "FLV" "MOV" "M4V" "RM" "RMVB" "3GP" "VOB")
sub_format=("srt" "ass" "ssa" "vtt" "sub" "idx" "SRT" "ASS" "SSA" "VTT" "SUB" "IDX")
video_bitrate=2000000
log_file="${SCRIPT_DIR}/transcode.log"
dry_run_mode=0 # 0 = 禁用, 1 = 启用


# 日志写入
function _write_log() {
    local message="$1"
    echo "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "${log_file}"
}

# 验证路径输入
function _validate_path() {
    local path="$1"
    # 允许相对路径，但进行额外检查
    if [[ -z "$path" ]]; then
        echo "错误: 路径不能为空"
        return 1
    fi
    
    # 检查路径是否存在
    if [[ ! -e "$path" ]]; then
        echo "警告: 路径不存在 - $path"
        # 如果是目标路径，可以尝试创建
        if [[ "$2" == "dest" ]]; then
            mkdir -p "$path" || {
                echo "错误: 无法创建目标路径 - $path"
                return 1
            }
            echo "已创建目标路径 - $path"
        else
            return 1
        fi
    fi
    
    return 0
}

# 检查文件是否为视频文件
function _is_video_format() {
    local file="$1"
    local ext="${file##*.}"
    for format in "${video_format[@]}"; do
        if [[ "$ext" == "$format" ]]; then
            return 0
        fi
    done
    return 1
}

# 检查文件是否为字幕文件
function _is_sub_format() {
    local file="$1"
    local ext="${file##*.}"
    for format in "${sub_format[@]}"; do
        if [[ "$ext" == "$format" ]]; then
            return 0
        fi
    done
    return 1
}

# 将指定文件直接复制至新路径
function _copy_file() {
    local src_file="$1"
    
    # 获取相对路径
    local relative_path=""
    if [[ "$src_file" == "$origin_path"* ]]; then
        relative_path="${src_file#$origin_path}"
        # 确保相对路径以/开头
        if [[ ! "$relative_path" == /* ]]; then
            relative_path="/$relative_path"
        fi
    else
        relative_path="/$(basename "$src_file")"
    fi
    
    local new_file_path="${dest_path}${relative_path}"
    local dest_dir="$(dirname "$new_file_path")"

    # 确保目标目录存在
    mkdir -p "$dest_dir" || {
        _write_log "错误: 无法创建目录 '$dest_dir'"
        return 1
    }

    # 如果目标文件已存在，删除并覆盖
    if [ -f "$new_file_path" ]; then
        rm -f "$new_file_path" || {
            _write_log "错误: 无法删除已存在的文件 '$new_file_path'"
            return 1
        }
    fi

    cp "$src_file" "$new_file_path" || {
        _write_log "错误: 复制失败 '$src_file' 到 '$new_file_path'"
        return 1
    }
    
    # 设置权限
    chmod 644 "$new_file_path" || {
        _write_log "警告: 无法设置文件权限 '$new_file_path'"
    }
    
    return 0
}


# 获取视频码率，单位为kbps
function _get_video_bitrate() {
    local video_path="$1"
    local bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_path")
  
    # 如果ffprobe获取不到码率，尝试使用格式信息
    if [[ -z "$bitrate" || "$bitrate" == "N/A" ]]; then
        bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_path")
    fi
    
    # 如果仍然获取不到，使用默认值
    if [[ -z "$bitrate" || "$bitrate" == "N/A" || "$bitrate" == "0" ]]; then
        echo "0"
    else
        echo "$bitrate"
    fi
}


# 根据用户选择设置输出格式
function set_format() {
    local ans
    echo "选择转码输出格式："
    
    if [ $silent_mode -eq 1 ]; then
        ans="2"  # 默认选择hevc
    else
        echo "1. h264"
        echo "2. hevc（默认）"
        read -p "请输入选项：" ans
    fi

    case "$ans" in
        1)
            ffmpeg_code="h264"
            _write_log "已选择输出格式: h264"
        ;;
        2)
            ffmpeg_code="hevc"
            _write_log "已选择输出格式: hevc"
        ;;
        *)
            _write_log "无效选择，将使用默认选项：hevc"
            ffmpeg_code="hevc"
        ;;
    esac
}

# 根据用户选择设置编解码器
function set_coder() {
    local ans
    echo "选择编码器 解码器："
    
    if [ $silent_mode -eq 1 ]; then
        ans="2"  # 默认选择RockChip MPP硬件编解码
    else
        echo "1. 软件解码 + RockChip MPP硬件编码"
        echo "2. RockChip MPP硬件编解码（默认）"
        echo "3. 软件编解码"
        read -p "请输入选项：" ans
    fi

    case "$ans" in
        1)
            ffmpeg_decode="CPU"
            ffmpeg_decode_cmd=()
            
            if [ "$ffmpeg_code" = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ "$ffmpeg_code" = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi
            _write_log "已选择: 软件解码 + RockChip MPP硬件编码"
        ;;
        2)
            ffmpeg_decode="MPP"
            ffmpeg_decode_cmd=(-hwaccel rkmpp -hwaccel_output_format drm_prime -afbc rga)

            if [ "$ffmpeg_code" = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ "$ffmpeg_code" = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi
            _write_log "已选择: RockChip MPP硬件编解码"
        ;;
        3)
            ffmpeg_decode="CPU"
            ffmpeg_decode_cmd=()

            if [ "$ffmpeg_code" = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v libx264)
            elif [ "$ffmpeg_code" = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v libx265)
            fi
            _write_log "已选择: 软件编解码"
        ;;
        *)
            _write_log "无效选择，将使用默认选项：RockChip MPP硬件编解码"
            ffmpeg_decode="MPP"
            ffmpeg_decode_cmd=(-hwaccel rkmpp -hwaccel_output_format drm_prime -afbc rga)
            
            if [ "$ffmpeg_code" = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ "$ffmpeg_code" = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi
        ;;
    esac
}

# 根据用户选择设置视频大小
function set_video_size() {
    local ans 
    local video_high
    # 根据用户选择设置视频大小
    echo "选择视频大小："

    if [ $silent_mode -eq 1 ]; then
        ans="3"  # 默认选择720P
    else
        echo "1. 4K"
        echo "2. 1080P"
        echo "3. 720P（默认）"
        echo "4. 480P"
        echo "5. 360P"
        read -p "请输入选项：" ans
    fi

    case "$ans" in
        1)
            video_high=2160
            _write_log "已选择视频大小: 4K (2160p)"
        ;;
        2)
            video_high=1080
            _write_log "已选择视频大小: 1080p"
        ;;
        3)
            video_high=720
            _write_log "已选择视频大小: 720p"
        ;;
        4)
            video_high=480
            _write_log "已选择视频大小: 480p"
        ;;
        5)
            video_high=360
            _write_log "已选择视频大小: 360p"
        ;;
        *)
            _write_log "无效选择，将使用默认选项：720P"
            video_high=720
        ;;
    esac

    # 正确处理引号和变量
    if [ "$ffmpeg_decode" = "CPU" ]; then
        ffmpeg_videosize_cmd=(-vf scale=-2:"'min($video_high,ih)'":flags=fast_bilinear,format=yuv420p)
    else
        ffmpeg_videosize_cmd=(-vf scale_rkrga=w=-2:h="'min($video_high,ih)'":format=nv12:afbc=1)
    fi
}


# 设置视频码率
function set_video_bitrate() {
    local ans
    # 根据用户选择设置视频码率
    echo "选择视频码率或直接输入码率："
    if [ $silent_mode -eq 1 ]; then
        ans="2"  # 默认选择2000k
    else
        echo "1. 1000k"
        echo "2. 2000k（默认）"
        echo "3. 3000k"
        echo "4. 4000k"
        echo "5. 5000k"
        read -p "请输入选项：" ans
    fi

    case "$ans" in
        1)
            video_bitrate=1000
            _write_log "已选择视频码率: 1000k"
        ;;
        2)
            video_bitrate=2000
            _write_log "已选择视频码率: 2000k"
        ;;
        3)
            video_bitrate=3000
            _write_log "已选择视频码率: 3000k"
        ;;
        4)
            video_bitrate=4000
            _write_log "已选择视频码率: 4000k"
        ;;
        5)
            video_bitrate=5000
            _write_log "已选择视频码率: 5000k"
        ;;
        *)
            # 验证输入值是否在100-100000之间
            if [[ "$ans" =~ ^[1-9][0-9]{1,4}$ ]] && [ "$ans" -ge 100 ] && [ "$ans" -le 100000 ]; then
                video_bitrate=$ans
                _write_log "已设置自定义视频码率: ${ans}k"
            else
                _write_log "无效选择，将使用默认选项：2000k"
                video_bitrate=2000
            fi
        ;;
    esac
    # 转换为比特每秒（bit/s）
    video_bitrate=$((video_bitrate * 1000))
}

# 遍历目录并将文件路径添加到列表
function lm_traverse_dir(){
    local base_path="$1"
    local all_files=()
    local file=""
    
    # 检查是否为目录
    if [ ! -d "$base_path" ]; then
        _write_log "错误: $base_path 不是一个目录"
        return 1
    fi

    _write_log "开始遍历目录: $base_path"
    
    # 使用find命令递归查找所有文件并添加到数组
    while IFS= read -r -d '' file; do
        all_files+=("$file")
    done < <(find "$base_path" -type f -print0)
    
    _write_log "共找到 ${#all_files[@]} 个文件"
    
    # 筛选文件类型
    for file in "${all_files[@]}"; do
        if _is_video_format "$file"; then
            # 视频文件
            video_file_paths+=("$file")
        elif _is_sub_format "$file"; then
            # 字幕文件
            sub_file_paths+=("$file")
        else
            # 其他文件
            other_file_paths+=("$file")
        fi
    done

    _write_log "分类结果: ${#video_file_paths[@]} 个视频文件, ${#sub_file_paths[@]} 个字幕文件, ${#other_file_paths[@]} 个其他文件"
}

function transcode_video(){
    # 检查输入参数是否为有效文件
    if [ -z "$1" ] || [ ! -f "$1" ]; then
        _write_log "错误: 无效的文件路径 - $1"
        return 1
    fi

    local src_file="$1"
    
    # 获取相对路径
    local relative_path=""
    if [[ "$src_file" == "$origin_path"* ]]; then
        relative_path="${src_file#$origin_path}"
        # 确保相对路径以/开头
        if [[ ! "$relative_path" == /* ]]; then
            relative_path="/$relative_path"
        fi
    else
        relative_path="/$(basename "$src_file")"
    fi
    
    local new_file_path="${dest_path}${relative_path}"
    local dest_dir="$(dirname "$new_file_path")"

    # 后缀替换
    new_file_path="${new_file_path%.*}.mp4"

    # 获取视频码率
    local origin_video_bitrate=$(_get_video_bitrate "$src_file")

    # 如果获取到的视频码率为0，使用默认码率但记录警告
    if [ "$origin_video_bitrate" -eq "0" ]; then
        _write_log "警告: 无法获取原视频码率，将使用设置码率: $video_bitrate"
    else
        # 如果原视频码率小于设置码率，则使用原视频码率
        if [ "$origin_video_bitrate" -lt "$video_bitrate" ]; then
            video_bitrate="$origin_video_bitrate"
            _write_log "原视频码率(${origin_video_bitrate})小于设置码率，将使用原视频码率"
        fi
    fi

    # 设置码率控制参数
    ffmpeg_rc_cmd=(-rc_mode VBR -b:v "$video_bitrate" -maxrate "$((video_bitrate * 12 / 10))" -bufsize "$((video_bitrate * 2))" -g:v 120)
    
    # 创建文件夹
    mkdir -p "$dest_dir" || {
        _write_log "错误: 无法创建目录 '$dest_dir'"
        return 1
    }

    # 记录开始转码
    _write_log "开始转码: $relative_path"
    _write_log "转码配置: 编码器=${ffmpeg_encode_cmd[*]}, 解码器=${ffmpeg_decode_cmd[*]}, 码率=$video_bitrate"

    # 构建完整的 ffmpeg 命令数组
    local cmd_parts=("ffmpeg" "-hide_banner")
    [[ ${#ffmpeg_decode_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_decode_cmd[@]}")
    cmd_parts+=("-i" "$src_file" "-strict" "-2")
    [[ ${#ffmpeg_videosize_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_videosize_cmd[@]}")
    [[ ${#ffmpeg_rc_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_rc_cmd[@]}")
    [[ ${#ffmpeg_encode_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_encode_cmd[@]}")
    [[ ${#ffmpeg_audio_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_audio_cmd[@]}")
    cmd_parts+=("-c:s" "mov_text" "-map" "0:v" "-map" "0:a?" "-map" "0:s?" "-y" "$new_file_path")

    # 将命令数组转换为适合打印的、经过引号处理的字符串
    local cmd_str=$(printf "%q " "${cmd_parts[@]}")

    if [ "$dry_run_mode" -eq 1 ]; then
        _write_log "dry-run命令，跳过执行，命令为:"
        # 直接打印到控制台，也记录到日志
        echo "    $cmd_str" 
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]     $cmd_str" >> "${log_file}"
        return 0 # 在 dry-run 模式下假装成功
    fi

    # 使用ffmpeg进行转码 - 使用构建好的命令数组确保参数安全
    "${cmd_parts[@]}"

    local ffmpeg_status=$?
    if [ $ffmpeg_status -eq 0 ]; then
        # 文件大小计算
        local origin_file_size=$(du -h "$src_file" | cut -f1)
        local new_file_size=$(du -h "$new_file_path" | cut -f1)
        _write_log "转码成功：$relative_path [$origin_file_size -> $new_file_size]"
        
        # 修复权限
        chmod 644 "$new_file_path" || {
            _write_log "警告: 无法设置文件权限 '$new_file_path'"
        }
        return 0
    else
        _write_log "转码失败,FFmpeg返回错误代码 $ffmpeg_status：$relative_path"
        # 清理可能部分生成的文件
        if [ -f "$new_file_path" ]; then
            rm -f "$new_file_path" || _write_log "警告: 无法删除失败的输出文件 '$new_file_path'"
        fi
        return 1
    fi
    
}

# 将字幕文件类型复制到新目录
function copy_sub_files(){ 
    local copyTotal=0
    local success_count=0
    local file_path=""
    
    _write_log "开始复制 ${#sub_file_paths[@]} 个字幕文件"
    
    for file_path in "${sub_file_paths[@]}"; do
        let copyTotal=copyTotal+1
        _write_log "字幕文件：复制第 $copyTotal 个文件，共计 ${#sub_file_paths[@]} 个文件"
        
        if _copy_file "$file_path"; then
            let success_count=success_count+1
        fi
    done
    
    _write_log "字幕文件复制完成: $success_count/${#sub_file_paths[@]} 个文件复制成功"
}


# 将其他文件类型复制到新目录
function copy_other_files(){ 
    local copyTotal=0
    local success_count=0
    local file_path=""
    
    _write_log "开始复制 ${#other_file_paths[@]} 个其他文件"
    
    for file_path in "${other_file_paths[@]}"; do
        let copyTotal=copyTotal+1
        _write_log "其他文件：复制第 $copyTotal 个文件，共计 ${#other_file_paths[@]} 个文件"
        
        if _copy_file "$file_path"; then
            let success_count=success_count+1
        fi
    done
    
    _write_log "其他文件复制完成: $success_count/${#other_file_paths[@]} 个文件复制成功"
}

# 安装别名到shell配置文件
function install_alias() {
    local full_path=$(readlink -f "$0")
    local alias_cmd="alias transcode='$full_path'"
    local installed=0
    
    _write_log "开始安装transcode别名..."
    
    # 为Bash设置别名
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -q "alias transcode=" "$HOME/.bashrc"; then
            echo "$alias_cmd" >> "$HOME/.bashrc"
            _write_log "已添加别名到 ~/.bashrc"
            installed=1
        else
            _write_log "别名已存在于 ~/.bashrc 中"
            installed=1
        fi
    fi
    
    # 为Zsh设置别名
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -q "alias transcode=" "$HOME/.zshrc"; then
            echo "$alias_cmd" >> "$HOME/.zshrc"
            _write_log "已添加别名到 ~/.zshrc"
            installed=1
        else
            _write_log "别名已存在于 ~/.zshrc 中"
            installed=1
        fi
    fi
    
    if [ $installed -eq 1 ]; then
        _write_log "别名安装成功。请运行 'source ~/.bashrc' 或 'source ~/.zshrc' 来激活别名，或重新打开终端。"
        echo "安装成功！请运行 'source ~/.bashrc' 或 'source ~/.zshrc' 来激活别名，或重新打开终端。"
        echo "之后可以直接使用 'transcode' 命令来运行此脚本。"
    else
        _write_log "错误: 未找到 ~/.bashrc 或 ~/.zshrc 文件，无法安装别名"
        echo "错误: 未找到 ~/.bashrc 或 ~/.zshrc 文件，无法安装别名"
    fi
    
    exit 0
}

function show_help() {
    cat << EOF
用法: $(basename "$0") [选项] [源目录] [目标目录]

选项:
  --install      安装transcode别名到bash和zsh配置文件
  --help         显示此帮助信息
  --dry-run      输出ffmpeg命令信息，而不实际转码视频

如果提供源目录和目标目录，脚本将以静默模式运行，使用默认配置。
如果不提供参数，脚本将交互式询问配置选项。
EOF
    exit 0
}

function main(){
    # 处理 --dry-run 参数
    local new_args=()
    for arg in "$@"; do
        if [ "$arg" = "--dry-run" ]; then
            dry_run_mode=1
            _write_log "启用 dry-run 模式，将仅输出命令，不执行转码。"
        else
            new_args+=("$arg") # 保留非 --dry-run 参数
        fi
    done

    set -- "${new_args[@]}"


    # 检查 --install 和 --help
    if [ "$1" = "--install" ]; then
        install_alias
        return
    elif [ "$1" = "--help" ]; then
        show_help
        return
    fi

    # 记录脚本开始运行
    _write_log "===== 视频转码脚本开始运行 ====="
    
    # 如未提供目录参数，则进行配置设置
    if [ ! -n "$1" ];then
        # 读取并验证原始文件目录和目标文件目录
        read -p "输入原始文件目录：" origin_path
        [ -z "$origin_path" ] && { _write_log "错误: 原始文件目录不能为空"; exit 1; }
        
        read -p "输入目标文件目录：" dest_path
        [ -z "$dest_path" ] && { _write_log "错误: 目标文件目录不能为空"; exit 1; }
    else
        silent_mode=1
        origin_path="$1"
        dest_path="$2"
        
        if [ -z "$dest_path" ]; then
            _write_log "错误: 目标文件目录不能为空"
            exit 1
        fi
    fi

    # 规范化路径 - 去除末尾的斜杠
    local original_input_path="$origin_path" # 保存原始输入路径
    origin_path="${origin_path%/}"
    dest_path="${dest_path%/}"
    
    # 验证路径输入
    _validate_path "$origin_path" "source" || { _write_log "错误: 无效的源路径"; exit 1; }
    _validate_path "$dest_path" "dest" || { _write_log "错误: 无效的目标路径"; exit 1; }

    # 选择转码输出格式
    set_format

    # 设置解码器和编码器
    set_coder

    # 设置视频大小
    set_video_size    

    # 设置视频码率
    set_video_bitrate
    
    # 检查输入是否为目录还是文件
    if [ -d "$original_input_path" ]; then # 使用原始输入路径判断类型
        _write_log "当前输入路径为目录: $origin_path"

        # 遍历目录
        lm_traverse_dir "$origin_path"

        # 复制字幕文件 (这部分逻辑可能也需要检查是否依赖正确的 origin_path)
        if [ ${#sub_file_paths[@]} -gt 0 ]; then
            copy_sub_files
        fi
        
        # 复制其他文件 (同上)
        if [ ${#other_file_paths[@]} -gt 0 ]; then
            copy_other_files
        fi

    else # 输入是单个文件
        _write_log "当前输入路径为单个文件: $original_input_path"

        # 判断是否为视频文件
        if ! _is_video_format "$original_input_path"; then
            _write_log "错误: $original_input_path 不是视频文件"
            exit 1
        fi
        
        # --- 修改开始 ---
        # 将 origin_path 设置为文件的父目录, 以便 transcode_video 计算相对路径
        origin_path="$(dirname "$original_input_path")"
        # 再次规范化一次，去除 dirname 可能带来的末尾斜杠（虽然通常不会）
        origin_path="${origin_path%/}" 
        _write_log "Info: 源路径已设置为文件的父目录: $origin_path" # 添加日志说明
        # --- 修改结束 ---
        
        # 将单个文件路径放入待处理列表
        video_file_paths=("$original_input_path")
    fi

    # 输出视频文件路径数组数量
    if [ ${#video_file_paths[@]} -eq 0 ]; then
        _write_log "错误: 没有找到视频文件!"
        exit 1
    fi

    # 遍历视频文件路径数组并转码
    local transcodeTotal=0
    local success_count=0
    local failure_count=0
    
    _write_log "开始转码 ${#video_file_paths[@]} 个视频文件"
    
    for file_path in "${video_file_paths[@]}"; do
        let transcodeTotal=transcodeTotal+1
        _write_log "开始转码第 $transcodeTotal 个文件，共计 ${#video_file_paths[@]} 个文件: $(basename "$file_path")"
        
        if transcode_video "$file_path"; then
            let success_count=success_count+1
        else
            let failure_count=failure_count+1
        fi
    done
    
    _write_log "===== 视频转码脚本结束 ====="
    _write_log "转码结果: $success_count 个成功, $failure_count 个失败, 总共 ${#video_file_paths[@]} 个文件"
}

# 检查ffmpeg是否安装
if ! command -v ffmpeg &> /dev/null; then
    echo "错误: ffmpeg 未安装，请先安装ffmpeg"
    exit 1
fi

# 检查ffprobe是否安装
if ! command -v ffprobe &> /dev/null; then
    echo "错误: ffprobe 未安装，请先安装ffprobe"
    exit 1
fi

# 运行主函数
main "$@"
