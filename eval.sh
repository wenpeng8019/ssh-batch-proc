#!/bin/bash

# set -e: 启用"错误即退出"模式
#   目的: 确保脚本在任何命令失败时立即停止，避免在错误状态下继续执行后续逻辑
#   作用: 任何返回非零退出码的命令都会触发脚本退出（除非在 if/while 条件中或使用 || 处理）
#   注意: 
#     - 管道命令默认只检查最后一个命令的退出码，需配合 set -o pipefail 检查整个管道
#     - 在子shell $() 中的失败不会直接触发退出
#     - 使用 command || true 可以忽略特定命令的失败
#     - trap EXIT 会在脚本退出时执行，用于清理资源
set -e

# 模型文件扩展名
MODEL_FILE_EXT="${MODEL_FILE_EXT:-.xyz}"

# 输入文件配置
INPUT_SUFFIX_LIST="${INPUT_SUFFIX_LIST:-_y.bin,_uv.bin}"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                        ★★★ 远程评测配置 ★★★                                 
# ║          以下配置对应远程服务器上的评测工具参数，请根据实际情况修改                
# ╚═══════════════════════════════════════════════════════════════════════════╝

# 远程工作目录（空默认为用户主目录 $HOME）
REMOTE_WORK_DIR="${REMOTE_WORK_DIR:-}"         

# 远程模型文件路径（相对于远程工作目录，支持多个模型）
# + 这些文件需要在本地的 ${MODEL_DIR} 目录中存在，脚本会自动上传到远程对应路径
REMOTE_MODEL_FILE0="${REMOTE_MODEL_FILE0:-model/model${MODEL_FILE_EXT}}"
REMOTE_MODEL_FILE1="${REMOTE_MODEL_FILE1:-}"
REMOTE_MODEL_FILE2="${REMOTE_MODEL_FILE2:-}"
REMOTE_MODEL_FILE3="${REMOTE_MODEL_FILE3:-}"

# 远程输入输出目录（相对于远程工作目录）
REMOTE_INPUT_DIR="${REMOTE_INPUT_DIR:-test_data}"
REMOTE_OUTPUT_DIR="${REMOTE_OUTPUT_DIR:-out}"

# INPUT_NUM 自动根据后缀数量计算，除非显式指定
_suffix_count=$(echo "$INPUT_SUFFIX_LIST" | tr ',' '\n' | wc -l | tr -d ' ')
INPUT_NUM="${INPUT_NUM:-$_suffix_count}"                # 输入批（tensor）文件数量

# 后处理插件（必须通过环境变量指定，无默认值）
POST_PROCESS_PLUGIN="${POST_PROCESS_PLUGIN:-}"

# 日志级别 (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR, 4=FATAL)
REMOTE_LOG_LEVEL="${REMOTE_LOG_LEVEL:-2}"

unset _suffix_count

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 远程评测命令模板（可选）                                                   
# │ 支持的变量:                                                              
# │   {WORK_DIR}     - 远程工作目录                                          
# │   {MODEL_PATH0}  - 第一个模型完整路径                                     
# │   {MODEL_PATH1}  - 第二个模型完整路径                                     
# │   {MODEL_PATH2}  - 第三个模型完整路径                                     
# │   {MODEL_PATH3}  - 第四个模型完整路径                                     
# │   {INPUT_PATH}   - 输入目录完整路径                                       
# │   {OUTPUT_PATH}  - 输出目录完整路径                                       
# │   {INPUT_NUM}    - 输入批（tensor）文件数量                               
# │   {INPUT_SUFFIX} - 文件后缀列表                                          
# │   {POST_PLUGIN}  - 后处理插件名称                                        
# │   {LOG_LEVEL}    - 日志级别                                              
# │ 留空则使用默认命令格式                                                   
# └─────────────────────────────────────────────────────────────────────────┘
REMOTE_EVAL_CMD="${REMOTE_EVAL_CMD:-$(cat << 'EVAL_CMD_EOF'
cd /root && ./run eval \
    --model_file "{MODEL_PATH0}" \
    --input_path "{INPUT_PATH}" \
    --input_num "{INPUT_NUM}" \
    --input_suffix "{INPUT_SUFFIX}" \
    --output_path "{OUTPUT_PATH}" \
    --post_process_plugin "{POST_PLUGIN}" \
    --log_level "{LOG_LEVEL}"
EVAL_CMD_EOF
)}"

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                          ★★★ 本地评测配置 ★★★
# ║                以下配置对应本地脚本行为，请根据实际情况修改
# ╚═══════════════════════════════════════════════════════════════════════════╝

# -------------------------------- 配置区域 --------------------------------
# SSH 配置
SSH_HOST="${SSH_HOST:-root@127.0.0.1}"              # SSH 主机地址
SSH_PORT="${SSH_PORT:-22}"                          # SSH 端口
SSH_KEY="${SSH_KEY:-}"                              # SSH 私钥路径（可选）

# 本地目录配置
EVAL_DIR="${EVAL_DIR:-}"                            # 评测数据集子目录（相对于脚本所在目录，例如 example/case0）
OUT_SUBDIR="${OUT_SUBDIR:-output}"                  # 评测结果输出子目录名（相对于评测数据集子目录）
IN_SUBDIR="${IN_SUBDIR:-yuv}"                       # 待评测输入数据子目录名（相对于评测数据集子目录）

# 本地模型目录（存放评测所使用的模型文件，可以是多个）
# + 默认会自动根据 EVAL_DIR 计算，即获取 EVAL_DIR 路径中的第一级目录。即该目录被视为”评测任务“，而 EVAL_DIR 则是该任务下的一个评测数据集子目录
MODEL_DIR="${MODEL_DIR:-}"

# 批处理配置
MAX_BATCH_SIZE="${MAX_BATCH_SIZE:-200}"             # 每批最大文件数量

# 压缩传输配置
ENABLE_COMPRESSION="${ENABLE_COMPRESSION:-true}"    # 是否启用压缩传输（可节省约50%传输时间）
COMPRESSION_TEMP_DIR="${COMPRESSION_TEMP_DIR:-/tmp/eval_compress}"  # 本地压缩临时目录

# 评测状态文件配置
EVAL_STATE_NAME="${EVAL_STATE_NAME:-.eval_task}"    # 状态文件名（不含路径，可不带 .state 后缀）

# 评测任务配置文件名
EVAL_CONFIG_NAME="${EVAL_CONFIG_NAME:-.eval_config}" # 任务配置文件名（在数据集目录下）

# -------------------------------- 帮助信息 --------------------------------

show_help() {
    cat << EOF
用法: $(basename "$0") [选项] <评测数据集子目录>
描述:
    将本地评测数据集分批上传到远程 SSH 服务器执行评测，并将结果取回本地。

参数:
    <评测数据集子目录>    要评测的子目录路径（如 part1/cyclist）

选项:
    -h, --help              显示此帮助信息
    -H, --host HOST         SSH 主机地址 (默认: $SSH_HOST)
    -p, --port PORT         SSH 端口 (默认: $SSH_PORT)
    -k, --key KEY_FILE      SSH 私钥文件路径
    -w, --work-dir DIR      远程工作目录 (默认: $REMOTE_WORK_DIR)
    -M, --model-dir DIR     本地模型目录（存放待上传的模型文件，默认为评测任务工作目录）
    -o, --output-dir DIR    评测结果输出子目录名 (默认: $OUT_SUBDIR)
    -i, --input-dir DIR     本地待评测输入数据子目录名 (默认: $IN_SUBDIR)
    -s, --suffix LIST       输入数据文件后缀列表，逗号分隔（如 "_y.bin,_uv.bin"）
    -b, --batch-size SIZE   每批最大文件数量 (默认: $MAX_BATCH_SIZE)
    -y, --dry-run [N]       干运行模式：仅打印将要执行的 SSH/SCP 命令，不实际连接远程服务器
                            可选参数 N：模拟延迟秒数，用于测试批次处理和进度监控 (默认: 0)
                            用于调试和验证配置是否正确
    -v, --verbose           详细输出模式

模型配置说明:
    脚本会根据远程模型配置（REMOTE_MODEL_FILE0/1/2/3）中的文件名，
    自动在本地模型目录中查找对应文件并上传到远程指定路径。

示例:
    $(basename "$0") -H user@192.168.1.100 -b 5 part1/cyclist
    $(basename "$0") -H user@server -M /path/to/models part1/cyclist
    $(basename "$0") -H user@server -s "_left.yuv" -b 5 part1/cyclist
    SSH_HOST=user@server MAX_BATCH_SIZE=20 $(basename "$0") part1/lane_parsing

注意:
    远程评测配置（模型路径、输入输出目录、后处理插件等）请在脚本开头的
    "★★★ 远程评测配置 ★★★" 区域修改。

EOF
    exit 0
}

# -------------------------------- 全局变量 --------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 检测操作系统
OS_TYPE="$(uname)"
IS_MACOS=false
[[ "$OS_TYPE" == "Darwin" ]] && IS_MACOS=true

DRY_RUN="${DRY_RUN:--1}"                            # 干运行模式（-1=关闭，>=0=开启，0=无延迟，>0=延迟N秒）
VERBOSE="${VERBOSE:-false}"                         # 详细输出模式  

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 状态文件数据结构: EVAL_STATE_FILE                                         
# ├─────────────────────────────────────────────────────────────────────────┤
# │ 文件格式（固定结构）:                                                     
# │   第 1 行:     # 评测任务状态文件
# │   第 2-9 行:  RUNNING_TOTAL_BATCHES=N       (总批次数量) 
# │               RUNNING_FAILED_BATCHES=N      (累计失败的批次数量)
# │               RUNNING_CURRENT_BATCH=N       (当前执行的批次号 1-based)
# │               RUNNING_BATCH_TOTAL=N         (当前批次总评测项数，即 MAX_BATCH_SIZE)
# │               RUNNING_BATCH_COMPLETED=N     (当前批次已上传完成的评测项数量)
# │               RUNNING_BATCH_STATE=N         (当前批次状态: 0=上传中, -2=远程执行中, -1=开始下载, >0=已下载数量)
# │               RUNNING_RETRY_COUNT=N         (当前批次累计重试次数)
# │               RUNNING_TIMESTAMP=N           (最后更新的 Unix 时间戳，创建或 update_running_info 时更新)
# │   第 9+ 行:    MAX_BATCH_SIZE=200           (批次大小配置)               
# │               TOTAL_DATA=N                  (总数据前缀数)               
# │               TOTAL_FILES=N                 (总文件数)                   
# │               SUFFIX_LIST="..."             (文件后缀列表)               
# │               {批次列表 BATCH_N=...}                                     
# │                                                                           
# │ 更新策略:                                                                 
# │   - RUNNING_ 字段: 每次上传批次时通过 update_running_info() 原子更新     
# │   - 固定配置: 仅在 generate_eval_state_file() 初始化时写入一次           
# │   - 批次列表: 记录每个批次的文件前缀（格式: BATCH_0=prefix1:prefix2...）  
# │                                                                           
# │ 原子性保证:                                                               
# │   使用 "构建临时文件 -> mv 原子替换" 模式，确保其他进程读取时不会看到     
# │   不完整的中间状态（详见 update_running_info() 函数实现）                
# └─────────────────────────────────────────────────────────────────────────┘
# RUNNING_XXX 字段的数量（固定值，用于性能优化）
readonly RUNNING_FIELD_COUNT=8
EVAL_STATE_FILE=""                                  # 状态文件完整路径（运行时自动生成）

# 远程备份记录（用于成功后恢复）
# > 首次运行时：在 init_remote_workspace() 中创建备份，在 upload_datasets_models() 结束时调用 save_backup_info() 保存到状态文件
# > 续传运行时：在主流程中调用 load_backup_info() 从状态文件恢复到内存
# > 完成清理时：在 final_cleanup() 中使用内存变量恢复远程备份
backup_input_dir=""                                 # 备份的输入目录路径
backup_output_dir=""                                # 备份的输出目录路径
backup_models=()                                    # 备份的模型文件（格式: "备份路径|原路径"）

