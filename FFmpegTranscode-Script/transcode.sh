#!/bin/bash
# ====================================================
#
#   Author        : SMY
#   File Name     : transcode.sh
#   Description   : A script to transcode videos using ffmpeg with user-selected configurations including
#                   source directory, destination directory, video codec, decoder, video size, and video bitrate.
#
# ====================================================


# 初始化变量
IFS=$'\t\n'
SCRIPT_DIR=$(dirname "$0")
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
ffmpeg_audio_cmd=()
ffmpeg_encode_cmd=()
video_format=("mp4" "mkv" "avi" "wmv" "flv" "mov" "m4v" "rm" "rmvb" "3gp" "vob" "MP4" "MKV" "AVI" "WMV" "FLV" "MOV" "M4V" "RM" "RMVB" "3GP" "VOB")
sub_format=("srt" "ass" "ssa" "vtt" "sub" "idx" "SRT" "ASS" "SSA" "VTT" "SUB" "IDX")
video_bitrate=2000000


# 日志写入
function _write_log() {
    local message="$1"
    echo "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "${SCRIPT_DIR}/transcode.log"
}

# 验证路径输入
function _validate_path() {
    local path="$1"
    if [[ "$path" == "../"* || "$path" == "./"* ]]; then
        echo "错误: 非法的路径输入"
        exit 1
    fi
}

# 检查文件是否为视频文件
function _is_video_format() {
    local file="$1"
    for format in "${video_format[@]}"; do
        if [[ "$file" == *."$format" ]]; then
            return 0
        fi
    done
    return 1
}

# 检查文件是否为字幕文件
function _is_sub_format() {
    local file="$1"
    for format in "${sub_format[@]}"; do
        if [[ "$file" == *."$format" ]]; then
            return 0
        fi
    done
    return 1
}

# 将指定文件直接复制至新路径
function _copy_file() {

    local relative_path="${1#$origin_path}"
    local new_file_path="${dest_path}${relative_path}"

    # 如果目标文件已存在，删除并覆盖
    if [ -f "$new_file_path" ]; then
        rm -f "$new_file_path" || {
            echo "Error: Failed to remove existing file '$new_file_path'."
            return 1
        }
    fi

    cp "$1" "$new_file_path"
    return 0

}


# 获取视频码率，单位为kbps
function _get_video_bitrate() {
    local video_path="$1"
    local bitrate=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of default=noprint_wrappers=1:nokey=1 "$video_path")
  
    if [[ -n "$bitrate" ]]; then
        echo "$bitrate"
    else
        echo "0"
    fi
}


# 根据用户选择设置输出格式
function set_format() {
    local ans
    echo "选择转码输出格式："
    
    if [ $silent_mode -eq 1 ]; then
        ans="abc"
    else
        echo "1. h264"
        echo "2. hevc（默认）"
        read -p "请输入选项：" ans
    fi

    case "$ans" in
        1)
            ffmpeg_code="h264"
        ;;
        2)
            ffmpeg_code="hevc"
        ;;
        *)
            echo "无效选择，将使用默认选项：hevc"
            ffmpeg_code="hevc"
        ;;
    esac
}
# 根据用户选择设置遍解码器
function set_coder() {
    local ans
    echo "选择编码器 解码器："
    
    if [ $silent_mode -eq 1 ]; then
        ans="abc"
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
            
            if [ $ffmpeg_code = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ $ffmpeg_code = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi

        ;;
        2)
            ffmpeg_decode="MPP"
            ffmpeg_decode_cmd=(-hwaccel rkmpp -hwaccel_output_format drm_prime -afbc rga)

            if [ $ffmpeg_code = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ $ffmpeg_code = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi
        ;;
        3)
            ffmpeg_decode="CPU"
            ffmpeg_decode_cmd=()

            if [ $ffmpeg_code = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v libx264)
            elif [ $ffmpeg_code = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v libx265)
            fi
        ;;
        *)
            echo "无效选择，将使用默认选项：RockChip MPP硬件编解码"
            ffmpeg_decode="MPP"
            ffmpeg_decode_cmd=(-hwaccel rkmpp -hwaccel_output_format drm_prime -afbc rga)
            
            if [ $ffmpeg_code = "h264" ] ; then
                ffmpeg_encode_cmd=(-c:v h264_rkmpp)
            elif [ $ffmpeg_code = "hevc" ]  ; then
                ffmpeg_encode_cmd=(-c:v hevc_rkmpp)
            fi
        ;;
    esac
}

# 根据用户选择设置视频大小
function set_video_size() {
    local ans video_high
    # 根据用户选择设置视频大小
    echo "选择视频大小："

    if [ $silent_mode -eq 1 ]; then
        ans="abc"
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
        ;;
        2)
            video_high=1080
        ;;
        3)
            video_high=720
        ;;
        4)
            video_high=480
        ;;
        5)
            video_high=360
        ;;
        *)
            echo "无效选择，将使用默认选项：720P"
            video_high=720
        ;;
    esac

    case "$ffmpeg_decode" in
        "CPU")
            ffmpeg_videosize_cmd=(-vf scale=-2:"'min($video_high,ih)'":flags=fast_bilinear,format=yuv420p)
        ;;
        "MPP")
            ffmpeg_videosize_cmd=(-vf scale_rkrga=w=-2:h="'min($video_high,ih)'":format=nv12:afbc=1)
        ;;
    esac
    
}


