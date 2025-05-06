#!/bin/bash
# ====================================================
#
#   Author        : SMY
#   File Name     : transcode.sh
#   Description   : 使用 ffmpeg 转码视频的脚本，支持用户选择源目录、目标目录、
#                   视频编解码器、硬件加速选项 (针对 RockChip MPP)、视频尺寸和视频码率。
#
# ====================================================

# 脚本行为设置
# set -e # 如果需要命令失败立即退出，可以取消此行注释，但需注意脚本中已有较多手动错误检查
set -u # 引用未定义变量时报错
set -o pipefail # 管道中任意命令失败则整个管道失败

# 初始化变量
IFS=$'\t\n' # 设置内部字段分隔符，以更好地处理带空格的文件名
# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# 初始化文件路径数组
video_file_paths=()
sub_file_paths=()
other_file_paths=()
# 初始化模式和路径变量
silent_mode=0 # 0 = 交互模式, 1 = 静默模式
origin_path=""  # 源路径
dest_path=""    # 目标路径
# 初始化ffmpeg相关命令数组和变量
ffmpeg_code="hevc" # 默认输出视频编码格式
ffmpeg_decode="MPP" # 默认解码方式
ffmpeg_videosize_cmd=() # ffmpeg视频尺寸调整命令
ffmpeg_rc_cmd=()        # ffmpeg码率控制命令
ffmpeg_decode_cmd=(-hwaccel rkmpp -hwaccel_output_format drm_prime) # ffmpeg硬件解码命令 (rkmpp默认)
ffmpeg_audio_cmd=(-c:a copy) # ffmpeg音频处理命令 (默认复制音轨)
ffmpeg_encode_cmd=(-c:v hevc_rkmpp) # ffmpeg视频编码命令 (默认hevc_rkmpp)
# 支持的视频和字幕格式列表 (大小写不敏感，脚本内部处理)
video_format=("mp4" "mkv" "avi" "wmv" "flv" "mov" "m4v" "rm" "rmvb" "3gp" "vob")
sub_format=("srt" "ass" "ssa" "vtt" "sub" "idx")
# 默认视频目标码率 (单位: bps - bits per second)
# 此值会在 set_video_bitrate 函数中被用户输入或默认值覆盖并乘以1000
# 这里初始化为2Mbps，与set_video_bitrate中的默认值2000k对应
target_video_bitrate=2000000
# 日志文件路径
log_file="${SCRIPT_DIR}/transcode.log"
# Dry-run 模式开关: 0 = 禁用 (实际执行转码), 1 = 启用 (仅打印命令)
dry_run_mode=0


# 函数：写入日志
# 参数1: message - 需要记录的日志信息
function _write_log() {
    local message="$1"
    # 同时输出到控制台和日志文件
    echo "${message}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" >> "${log_file}"
}

# 函数：验证路径输入
# 参数1: path - 需要验证的路径
# 参数2: type - 路径类型 ("source" 或 "dest")
function _validate_path() {
    local path="$1"
    local type="$2"

    if [[ -z "$path" ]]; then
        _write_log "错误: 路径不能为空。"
        return 1
    fi

    # 检查路径是否存在
    # 对于相对路径，它会相对于当前工作目录进行检查
    if [[ ! -e "$path" ]]; then
        _write_log "警告: 路径不存在 - '${path}'"
        # 如果是目标路径且不存在，则尝试创建
        if [[ "$type" == "dest" ]]; then
            if mkdir -p "$path"; then
                _write_log "信息: 已成功创建目标路径 - '${path}'"
            else
                _write_log "错误: 无法创建目标路径 - '${path}'"
                return 1
            fi
        else
            # 源路径不存在则返回错误
            return 1
        fi
    fi
    _write_log "信息: 路径 '${path}' 验证通过。"
    return 0
}

# 函数：检查文件是否为支持的视频格式 (忽略大小写)
# 参数1: file - 文件路径
function _is_video_format() {
    local file="$1"
    local ext_lowercase="${file##*.}" # 获取文件扩展名
    ext_lowercase="${ext_lowercase,,}" # 转换为小写
    for format in "${video_format[@]}"; do
        if [[ "$ext_lowercase" == "$format" ]]; then
            return 0 # 是视频文件
        fi
    done
    return 1 # 不是视频文件
}

# 函数：检查文件是否为支持的字幕格式 (忽略大小写)
# 参数1: file - 文件路径
function _is_sub_format() {
    local file="$1"
    local ext_lowercase="${file##*.}" # 获取文件扩展名
    ext_lowercase="${ext_lowercase,,}" # 转换为小写
    for format in "${sub_format[@]}"; do
        if [[ "$ext_lowercase" == "$format" ]]; then
            return 0 # 是字幕文件
        fi
    done
    return 1 # 不是字幕文件
}