# 本次上传的模型记录（用于完成后清理）
uploaded_models=()                                  # 本次上传的模型路径列表

# 失败环境记录（用于失败后保留调试环境）
failed_input_dir=""                                 # 失败时的输入目录路径
failed_output_dir=""                                # 失败时的输出目录路径
failed_timestamp=""                                 # 失败时的时间戳

# 全局模型类型标志
all_models_absolute=true                            # 所有模型是否均为远程绝对路径

# -------------------------------- 工具函数 --------------------------------

log_info() {
    echo -e "\033[32m[INFO]\033[0m $*"
}

log_warn() {
    echo -e "\033[33m[WARN]\033[0m $*"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $*" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "\033[36m[DEBUG]\033[0m $*"
    fi
}

# 跨平台 sed -i（macOS 需要 -i ''，Linux 只需 -i）
sed_inplace() {
    if [[ "$IS_MACOS" == "true" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# 跨平台获取 MD5
get_local_md5() {
    local file="$1"
    if [[ "$IS_MACOS" == "true" ]]; then
        md5 -q "$file" 2>/dev/null
    else
        md5sum "$file" 2>/dev/null | awk '{print $1}'
    fi
}

# 获取远程文件 MD5
get_remote_md5() {
    local remote_file="$1"
    
    # DRY_RUN 模式：返回模拟的 MD5（与本地相同，避免验证失败）
    if [[ $DRY_RUN -ge 0 ]]; then
        # 尝试计算对应的本地文件 MD5，如果找不到则返回固定值
        local filename
        filename=$(basename "$remote_file")
        # 在输入目录中查找对应文件
        local local_input="$SCRIPT_DIR/$EVAL_DIR/$IN_SUBDIR/$filename"
        if [[ -f "$local_input" ]]; then
            get_local_md5 "$local_input"
        else
            # 如果找不到本地文件，返回固定的模拟MD5
            echo "0dcb3a5ccbfe2505697a1aba4e003ee0"
        fi
        return 0
    fi
    
    run_ssh "md5sum $remote_file 2>/dev/null | awk '{print \$1}' || md5 -q $remote_file 2>/dev/null" 2>/dev/null
}

# 构建 SSH 命令参数
build_ssh_opts() {

    # !! 注意，-n: 用于将 stdin 重定向到 /dev/null，否则 ssh 会消费 stdin 的数据。
    # 如果外层使用类似 while read 语句来执行循环操作，即遍历 stdin 中的数据时，
    # 那么不加 -n 的 ssh 就可能会将 stdin 中的数据消费掉，导致外层循环提前退出。
    local opts="-n -o StrictHostKeyChecking=no -o ConnectTimeout=10"
    opts+=" -p $SSH_PORT"
    if [[ -n "$SSH_KEY" ]]; then
        opts+=" -i $SSH_KEY"
    fi
    echo "$opts"
}

# 构建 SCP 命令参数
build_scp_opts() {
    local opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
    opts+=" -P $SSH_PORT"  # SCP 使用大写 -P 指定端口
    if [[ -n "$SSH_KEY" ]]; then
        opts+=" -i $SSH_KEY"
    fi
    echo "$opts"
}

# 执行 SSH 命令
run_ssh() {

    local cmd="$1"
    local ssh_opts
    ssh_opts=$(build_ssh_opts)
    
    if [[ $DRY_RUN -ge 0 ]]; then
        log_info "[DRY-RUN] ssh $ssh_opts $SSH_HOST \"$cmd\""
        if [[ $DRY_RUN -gt 0 ]]; then
            log_debug "[DRY-RUN] 模拟延迟 ${DRY_RUN}s..."
            sleep "$DRY_RUN"
        fi
        return 0
    fi
    
    log_debug "执行远程命令: $cmd"
    # shellcheck disable=SC2086
    ssh $ssh_opts "$SSH_HOST" "$cmd"
}

# 执行 SCP 上传
run_scp_upload() {

    local src="$1"
    local dst="$2"
    local scp_opts
    scp_opts=$(build_scp_opts)
    
    if [[ $DRY_RUN -ge 0 ]]; then
        log_info "[DRY-RUN] scp $scp_opts -r $src $SSH_HOST:$dst"
        [[ $DRY_RUN -gt 0 ]] && sleep "$DRY_RUN"
        return 0
    fi
    
    log_debug "上传: $src -> $SSH_HOST:$dst"
    # shellcheck disable=SC2086
    scp $scp_opts -r "$src" "$SSH_HOST:$dst"
}

# 执行 SCP 下载
run_scp_download() {

    local src="$1"
    local dst="$2"
    local scp_opts
    scp_opts=$(build_scp_opts)
    
    if [[ $DRY_RUN -ge 0 ]]; then
        log_info "[DRY-RUN] scp $scp_opts -r $SSH_HOST:$src $dst"
        
        # 如果目标是文件（不以/结尾），创建文件；否则创建目录
        if [[ "$dst" != */ ]]; then
            # 目标是文件，检查是否是压缩包
            mkdir -p "$(dirname "$dst")"
            
            if [[ "$dst" =~ \.(tar\.gz|tgz|tar\.bz2|tbz2|zip)$ ]]; then
                # 压缩包文件：创建临时目录，生成模拟文件，然后打包
                local temp_dir="/tmp/dry_run_archive_$$_$RANDOM"
                mkdir -p "$temp_dir"
                
                # 生成 3-5 个模拟的结果文件
                local file_count=$((RANDOM % 3 + 3))
                for i in $(seq 1 $file_count); do
                    local fake_file="$temp_dir/result_${i}.txt"
                    echo "[DRY-RUN] 模拟下载的评测结果文件 $i" > "$fake_file"
                    echo "时间戳: $(date)" >> "$fake_file"
                    echo "数据大小: $((RANDOM % 1000 + 100)) KB" >> "$fake_file"
                    echo "批次信息: batch_$(basename "$dst" | sed 's/[^0-9]//g')" >> "$fake_file"
                done
                
                # 根据文件扩展名创建对应的压缩包
                if [[ "$dst" =~ \.(tar\.gz|tgz)$ ]]; then
                    tar czf "$dst" -C "$temp_dir" . 2>/dev/null
                elif [[ "$dst" =~ \.(tar\.bz2|tbz2)$ ]]; then
                    tar cjf "$dst" -C "$temp_dir" . 2>/dev/null
                elif [[ "$dst" =~ \.zip$ ]]; then
                    (cd "$temp_dir" && zip -q -r "$dst" .) 2>/dev/null
                fi
                
                # 清理临时目录
                rm -rf "$temp_dir"
                log_debug "[DRY-RUN] 已生成模拟压缩包: $dst (包含 $file_count 个文件)"
            else
                # 普通文件
                echo "[DRY-RUN] 模拟下载的文件" > "$dst"
                echo "时间戳: $(date)" >> "$dst"
                echo "数据大小: $((RANDOM % 1000 + 100)) KB" >> "$dst"
                log_debug "[DRY-RUN] 已生成模拟文件: $dst"
            fi
        else
            # 目标是目录，生成模拟下载的文件（支持通配符解析）
            local target_dir="$dst"
            [[ "$dst" == */ ]] && target_dir="${dst%/}"  # 去掉末尾的斜杠
            mkdir -p "$target_dir"
            
            # 从源路径提取前缀（用于生成文件名）
            local src_pattern="${src##*/}"  # 获取最后一部分，可能包含通配符
            local src_prefix="${src_pattern%%\**}"  # 去掉通配符部分
            
            # 生成 1-3 个随机模拟文件
            local file_count=$((RANDOM % 3 + 1))
            for i in $(seq 1 $file_count); do
                local fake_file="$target_dir/${src_prefix}result_${i}.txt"
                echo "[DRY-RUN] 模拟下载的评测结果文件 $i" > "$fake_file"
                echo "时间戳: $(date)" >> "$fake_file"
                echo "数据大小: $((RANDOM % 1000 + 100)) KB" >> "$fake_file"
            done
            log_debug "[DRY-RUN] 已生成 $file_count 个模拟文件到 $target_dir"
        fi
        
        sleep "$DRY_RUN"
        return 0
    fi
    
    log_debug "下载: $SSH_HOST:$src -> $dst"
    # shellcheck disable=SC2086
    scp $scp_opts -r "$SSH_HOST:$src" "$dst"
}

# 批量压缩上传（压缩单个文件并批量SCP）
batch_compress_upload() {

    local remote_dir="$1"
    shift
    local files=("$@")
    
    if [[ ${#files[@]} -eq 0 ]]; then
        return 0
    fi
    
    # DRY_RUN 模式：仅打印信息，不实际压缩和上传
    if [[ $DRY_RUN -ge 0 ]]; then
        log_info "[DRY-RUN] gzip + scp ${#files[@]} 个文件 -> $SSH_HOST:$remote_dir"
        [[ $DRY_RUN -gt 0 ]] && sleep "$DRY_RUN"
        return 0
    fi
    
    # 创建临时压缩目录
    mkdir -p "$COMPRESSION_TEMP_DIR"
    
    # 压缩每个文件
    local gz_files=()
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            local filename
            filename=$(basename "$file")
            local gz_file="$COMPRESSION_TEMP_DIR/${filename}.gz"
            gzip -c "$file" > "$gz_file"
            gz_files+=("$gz_file")
        fi
    done
    
    if [[ ${#gz_files[@]} -eq 0 ]]; then
        return 0
    fi
    
    # 批量 SCP 上传压缩文件
    local scp_opts
    scp_opts=$(build_scp_opts)
    
    # shellcheck disable=SC2086
    scp $scp_opts "${gz_files[@]}" "$SSH_HOST:$remote_dir"
    
    # 清理本地临时文件
    rm -f "${gz_files[@]}"
    
    return 0
}

# 远程压缩并下载（先在远程压缩，下载后本地解压）
# 参数: $1=远程路径模式（支持通配符）, $2=本地目标目录
compress_download() {

    local remote_pattern="$1"
    local local_dir="$2"
    
    # 解析远程路径
    local remote_base_dir="${remote_pattern%/*}"
    local remote_file_pattern="${remote_pattern##*/}"
    
    # 生成临时打包文件名
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S_%N')
    local tar_name="download_${timestamp}.tar.gz"
    local remote_tar="$remote_base_dir/$tar_name"
    
    if [[ $DRY_RUN -ge 0 ]]; then
        log_info "[DRY-RUN] 远程压缩下载: $remote_pattern -> $local_dir"
        log_info "[DRY-RUN]   1. ssh: tar -czf $remote_tar -C $remote_base_dir $remote_file_pattern"
        log_info "[DRY-RUN]   2. scp: $remote_tar -> $local_dir/$tar_name"
        log_info "[DRY-RUN]   3. 本地解压: tar -xzf $local_dir/$tar_name -C $local_dir"
        log_info "[DRY-RUN]   4. 清理远程和本地临时文件"
        
        # 生成模拟下载的文件
        mkdir -p "$local_dir"
        local src_prefix="${remote_file_pattern%%\**}"
        local file_count=$((RANDOM % 3 + 1))
        for i in $(seq 1 $file_count); do
            local fake_file="$local_dir/${src_prefix}result_${i}.txt"
            echo "[DRY-RUN] 压缩下载的模拟文件 $i" > "$fake_file"
            echo "时间戳: $(date)" >> "$fake_file"
            echo "压缩率: $((RANDOM % 40 + 60))%" >> "$fake_file"
        done
        log_debug "[DRY-RUN] 已生成 $file_count 个模拟文件"
        
        sleep "$DRY_RUN"
        return 0
    fi
    
    # 确保本地目录存在
    mkdir -p "$local_dir"
    
    # 1. 远程打包压缩
    log_debug "远程压缩: $remote_pattern"
    if ! run_ssh "cd $remote_base_dir && tar -czf $tar_name $remote_file_pattern 2>/dev/null"; then
        log_warn "远程压缩失败，可能没有匹配的文件"
        return 1
    fi
    
    # 2. 下载压缩包
    log_debug "下载压缩包: $remote_tar -> $local_dir/"
    run_scp_download "$remote_tar" "$local_dir/"
    
    # 3. 本地解压
    local local_tar="$local_dir/$tar_name"
    if [[ -f "$local_tar" ]]; then
        log_debug "解压到: $local_dir"
        tar -xzf "$local_tar" -C "$local_dir" 2>/dev/null || true
        # 清理本地压缩包
        rm -f "$local_tar"
    fi
    
    # 4. 清理远程压缩包
    run_ssh "rm -f $remote_tar" 2>/dev/null || true
    
    return 0
}

# 远程批量解压
remote_batch_decompress() {

    local remote_dir="$1"
    
    if [[ $DRY_RUN -ge 0 ]]; then
        log_info "[DRY-RUN] ssh: gunzip $remote_dir/*.gz"
        [[ $DRY_RUN -gt 0 ]] && sleep "$DRY_RUN"
        return 0
    fi
    
    run_ssh "cd $remote_dir && gunzip -f *.gz 2>/dev/null || true"
}

# 清理压缩临时目录
cleanup_compression_temp() {
    if [[ -d "$COMPRESSION_TEMP_DIR" ]]; then
        rm -rf "$COMPRESSION_TEMP_DIR"
    fi
}

# -------------------------------- 核心函数 --------------------------------

# 构建远程评测命令
# + 对 REMOTE_EVAL_CMD 进行解析
#   - 替换模板变量
#   - 处理模型路径，支持绝对和相对路径
build_remote_eval_cmd() {

    local full_input_path="$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
    local full_output_path="$REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR"
    
    # 构造远程命令
    local cmd="$REMOTE_EVAL_CMD"
    
    # 构建模型路径（绝对路径直接使用，相对路径拼接 REMOTE_WORK_DIR）
    local model_path0=""
    local model_path1=""
    local model_path2=""
    local model_path3=""
    if [[ -n "$REMOTE_MODEL_FILE0" ]]; then
        [[ "$REMOTE_MODEL_FILE0" == /* ]] && model_path0="$REMOTE_MODEL_FILE0" || model_path0="$REMOTE_WORK_DIR/$REMOTE_MODEL_FILE0"
    fi
    if [[ -n "$REMOTE_MODEL_FILE1" ]]; then
        [[ "$REMOTE_MODEL_FILE1" == /* ]] && model_path1="$REMOTE_MODEL_FILE1" || model_path1="$REMOTE_WORK_DIR/$REMOTE_MODEL_FILE1"
    fi
    if [[ -n "$REMOTE_MODEL_FILE2" ]]; then
        [[ "$REMOTE_MODEL_FILE2" == /* ]] && model_path2="$REMOTE_MODEL_FILE2" || model_path2="$REMOTE_WORK_DIR/$REMOTE_MODEL_FILE2"
    fi
    if [[ -n "$REMOTE_MODEL_FILE3" ]]; then
        [[ "$REMOTE_MODEL_FILE3" == /* ]] && model_path3="$REMOTE_MODEL_FILE3" || model_path3="$REMOTE_WORK_DIR/$REMOTE_MODEL_FILE3"
    fi
    
    # 替换所有模板变量
    cmd="${cmd//\{WORK_DIR\}/$REMOTE_WORK_DIR}"
    cmd="${cmd//\{MODEL_PATH0\}/$model_path0}"
    cmd="${cmd//\{MODEL_PATH1\}/$model_path1}"
    cmd="${cmd//\{MODEL_PATH2\}/$model_path2}"
    cmd="${cmd//\{MODEL_PATH3\}/$model_path3}"
    cmd="${cmd//\{INPUT_PATH\}/$full_input_path}"
    cmd="${cmd//\{OUTPUT_PATH\}/$full_output_path}"
    cmd="${cmd//\{INPUT_NUM\}/$INPUT_NUM}"
    cmd="${cmd//\{INPUT_SUFFIX\}/$INPUT_SUFFIX_LIST}"
    cmd="${cmd//\{POST_PLUGIN\}/$POST_PROCESS_PLUGIN}"
    cmd="${cmd//\{LOG_LEVEL\}/$REMOTE_LOG_LEVEL}"
    
    # 如果 POST_PROCESS_PLUGIN 为空，移除 --post_process_plugin 参数
    # 同时支持单行和多行两种模式：
    # - 多行模式：删除包含该参数的整行
    # - 单行模式：只删除该参数及其值，保留同行的其他内容
    if [[ -z "$POST_PROCESS_PLUGIN" ]]; then
        cmd=$(echo "$cmd" | sed -E '
            /^[[:space:]]*--post_process_plugin[[:space:]]/d
            s/[[:space:]]+--post_process_plugin[[:space:]]+"[^"]*"//g
            s/[[:space:]]+--post_process_plugin[[:space:]]+[^[:space:]]+//g
        ')
    fi
    
    # 将多行命令转换为单行并清理多余空格
    cmd=$(echo "$cmd" | tr '\n' ' ' | sed 's/  \+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')
    
    # 输出最终命令（输入/输出目录已由 init_remote_workspace 创建）
    echo "$cmd"
}

# 加载评测配置文件
# + 这里的配置是针对一个特定的评测数据集子目录，即最终的评测目标。同时可被环境变量重载，也就是可被上级脚本覆盖
load_eval_config() {

    local full_eval_dir="$SCRIPT_DIR/$EVAL_DIR"
    local config_file="$full_eval_dir/$EVAL_CONFIG_NAME"
    
    if [[ -f "$config_file" ]]; then
        log_info "加载任务配置文件: $config_file"
        # 只加载允许的配置项
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            # 跳过注释和空行
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            # 去除首尾空格
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # 去除值的引号
            value=${value#\"}
            value=${value%\"}
            value=${value#\'}
            value=${value%\'}
            
            # 只有环境变量未设置时才使用配置文件的值
            case "$key" in
                REMOTE_INPUT_DIR|REMOTE_OUTPUT_DIR|\
                REMOTE_MODEL_FILE0|REMOTE_MODEL_FILE1|REMOTE_MODEL_FILE2|REMOTE_MODEL_FILE3|\
                INPUT_SUFFIX_LIST|POST_PROCESS_PLUGIN|INPUT_NUM|\
                MODEL_DIR|IN_SUBDIR|OUT_SUBDIR|MAX_BATCH_SIZE)
                    if [[ -z "${!key}" ]]; then
                        export "$key=$value"
                        log_debug "  $key=$value"
                    else
                        log_debug "  $key 已由环境变量设置，跳过配置文件值"
                    fi
                    ;;
                *)
                    log_warn "  忽略未知配置项: $key"
                    ;;
            esac
        done < "$config_file"
    fi
}

# 检查必要条件
check_prerequisites() {

    # 先加载评测配置文件
    load_eval_config
    
    log_info "检查前置条件..."
    
    # 检查 SSH 主机配置
    if [[ -z "$SSH_HOST" || "$SSH_HOST" == "user@remote-server" ]]; then
        log_error "  请配置 SSH 主机地址 (使用 -H 选项或设置 SSH_HOST 环境变量)"
        exit 1
    fi
    
    # 检查评测数据集目录是否存在
    local full_eval_dir="$SCRIPT_DIR/$EVAL_DIR"
    if [[ ! -d "$full_eval_dir" ]]; then
        log_error "  评测数据集目录不存在: $full_eval_dir"
        exit 1
    fi
    
    # 检查输入数据子目录是否存在
    local input_dir="$full_eval_dir/$IN_SUBDIR"
    if [[ ! -d "$input_dir" ]]; then
        log_error "  输入数据子目录不存在: $input_dir"
        exit 1
    fi
    
    # 统计模型类型，赋值全局变量 all_models_absolute，同时统计数量用于本地检查
    all_models_absolute=true
    local model_count=0
    local remote_model_count=0
    local -a relative_models=()
    
    for i in 0 1 2 3; do
        local remote_model_var="REMOTE_MODEL_FILE$i"
        local remote_model_path="${!remote_model_var}"
        if [[ -n "$remote_model_path" ]]; then
            if [[ "$remote_model_path" == /* ]]; then
                ((remote_model_count++)) || true
            else
                all_models_absolute=false
                relative_models+=("$remote_model_var:$remote_model_path")
                ((model_count++)) || true
            fi
        fi
    done

    # 只有存在需要上传的模型（模型路径为相对地址）时，才检查 MODEL_DIR 和本地文件
    if [[ $model_count -gt 0 ]]; then

        # 检查本地模型目录（默认为 EVAL_DIR 的第一级目录，即工作目录）
        local model_dir="${MODEL_DIR:-$SCRIPT_DIR/${EVAL_DIR%%/*}}"
        if [[ ! -d "$model_dir" ]]; then
            log_error "  本地模型目录不存在: $model_dir"
            exit 1
        fi

        # 检查需要上传的本地模型文件是否存在
        for model_info in "${relative_models[@]}"; do
            local remote_model_var="${model_info%%:*}"
            local remote_model_path="${model_info#*:}"
            local model_name
            model_name=$(basename "$remote_model_path")
            local local_model_file="$model_dir/$model_name"
            if [[ ! -f "$local_model_file" ]]; then
                log_error "  本地模型文件不存在: $local_model_file (对应远程 $remote_model_var)"
                exit 1
            fi
        done
        log_info "  总共需要上传 $model_count 个模型文件"
    fi
    if [[ $remote_model_count -gt 0 ]]; then
        log_info "  直接使用 $remote_model_count 个远程已有模型文件"
    fi
    
    # 检查 SSH 私钥
    if [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]]; then
        log_error "  SSH 私钥文件不存在: $SSH_KEY"
        exit 1
    fi
    
    # 测试 SSH 连接
    log_info "  测试 SSH 连接到 $SSH_HOST..."
    if ! run_ssh "echo 'SSH connection OK'" > /dev/null 2>&1; then
        if [[ $DRY_RUN -lt 0 ]]; then
            log_error "  无法连接到 SSH 服务器: $SSH_HOST"
            exit 1
        fi
    fi
    
    log_info "前置条件检查通过"
}

# 验证远程文件 MD5 是否与本地一致
verify_remote_files_md5() {
    local prefix="$1"
    local input_dir="$SCRIPT_DIR/$EVAL_DIR/$IN_SUBDIR"
    local remote_input="$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
    
    local -a suffixes
    IFS=',' read -ra suffixes <<< "$INPUT_SUFFIX_LIST"
    
    for suffix in "${suffixes[@]}"; do
        local local_file="$input_dir/${prefix}${suffix}"
        local remote_file="$remote_input/${prefix}${suffix}"
        
        if [[ ! -f "$local_file" ]]; then
            continue
        fi
        
        local local_md5
        local_md5=$(get_local_md5 "$local_file")
        local remote_md5
        remote_md5=$(get_remote_md5 "$remote_file")
        
        if [[ "$local_md5" != "$remote_md5" ]]; then
            log_debug "MD5 不匹配: $prefix$suffix (本地: $local_md5, 远程: $remote_md5)"
            return 1
        fi
    done
    
    return 0
}

# 初始化远程工作目录
init_remote_workspace() {

    local is_resume="${1:-false}"
    log_info "初始化远程工作目录: $REMOTE_WORK_DIR"
    
    # 生成时间戳后缀
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    
    # 确保远程工作目录存在
    run_ssh "mkdir -p $REMOTE_WORK_DIR"
    
    # 续传模式：检查并恢复上次保存的环境
    local need_backup_and_create=true
    if [[ "$is_resume" == "true" && -f "$EVAL_STATE_FILE" ]]; then
        local saved_failed_input saved_failed_output saved_failed_models saved_failed_timestamp
        saved_failed_input=$(grep '^failed_input_dir=' "$EVAL_STATE_FILE" 2>/dev/null | cut -d'=' -f2)
        saved_failed_output=$(grep '^failed_output_dir=' "$EVAL_STATE_FILE" 2>/dev/null | cut -d'=' -f2)
        saved_failed_models=$(grep '^failed_models=' "$EVAL_STATE_FILE" 2>/dev/null | cut -d'=' -f2)
        saved_failed_timestamp=$(grep '^failed_timestamp=' "$EVAL_STATE_FILE" 2>/dev/null | cut -d'=' -f2)
        
        # 如果有保存的环境记录，恢复它（不管是什么状态）
        if [[ -n "$saved_failed_input" && -n "$saved_failed_output" && -n "$saved_failed_timestamp" ]]; then
            log_info "续传模式：恢复上次保存的环境 (时间戳: $saved_failed_timestamp)..."
            
            local input_dir="$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
            local output_dir="$REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR"
            
            # 先备份当前环境（如果存在）
            if run_ssh "test -d $input_dir" 2>/dev/null; then
                backup_input_dir="${input_dir}.${timestamp}"
                log_info "备份当前输入目录: $REMOTE_INPUT_DIR -> $(basename "$backup_input_dir")"
                run_ssh "mv $input_dir $backup_input_dir"
            fi
            if run_ssh "test -d $output_dir" 2>/dev/null; then
                backup_output_dir="${output_dir}.${timestamp}"
                log_info "备份当前输出目录: $REMOTE_OUTPUT_DIR -> $(basename "$backup_output_dir")"
                run_ssh "mv $output_dir $backup_output_dir"
            fi
            
            # 恢复上次保存的环境
            local failed_input_path="$REMOTE_WORK_DIR/$saved_failed_input"
            local failed_output_path="$REMOTE_WORK_DIR/$saved_failed_output"
            
            if run_ssh "test -d $failed_input_path" 2>/dev/null; then
                log_info "恢复上次保存的输入目录: $saved_failed_input -> $REMOTE_INPUT_DIR"
                run_ssh "mv $failed_input_path $input_dir"
            else
                log_warn "上次保存的输入目录不存在: $saved_failed_input"
                # 创建空目录
                run_ssh "mkdir -p $input_dir"
            fi
            
            if run_ssh "test -d $failed_output_path" 2>/dev/null; then
                log_info "恢复上次保存的输出目录: $saved_failed_output -> $REMOTE_OUTPUT_DIR"
                run_ssh "mv $failed_output_path $output_dir"
            else
                log_warn "上次保存的输出目录不存在: $saved_failed_output"
                # 创建空目录
                run_ssh "mkdir -p $output_dir"
            fi
            
            # 恢复上次保存的模型文件
            if [[ -n "$saved_failed_models" ]]; then
                IFS='|' read -ra failed_model_list <<< "$saved_failed_models"
                for relative_failed_path in "${failed_model_list[@]}"; do
                    local failed_model_path="$REMOTE_WORK_DIR/$relative_failed_path"
                    # 提取原始相对路径（去掉.timestamp.failed/pending后缀）
                    local relative_original=$(echo "$relative_failed_path" | sed -E 's/\.[0-9]{8}_[0-9]{6}\.(failed|pending)$//')
                    local original_path="$REMOTE_WORK_DIR/$relative_original"
                    
                    if run_ssh "test -f $failed_model_path" 2>/dev/null; then
                        log_info "恢复上次保存的模型文件: $relative_failed_path -> $relative_original"
                        run_ssh "mv $failed_model_path $original_path" 2>/dev/null || true
                        # 重新加入 uploaded_models 数组，以便后续清理
                        uploaded_models+=("$original_path")
                    else
                        log_warn "上次保存的模型文件不存在: $relative_failed_path"
                    fi
                done
            fi
            
            # 清除状态文件中的保存环境记录
            sed_inplace '/^failed_input_dir=/d; /^failed_output_dir=/d; /^failed_models=/d; /^failed_timestamp=/d' "$EVAL_STATE_FILE"
            
            # 标记已完成环境准备
            need_backup_and_create=false
        fi
    fi
    
    # 如果没有恢复保存的环境，则执行正常的备份和创建逻辑
    if [[ "$need_backup_and_create" == "true" ]]; then
        local input_dir="$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
        if run_ssh "test -d $input_dir" 2>/dev/null; then
            backup_input_dir="${input_dir}.${timestamp}"
            log_warn "$REMOTE_INPUT_DIR 目录已存在，重命名为: $backup_input_dir"
            run_ssh "mv $input_dir $backup_input_dir"
        fi
        
        # 检查并备份已存在的输出目录
        local output_dir="$REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR"
        if run_ssh "test -d $output_dir" 2>/dev/null; then
            backup_output_dir="${output_dir}.${timestamp}"
            log_warn "$REMOTE_OUTPUT_DIR 目录已存在，重命名为: $backup_output_dir"
            run_ssh "mv $output_dir $backup_output_dir"
        fi
        
        # 创建新的输入/输出目录
        run_ssh "mkdir -p $input_dir $output_dir"
    fi
    
    local model_dir="${MODEL_DIR:-$SCRIPT_DIR/${EVAL_DIR%%/*}}"
    local uploaded=0
    local skipped=0

    if [[ "$all_models_absolute" == "true" ]]; then
        log_debug "所有模型均为远程绝对路径，跳过本地模型相关处理"
    else
        # 先批量校验所有绝对路径模型的本地 MD5（如有本地同名文件）
        for i in 0 1 2 3; do
            local remote_model_var="REMOTE_MODEL_FILE$i"
            local remote_model_path="${!remote_model_var}"
            if [[ -n "$remote_model_path" && "$remote_model_path" == /* ]]; then
                local model_name
                model_name=$(basename "$remote_model_path")
                local local_model_file="$model_dir/$model_name"
                if [[ -f "$local_model_file" ]]; then
                    log_info "  验证远程模型与本地一致性: $model_name"
                    local local_md5
                    local_md5=$(get_local_md5 "$local_model_file")
                    local remote_md5
                    remote_md5=$(get_remote_md5 "$remote_model_path")
                    log_debug "本地 MD5: $local_md5"
                    log_debug "远程 MD5: $remote_md5"
                    if [[ -z "$remote_md5" ]]; then
                        log_error "  远程模型不存在: $remote_model_path"
                        exit 1
                    elif [[ "$local_md5" != "$remote_md5" ]]; then
                        log_error "  远程模型与本地不一致!"
                        log_error "    本地: $local_md5"
                        log_error "    远程: $remote_md5"
                        log_error "  请检查是否使用了正确的模型版本"
                        exit 1
                    fi
                    log_info "  远程模型 MD5 验证通过: ${local_md5:0:16}..."
                else
                    log_debug "跳过远程模型验证（绝对路径，本地无同名文件）: $remote_model_path"
                fi
            fi
        done

        # 上传模型文件（只处理相对路径模型）
        for i in 0 1 2 3; do
            local remote_model_var="REMOTE_MODEL_FILE$i"
            local remote_model_path="${!remote_model_var}"
            if [[ -z "$remote_model_path" || "$remote_model_path" == /* ]]; then
                continue
            fi
            # 提取文件名和远程完整路径
            local model_name
            model_name=$(basename "$remote_model_path")
            local local_model_file="$model_dir/$model_name"
            local full_remote_path="$REMOTE_WORK_DIR/$remote_model_path"
            local remote_model_dir
            remote_model_dir=$(dirname "$full_remote_path")

            # 确保远程目录存在
            run_ssh "mkdir -p $remote_model_dir"

            # 检查远程模型是否存在
            if run_ssh "test -f $full_remote_path" 2>/dev/null; then
                log_debug "检测到远程模型已存在: $full_remote_path"
                # 比较 MD5
                local local_md5
                local_md5=$(get_local_md5 "$local_model_file")
                local remote_md5
                remote_md5=$(get_remote_md5 "$full_remote_path")

                log_debug "本地 MD5: $local_md5"
                log_debug "远程 MD5: $remote_md5"

                if [[ "$local_md5" == "$remote_md5" ]]; then
                    log_info "  跳过模型 (MD5 一致): $model_name"
                    ((skipped++)) || true
                    continue
                fi

                # MD5 不一致，备份远程模型
                local backup_model="$full_remote_path.${timestamp}"
                log_warn "  模型 MD5 不一致，备份远程模型为: $(basename "$backup_model")"
                run_ssh "mv $full_remote_path $backup_model"
                # 记录备份信息（用于成功后恢复）
                backup_models+=("$backup_model|$full_remote_path")
            else
                log_debug "远程模型不存在，需要上传: $full_remote_path"
            fi

            # 上传模型
            log_info "  上传模型: $model_name -> $full_remote_path"
            run_scp_upload "$local_model_file" "$full_remote_path"
            
            # 记录本次上传的模型（用于完成后清理）
            uploaded_models+=("$full_remote_path")

            # 上传后验证 MD5（DRY_RUN 模式跳过验证）
            if [[ $DRY_RUN -lt 0 ]]; then
                local verify_local_md5
                verify_local_md5=$(get_local_md5 "$local_model_file")
                local verify_remote_md5
                verify_remote_md5=$(get_remote_md5 "$full_remote_path")

                if [[ "$verify_local_md5" != "$verify_remote_md5" ]]; then
                    log_error "  模型上传后 MD5 验证失败!"
                    log_error "    本地: $verify_local_md5"
                    log_error "    远程: $verify_remote_md5"
                    exit 1
                fi
                log_info "  模型 MD5 验证通过: ${verify_local_md5:0:16}..."
            fi

            ((uploaded++)) || true
        done

        if [[ $uploaded -gt 0 || $skipped -gt 0 ]]; then
            log_info "模型处理完成: 上传 $uploaded 个, 跳过 $skipped 个"
        fi
    fi

    # 保存备份信息到状态文件（此时状态文件已在 main 中创建）
    if [[ -n "$backup_input_dir" || -n "$backup_output_dir" || ${#backup_models[@]} -gt 0 ]]; then
        save_backup_info
    fi
}

# 获取第一个后缀（用于查询文件）
get_primary_suffix() {
    echo "${INPUT_SUFFIX_LIST%%,*}"
}

# 获取后缀数量
get_suffix_count() {

    if [[ -z "$INPUT_SUFFIX_LIST" ]]; then
        echo "1"
        return
    fi
    local count
    count=$(echo "$INPUT_SUFFIX_LIST" | tr ',' '\n' | wc -l | tr -d ' ')
    echo "$count"
}

# 获取数据集文件列表（只查询第一个后缀的文件，不递归子目录）
get_input_files() {

    local input_dir="$SCRIPT_DIR/$EVAL_DIR/$IN_SUBDIR"
    local primary_suffix
    primary_suffix=$(get_primary_suffix)
    
    if [[ -n "$primary_suffix" ]]; then
        # 只查询第一个后缀的文件
        for f in "$input_dir"/*"${primary_suffix}"; do
            [[ -f "$f" ]] && echo "$f"
        done | sort
        # 备选：文件数量极多时使用 find（流式处理，避免参数列表过长）
        # find "$input_dir" -maxdepth 1 -type f -name "*${primary_suffix}" 2>/dev/null | sort
    else
        # 没有指定后缀，查询全部文件
        for f in "$input_dir"/*; do
            [[ -f "$f" ]] && echo "$f"
        done | sort
        # 备选：文件数量极多时使用 find
        # find "$input_dir" -maxdepth 1 -type f 2>/dev/null | sort
    fi
}

# 从文件路径获取前缀（去除第一个后缀）
get_file_prefix() {
    local filepath="$1"

    local filename
    filename=$(basename "$filepath")
    local primary_suffix
    primary_suffix=$(get_primary_suffix)
    
    if [[ -n "$primary_suffix" && "$filename" == *"$primary_suffix" ]]; then
        echo "${filename%$primary_suffix}"
    else
        echo "${filename%.*}"
    fi
}

# 根据前缀展开为完整的文件列表
expand_prefix_to_files() {
    local prefix="$1"

    local input_dir="$SCRIPT_DIR/$EVAL_DIR/$IN_SUBDIR"
    local -a expanded_files=()
    
    if [[ -z "$INPUT_SUFFIX_LIST" ]]; then
        # 没有后缀列表，返回匹配前缀的所有文件
        while IFS= read -r -d '' file; do
            expanded_files+=("$file")
        done < <(find "$input_dir" -type f -name "${prefix}*" -print0 2>/dev/null)
    else
        # 根据后缀列表展开
        local -a suffixes
        IFS=',' read -ra suffixes <<< "$INPUT_SUFFIX_LIST"
        
        for suffix in "${suffixes[@]}"; do
            local file="$input_dir/${prefix}${suffix}"
            if [[ -f "$file" ]]; then
                expanded_files+=("$file")
            else
                log_warn "文件不存在: ${prefix}${suffix}"
            fi
        done
    fi
    
    # 输出用 | 分隔的文件列表
    local IFS='|'
    echo "${expanded_files[*]}"
}

# 获取状态文件名（不含路径）
get_eval_state_name() {

    local states_name="$EVAL_STATE_NAME"
    
    # 确保以 . 开头（隐藏文件）
    [[ "$states_name" != .* ]] && states_name=".$states_name"
    
    # 自动补全 .state 后缀
    [[ "$states_name" != *.state ]] && states_name="${states_name}.state"
    
    echo "$states_name"
}

# 更新状态文件头部的运行信息（轻量级，快速访问）
update_running_info() {
    local current_batch="$1"
    local total_batches="$2"
    local batch_completed="$3"
    local batch_total="$4"
    local failed_count="$5"
    local retry_count="${6:-0}"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return
    fi
    
    # 在文件开头插入新的运行信息（在第一行注释后）
    # 策略：完全原子操作 - 先构建完整新内容到临时文件（删除旧 RUNNING_ 并插入新的），再原子替换
    local temp_file="${EVAL_STATE_FILE}.tmp"
    local batch_state="${7:-0}"  # 默认为 0（上传中）
    {
        head -1 "$EVAL_STATE_FILE"  # 输出第1行（文件头注释: "# 评测任务状态文件"）
        echo "RUNNING_TOTAL_BATCHES=$total_batches"
        echo "RUNNING_FAILED_BATCHES=$failed_count"
        echo "RUNNING_CURRENT_BATCH=$current_batch"
        echo "RUNNING_BATCH_TOTAL=$batch_total"
        echo "RUNNING_BATCH_COMPLETED=$batch_completed"
        echo "RUNNING_BATCH_STATE=$batch_state"
        echo "RUNNING_RETRY_COUNT=$retry_count"
        echo "RUNNING_TIMESTAMP=$(date '+%s')"
        # 跳过第1行注释 + RUNNING_FIELD_COUNT 行 RUNNING_ 字段，输出剩余内容
        # 使用固定行数跳过，避免 grep 过滤开销（性能优化）
        tail -n +$((2 + RUNNING_FIELD_COUNT)) "$EVAL_STATE_FILE"
    } > "$temp_file"
    
    # 原子替换：mv 在同一文件系统内是原子操作（单个系统调用修改 inode 指针）
    # 其他进程要么看到旧文件，要么看到新文件，不会读到不完整的中间状态
    # 其他具有原子性的文件操作：mkdir/ln/rename 系统调用、symlink（符号链接创建）
    mv -f "$temp_file" "$EVAL_STATE_FILE" 2>/dev/null || true
}

# 清除运行信息
clear_running_info() {
    if [[ -f "$EVAL_STATE_FILE" ]]; then
        sed_inplace '/^RUNNING_/d' "$EVAL_STATE_FILE"
    fi
}

# 生成任务状态文件
generate_eval_state_file() {

    # 构建状态文件路径
    EVAL_STATE_FILE="$SCRIPT_DIR/$EVAL_DIR/$(get_eval_state_name)"
    
    # 自动检测：如果任务文件存在，检查配置是否一致
    if [[ -f "$EVAL_STATE_FILE" ]]; then
        # 检查 MAX_BATCH_SIZE 是否变化
        local saved_batch_size
        saved_batch_size=$(grep "^MAX_BATCH_SIZE=" "$EVAL_STATE_FILE" 2>/dev/null | cut -d'=' -f2)
        
        if [[ -n "$saved_batch_size" && "$saved_batch_size" != "$MAX_BATCH_SIZE" ]]; then
            log_warn "[$EVAL_DIR] 检测到 MAX_BATCH_SIZE 已变化: $saved_batch_size -> $MAX_BATCH_SIZE"
            log_warn "[$EVAL_DIR] 批次划分将改变，无法继续使用旧状态文件"
            log_warn "[$EVAL_DIR] 正在清理并重新初始化..."
            
            # 重置远程目录（清空内容，保留目录）
            final_cleanup "reset"
            
            # 删除旧状态文件
            rm -f "$EVAL_STATE_FILE"
            
            log_info "[$EVAL_DIR] 已清理旧状态，将重新生成任务"
        else
            # 配置未变化，检查状态文件格式
            log_info "发现已有任务文件: $EVAL_STATE_FILE"
            
            # 检查是否包含必需的 RUNNING_ 字段（先检查格式，再处理内容）
            if ! grep -q "^RUNNING_TOTAL_BATCHES=" "$EVAL_STATE_FILE"; then
                log_info "[$EVAL_DIR] 检测到旧版本状态文件，正在自动升级..."
                
                # 重置远程目录
                final_cleanup "reset"
                
                # 删除旧状态文件
                rm -f "$EVAL_STATE_FILE"
                
                log_info "[$EVAL_DIR] 状态文件已升级，重新生成任务配置"
                # 删除后不再返回，继续往下执行生成新文件
            else
                # 格式正确，处理失败批次重置
                log_info "如需重新开始，请先删除该文件"
                
                # 重置所有失败批次的状态为 pending，并清零重试次数
                local reset_count=0
                local temp_file="${EVAL_STATE_FILE}.tmp"
                while IFS= read -r line; do
                    if [[ "$line" =~ ^BATCH_[0-9]+_STATUS=failed$ ]]; then
                        echo "${line%=*}=pending"
                        ((reset_count++)) || true
                    elif [[ "$line" =~ ^BATCH_[0-9]+_RETRY_COUNT= ]]; then
                        echo "${line%=*}=0"
                    else
                        echo "$line"
                    fi
                done < "$EVAL_STATE_FILE" > "$temp_file"
                
                if [[ $reset_count -gt 0 ]]; then
                    mv -f "$temp_file" "$EVAL_STATE_FILE"
                    log_info "已重置 $reset_count 个失败批次，可重新执行"
                else
                    rm -f "$temp_file"
                fi
                
                return 0  # 格式正确且已处理，直接返回
            fi
        fi
    fi
    
    # 只有在状态文件不存在或被删除后，才会执行到这里生成新文件
    log_info "生成任务状态文件: $EVAL_STATE_FILE"
    
    # 提取所有输入数据文件的前缀（分组）
    local -a all_prefixes=()
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local prefix
            prefix=$(get_file_prefix "$file")
            all_prefixes+=("$prefix")
        fi
    done < <(get_input_files)
    
    if [[ ${#all_prefixes[@]} -eq 0 ]]; then
        log_warn "未找到任何匹配的文件"
        return 1
    fi
    
    local suffix_count
    suffix_count=$(get_suffix_count)
    local total_files=$((${#all_prefixes[@]} * suffix_count))
    
    log_info "找到 ${#all_prefixes[@]} 项数据（每项数据 $suffix_count 个文件，共 $total_files 个文件）"
    
    # 将前缀打包成批次
    local -a batches=()
    local current_batch=""
    local current_batch_count=0
    
    for prefix in "${all_prefixes[@]}"; do
        # 如果当前批次已满，保存并开始新批次
        if [[ $current_batch_count -ge $MAX_BATCH_SIZE ]]; then
            batches+=("$current_batch")
            current_batch=""
            current_batch_count=0
        fi
        
        # 添加前缀到当前批次
        if [[ -z "$current_batch" ]]; then
            current_batch="$prefix"
        else
            current_batch="$current_batch|$prefix"
        fi
        ((current_batch_count++)) || true
    done
    
    # 保存最后一个批次
    if [[ -n "$current_batch" ]]; then
        batches+=("$current_batch")
    fi
    
    # 获取模型 MD5
    local model_md5_list=""
    local model_dir="${MODEL_DIR:-$SCRIPT_DIR/${EVAL_DIR%%/*}}"
    for i in 0 1 2 3; do
        local remote_model_var="REMOTE_MODEL_FILE$i"
        local remote_model_path="${!remote_model_var}"
        if [[ -n "$remote_model_path" ]]; then
            local model_name
            model_name=$(basename "$remote_model_path")
            local local_model_file="$model_dir/$model_name"
            if [[ -f "$local_model_file" ]]; then
                local md5
                md5=$(get_local_md5 "$local_model_file")
                if [[ -n "$model_md5_list" ]]; then
                    model_md5_list="$model_md5_list,$model_name:$md5"
                else
                    model_md5_list="$model_name:$md5"
                fi
            fi
        fi
    done
    
    # 写入任务文件（包含 RUNNING_ 字段占位符，确保结构统一）
    {
        echo "# 评测任务状态文件"
        # 初始化 RUNNING_ 字段（占位符，运行时由 update_running_info 更新）
        echo "RUNNING_TOTAL_BATCHES=${#batches[@]}"
        echo "RUNNING_FAILED_BATCHES=0"
        echo "RUNNING_CURRENT_BATCH=1"
        echo "RUNNING_BATCH_TOTAL=0"
        echo "RUNNING_BATCH_COMPLETED=0"
        echo "RUNNING_BATCH_STATE=0"
        echo "RUNNING_RETRY_COUNT=0"
        echo "RUNNING_TIMESTAMP=$(date '+%s')"
        # 固定配置
        echo "MAX_BATCH_SIZE=$MAX_BATCH_SIZE"
        echo "TOTAL_DATA=${#all_prefixes[@]}"
        echo "TOTAL_FILES=$total_files"
        echo "SUFFIX_LIST=\"$INPUT_SUFFIX_LIST\""
        echo "POST_PLUGIN=\"$POST_PROCESS_PLUGIN\""
        echo "MODEL_MD5=\"$model_md5_list\""
        echo ""
        
        for ((i=0; i<${#batches[@]}; i++)); do
            echo "BATCH_${i}_STATUS=pending"
            echo "BATCH_${i}_PREFIXES=\"${batches[$i]}\""
            echo ""
        done
        
        # 详细说明注释（放在文件末尾，不影响性能）
        echo "# ========== 任务生成信息 =========="
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 评测目录: $EVAL_DIR"
        echo "# 批次大小: $MAX_BATCH_SIZE"
        echo "# 总批次数: ${#batches[@]}"
        echo "# 总数据数: ${#all_prefixes[@]}"
        echo "# 总文件数: $total_files"
        echo "# 后缀列表: ${INPUT_SUFFIX_LIST:-无}"
        echo "# 后处理插件: $POST_PROCESS_PLUGIN"
        echo "# 模型MD5: $model_md5_list"
    } > "$EVAL_STATE_FILE"
    
    log_info "任务文件生成完成: ${#batches[@]} 个批次，${#all_prefixes[@]} 项数据"
}

# 更新批次状态
update_batch_status() {

    local batch_id="$1"
    local status="$2"  # pending, running, completed, failed
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 1
    fi
    
    sed_inplace "s/^BATCH_${batch_id}_STATUS=.*/BATCH_${batch_id}_STATUS=$status/" "$EVAL_STATE_FILE"
    log_debug "更新批次 $((batch_id+1)) 状态: $status"
}

# 获取批次状态
get_batch_status() {

    local batch_id="$1"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        echo "unknown"
        return 1
    fi
    
    grep "^BATCH_${batch_id}_STATUS=" "$EVAL_STATE_FILE" | cut -d'=' -f2
}

# 获取批次前缀列表
get_batch_prefixes() {

    local batch_id="$1"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 1
    fi
    
    local prefixes_line
    prefixes_line=$(grep "^BATCH_${batch_id}_PREFIXES=" "$EVAL_STATE_FILE")
    # 去除前缀和引号
    prefixes_line=${prefixes_line#BATCH_${batch_id}_PREFIXES=}
    prefixes_line=${prefixes_line#\"}
    prefixes_line=${prefixes_line%\"}
    echo "$prefixes_line"
}

# 获取总批次数
get_total_batches() {

    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        echo "0"
        return 1
    fi
    
    grep "^RUNNING_TOTAL_BATCHES=" "$EVAL_STATE_FILE" | cut -d'=' -f2
}

# 更新批次上传进度（记录最后成功上传的前缀）
# 同时更新运行统计信息（利用这个更新点统一维护）
update_batch_last_prefix() {

    local batch_id="$1"
    local last_prefix="$2"
    local batch_num="$3"          # 当前批次号（1-based）
    local total_batches="$4"       # 总批次数
    local uploaded_count="$5"      # 当前批次内已上传的评测项数
    local batch_total="$6"         # 当前批次总评测项数
    local failed_count="$7"        # 失败批次数
    local retry_count="${8:-0}"    # 重试次数
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 1
    fi
    
    # 检查是否已有该字段
    if grep -q "^BATCH_${batch_id}_LAST_PREFIX=" "$EVAL_STATE_FILE"; then
        sed_inplace "s/^BATCH_${batch_id}_LAST_PREFIX=.*/BATCH_${batch_id}_LAST_PREFIX=\"$last_prefix\"/" "$EVAL_STATE_FILE"
    else
        # 在 BATCH_X_PREFIXES 后面添加
        sed_inplace "/^BATCH_${batch_id}_PREFIXES=/a\\
BATCH_${batch_id}_LAST_PREFIX=\"$last_prefix\"
" "$EVAL_STATE_FILE"
    fi
    
    # 同时更新运行信息
    if [[ -n "$batch_num" && -n "$total_batches" ]]; then
        # 上传过程中的状态更新，batch_state 保持为 0（表示上传阶段）
        update_running_info "$batch_num" "$total_batches" "$uploaded_count" "$batch_total" "$failed_count" "$retry_count" "0"
    fi
}

# 获取批次上传进度
get_batch_last_prefix() {

    local batch_id="$1"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        echo ""
        return 1
    fi
    
    local line
    line=$(grep "^BATCH_${batch_id}_LAST_PREFIX=" "$EVAL_STATE_FILE" 2>/dev/null || echo "")
    if [[ -n "$line" ]]; then
        line=${line#BATCH_${batch_id}_LAST_PREFIX=}
        line=${line#\"}
        line=${line%\"}
        echo "$line"
    else
        echo ""
    fi
}

# 清除批次上传进度
clear_batch_last_prefix() {

    local batch_id="$1"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 1
    fi
    
    sed_inplace "/^BATCH_${batch_id}_LAST_PREFIX=/d" "$EVAL_STATE_FILE"
}

# 保存备份信息到状态文件
save_backup_info() {
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 0  # 状态文件不存在时不保存（正常情况，首次运行时还未创建状态文件）
    fi
    
    # 先删除旧的备份信息（包括注释行）
    sed_inplace '/^backup_input_dir=/d; /^backup_output_dir=/d; /^backup_models=/d; /^# 远程备份信息/d' "$EVAL_STATE_FILE"
    
    # 追加新的备份信息
    {
        echo ""
        echo "# 远程备份信息（用于成功后恢复）"
        [[ -n "$backup_input_dir" ]] && echo "backup_input_dir=\"$backup_input_dir\""
        [[ -n "$backup_output_dir" ]] && echo "backup_output_dir=\"$backup_output_dir\""
        
        # 保存模型备份列表（用 | 分隔多个）
        if [[ ${#backup_models[@]} -gt 0 ]]; then
            local models_str
            models_str=$(IFS='|'; echo "${backup_models[*]}")
            echo "backup_models=\"$models_str\""
        fi
    } >> "$EVAL_STATE_FILE"
    
    log_debug "备份信息已保存到状态文件"
}

# 从状态文件加载备份信息
load_backup_info() {
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 1
    fi
    
    # 加载输入/输出目录备份
    local line
    line=$(grep '^backup_input_dir=' "$EVAL_STATE_FILE" 2>/dev/null || echo "")
    if [[ -n "$line" ]]; then
        backup_input_dir=$(echo "$line" | sed 's/^backup_input_dir="\(.*\)"$/\1/')
    fi
    
    line=$(grep '^backup_output_dir=' "$EVAL_STATE_FILE" 2>/dev/null || echo "")
    if [[ -n "$line" ]]; then
        backup_output_dir=$(echo "$line" | sed 's/^backup_output_dir="\(.*\)"$/\1/')
    fi
    
    # 加载模型备份列表
    line=$(grep '^backup_models=' "$EVAL_STATE_FILE" 2>/dev/null || echo "")
    if [[ -n "$line" ]]; then
        local models_str
        models_str=$(echo "$line" | sed 's/^backup_models="\(.*\)"$/\1/')
        IFS='|' read -ra backup_models <<< "$models_str"
    fi
    
    log_debug "已加载备份信息: INPUT=$backup_input_dir, OUTPUT=$backup_output_dir, MODELS=${#backup_models[@]}个"
}

# 获取批次重试次数
get_batch_retry_count() {
    local batch_id="$1"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        echo "0"
        return
    fi
    
    local line
    line=$(grep "^BATCH_${batch_id}_RETRY_COUNT=" "$EVAL_STATE_FILE" 2>/dev/null || echo "")
    if [[ -n "$line" ]]; then
        echo "${line#BATCH_${batch_id}_RETRY_COUNT=}"
    else
        echo "0"
    fi
}

# 设置批次重试次数
set_batch_retry_count() {
    local batch_id="$1"
    local count="$2"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 1
    fi
    
    if grep -q "^BATCH_${batch_id}_RETRY_COUNT=" "$EVAL_STATE_FILE"; then
        sed_inplace "s/^BATCH_${batch_id}_RETRY_COUNT=.*/BATCH_${batch_id}_RETRY_COUNT=$count/" "$EVAL_STATE_FILE"
    else
        # 在批次状态行后添加重试计数
        sed_inplace "/^BATCH_${batch_id}_STATUS=/a\\
BATCH_${batch_id}_RETRY_COUNT=$count" "$EVAL_STATE_FILE"
    fi
}

# 增加批次重试次数
increment_batch_retry_count() {
    local batch_id="$1"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 1
    fi
    
    local current_count
    current_count=$(get_batch_retry_count "$batch_id")
    local new_count=$((current_count + 1))
    
    if grep -q "^BATCH_${batch_id}_RETRY_COUNT=" "$EVAL_STATE_FILE"; then
        sed_inplace "s/^BATCH_${batch_id}_RETRY_COUNT=.*/BATCH_${batch_id}_RETRY_COUNT=$new_count/" "$EVAL_STATE_FILE"
    else
        # 在批次状态行后添加重试计数
        sed_inplace "/^BATCH_${batch_id}_STATUS=/a\\
BATCH_${batch_id}_RETRY_COUNT=$new_count" "$EVAL_STATE_FILE"
    fi
    
    echo "$new_count"
}

# 清除批次重试次数
clear_batch_retry_count() {
    local batch_id="$1"
    
    if [[ ! -f "$EVAL_STATE_FILE" ]]; then
        return 1
    fi
    
    sed_inplace "/^BATCH_${batch_id}_RETRY_COUNT=/d" "$EVAL_STATE_FILE"
}

# 验证批次所有文件的远程 MD5
verify_batch_remote_md5() {
    local batch_prefixes_str="$1"

    local input_dir="$SCRIPT_DIR/$EVAL_DIR/$IN_SUBDIR"
    local remote_input="$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
    
    local -a batch_prefixes
    IFS='|' read -ra batch_prefixes <<< "$batch_prefixes_str"
    
    for prefix in "${batch_prefixes[@]}"; do
        if ! verify_remote_files_md5 "$prefix"; then
            return 1
        fi
    done
    
    return 0
}

# 分批处理文件
process_batches() {

    local full_eval_dir="$SCRIPT_DIR/$EVAL_DIR"
    
    # 判断 OUT_SUBDIR 是否是绝对路径
    local output_dir
    if [[ "$OUT_SUBDIR" == /* ]]; then
        # 绝对路径：直接使用
        output_dir="$OUT_SUBDIR"
    else
        # 相对路径：相对于数据集目录
        output_dir="$full_eval_dir/$OUT_SUBDIR"
    fi
    
    # 确保本地输出目录存在
    mkdir -p "$output_dir"
    
    # 获取批次信息（状态文件已在 main 中创建）
    local total_batches
    total_batches=$(get_total_batches)
    
    if [[ $total_batches -eq 0 ]]; then
        log_warn "没有待处理的批次"
        return 0
    fi
    
    local completed=0
    local failed=0
    local skipped=0
    
    # 统计运行时失败批次数（在执行过程中动态更新）
    local failed_batches=0
    
    for ((batch_id=0; batch_id<total_batches; batch_id++)); do
        local batch_num=$((batch_id + 1))
        local status
        status=$(get_batch_status "$batch_id")
        
        # 检查批次状态
        if [[ "$status" == "completed" ]]; then
            log_info "[$EVAL_DIR] 批次 $batch_num/$total_batches 已完成，跳过"
            ((skipped++)) || true
            ((completed++)) || true
            continue
        fi
        
        # 检查是否已超过最大重试次数
        local retry_count
        retry_count=$(get_batch_retry_count "$batch_id")
        if [[ "$status" == "failed" && $retry_count -ge 3 ]]; then
            log_error "[$EVAL_DIR] 批次 $batch_num/$total_batches 已重试 $retry_count 次，跳过"
            ((failed++)) || true
            continue
        fi
        
        # 获取本批次前缀列表
        local batch_prefixes_str
        batch_prefixes_str=$(get_batch_prefixes "$batch_id")
        
        local -a batch_prefixes
        IFS='|' read -ra batch_prefixes <<< "$batch_prefixes_str"
        local batch_data_count=${#batch_prefixes[@]}
        local suffix_count
        suffix_count=$(get_suffix_count)
        local file_count=$((batch_data_count * suffix_count))
        
        log_info "[$EVAL_DIR] ========== 处理第 $batch_num/$total_batches 批 ($batch_data_count 项数据, $file_count 个文件) =========="
        
        # 更新运行信息：批次开始（写入状态文件头部）
        update_running_info "$batch_num" "$total_batches" "0" "$batch_data_count" "$failed_batches" "$retry_count" "0"
        
        # 重试循环（最多3次）
        local max_retries=3
        local batch_success=false
        
        while [[ $retry_count -lt $max_retries ]]; do
            # 检查是否为续传/重试模式
            local is_resume=false
            local skip_upload=false
            local last_prefix=""
            local skip_until_after=""
            
            if [[ "$status" == "failed" ]]; then
                # 失败重试：增加重试计数并检查 MD5
                ((retry_count++)) || true
                set_batch_retry_count "$batch_id" "$retry_count"
                log_info "[$EVAL_DIR] 批次 $batch_num 第 $retry_count 次重试"
                
                # 检查远程数据 MD5 是否一致
                log_info "[$EVAL_DIR] 验证远程数据完整性..."
                if verify_batch_remote_md5 "$batch_prefixes_str"; then
                    log_info "[$EVAL_DIR] 远程数据 MD5 验证通过，跳过上传直接重试评测"
                    skip_upload=true
                    is_resume=true
                else
                    log_warn "[$EVAL_DIR] 远程数据 MD5 不一致，需要重新上传"
                fi
            elif [[ "$status" == "running" ]]; then
                last_prefix=$(get_batch_last_prefix "$batch_id")

                if [[ -n "$last_prefix" ]]; then
                    log_info "[$EVAL_DIR] 检测到上次中断，最后上传的前缀: $last_prefix"
                    
                    # 压缩模式下，先尝试解压远程可能存在的 .gz 文件
                    if [[ "$ENABLE_COMPRESSION" == "true" ]]; then
                        log_debug "尝试解压远程残留的 .gz 文件..."
                        remote_batch_decompress "$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
                    fi
                    
                    # 验证最后上传的文件是否完整
                    if verify_remote_files_md5 "$last_prefix"; then
                        log_info "[$EVAL_DIR] MD5 验证通过，从下一个前缀继续上传"
                        skip_until_after="$last_prefix"
                        is_resume=true
                    else
                        log_warn "[$EVAL_DIR] MD5 验证失败，将重新上传该前缀"
                        # 找到 last_prefix 的前一个作为跳过点
                        local prev_prefix=""
                        for p in "${batch_prefixes[@]}"; do
                            if [[ "$p" == "$last_prefix" ]]; then
                                break
                            fi
                            prev_prefix="$p"
                        done
                        if [[ -n "$prev_prefix" ]]; then
                            skip_until_after="$prev_prefix"
                            is_resume=true
                        fi
                    fi
                fi
            fi
        
        # 标记为运行中
        update_batch_status "$batch_id" "running"
        
        # 跳过上传（failed 重试且 MD5 验证通过）
        if [[ "$skip_upload" != "true" ]]; then
            # 上传本批文件（展开前缀为完整文件列表）
            if [[ "$ENABLE_COMPRESSION" == "true" ]]; then
                log_info "上传文件到远程服务器（压缩传输）..."
            else
                log_info "上传文件到远程服务器..."
            fi
            local should_skip=true
            [[ -z "$skip_until_after" ]] && should_skip=false
            
            # 收集待上传的文件（用于压缩批量上传）
            local -a batch_files_to_upload=()
        
        for prefix in "${batch_prefixes[@]}"; do
            # 续传模式：跳过已上传的前缀
            if [[ "$should_skip" == "true" ]]; then
                if [[ "$prefix" == "$skip_until_after" ]]; then
                    should_skip=false
                    log_debug "跳过已上传: $prefix"
                else
                    log_debug "跳过已上传: $prefix"
                fi
                continue
            fi
            
            local expanded_files
            expanded_files=$(expand_prefix_to_files "$prefix")
            
            local -a files_to_upload
            IFS='|' read -ra files_to_upload <<< "$expanded_files"
            
            if [[ "$ENABLE_COMPRESSION" == "true" ]]; then
                # 压缩模式：收集文件，每个前缀批量上传
                for file in "${files_to_upload[@]}"; do
                    if [[ -f "$file" ]]; then
                        batch_files_to_upload+=("$file")
                    fi
                done
                
                # 每收集一个前缀的文件就上传（保持续传粒度）
                if [[ ${#batch_files_to_upload[@]} -gt 0 ]]; then
                    batch_compress_upload "$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR/" "${batch_files_to_upload[@]}"
                    batch_files_to_upload=()
                fi
            else
                # 非压缩模式：逐个上传
                for file in "${files_to_upload[@]}"; do
                    if [[ -f "$file" ]]; then
                        local filename
                        filename=$(basename "$file")
                        log_debug "上传: $filename"
                        run_scp_upload "$file" "$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR/"
                    fi
                done
            fi
            
            # 计算已上传数量
            local uploaded_count=0
            for p in "${batch_prefixes[@]}"; do
                [[ "$p" == "$prefix" ]] && break
                ((uploaded_count++)) || true
            done
            ((uploaded_count++)) || true  # 加上当前前缀
            
            # 记录上传进度并同步更新运行信息
            update_batch_last_prefix "$batch_id" "$prefix" "$batch_num" "$total_batches" "$uploaded_count" "$batch_data_count" "$failed_batches" "$retry_count"
        done
        
            # 压缩模式：远程解压
            if [[ "$ENABLE_COMPRESSION" == "true" ]]; then
                log_info "远程解压文件..."
                remote_batch_decompress "$REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
            fi
        fi  # end of skip_upload check
        
        # 执行远程评测
        log_info "[$EVAL_DIR] 执行远程评测命令..."
        # 更新状态：开始远程执行
        update_running_info "$batch_num" "$total_batches" "$batch_data_count" "$batch_data_count" "$failed_batches" "$retry_count" "-2"
        
        local eval_cmd
        eval_cmd=$(build_remote_eval_cmd)
        log_debug "评测命令: $eval_cmd"
        
        # DRY_RUN 模式下模拟随机失败（用于测试失败重试机制）
        local eval_result=0
        if [[ $DRY_RUN -ge 0 ]]; then
            run_ssh "cd $REMOTE_WORK_DIR && $eval_cmd"
            # 模拟失败：DRY_RUN_FAIL_RATE 设置失败概率（0-100）
            # 或 DRY_RUN_FAIL_BATCH 设置特定失败的批次号
            local fail_rate="${DRY_RUN_FAIL_RATE:-0}"
            local fail_batch="${DRY_RUN_FAIL_BATCH:-}"
            if [[ -n "$fail_batch" && "$batch_num" == "$fail_batch" ]]; then
                log_warn "[DRY-RUN] 模拟批次 $batch_num 评测失败（指定批次）"
                eval_result=1
            elif [[ $fail_rate -gt 0 ]]; then
                local rand=$((RANDOM % 100))
                if [[ $rand -lt $fail_rate ]]; then
                    log_warn "[DRY-RUN] 模拟评测失败（随机失败率: ${fail_rate}%）"
                    eval_result=1
                fi
            fi
        else
            # 禁用 set -e 以捕获命令失败，允许重试逻辑执行
            set +e
            run_ssh "cd $REMOTE_WORK_DIR && $eval_cmd"
            eval_result=$?
            set -e
            log_debug "评测命令退出码: $eval_result"
        fi
        
        if [[ $eval_result -eq 0 ]]; then
            log_info "[$EVAL_DIR] 评测完成，下载结果..."
            # 更新状态：开始下载
            update_running_info "$batch_num" "$total_batches" "$batch_data_count" "$batch_data_count" "$failed_batches" "$retry_count" "-1"
            
            # 下载结果（按前缀组织输出目录）
            log_info "[$EVAL_DIR] 下载评测结果..."
            local downloaded_count=0
            
            # 优先使用压缩下载（如果启用了压缩模式）
            if [[ "$ENABLE_COMPRESSION" == "true" ]]; then
                log_info "使用压缩方式批量下载结果..."
                
                # 整个批次一次性打包下载：远程打包整个输出目录 -> 下载 -> 本地解压
                local batch_archive="batch_${batch_id}_output.tar.gz"
                local remote_archive="$REMOTE_WORK_DIR/$batch_archive"
                local local_archive="/tmp/$batch_archive"
                
                # 远程打包整个批次的输出
                log_info "[$EVAL_DIR] 远程打包批次输出..."
                run_ssh "cd $REMOTE_WORK_DIR && tar czf $batch_archive -C $REMOTE_OUTPUT_DIR . 2>/dev/null" || {
                    log_warn "远程打包失败，尝试逐项下载..."
                    # 降级到逐项下载
                    for prefix in "${batch_prefixes[@]}"; do
                        local local_output_subdir="$output_dir/$prefix"
                        mkdir -p "$local_output_subdir"
                        local remote_output="$REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR/$prefix"
                        run_scp_download "$remote_output/*" "$local_output_subdir/" 2>/dev/null || true
                        ((downloaded_count++)) || true
                    done
                }
                
                # 如果打包成功，下载并解压
                if run_ssh "test -f $remote_archive" 2>/dev/null; then
                    log_info "[$EVAL_DIR] 下载批次压缩包..."
                    run_scp_download "$remote_archive" "$local_archive" 2>/dev/null && {
                        log_info "[$EVAL_DIR] 解压批次输出..."
                        tar xzf "$local_archive" -C "$output_dir" 2>/dev/null || log_warn "解压失败"
                        rm -f "$local_archive"
                    }
                    
                    # 清理远程压缩包
                    run_ssh "rm -f $remote_archive" 2>/dev/null || true
                    downloaded_count=${#batch_prefixes[@]}
                    # 更新下载进度
                    update_running_info "$batch_num" "$total_batches" "$batch_data_count" "$batch_data_count" "$failed_batches" "$retry_count" "$downloaded_count"
                fi
            else
                # 普通下载方式：逐项下载
                for prefix in "${batch_prefixes[@]}"; do
                    local local_output_subdir="$output_dir/$prefix"
                    mkdir -p "$local_output_subdir"
                    
                    # 尝试下载对应的输出文件
                    local remote_output="$REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR/$prefix"
                    if run_ssh "test -d $remote_output" 2>/dev/null; then
                        run_scp_download "$remote_output/*" "$local_output_subdir/" 2>/dev/null || true
                    else
                        # 尝试直接下载以前缀开头的输出
                        run_scp_download "$REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR/${prefix}*" "$local_output_subdir/" 2>/dev/null || true
                    fi
                    
                    ((downloaded_count++)) || true
                    # 更新下载进度
                    update_running_info "$batch_num" "$total_batches" "$batch_data_count" "$batch_data_count" "$failed_batches" "$retry_count" "$downloaded_count"
                done
            fi
            
            # 标记为完成，清除重试计数和上传进度
            update_batch_status "$batch_id" "completed"
            clear_batch_last_prefix "$batch_id"
            clear_batch_retry_count "$batch_id"
            batch_success=true
            ((completed++)) || true
            log_info "[$EVAL_DIR] 第 $batch_num 批处理完成"
            
            # 批次成功完成，清理远程输入输出目录中本批次的内容
            log_info "[$EVAL_DIR] 清理远程输入输出目录..."
            run_ssh "rm -rf $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR/* $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR/*" 2>/dev/null || true
            
            # 批次完成后，立即更新 RUNNING_CURRENT_BATCH 为下一个批次号
            local next_batch=$((batch_num + 1))
            if [[ $next_batch -le $total_batches ]]; then
                # 还有下一批，更新为下一批次号（批次内完成数重置为 0）
                update_running_info "$next_batch" "$total_batches" "0" "0" "$failed_batches" "0" "0"
            else
                # 所有批次完成，清除运行信息
                clear_running_info
            fi
            
            break  # 成功，退出重试循环
        else
            log_error "[$EVAL_DIR] 第 $batch_num 批评测失败 (重试 $retry_count/$max_retries)"
            log_error "  数据项: ${batch_prefixes[*]}"
            
            # 每次失败都增加失败计数（包括重试失败）
            ((failed_batches++)) || true
            
            update_batch_status "$batch_id" "failed"
            status="failed"  # 更新状态，下次循环会检查 MD5
            
            if [[ $retry_count -ge $max_retries ]]; then
                log_error "[$EVAL_DIR] 批次 $batch_num 已达到最大重试次数 ($max_retries)，跳过"
                ((failed++)) || true
                break  # 达到最大重试次数，退出重试循环
            fi
            
            log_warn "将立即重试..."
        fi
        done  # end of retry while loop
        
        log_info "[$EVAL_DIR] 进度: 完成 $completed / $total_batches 批次"
    done
    
    log_info "[$EVAL_DIR] ========== 处理完成 =========="
    log_info "[$EVAL_DIR] 总批次: $total_batches"
    log_info "[$EVAL_DIR] 成功: $completed 个"
    if [[ $skipped -gt 0 ]]; then
        log_info "[$EVAL_DIR] 跳过(已完成): $skipped 个"
    fi
    if [[ $failed -gt 0 ]]; then
        log_warn "[$EVAL_DIR] 失败: $failed 个"
        log_warn "[$EVAL_DIR] 可使用 -r 参数重试失败的批次"
    else
        # 全部成功，清除运行信息并重命名状态文件标记完成
        clear_running_info
        log_info "[$EVAL_DIR] 所有批次处理成功"
        local complete_file="${EVAL_STATE_FILE%.state}.complete.state"
        mv -f "$EVAL_STATE_FILE" "$complete_file" 2>/dev/null || true
    fi
}

# 最终清理
# 参数: $1 = "reset" 时重置模式，仅清空目录内容（保留目录本身）
final_cleanup() {
    local mode="${1:-}"
    
    # 清理本地压缩临时目录
    cleanup_compression_temp
    
    # 加载备份信息（如果还未加载）
    if [[ -z "$backup_input_dir" && -z "$backup_output_dir" ]]; then
        load_backup_info
    fi
    
    # 检查状态文件（包括完成状态的文件）
    local state_file="$EVAL_STATE_FILE"
    if [[ ! -f "$state_file" ]]; then
        # 尝试查找完成状态文件
        local complete_file="${EVAL_STATE_FILE%.state}.complete.state"
        if [[ -f "$complete_file" ]]; then
            state_file="$complete_file"
        else
            # 状态文件不存在，可能是初始化阶段失败（如模型上传失败）
            log_info "状态文件不存在，跳过远程清理"
            return 0
        fi
    fi
    
    # 重置模式：只清空目录内容（保留目录本身，因为 init_remote_workspace 已创建）
    if [[ "$mode" == "reset" ]]; then
        log_info "配置已变化，清空远程输入输出目录内容..."
        run_ssh "rm -rf $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR/* $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR/*" 2>/dev/null || true
        return 0
    fi
    
    # 检查是否有未完成的批次
    local has_unfinished=false
    if ! grep -q "^BATCH_0_STATUS=completed" "$state_file" 2>/dev/null || \
       grep -qE "_STATUS=(pending|running|failed)" "$state_file" 2>/dev/null; then
        has_unfinished=true
    fi
    
    # 如果有未完成的批次，保存失败环境并恢复原环境
    if [[ "$has_unfinished" == "true" ]]; then
        log_info "检测到有未完成的批次，保存失败环境并恢复原环境..."
        
        # 先删除状态文件中的旧失败环境记录（如果有）
        sed_inplace '/^failed_input_dir=/d; /^failed_output_dir=/d; /^failed_models=/d; /^failed_timestamp=/d' "$state_file"
        
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local status_suffix=".pending"
        
        # 判断状态后缀
        if grep -q "_STATUS=failed" "$state_file" 2>/dev/null; then
            status_suffix=".failed"
        fi
        
        # 保存输入目录
        if run_ssh "test -d $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR" 2>/dev/null; then
            local failed_input="$REMOTE_WORK_DIR/${REMOTE_INPUT_DIR}.${timestamp}${status_suffix}"
            log_info "保存失败环境的输入目录: $REMOTE_INPUT_DIR -> $(basename "$failed_input")"
            run_ssh "mv $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR $failed_input" 2>/dev/null || true
            
            # 记录到状态文件
            echo "failed_input_dir=$(basename "$failed_input")" >> "$state_file"
        fi
        
        # 保存输出目录
        if run_ssh "test -d $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR" 2>/dev/null; then
            local failed_output="$REMOTE_WORK_DIR/${REMOTE_OUTPUT_DIR}.${timestamp}${status_suffix}"
            log_info "保存失败环境的输出目录: $REMOTE_OUTPUT_DIR -> $(basename "$failed_output")"
            run_ssh "mv $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR $failed_output" 2>/dev/null || true
            
            # 记录到状态文件
            echo "failed_output_dir=$(basename "$failed_output")" >> "$state_file"
        fi
        
        # 保存上传的模型文件
        if [[ ${#uploaded_models[@]} -gt 0 ]]; then
            local failed_models_list=()
            for model_path in "${uploaded_models[@]}"; do
                if run_ssh "test -f $model_path" 2>/dev/null; then
                    local model_name=$(basename "$model_path")
                    local failed_model="${model_path}.${timestamp}${status_suffix}"
                    # 提取相对于REMOTE_WORK_DIR的路径
                    local relative_path="${model_path#$REMOTE_WORK_DIR/}"
                    local relative_failed="${relative_path}.${timestamp}${status_suffix}"
                    log_info "保存失败环境的模型文件: $relative_path -> $relative_failed"
                    run_ssh "mv $model_path $failed_model" 2>/dev/null || true
                    failed_models_list+=("$relative_failed")
                fi
            done
            
            # 记录到状态文件（用|分隔多个模型）
            if [[ ${#failed_models_list[@]} -gt 0 ]]; then
                local models_str=$(IFS='|'; echo "${failed_models_list[*]}")
                echo "failed_models=$models_str" >> "$state_file"
            fi
        fi
        
        # 记录时间戳
        echo "failed_timestamp=$timestamp" >> "$state_file"
        
        # 恢复原环境
        if [[ -n "$backup_input_dir" ]]; then
            log_info "恢复备份的输入目录: $backup_input_dir -> $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
            run_ssh "mv $backup_input_dir $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR" 2>/dev/null || true
        fi
        if [[ -n "$backup_output_dir" ]]; then
            log_info "恢复备份的输出目录: $backup_output_dir -> $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR"
            run_ssh "mv $backup_output_dir $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR" 2>/dev/null || true
        fi
        if [[ ${#backup_models[@]} -gt 0 ]]; then
            for backup_info in "${backup_models[@]}"; do
                local backup_path="${backup_info%%|*}"
                local original_path="${backup_info##*|}"
                log_info "恢复备份的模型: $(basename "$backup_path") -> $(basename "$original_path")"
                run_ssh "rm -f $original_path && mv $backup_path $original_path" 2>/dev/null || true
            done
        fi
        
        return 0
    fi
    
    # 正常完成清理：所有批次都是 completed，删除目录并恢复备份
    log_info "所有批次已完成，执行最终清理..."
    
    # 删除本次任务创建的输入/输出目录
    run_ssh "rm -rf $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR" 2>/dev/null || true
    
    # 恢复备份的目录（如果有）
    if [[ -n "$backup_input_dir" ]]; then
        log_info "恢复备份的输入目录: $backup_input_dir -> $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR"
        run_ssh "mv $backup_input_dir $REMOTE_WORK_DIR/$REMOTE_INPUT_DIR" 2>/dev/null || true
    fi
    if [[ -n "$backup_output_dir" ]]; then
        log_info "恢复备份的输出目录: $backup_output_dir -> $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR"
        run_ssh "mv $backup_output_dir $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR" 2>/dev/null || true
    fi
    
    # 清理本次上传的模型文件
    if [[ ${#uploaded_models[@]} -gt 0 ]]; then
        for model_path in "${uploaded_models[@]}"; do
            log_info "删除本次上传的模型: $(basename "$model_path")"
            run_ssh "rm -f $model_path" 2>/dev/null || true
        done
    fi
    
    # 恢复备份的模型文件（如果有）
    if [[ ${#backup_models[@]} -gt 0 ]]; then
        for backup_info in "${backup_models[@]}"; do
            local backup_path="${backup_info%%|*}"
            local original_path="${backup_info##*|}"
            log_info "恢复备份的模型: $(basename "$backup_path") -> $(basename "$original_path")"
            run_ssh "mv $backup_path $original_path" 2>/dev/null || true
        done
    fi
}

# -------------------------------- 参数解析 --------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            -H|--host)
                SSH_HOST="$2"
                shift 2
                ;;
            -p|--port)
                SSH_PORT="$2"
                shift 2
                ;;
            -k|--key)
                SSH_KEY="$2"
                shift 2
                ;;
            -b|--batch-size)
                MAX_BATCH_SIZE="$2"
                shift 2
                ;;
            -w|--work-dir)
                REMOTE_WORK_DIR="$2"
                shift 2
                ;;
            -M|--model-dir)
                MODEL_DIR="$2"
                shift 2
                ;;
            -i|--input-dir)
                IN_SUBDIR="$2"
                shift 2
                ;;
            -s|--suffix)
                INPUT_SUFFIX_LIST="$2"
                shift 2
                ;;
            -o|--output-dir)
                OUT_SUBDIR="$2"
                shift 2
                ;;
            -y|--dry-run)
                # 检查下一个参数是否是数字（延迟秒数）
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    DRY_RUN="$2"
                    shift 2
                else
                    DRY_RUN=0  # 默认启用但不延迟
                    shift
                fi
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                log_error "未知选项: $1"
                echo "使用 -h 或 --help 查看帮助信息"
                exit 1
                ;;
            *)
                if [[ -z "$EVAL_DIR" ]]; then
                    EVAL_DIR="$1"
                else
                    log_error "只能指定一个评测目录"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # 检查必需参数
    if [[ -z "$EVAL_DIR" ]]; then
        log_error "请指定评测数据集子目录"
        echo "使用 -h 或 --help 查看帮助信息"
        exit 1
    fi
}

# -------------------------------- 主程序 --------------------------------

main() {
    parse_args "$@"
    
    log_info "开始评测任务"

    if [[ $DRY_RUN -ge 0 ]]; then
        if [[ $DRY_RUN -eq 0 ]]; then
            log_warn "=== 干运行模式（无延迟） ==="
        else
            log_warn "=== 干运行模式（模拟延迟: ${DRY_RUN}s） ==="
        fi
    fi
    
    log_info "评测目录: $EVAL_DIR"
    log_info "SSH 主机: $SSH_HOST"
    log_info "批处理大小: $MAX_BATCH_SIZE"
    log_info "输入目录: $IN_SUBDIR"
    log_info "输出目录: $OUT_SUBDIR"
    log_info "本地模型目录: ${MODEL_DIR:-$SCRIPT_DIR/${EVAL_DIR%%/*}}"
    
    # 显示远程模型配置
    for i in 0 1 2 3; do
        local remote_model_var="REMOTE_MODEL_FILE$i"
        local remote_model_path="${!remote_model_var}"
        if [[ -n "$remote_model_path" ]]; then
            log_info "远程模型$i: $remote_model_path"
        fi
    done
    
    # 设置清理钩子
    trap final_cleanup EXIT
    
    # 显示远程评测配置信息
    log_info "远程工作目录: $REMOTE_WORK_DIR"
    log_info "远程输入目录: $REMOTE_INPUT_DIR"
    log_info "远程输出目录: $REMOTE_OUTPUT_DIR"
    log_info "数据集文件后缀列表: $INPUT_SUFFIX_LIST"
    log_info "后处理插件: ${POST_PROCESS_PLUGIN:-<none>}"
    
    check_prerequisites
    
    # 构建状态文件路径
    EVAL_STATE_FILE="$SCRIPT_DIR/$EVAL_DIR/$(get_eval_state_name)"
    
    # 检查是否已经完成（存在 .complete.state 文件）
    local complete_state_file="${EVAL_STATE_FILE%.state}.complete.state"
    if [[ -f "$complete_state_file" ]]; then
        log_warn "检测到任务已完成: $complete_state_file"
        log_warn "如需重新执行，请先删除该文件"
        exit 0
    fi
    
    # 生成或加载状态文件（在 init_remote_workspace 之前，以便保存备份信息）
    local is_resume="false"
    
    # 检查状态文件是否已存在（续传模式）
    if [[ -f "$EVAL_STATE_FILE" ]]; then
        is_resume="true"
        log_info "检测到续传模式，加载已有状态文件"
        # 从状态文件加载备份信息
        load_backup_info
    fi
    
    # 生成或验证状态文件
    if ! generate_eval_state_file; then
        log_error "状态文件初始化失败"
        exit 1
    fi

    # 初始化远程工作空间（上传模型等）
    init_remote_workspace "$is_resume"

    process_batches
    
    log_info "评测任务完成！"
}

main "$@"