# 设置视频码率
function set_video_bitrate() {

    # 根据用户选择设置视频码率
    echo "选择视频码率或直接输入码率："
    if [ $silent_mode -eq 1 ]; then
        ans="abc"
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
        ;;
        2)
            video_bitrate=2000
        ;;
        3)
            video_bitrate=3000
        ;;
        4)
            video_bitrate=4000
        ;;
        5)
            video_bitrate=5000
        ;;
        *)
            # 验证输入值是否在100-100000之间
            if ! [[ $ans =~ ^[1-9][0-9]{1,4}$ ]]; then
                echo "无效选择，将使用默认选项：2000k"
                video_bitrate=2000
            else
                video_bitrate=$ans

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
        echo "错误: $base_path 不是一个目录."
        return 1
    fi

    # 使用find命令递归查找所有文件并添加到数组
    while IFS= read -r -d '' file; do
        all_files+=("$file")
    done < <(find "$base_path" -type f -print0)
    
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

}

function transcode_video(){
   
    # 检查输入参数是否为有效文件
    if [ -z "$1" ] || [ ! -f "$1" ]; then
        echo "Error: No valid file provided."
        return 1
    fi

    # 安全路径处理
    # 检查origin_path是否为目录还是文件
    if [ -d "$origin_path" ]; then
        local relative_path="${1#$origin_path}"
    else
        local relative_path="/$(basename $1)"
    fi

    local new_file_path="${dest_path}${relative_path}"

    # 后缀替换
    new_file_path="${new_file_path%.*}.mp4"

    # 获取视频码率
    local origin_video_bitrate=$(_get_video_bitrate "$1")

    # 如果获取到的视频码率为0，输出错误
    if [ "$origin_video_bitrate" -eq "0"  ]; then
        _write_log "转码失败,无法获取原视频码率：$relative_path"
        return 1
    fi

    # 如果原视频码率小于设置码率，则使用原视频码率
    if [ "$origin_video_bitrate" -lt "$video_bitrate" ]; then
        video_bitrate="$origin_video_bitrate"
    fi

    ffmpeg_rc_cmd=(-rc_mode VBR -b:v $video_bitrate -maxrate $((video_bitrate * 12 / 10)) -bufsize $((video_bitrate * 2)) -g:v 120)
    
    # 创建文件夹
    if [ ! -d "${new_file_path%/*}" ]; then
        mkdir -p "${new_file_path%/*}"
    fi

    # 使用ffmpeg进行转码
    ffmpeg -hide_banner "${ffmpeg_decode_cmd[@]}" -i "$1" -strict -2 "${ffmpeg_videosize_cmd[@]}" "${ffmpeg_rc_cmd[@]}" "${ffmpeg_encode_cmd[@]}" "${ffmpeg_audio_cmd[@]}" -c:s mov_text -map 0:v -map 0:a -map 0:s? -y "$new_file_path"
    if [ $? -eq 0 ]; then
        # 文件大小计算
        local origin_file_size=$(du -h "$1" | cut -f1)
        local new_file_size=$(du -h "$new_file_path" | cut -f1)
        _write_log "转码成功：$relative_path [$origin_file_size -> $new_file_size]"
    else
        _write_log "转码失败,FFmpeg错误：$relative_path"
        return 1
    fi

    # 修复权限
    chmod 777 "$new_file_path" || {
        echo "Error in file '$1': Failed to set permissions on the output file."
        return 1
    }
}

# 将字幕文件类型复制到新目录
function copy_sub_files(){ 
    
    local copyTotal=0
    local file_path=""
    for file_path in "${sub_file_paths[@]}"; do
        
        let copyTotal=copyTotal+1
        _write_log "字幕文件：复制第 $copyTotal 个文件，共计 ${#sub_file_paths[@]} 个文件"
        _copy_file "$file_path"
    
    done

}


# 将其他文件类型复制到新目录
function copy_other_files(){ 
    
    local copyTotal=0
    local file_path=""
    for file_path in "${other_file_paths[@]}"; do
        
        let copyTotal=copyTotal+1
        _write_log "其他文件：复制第 $copyTotal 个文件，共计 ${#other_file_paths[@]} 个文件"
        _copy_file "$file_path"
    
    done

}

function main(){

    # 如未提供目录参数，则进行配置设置
    if [ ! -n "$1" ];then
        
        # 读取并验证原始文件目录和目标文件目录
        read -p "输入原始文件目录：" origin_path
        [ -z "$origin_path" ] && { echo "原始文件目录不能为空"; exit 1; }
        
        read -p "输入目标文件目录：" dest_path
        [ -z "$dest_path" ] && { echo "目标文件目录不能为空"; exit 1; }

    else

        silent_mode=1
        origin_path="$1"
        dest_path="$2"

    fi

    # 验证路径输入
    _validate_path "$origin_path"
    _validate_path "$dest_path"

    # 选择转码输出格式
    set_format

    # 设置解码器和编码器
    set_coder

    # 设置视频大小
    set_video_size    

    # 设置视频码率
    set_video_bitrate
    
    # 检查输入是否为目录还是文件
    if [ -d "$origin_path" ]; then
        echo "当前输入路径为目录"

        lm_traverse_dir "$origin_path"

        # 复制字幕文件
        if [ ${#sub_file_paths[@]} -gt 0 ]; then
            copy_sub_files
        fi

    else
        echo "当前输入路径为单个文件"

        # 判断是否为视频文件
        if ! _is_video_format "$origin_path"; then
            echo "Error: $origin_path 不是视频文件"
            exit 1
        fi
        video_file_paths=("$origin_path")
    fi

    # 输出视频文件路径数组数量
    if [ ${#video_file_paths[@]} -eq 0 ]; then
        echo "文件路径数组为空！"
        exit 1
    fi

    # 遍历视频文件路径数组并转码
    transcodeTotal=0
    for file_path in "${video_file_paths[@]}"; do
        
        let transcodeTotal=transcodeTotal+1
        _write_log "开始转码第 $transcodeTotal 个文件，共计 ${#video_file_paths[@]} 个文件"
        transcode_video "$file_path"
    
    done

}

main "$@"