# 函数：将指定文件直接复制至新路径，保持相对目录结构
# 参数1: src_file - 源文件完整路径
function _copy_file() {
    local src_file="$1"
    local relative_path # 文件相对于源基础路径的路径

    # 计算相对路径
    # "$origin_path" 应该是规范化的，不以 / 结尾的路径
    if [[ "$src_file" == "${origin_path}"* ]]; then
        relative_path="${src_file#${origin_path}}"
        # 确保 relative_path 以 / 开头
        if [[ ! "$relative_path" == /* ]]; then
            relative_path="/$relative_path"
        fi
    else
        # 如果源文件不在 origin_path 下 (例如处理单个文件时，origin_path可能是其父目录)
        # 则只取文件名作为相对路径的一部分
        relative_path="/$(basename "$src_file")"
    fi

    local new_file_path="${dest_path}${relative_path}"
    local dest_dir # 目标文件所在的目录

    dest_dir="$(dirname "$new_file_path")"

    # 确保目标目录存在
    if ! mkdir -p "$dest_dir"; then
        _write_log "错误: 复制操作中，无法创建目录 '$dest_dir'"
        return 1
    fi

    # 如果目标文件已存在，则先删除 (cp -f 行为)
    if [ -f "$new_file_path" ]; then
        if ! rm -f "$new_file_path"; then
            _write_log "错误: 复制操作中，无法删除已存在的目标文件 '$new_file_path'"
            return 1
        fi
    fi

    # 执行复制
    if cp "$src_file" "$new_file_path"; then
        _write_log "信息: 文件已复制到 '$new_file_path'"
        # 设置权限为 644 (所有者读写，组读，其他读)
        if ! chmod 644 "$new_file_path"; then
            _write_log "警告: 复制操作中，无法设置文件权限 '$new_file_path'"
        fi
        return 0
    else
        _write_log "错误: 复制文件失败 从 '$src_file' 到 '$new_file_path'"
        return 1
    fi
}


# 函数：获取视频文件的码率 (单位: bps)
# 参数1: video_path - 视频文件路径
function _get_video_bitrate() {
    local video_path="$1"
    local bitrate

    # 优先尝试获取视频流的码率
    # 2>/dev/null 抑制 ffprobe 可能的错误输出，例如文件损坏或非媒体文件
    bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_path" 2>/dev/null)

    # 如果无法从视频流获取码率 (例如某些格式或 ffprobe 版本问题)，则尝试获取整个文件的平均码率
    if [[ -z "$bitrate" || "$bitrate" == "N/A" ]]; then
        bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_path" 2>/dev/null)
    fi

    # 如果仍然无法获取，或获取到的值为0或无效，则返回 "0"
    # "0" 将在调用此函数的地方被特殊处理
    if [[ -z "$bitrate" || "$bitrate" == "N/A" || "$bitrate" == "0" ]]; then
        echo "0"
    else
        echo "$bitrate" # ffprobe 通常返回 bps
    fi
}


# 函数：根据用户选择设置输出视频编码格式 (h264 或 hevc)
function set_format() {
    local ans
    echo "----------------------------------------"
    echo "选择转码输出格式："

    if [ $silent_mode -eq 1 ]; then
        ans="2"  # 静默模式默认选择 hevc
        _write_log "信息: 静默模式，默认输出格式: hevc"
    else
        echo "1. h264"
        echo "2. hevc (默认)"
        read -p "请输入选项 (1-2) [默认为2]: " ans
    fi

    case "$ans" in
        1)
            ffmpeg_code="h264"
            _write_log "信息: 用户选择输出格式: h264"
        ;;
        2|"") # "" 表示用户直接回车，选择默认
            ffmpeg_code="hevc"
            _write_log "信息: 用户选择输出格式: hevc (默认)"
        ;;
        *)
            _write_log "警告: 无效的输出格式选项，将使用默认：hevc"
            ffmpeg_code="hevc"
        ;;
    esac
}

# 函数：根据用户选择设置编解码器方案
function set_coder() {
    local ans
    echo "----------------------------------------"
    echo "选择编码器和解码器方案："

    if [ $silent_mode -eq 1 ]; then
        ans="2"  # 静默模式默认选择 RockChip MPP 硬件编解码
        _write_log "信息: 静默模式，默认编解码方案: RockChip MPP 硬件编解码"
    else
        echo "1. 软件解码 + RockChip MPP硬件编码 (推荐兼容性)"
        echo "2. RockChip MPP硬件解码 + RockChip MPP硬件编码 (推荐性能，需硬件支持良好)"
        echo "3. 软件解码 + 软件编码 (通用，速度较慢)"
        read -p "请输入选项 (1-3) [默认为2]: " ans
    fi

    # 重置解码和编码命令数组
    ffmpeg_decode_cmd=()
    ffmpeg_encode_cmd=()

    case "$ans" in
        1)
            ffmpeg_decode="CPU" # 标记为CPU解码
            # ffmpeg_decode_cmd 保持为空，表示使用ffmpeg默认的软件解码
            if [ "$ffmpeg_code" = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ "$ffmpeg_code" = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi
            _write_log "信息: 用户选择编解码方案: 软件解码 + RockChip MPP硬件编码"
        ;;
        2|"") # "" 表示用户直接回车，选择默认
            ffmpeg_decode="MPP" # 标记为MPP解码
            # -hwaccel rkmpp: 启用rkmpp硬件加速进行解码
            # -hwaccel_output_format drm_prime: 指定硬件加速解码后的像素格式为drm_prime, 通常用于零拷贝
            # -vf "hwmap=derive_device=vaapi,scale_vaapi=format=nv12" # 示例：如果需要进一步处理，可能需要映射和VAAPI滤镜
            # 如果解码器直接输出的格式编码器能接受，则不需要复杂的滤镜链
            ffmpeg_decode_cmd=(-hwaccel rkmpp -hwaccel_output_format drm_prime -afbc rga)

            if [ "$ffmpeg_code" = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ "$ffmpeg_code" = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi
            _write_log "信息: 用户选择编解码方案: RockChip MPP硬件编解码 (默认)"
        ;;
        3)
            ffmpeg_decode="CPU" # 标记为CPU解码
            # ffmpeg_decode_cmd 保持为空
            if [ "$ffmpeg_code" = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v libx264 -preset medium -crf 23) # 添加preset和crf以获得较好的软编码质量与速度平衡
            elif [ "$ffmpeg_code" = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v libx265 -preset medium -crf 28)
            fi
            _write_log "信息: 用户选择编解码方案: 软件编解码"
        ;;
        *)
            _write_log "警告: 无效的编解码方案选项，将使用默认：RockChip MPP硬件编解码"
            ffmpeg_decode="MPP"
            ffmpeg_decode_cmd=(-hwaccel rkmpp -hwaccel_output_format drm_prime)
            if [ "$ffmpeg_code" = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ "$ffmpeg_code" = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi
        ;;
    esac
}

# 函数：根据用户选择设置输出视频高度 (宽度将自动缩放以保持宽高比)
function set_video_size() {
    local ans
    local video_target_h # 目标视频高度
    echo "----------------------------------------"
    echo "选择输出视频高度 (宽度将按比例缩放)："

    if [ $silent_mode -eq 1 ]; then
        ans="3"  # 静默模式默认选择 720P
        _write_log "信息: 静默模式，默认视频高度: 720p"
    else
        echo "1. 4K (2160p)"
        echo "2. 1080P"
        echo "3. 720P (默认)"
        echo "4. 480P"
        echo "5. 360P"
        echo "6. 保持原始高度"
        read -p "请输入选项 (1-6) [默认为3]: " ans
    fi

    case "$ans" in
        1) video_target_h=2160; _write_log "信息: 用户选择视频高度: 4K (2160p)";;
        2) video_target_h=1080; _write_log "信息: 用户选择视频高度: 1080p";;
        3|"") video_target_h=720; _write_log "信息: 用户选择视频高度: 720p (默认)";; # "" 表示默认
        4) video_target_h=480; _write_log "信息: 用户选择视频高度: 480p";;
        5) video_target_h=360; _write_log "信息: 用户选择视频高度: 360p";;
        6) video_target_h=-1; _write_log "信息: 用户选择视频高度: 保持原始高度";; # 使用-1作为不缩放的标记
        *)
            _write_log "警告: 无效的视频高度选项，将使用默认：720P"
            video_target_h=720
        ;;
    esac

    # 如果选择不缩放，则清空视频尺寸命令数组
    if [ "$video_target_h" -eq -1 ]; then
        ffmpeg_videosize_cmd=()
        _write_log "信息: 视频将保持原始高度和宽度。"
        return
    fi
    
    # 构建视频缩放滤镜命令
    # scale=-2:H 或 scale=W:-2 : 将宽度/高度设置为-2，ffmpeg会自动计算另一个维度以保持宽高比
    # min(H,ih) : 输出高度不超过 H，也不超过输入视频高度 ih (避免放大低分辨率视频)
    # flags=fast_bilinear : 使用较快的双线性插值算法进行缩放
    # format=yuv420p : 确保输出为YUV420P像素格式，这是H.264/H.265编码器广泛兼容的格式
    # scale_rkrga : RockChip RGA硬件加速缩放
    # format=nv12 : NV12是硬件处理中常见的像素格式
    # afbc=1 : 可能启用AFBC（ARM FrameBuffer Compression）以优化内存带宽，需硬件支持
    # 注意: ffmpeg滤镜语法中，变量替换应在shell层面完成，然后将整个滤镜字符串传递给ffmpeg
    if [ "$ffmpeg_decode" = "CPU" ]; then
        # 软件解码后，可以使用CPU进行缩放，或如果后续是硬件编码，可能需要特定格式
        # format=yuv420p 是通用的选择
        ffmpeg_videosize_cmd=("-vf" "scale=-2:'min(${video_target_h},ih)':flags=bicubic,format=yuv420p")
    else # MPP解码
        # 硬件解码后，优先使用硬件缩放 (scale_rkrga)
        ffmpeg_videosize_cmd=("-vf" "scale_rkrga=w=-2:h='min(${video_target_h},ih)':format=nv12:afbc=1")
    fi
    _write_log "信息: 视频缩放命令设置为: ${ffmpeg_videosize_cmd[*]}"
}


# 函数：设置视频目标码率 (单位: kbps 输入, 内部转换为 bps)
function set_video_bitrate() {
    local ans
    local input_kbps # 用户输入的kbps值
    echo "----------------------------------------"
    echo "选择视频目标码率 (单位 kbps) 或直接输入数值 (例如 1500)："

    if [ $silent_mode -eq 1 ]; then
        input_kbps="2000"  # 静默模式默认选择 2000 kbps
        _write_log "信息: 静默模式，默认视频目标码率: ${input_kbps}kbps"
    else
        echo "1. 1000 kbps (较低质量，适合网络传输)"
        echo "2. 2000 kbps (默认，平衡质量与大小)"
        echo "3. 4000 kbps (较高质量)"
        echo "4. 6000 kbps (很高质量)"
        echo "5. 8000 kbps (极高质量)"
        read -p "请输入选项或自定义码率 (kbps) [默认为2000]: " ans
        
        case "$ans" in
            1) input_kbps=1000 ;;
            2|"") input_kbps=2000 ;; # "" 表示默认
            3) input_kbps=4000 ;;
            4) input_kbps=6000 ;;
            5) input_kbps=8000 ;;
            *)
                # 验证输入是否为纯数字
                if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 100 ] && [ "$ans" -le 100000 ]; then
                    input_kbps=$ans
                    _write_log "信息: 用户设置自定义视频目标码率: ${input_kbps}kbps"
                else
                    _write_log "警告: 无效的码率选项或输入 '${ans}'，将使用默认：2000kbps"
                    input_kbps=2000
                fi
            ;;
        esac
    fi
    # 将kbps转换为bps (bits per second) 并存储到全局变量
    target_video_bitrate=$((input_kbps * 1000))
    _write_log "信息: 最终视频目标码率设置为: ${target_video_bitrate}bps"
}

# 函数：遍历指定目录，并将不同类型文件路径分别添加到对应列表
# 参数1: base_path - 要遍历的基础目录路径
function lm_traverse_dir(){
    local base_path="$1"
    local file_count=0
    local video_count=0
    local sub_count=0
    local other_count=0

    if [ ! -d "$base_path" ]; then
        _write_log "错误: 指定的源路径 '$base_path' 不是一个目录。"
        return 1
    fi

    _write_log "信息: 开始遍历目录: '$base_path'"

    # 使用find命令递归查找所有文件，并通过read命令安全处理各种文件名
    # -print0 和 -d '' 配合使用，可以正确处理包含空格、换行符等特殊字符的文件名
    local file
    while IFS= read -r -d '' file; do
        ((file_count++))
        if _is_video_format "$file"; then
            video_file_paths+=("$file")
            ((video_count++))
        elif _is_sub_format "$file"; then
            sub_file_paths+=("$file")
            ((sub_count++))
        else
            other_file_paths+=("$file")
            ((other_count++))
        fi
    done < <(find "$base_path" -type f -print0)

    _write_log "信息: 目录遍历完成。总共找到 ${file_count} 个文件。"
    _write_log "信息: 分类结果: ${video_count} 个视频文件, ${sub_count} 个字幕文件, ${other_count} 个其他文件。"
    
    if [ "$video_count" -eq 0 ]; then
         _write_log "警告: 在目录 '$base_path' 中没有找到支持的视频文件。"
    fi
}

# 函数：执行单个视频文件的转码操作
# 参数1: src_file - 源视频文件完整路径
function transcode_video(){
    local src_file="$1" # 源文件完整路径

    if [ -z "$src_file" ] || [ ! -f "$src_file" ]; then
        _write_log "错误: 无效的视频文件路径 - '$src_file'"
        return 1
    fi

    local relative_path # 文件相对于源基础路径的路径
    # 计算相对路径，确保目标路径结构正确
    if [[ "$src_file" == "${origin_path}"* ]]; then
        relative_path="${src_file#${origin_path}}"
        if [[ ! "$relative_path" == /* ]]; then
            relative_path="/$relative_path" # 确保以 / 开头
        fi
    else
        # 如果 src_file 不在 origin_path 下（例如单文件模式），则只使用文件名
        relative_path="/$(basename "$src_file")"
    fi

    # 构建目标文件完整路径，并将输出格式固定为 .mp4
    local new_file_path="${dest_path}${relative_path}"
    new_file_path="${new_file_path%.*}.mp4" # 替换扩展名为 .mp4
    local dest_dir
    dest_dir="$(dirname "$new_file_path")"

    # 获取原视频的码率 (bps)
    local origin_video_actual_bitrate
    origin_video_actual_bitrate=$(_get_video_bitrate "$src_file")

    # 确定当前文件转码使用的最终码率 (bps)
    # BUG修复：使用局部变量 current_file_effective_bitrate，避免修改全局 target_video_bitrate
    local current_file_effective_bitrate="${target_video_bitrate}"

    if [ "${origin_video_actual_bitrate}" -eq 0 ]; then
        _write_log "警告: 无法获取视频 '$src_file' 的原始码率。将使用用户设置的目标码率: ${current_file_effective_bitrate}bps"
    elif [ "${origin_video_actual_bitrate}" -lt "${current_file_effective_bitrate}" ]; then
        _write_log "信息: 视频 '$src_file' 的原始码率 (${origin_video_actual_bitrate}bps) 低于目标码率 (${current_file_effective_bitrate}bps)。将使用原始码率进行转码以避免不必要的放大。"
        current_file_effective_bitrate="${origin_video_actual_bitrate}"
    else
        _write_log "信息: 视频 '$src_file' 将使用目标码率 ${current_file_effective_bitrate}bps 转码 (其原始码率为 ${origin_video_actual_bitrate}bps)。"
    fi
    
    # 设置码率控制相关参数 (VBR模式)
    # -b:v : 目标平均码率
    # -maxrate : 最大瞬时码率 (通常设置为平均码率的 1.2 到 2 倍)
    # -bufsize : 解码器缓冲区大小 (通常设置为平均码率的 2 倍左右，影响码率控制的平滑度)
    # -g:v : GOP (Group of Pictures) 大小，即关键帧间隔帧数。对于rkmpp，可能需要特定值或由驱动决定。120是一个常用值。
    ffmpeg_rc_cmd=(-rc_mode VBR -b:v "${current_file_effective_bitrate}" -maxrate "$((current_file_effective_bitrate * 15 / 10))" -bufsize "$((current_file_effective_bitrate * 2))" -g:v 120)

    # 创建目标文件所在的目录 (如果不存在)
    if ! mkdir -p "$dest_dir"; then
        _write_log "错误: 转码操作中，无法创建目录 '$dest_dir' 用于输出文件 '$new_file_path'"
        return 1
    fi

    _write_log "信息: 开始转码: '$src_file' -> '$new_file_path'"
    _write_log "配置: 编码器=${ffmpeg_encode_cmd[*]}; 解码器选项=${ffmpeg_decode_cmd[*]}; 视频尺寸选项=${ffmpeg_videosize_cmd[*]}; 码率控制=${ffmpeg_rc_cmd[*]}; 音频=${ffmpeg_audio_cmd[*]}"

    # 构建完整的 ffmpeg 命令数组
    # -hide_banner : 不显示ffmpeg的版本和编译信息
    # -i "$src_file" : 输入文件
    # -strict -2 或 -strict experimental : 允许使用一些实验性或非标准兼容的特性 (例如某些编码器的aac音频)
    # -c:s mov_text : 将字幕流转换为MP4兼容的mov_text格式 (主要用于SRT, ASS等文本字幕)
    # -map 0:v : 映射第一个视频流
    # -map 0:a? : 映射所有音频流 (如果存在)
    # -map 0:s? : 映射所有字幕流 (如果存在)
    # -y : 无需确认，直接覆盖输出文件
    local cmd_parts=("ffmpeg" "-hide_banner")
    # 根据是否有解码选项添加
    [[ ${#ffmpeg_decode_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_decode_cmd[@]}")
    cmd_parts+=("-i" "$src_file" "-strict" "-2")
    # 根据是否有视频尺寸调整选项添加
    [[ ${#ffmpeg_videosize_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_videosize_cmd[@]}")
    # 添加码率控制选项
    [[ ${#ffmpeg_rc_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_rc_cmd[@]}")
    # 添加视频编码选项
    [[ ${#ffmpeg_encode_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_encode_cmd[@]}")
    # 添加音频处理选项
    [[ ${#ffmpeg_audio_cmd[@]} -gt 0 ]] && cmd_parts+=("${ffmpeg_audio_cmd[@]}")
    # 添加字幕处理和流映射，以及输出文件
    cmd_parts+=("-c:s" "mov_text" "-map" "0:v:0" "-map" "0:a?" "-map" "0:s?" "-y" "$new_file_path")


    # 将命令数组转换为适合打印的、经过引号处理的字符串
    local cmd_str
    cmd_str=$(printf "%q " "${cmd_parts[@]}") # %q 会对特殊字符进行转义，便于阅读和调试

    if [ "$dry_run_mode" -eq 1 ]; then
        _write_log "信息: [Dry Run] 模式，跳过实际执行。命令如下:"
        # 直接打印到控制台，也记录到日志
        echo "    ${cmd_str}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Dry Run Command] ${cmd_str}" >> "${log_file}"
        return 0 # 在 dry-run 模式下假装成功
    fi

    # 执行ffmpeg转码命令
    # 使用 "${cmd_parts[@]}" 可以确保每个参数被正确传递，即使包含空格或特殊字符
    if "${cmd_parts[@]}"; then
        local origin_file_size
        local new_file_size
        origin_file_size=$(du -sh "$src_file" | awk '{print $1}') # 获取易读的文件大小
        new_file_size=$(du -sh "$new_file_path" | awk '{print $1}') # 获取易读的文件大小
        _write_log "成功: 转码完成 '$src_file' -> '$new_file_path' [${origin_file_size} -> ${new_file_size}]"
        
        # 设置输出文件权限
        if ! chmod 644 "$new_file_path"; then
            _write_log "警告: 转码成功后，无法设置文件权限 '$new_file_path'"
        fi
        return 0
    else
        local ffmpeg_status=$?
        _write_log "错误: 转码失败 (FFmpeg 返回错误码 ${ffmpeg_status})：'$src_file'"
        # 清理可能已部分生成的输出文件
        if [ -f "$new_file_path" ]; then
            if rm -f "$new_file_path"; then
                 _write_log "信息: 已删除转码失败的部分输出文件 '$new_file_path'"
            else
                 _write_log "警告: 无法删除转码失败的部分输出文件 '$new_file_path'"
            fi
        fi
        return 1
    fi
}

# 函数：复制所有找到的字幕文件到目标目录，保持相对路径结构
function copy_sub_files(){
    if [ ${#sub_file_paths[@]} -eq 0 ]; then
        _write_log "信息: 没有找到字幕文件需要复制。"
        return
    fi

    local total_subs=${#sub_file_paths[@]}
    local copied_count=0
    local current_num=0
    _write_log "信息: 开始复制 ${total_subs} 个字幕文件..."

    for file_path in "${sub_file_paths[@]}"; do
        ((current_num++))
        _write_log "进度: 正在复制字幕文件 ${current_num}/${total_subs} : '$(basename "$file_path")'"
        if _copy_file "$file_path"; then
            ((copied_count++))
        fi
    done

    _write_log "信息: 字幕文件复制完成。成功复制 ${copied_count}/${total_subs} 个文件。"
}

# 函数：复制所有找到的其他类型文件到目标目录，保持相对路径结构
function copy_other_files(){
    if [ ${#other_file_paths[@]} -eq 0 ]; then
        _write_log "信息: 没有找到其他类型的文件需要复制。"
        return
    fi

    local total_others=${#other_file_paths[@]}
    local copied_count=0
    local current_num=0
    _write_log "信息: 开始复制 ${total_others} 个其他类型文件..."

    for file_path in "${other_file_paths[@]}"; do
        ((current_num++))
        _write_log "进度: 正在复制其他文件 ${current_num}/${total_others} : '$(basename "$file_path")'"
        if _copy_file "$file_path"; then
            ((copied_count++))
        fi
    done

    _write_log "信息: 其他类型文件复制完成。成功复制 ${copied_count}/${total_others} 个文件。"
}

# 函数：安装脚本别名到用户的 shell 配置文件 (.bashrc, .zshrc)
function install_alias() {
    # 获取脚本的绝对路径
    local script_full_path
    script_full_path=$(readlink -f "$0")
    local alias_name="transcode"
    local alias_command="alias ${alias_name}='${script_full_path}'"
    local installed_to_bash=0
    local installed_to_zsh=0

    _write_log "信息: 开始尝试安装 '${alias_name}' 别名..."

    # 为 Bash 设置别名
    if [ -f "$HOME/.bashrc" ]; then
        if grep -Fxq "${alias_command}" "$HOME/.bashrc"; then
            _write_log "信息: 别名已存在于 ~/.bashrc"
            installed_to_bash=1
        elif grep -q "alias ${alias_name}=" "$HOME/.bashrc"; then
             _write_log "警告: ~/.bashrc 中已存在名为 '${alias_name}' 的不同别名。请手动检查。"
        else
            echo -e "\n# Alias for video transcoding script\n${alias_command}" >> "$HOME/.bashrc"
            _write_log "信息: 已成功添加别名到 ~/.bashrc"
            installed_to_bash=1
        fi
    else
        _write_log "信息: 未找到 ~/.bashrc 文件，跳过 Bash 别名安装。"
    fi

    # 为 Zsh 设置别名
    if [ -f "$HOME/.zshrc" ]; then
        if grep -Fxq "${alias_command}" "$HOME/.zshrc"; then
            _write_log "信息: 别名已存在于 ~/.zshrc"
            installed_to_zsh=1
        elif grep -q "alias ${alias_name}=" "$HOME/.zshrc"; then
            _write_log "警告: ~/.zshrc 中已存在名为 '${alias_name}' 的不同别名。请手动检查。"
        else
            echo -e "\n# Alias for video transcoding script\n${alias_command}" >> "$HOME/.zshrc"
            _write_log "信息: 已成功添加别名到 ~/.zshrc"
            installed_to_zsh=1
        fi
    else
        _write_log "信息: 未找到 ~/.zshrc 文件，跳过 Zsh 别名安装。"
    fi

    if [ "$installed_to_bash" -eq 1 ] || [ "$installed_to_zsh" -eq 1 ]; then
        echo "别名 '${alias_name}' 安装或已确认存在。"
        echo "请运行 'source ~/.bashrc' (如果使用Bash) 或 'source ~/.zshrc' (如果使用Zsh) 来使别名立即生效，"
        echo "或者重新打开您的终端。"
        echo "之后，您可以直接使用 '${alias_name}' 命令来运行此脚本。"
    else
        echo "错误: 未能安装别名。请检查您的 shell 配置文件路径和权限。"
        _write_log "错误: 别名安装失败。"
    fi
    exit 0
}

# 函数：显示帮助信息
function show_help() {
    # 使用 cat 和 EOF 来定义多行帮助文本
    cat << EOF
用法: $(basename "$0") [选项] [源目录或源文件] [目标目录]

这是一个视频转码脚本，使用 ffmpeg 进行处理，并针对 RockChip MPP 硬件加速进行了优化。

选项:
  --install      将 'transcode' 命令别名安装到您的 shell 配置文件中
                 (支持 .bashrc 和 .zshrc)。
  --help         显示此帮助信息并退出。
  --dry-run      模拟转码过程。脚本将输出将要执行的 ffmpeg 命令，
                 但不会实际进行任何文件转码或复制操作。这对于调试
                 和检查生成的命令非常有用。

参数:
  源目录或源文件   指定包含视频文件的源文件夹路径，或单个视频文件的路径。
                 如果省略此参数和目标目录，脚本将进入交互模式。
  目标目录       指定转码后视频文件存放的目标文件夹路径。
                 如果提供了源路径，则此参数为必需。

交互模式:
  如果未提供源路径和目标路径参数，脚本将以交互模式启动，引导您完成
  以下配置：
    1. 源路径和目标路径。
    2. 输出视频格式 (h264/hevc)。
    3. 编解码方案 (软解/硬解，软编/硬编)。
    4. 输出视频高度 (如 1080p, 720p，或保持原始)。
    5. 视频目标码率 (如 2000kbps)。

静默模式:
  当通过命令行参数提供了源路径和目标路径时，脚本将以静默模式运行，
  并使用预设的默认配置进行转码。您可以通过编辑脚本顶部的变量
  来修改这些默认配置。

日志:
  脚本运行期间的所有操作和 ffmpeg 命令输出都会记录在脚本所在目录下的
  'transcode.log' 文件中。

示例:
  1. 交互模式启动:
     bash $(basename "$0")

  2. 指定目录进行转码 (静默模式，使用默认配置):
     bash $(basename "$0") /path/to/source_videos /path/to/output_videos

  3. 转码单个文件:
     bash $(basename "$0") /path/to/source_videos/movie.mkv /path/to/output_videos

  4. Dry-run 模式检查命令:
     bash $(basename "$0") --dry-run /path/to/source_videos /path/to/output_videos

依赖:
  - ffmpeg: 必须安装并可在 PATH 中找到。
  - ffprobe: 通常与 ffmpeg 一同安装，也必须可在 PATH 中找到。

EOF
    exit 0
}

# 主函数
function main(){
    # 优先处理 --dry-run, --install, --help 等特殊参数
    # 遍历所有参数，查找特殊选项
    local temp_args=() # 用于存储非特殊选项的参数
    for arg in "$@"; do
        case "$arg" in
            --install)
                install_alias # 执行安装并退出
                return # install_alias 内部会 exit
                ;;
            --help)
                show_help # 显示帮助并退出
                return # show_help 内部会 exit
                ;;
            --dry-run)
                dry_run_mode=1
                _write_log "信息: [Dry Run] 模式已启用。脚本将仅显示命令，不执行实际操作。"
                # dry_run_mode 是全局变量，不需要从参数中移除，后续逻辑会检查它
                ;;
            *)
                temp_args+=("$arg") # 非特殊选项，添加到临时数组
                ;;
        esac
    done
    # 用处理过的参数列表覆盖原始参数列表
    # set -- "${temp_args[@]}" # 这行会导致参数丢失，因为 for 循环只处理一次
    # 正确的方式是直接使用 temp_args 或者在循环外判断

    # 重新设置参数，移除已处理的 --dry-run (如果需要的话，但dry_run_mode已设)
    # 这里我们主要关心源和目标路径参数
    # 实际上，上面的循环已经设置了 dry_run_mode，我们可以直接处理剩下的参数
    # 假设参数现在是 $1, $2 ...

    # 记录脚本开始运行
    _write_log "===================================================="
    _write_log "=====          视频转码脚本开始运行          ====="
    _write_log "===================================================="
    if [ "$dry_run_mode" -eq 1 ]; then
        _write_log "##### 注意：当前为 DRY-RUN 模式，不会执行实际转码 #####"
    fi

    # 根据参数数量判断是交互模式还是静默模式
    # $@ 在这里是经过上面 for 循环筛选后的参数 (如果 temp_args 被正确使用)
    # 为了简化，我们直接检查原始参数中非选项参数的数量
    # 假设 --dry-run 等选项不计入路径参数
    
    local path_arg_count=0
    local first_path_arg=""
    local second_path_arg=""

    for arg in "$@"; do
        if [[ "$arg" != --* ]]; then # 非选项参数才可能是路径
            if [ $path_arg_count -eq 0 ]; then
                first_path_arg="$arg"
            elif [ $path_arg_count -eq 1 ]; then
                second_path_arg="$arg"
            fi
            ((path_arg_count++))
        fi
    done


    if [ $path_arg_count -eq 0 ]; then # 没有提供路径参数，进入交互模式
        silent_mode=0
        _write_log "信息: 未提供路径参数，进入交互配置模式。"
        read -rp "请输入原始文件目录或单个文件路径: " origin_path_input
        # readlink -m 会解析路径，处理 ./ ../ 并返回绝对路径，如果路径不存在也不会报错
        origin_path_input=$(readlink -m "${origin_path_input}")
        if [ -z "$origin_path_input" ]; then _write_log "错误: 原始路径不能为空。"; exit 1; fi

        read -rp "请输入目标文件目录: " dest_path_input
        dest_path_input=$(readlink -m "${dest_path_input}")
        if [ -z "$dest_path_input" ]; then _write_log "错误: 目标路径不能为空。"; exit 1; fi
    elif [ $path_arg_count -eq 1 ]; then # 只提供了一个路径参数，通常是错误用法
         _write_log "错误: 检测到一个路径参数 '$first_path_arg'。脚本需要源路径和目标路径，或不提供路径以进入交互模式。"
         show_help
         exit 1
    elif [ $path_arg_count -ge 2 ]; then # 提供了两个或更多路径参数
        silent_mode=1
        origin_path_input="$first_path_arg"
        dest_path_input="$second_path_arg"
        _write_log "信息: 检测到路径参数，进入静默模式。"
        _write_log "信息: 源路径: '$origin_path_input'"
        _write_log "信息: 目标路径: '$dest_path_input'"
        if [ $path_arg_count -gt 2 ]; then
            _write_log "警告: 检测到超过两个路径参数，多余的参数将被忽略。"
        fi
    fi
    
    # 规范化路径: 去除末尾的斜杠，并确保是绝对路径
    # 使用 readlink -m 来处理相对路径并转为绝对路径，同时处理 ./ 和 ../
    # 如果路径不存在，readlink -m 仍然会构建一个理论上的绝对路径
    origin_path=$(readlink -m "${origin_path_input}")
    dest_path=$(readlink -m "${dest_path_input}")
    
    # 再次去除末尾斜杠，以防 readlink -m 添加了它 (通常不会对目录这么做)
    origin_path="${origin_path%/}"
    dest_path="${dest_path%/}"

    # 验证路径
    if ! _validate_path "$origin_path" "source"; then _write_log "错误: 无效的源路径 '$origin_path'"; exit 1; fi
    if ! _validate_path "$dest_path" "dest"; then _write_log "错误: 无效的目标路径 '$dest_path'"; exit 1; fi

    if [ "$origin_path" == "$dest_path" ]; then
        _write_log "错误: 源路径和目标路径不能相同，以避免数据覆盖风险。"
        exit 1
    fi
    
    # 获取转码配置
    set_format
    set_coder
    set_video_size
    set_video_bitrate
    echo "----------------------------------------"
    _write_log "信息: 配置完成。准备开始处理文件..."

    # 判断输入源是目录还是单个文件
    if [ -d "$origin_path_input" ]; then # 使用用户原始输入判断类型，因为readlink -m后的路径可能已创建
        _write_log "信息: 输入源 '${origin_path_input}' 是一个目录。"
        # 遍历目录获取文件列表
        lm_traverse_dir "$origin_path" # lm_traverse_dir 使用规范化后的 origin_path

        # 复制字幕文件
        copy_sub_files
        # 复制其他文件
        copy_other_files

    elif [ -f "$origin_path_input" ]; then
        _write_log "信息: 输入源 '${origin_path_input}' 是一个文件。"
        if ! _is_video_format "$origin_path_input"; then
            _write_log "错误: 指定的输入文件 '${origin_path_input}' 不是支持的视频格式。"
            exit 1
        fi
        # 对于单个文件，其 "origin_path" (用于计算相对路径的基准) 应为其父目录
        # 而 video_file_paths 数组只包含这一个文件
        video_file_paths=("$origin_path_input") # 使用用户原始输入的文件路径
        # 更新 origin_path 为该文件的父目录，以便 _copy_file 和 transcode_video 正确计算相对路径
        origin_path="$(dirname "$origin_path_input")"
        origin_path="${origin_path%/}" # 规范化父目录路径
        _write_log "信息: 单文件模式，源文件基准目录已设置为: '$origin_path'"
    else
        _write_log "错误: 指定的源路径 '${origin_path_input}' 既不是有效的文件也不是目录。"
        exit 1
    fi

    # 检查是否有视频文件需要处理
    if [ ${#video_file_paths[@]} -eq 0 ]; then
        _write_log "警告: 没有找到任何视频文件需要转码。"
    else
        _write_log "信息: 将处理 ${#video_file_paths[@]} 个视频文件。"
        local total_videos=${#video_file_paths[@]}
        local transcode_num=0
        local success_count=0
        local failure_count=0

        for file_to_transcode in "${video_file_paths[@]}"; do
            ((transcode_num++))
            _write_log "----------------------------------------"
            _write_log "进度: 开始处理视频 ${transcode_num}/${total_videos} : '$(basename "$file_to_transcode")'"
            if transcode_video "$file_to_transcode"; then
                ((success_count++))
            else
                ((failure_count++))
            fi
        done
        _write_log "----------------------------------------"
        _write_log "所有视频文件处理完成。"
        _write_log "转码统计: ${success_count} 个成功, ${failure_count} 个失败, 总共 ${total_videos} 个视频文件。"
    fi

    _write_log "===================================================="
    _write_log "=====          视频转码脚本执行结束          ====="
    _write_log "===================================================="
}

# --- 脚本执行入口 ---

# 检查核心依赖: ffmpeg 和 ffprobe
if ! command -v ffmpeg &> /dev/null; then
    echo "关键错误: ffmpeg 命令未找到。请确保 ffmpeg 已安装并在您的 PATH 环境变量中。" >&2
    _write_log "错误: ffmpeg 未安装或不在PATH中。" # 也记录到日志
    exit 1
fi
if ! command -v ffprobe &> /dev/null; then
    echo "关键错误: ffprobe 命令未找到。请确保 ffprobe 已安装 (通常随 ffmpeg 一同安装) 并在您的 PATH 环境变量中。" >&2
    _write_log "错误: ffprobe 未安装或不在PATH中。"
    exit 1
fi

# 调用主函数，并传递所有命令行参数
main "$@"
