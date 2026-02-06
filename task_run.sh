#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 检测操作系统
OS_TYPE="$(uname)"
IS_MACOS=false
[[ "$OS_TYPE" == "Darwin" ]] && IS_MACOS=true

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                        ★★★ 批量任务执行脚本 ★★★                              
# ║                   自动执行所有任务，支持串行/并发模式                             
# ╚═══════════════════════════════════════════════════════════════════════════╝

# -------------------------------- 配置区域 --------------------------------

# 任务执行脚本
RUN_SCRIPT="$SCRIPT_DIR/eval.sh"

# 检查执行脚本是否存在（必须存在才能执行任务）
if [[ ! -f "$RUN_SCRIPT" ]]; then
    echo "错误: 找不到执行脚本 $RUN_SCRIPT" >&2
    echo "请确保 eval.sh 存在于脚本目录中" >&2
    exit 1
fi

# 任务配置文件名（在每个任务目录下的配置文件）
# 从 eval.sh 中一次性批量加载默认配置（用一次性读取的文件内容，多次 grep）
_script_content=$(cat "$RUN_SCRIPT")

_run_state_default=$(echo "$_script_content" | grep -E '^EVAL_STATE_NAME=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
RUN_STATE_NAME="${RUN_STATE_NAME:-${_run_state_default}}"

_target_ext_default=$(echo "$_script_content" | grep -E '^MODEL_FILE_EXT=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
TARGET_FILE_EXT="${TARGET_FILE_EXT:-${_target_ext_default}}"

# 验证关键默认值必须有效
if [[ -z "$RUN_STATE_NAME" ]]; then
    echo "错误: 无法从 eval.sh 中提取 RUN_STATE_NAME 设置，需要该信息来跟踪任务状态" >&2
    exit 1
fi
if [[ -z "$TARGET_FILE_EXT" ]]; then
    echo "错误: 无法从 eval.sh 中提取 TARGET_FILE_EXT 设置，需要该信息来识别任务目录" >&2
    exit 1
fi

_ssh_host_default=$(echo "$_script_content" | grep -E '^SSH_HOST=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
SSH_HOST="${SSH_HOST:-${_ssh_host_default}}"
_ssh_port_default=$(echo "$_script_content" | grep -E '^SSH_PORT=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
SSH_PORT="${SSH_PORT:-${_ssh_port_default}}"

# 服务器配置文件（优先级高于 eval.sh 默认值）
SERVER_CONFIG_FILE="$SCRIPT_DIR/.server"
if [[ -f "$SERVER_CONFIG_FILE" ]]; then
    server_config=$(cat "$SERVER_CONFIG_FILE" | tr -d '[:space:]')
    if [[ -n "$server_config" ]]; then
        # 解析格式：user@ip:port
        if [[ "$server_config" =~ ^([^:]+):([0-9]+)$ ]]; then
            SSH_HOST="${BASH_REMATCH[1]}"
            SSH_PORT="${BASH_REMATCH[2]}"
        elif [[ "$server_config" =~ ^[^:]+$ ]]; then
            # 只有 user@ip，没有 port
            SSH_HOST="$server_config"
            SSH_PORT="22"  # 默认端口
        else
            echo "警告: .server 配置格式不正确，应为 'user@ip:port' 或 'user@ip'，当前值: $server_config" >&2
        fi
    fi
fi

if [[ -z "$SSH_HOST" ]]; then
    echo "错误: 无法从 eval.sh 中提取 SSH_HOST 设置，需要该信息来连接远程服务器" >&2
    exit 1
fi
if [[ -z "$SSH_PORT" ]]; then
    echo "错误: 无法从 eval.sh 中提取 SSH_PORT 设置，需要该信息来连接远程服务器" >&2
    exit 1
fi

_run_config_default=$(echo "$_script_content" | grep -E '^EVAL_CONFIG_NAME=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
RUN_CONFIG_NAME="${RUN_CONFIG_NAME:-${_run_config_default}}"

_in_subdir_default=$(echo "$_script_content" | grep -E '^IN_SUBDIR=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
IN_SUBDIR="${IN_SUBDIR:-${_in_subdir_default}}"
_input_suffix_default=$(echo "$_script_content" | grep -E '^INPUT_SUFFIX_LIST=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
INPUT_SUFFIX_LIST="${INPUT_SUFFIX_LIST:-${_input_suffix_default}}"

_out_subdir_default=$(echo "$_script_content" | grep -E '^OUT_SUBDIR=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
OUT_SUBDIR="${OUT_SUBDIR:-${_out_subdir_default}}"

_batch_size_default=$(echo "$_script_content" | grep -E '^MAX_BATCH_SIZE=' | sed 's/.*:-\([^}]*\)}.*/\1/' | head -1)
MAX_BATCH_SIZE="${MAX_BATCH_SIZE:-${_batch_size_default}}"

unset _script_content _run_state_default _run_config_default _in_subdir_default _out_subdir_default _input_suffix_default _target_ext_default _ssh_host_default _ssh_port_default _batch_size_default  # 清理临时变量

# 运行日志存储配置
RUN_LOGS_DIR="$SCRIPT_DIR/.run_logs"                    # 任务详细日志目录
SAVE_RUN_LOGS=0                                         # 是否保存任务详细日志（通过 --save-logs 参数开启）


# 基本环境配置
REMOTE_TASK_HOME="${REMOTE_TASK_HOME:-}"                # 远程任务主目录（环境变量，空时自动获取）
CLEANUP_REMOTE_WORKDIR="${CLEANUP_REMOTE_WORKDIR:-1}"   # 是否清理远程工作目录（0=保留，1=清理，默认清理）
CLEANUP_SHARED_MODELS="${CLEANUP_SHARED_MODELS:-0}"     # 是否清理共享模型（0=保留，1=任务完成后清理，2=全部完成后清理，默认保留）

# 任务管理相关文件
TASK_LIST_FILE="$SCRIPT_DIR/.task_list"                 # 任务列表文件
FAILED_TASKS_FILE="$SCRIPT_DIR/failed_tasks.txt"        # 失败任务列表文件
LOG_FILE="$SCRIPT_DIR/task_run.log"                     # 任务执行日志文件

# 并行任务锁文件和进程ID文件
MAIN_PID_FILE="$SCRIPT_DIR/.main_pid"                   # 主进程PID文件（用于监控和安全停止）
PID_FILE="$SCRIPT_DIR/.running_pids"                    # 并行模式：记录后台任务进程ID
MAX_CONCURRENT=3                                        # 最大并发任务数（通过 -p N 参数设置）

# 在 /tmp 中生成锁文件目录
# + 存储在 /tmp 目录避免被某些对文件进行实时监控的程序（如 Docker）干扰
# + 设计说明：
#   1. MD5 基于脚本目录路径生成，确保不同目录的实例使用独立的锁目录
#   2. 移动脚本目录后，MD5 会变化，自动使用新的锁目录（隔离设计）
#   3. flock 机制：锁文件不存在时会自动创建（通过 200>"$LOCK_FILE" 重定向）
#   4. 旧的锁目录会被系统自动清理（/tmp 目录在重启时清空）
LOCK_DIR_ID=$(echo -n "$SCRIPT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1 || echo -n "$SCRIPT_DIR" | md5 2>/dev/null || echo "default")
LOCK_DIR="/tmp/task_locks_${LOCK_DIR_ID}"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

# 锁文件路径（flock 会在首次使用时自动创建这些文件）
LOG_LOCK_FILE="$LOCK_DIR/task_run.log.lock"
TASK_LIST_LOCK_FILE="$LOCK_DIR/task_list.lock"


# 全局状态变量（供监控模式使用）
running_tasks_list=""      # 正在运行的任务列表
running_tasks_detail=""    # 运行任务的详细信息（批次进度等）
render_output_cache=""     # 渲染输出缓存（避免监控模式重复调用）

# -------------------------------- 工具函数 --------------------------------

# 颜色定义（需要在依赖检查函数之前定义）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
WHITE='\033[1;37m'
NC='\033[0m'

# 检查并安装必要的依赖工具（macOS/Linux）
check_and_install_dependencies() {
    # 必要工具列表：工具名|用途说明|包名(brew)|包名(apt)
    local deps=(
        "flock|文件锁工具，防止并发模式下日志写入冲突|flock|util-linux"
        "gzip|压缩工具，用于加速模型文件上传|gzip|gzip"
    )
    
    local missing_tools=()
    local missing_purposes=()
    local missing_packages=()
    
    # 检测缺失的工具
    for dep_info in "${deps[@]}"; do
        IFS='|' read -r tool purpose pkg_brew pkg_apt <<< "$dep_info"
        
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
            missing_purposes+=("$purpose")
            if [[ "$IS_MACOS" == "true" ]]; then
                missing_packages+=("$pkg_brew")
            else
                missing_packages+=("$pkg_apt")
            fi
        fi
    done
    
    # 如果没有缺失，直接返回
    [[ ${#missing_tools[@]} -eq 0 ]] && return 0
    
    # 提示用户
    echo ""
    echo -e "${YELLOW}检测到缺失以下必要工具：${NC}"
    for ((i=0; i<${#missing_tools[@]}; i++)); do
        echo "  • ${missing_tools[$i]}: ${missing_purposes[$i]}"
    done
    echo ""
    
    # 根据系统选择包管理器
    local pkg_manager=""
    local install_cmd=""
    
    if [[ "$IS_MACOS" == "true" ]]; then
        if ! command -v brew >/dev/null 2>&1; then
            echo -e "${RED}错误: Homebrew 未安装，无法自动安装依赖${NC}"
            echo "请手动安装 Homebrew: https://brew.sh/"
            return 1
        fi
        pkg_manager="Homebrew"
        install_cmd="brew install"
    else
        # Linux 系统
        if command -v apt-get >/dev/null 2>&1; then
            pkg_manager="apt"
            install_cmd="sudo apt-get install -y"
        elif command -v yum >/dev/null 2>&1; then
            pkg_manager="yum"
            install_cmd="sudo yum install -y"
        else
            echo -e "${RED}错误: 未检测到支持的包管理器（apt/yum）${NC}"
            echo "请手动安装: ${missing_packages[*]}"
            return 1
        fi
    fi
    
    # 询问是否安装
    # ! 注意，必须从 /dev/tty 读取用户输入：
    #   如果脚本在非交互式环境运行（如管道、后台任务），stdin 可能不是终端
    #   此时 read 会从空的 stdin 立即返回（answer 为空），导致直接跳到 else 分支
    #   使用 </dev/tty 强制从终端设备读取，确保能等待用户交互输入
    echo -n "是否使用 $pkg_manager 自动安装？(y/n): "
    read -r answer </dev/tty
    
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        echo ""
        echo -e "${GREEN}开始安装依赖工具...${NC}"
        for pkg in "${missing_packages[@]}"; do
            echo "正在安装: $pkg"
            if eval "$install_cmd $pkg"; then
                echo -e "${GREEN}✓ $pkg 安装成功${NC}"
            else
                echo -e "${RED}✗ $pkg 安装失败${NC}"
                return 1
            fi
        done
        echo ""
        echo -e "${GREEN}所有依赖工具安装完成！${NC}"
        return 0
    else
        echo ""
        echo -e "${YELLOW}跳过安装。注意：缺少这些工具可能影响脚本功能。${NC}"
        echo -e "${DIM}(串行模式可以继续使用，并发模式可能出现日志混乱)${NC}"
        return 0  # 不阻止脚本继续运行
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

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local msg_line="[$timestamp] [$level] $msg"
    
    # 使用锁避免并发写入日志混乱（仅在 flock 可用时启用）
    if command -v flock >/dev/null 2>&1; then
        (
            # -w 5: 5秒超时，避免死锁
            if flock -w 5 -x 200; then
                echo -e "$msg_line" | tee -a "$LOG_FILE"
            else
                # 超时后直接输出到终端，不写入日志文件
                echo -e "$msg_line"
            fi
        ) 200>"$LOG_LOCK_FILE"
    else
        # flock 不可用（如 macOS），直接写入（并发模式下可能出现日志交错）
        echo -e "$msg_line" | tee -a "$LOG_FILE"
    fi
}

log_info() {
    log "INFO" "${GREEN}$*${NC}"
}

log_warn() {
    log "WARN" "${YELLOW}$*${NC}"
}

log_error() {
    log "ERROR" "${RED}$*${NC}"
}

log_task() {
    log "TASK" "${CYAN}$*${NC}"
}

# -------------------------------- 模拟关联数组（兼容 bash 3.2）--------------------------------

# 设置缓存模型路径（模拟关联数组）
# 参数: $1=任务路径, $2=远程模型路径
cache_model_set() {
    local key="$1"
    local value="$2"
    # 使用 ||| 作为分隔符（不太可能出现在路径中）
    CACHED_MODELS="${CACHED_MODELS}${key}|||${value};;;"
}

# 获取缓存的模型路径（模拟关联数组）
# 参数: $1=任务路径
cache_model_get() {
    local key="$1"
    # 提取对应的值
    local pattern="${key}|||"
    local result="${CACHED_MODELS#*${pattern}}"
    if [[ "$result" != "$CACHED_MODELS" ]]; then
        echo "${result%%;;;*}"
    else
        echo ""
    fi
}

# -------------------------------- 任务维护工具 --------------------------------

# 获取状态文件名（确保以 . 开头且有 .state 后缀）
get_run_state_name() {
    local states_name="$RUN_STATE_NAME"
    
    # 确保以 . 开头（隐藏文件）
    [[ "$states_name" != .* ]] && states_name=".$states_name"
    
    # 自动补全 .state 后缀
    [[ "$states_name" != *.state ]] && states_name="${states_name}.state"
    
    echo "$states_name"
}

# 获取完成状态文件名
get_run_state_complete_name() {
    local states_name
    states_name=$(get_run_state_name)
    echo "${states_name%.state}.complete.state"
}

# 检查任务是否已完成
# 判断依据：
# 1. 检查完成状态文件（.complete.state）是否存在
# 2. 如果不存在，比较输出目录文件数量和数据集目录任务数量
is_run_completed() {
    local task_path="$1"  # 格式: task_dir/dataset
    local full_path="$SCRIPT_DIR/$task_path"
    
    # 方法1: 检查完成状态文件是否存在
    local complete_state_file
    complete_state_file="$full_path/$(get_run_state_complete_name)"
    if [[ -f "$complete_state_file" ]]; then
        return 0  # 已完成
    fi
    
    # 方法2: 比较文件数量（兜底方案）
    # 处理统一输出目录：以 . 开头或绝对路径
    local output_dir
    if [[ "$OUT_SUBDIR" == .* ]]; then
        # 以 . 开头：相对于脚本目录
        output_dir="$SCRIPT_DIR/$OUT_SUBDIR/$task_path"
    elif [[ "$OUT_SUBDIR" == /* ]]; then
        # 绝对路径：直接使用
        output_dir="$OUT_SUBDIR/$task_path"
    else
        # 普通路径：相对于数据集目录
        output_dir="$full_path/$OUT_SUBDIR"
    fi
    local input_dir="$full_path/$IN_SUBDIR"
    
    if [[ -d "$output_dir" ]] && [[ -d "$input_dir" ]]; then
        # 获取第一个后缀（用于统计任务数）
        local primary_suffix="${INPUT_SUFFIX_LIST%%,*}"
        
        # 统计数据集目录中的任务数（使用第一个后缀）
        local ds_tasks
        if [[ -n "$primary_suffix" ]]; then
            ds_tasks=$(find "$input_dir" -name "*${primary_suffix}" 2>/dev/null | wc -l)
        else
            ds_tasks=$(find "$input_dir" -type f 2>/dev/null | wc -l)
        fi
        
        # 统计输出目录中的输出文件数
        local output_files
        output_files=$(find "$output_dir" -type f 2>/dev/null | wc -l)
        
        # 如果输出文件数 >= 任务数，认为已完成
        if [[ "$output_files" -ge "$ds_tasks" ]] && [[ "$ds_tasks" -gt 0 ]]; then
            return 0  # 已完成
        fi
    fi
    
    return 1  # 未完成
}

# 读取单个配置文件，输出 key=value 格式（跳过注释和空行）
parse_run_config() {
    local config_file="$1"
    
    [[ ! -f "$config_file" ]] && return
    
    while IFS='=' read -r key value; do
        # 跳过注释行和空行
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # 清理 key（去除空格）
        key=$(echo "$key" | tr -d ' ' | tr -d '\r')
        # 清理 value（去除引号和回车）
        value=$(echo "$value" | tr -d '"' | tr -d "'" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 只输出非空值
        [[ -n "$value" ]] && echo "$key=$value"
    done < "$config_file"
}

# 构建任务配置（一次性读取所有配置项）
# 输出格式：每行一个 key=value
# 使用方式：task_config=$(build_task_config "$task_dir" "$dataset")
build_task_config() {
    local task_dir="$1"
    local dataset="${2:-}"  # 可选：数据集路径
    
    # 先输出全局默认配置
    echo "IN_SUBDIR=$IN_SUBDIR"
    echo "INPUT_SUFFIX_LIST=$INPUT_SUFFIX_LIST"
    
    # 处理 OUT_SUBDIR：统一输出目录模式（以 . 开头或绝对路径）
    local out_subdir="$OUT_SUBDIR"
    if [[ -n "$dataset" ]]; then
        if [[ "$OUT_SUBDIR" == .* ]]; then
            # 以 . 开头：相对于脚本目录
            out_subdir="$SCRIPT_DIR/$OUT_SUBDIR/$task_dir/$dataset"
        elif [[ "$OUT_SUBDIR" == /* ]]; then
            # 绝对路径：直接使用
            out_subdir="$OUT_SUBDIR/$task_dir/$dataset"
        fi
    fi
    echo "OUT_SUBDIR=$out_subdir"
    
    # 读取并输出任务级配置（会覆盖同名的全局配置）
    if [[ -n "$RUN_CONFIG_NAME" ]]; then
        local model_config="$SCRIPT_DIR/$task_dir/$RUN_CONFIG_NAME"
        if [[ -f "$model_config" ]]; then
            parse_run_config "$model_config"
        fi
    fi
    
    # 验证：IN_SUBDIR 或 INPUT_SUFFIX_LIST 至少一个有效
    if [[ -z "$IN_SUBDIR" && -z "$INPUT_SUFFIX_LIST" ]]; then
        echo "[WARN] 任务 $task_dir: IN_SUBDIR 和 INPUT_SUFFIX_LIST 均未设置，无法识别评测数据集" >&2
    fi
}

# 构造评测的环境变量配置字符串（用于 env 命令）
make_run_env_vars() {
    local task_dir="$1"
    local dataset="${2:-}"  # 可选：数据集路径
    
    # 获取任务配置（一次性读取，传入 dataset 用于统一输出目录）
    local task_config
    task_config=$(build_task_config "$task_dir" "$dataset")
    
    # 转换为环境变量格式（key=value 用空格连接）
    local env_str=""
    while IFS= read -r line; do
        [[ -n "$line" ]] && env_str+="$line "
    done <<< "$task_config"
    
    echo "$env_str"
}

# 扫描任务目录（深度最多2层，查找模型文件）
# 性能优化策略：
# 1. 使用循环而非递归 find，避免深入遍历包含大量文件的数据集目录
# 2. 使用 find -maxdepth 1 -quit 快速检测，找到当前目录下第一个匹配文件即退出，避免枚举所有文件（比对 ls 的结果过滤更快）
# 3. 只检查前2层目录，不进入更深层级
scan_task_dirs() {
    local tasks=()
    
    # 第1层：直接子目录
    for item in "$SCRIPT_DIR"/*/; do
        [[ ! -d "$item" ]] && continue
        local dir_name
        dir_name=$(basename "$item")
        
        # 跳过隐藏目录和特殊目录
        [[ "$dir_name" == .* ]] && continue
        
        # 检查是否有模型文件（find -quit：找到第一个即退出，性能最优）
        if [[ -n "$(find "$item" -maxdepth 1 -name "*$TARGET_FILE_EXT" -print -quit 2>/dev/null)" ]]; then
            tasks+=("$dir_name")
            continue
        fi
        
        # 第2层：检查子目录
        for subitem in "$item"/*/; do
            [[ ! -d "$subitem" ]] && continue
            local subdir_name
            subdir_name=$(basename "$subitem")
            
            [[ "$subdir_name" == .* ]] && continue
            
            if [[ -n "$(find "$subitem" -maxdepth 1 -name "*$TARGET_FILE_EXT" -print -quit 2>/dev/null)" ]]; then
                tasks+=("$dir_name/$subdir_name")
            fi
        done
    done
    
    # 输出任务列表（每行一个）
    printf '%s\n' "${tasks[@]}"
}

# 收集所有评测数据集（相对于任务目录的路径）
# 在任务目录下最多遍历 2 层子目录，查找包含指定数据集子目录的目录
# 参数：
#   $1 - task_dir: 任务目录
#   $2 - task_config: (可选) build_task_config 的输出结果，用于获取 IN_SUBDIR
collect_datasets() {
    local task_dir="$1"
    local task_config="${2:-}"
    local ds_subdir="$IN_SUBDIR"  # 默认使用全局配置
    
    # 如果提供了配置缓存，从中提取 IN_SUBDIR（使用 tail -1 获取最后一个匹配，实现覆盖效果）
    if [[ -n "$task_config" ]]; then
        local value=$(echo "$task_config" | grep "^IN_SUBDIR=" | tail -1 | cut -d'=' -f2-)
        [[ -n "$value" ]] && ds_subdir="$value"
    fi
    
    local full_path="$SCRIPT_DIR/$task_dir"
    local datasets=()
    
    # 第1层：直接子目录
    for item in "$full_path"/*/; do
        [[ ! -d "$item" ]] && continue
        local subdir_name
        subdir_name=$(basename "$item")
        
        # 跳过隐藏目录
        [[ "$subdir_name" == .* ]] && continue
        
        # 检查是否直接包含数据集子目录
        if [[ -d "$item/$ds_subdir" ]]; then
            datasets+=("$subdir_name")
        else
            # 跳过以 out 开头的目录（如 output、output.wp 等），避免遍历输出目录
            [[ "$subdir_name" == out* ]] && continue
            
            # 第2层：检查子目录的子目录
            for subitem in "$item"/*/; do
                [[ ! -d "$subitem" ]] && continue
                local subsubdir_name
                subsubdir_name=$(basename "$subitem")
                
                [[ "$subsubdir_name" == .* ]] && continue
                
                if [[ -d "$subitem/$ds_subdir" ]]; then
                    datasets+=("$subdir_name/$subsubdir_name")
                fi
            done
        fi
    done
    
    # 第一行输出数量，后续行输出数据集路径
    echo "${#datasets[@]}"
    printf '%s\n' "${datasets[@]}"
}

# （重新）生成任务列表文件
# 文件格式：
#   *task_dir|plugin|ds_count      - 任务行（以 * 开头）
#   -dataset_path|status           - 数据集行（以 - 开头），status: 0=pending, 1=running, 2=completed
#   +summary|total_tasks|total_datasets - 汇总行（以 + 开头）
generate_task_list() {
    log_info "扫描任务目录..."
    
    local tasks
    tasks=$(scan_task_dirs)
    
    if [[ -z "$tasks" ]]; then
        log_warn "未发现任何任务目录"
        return 1
    fi
    
    # 生成任务列表（保存数据集列表，只需执行一次）
    local count=0
    local total_datasets=0
    
    > "$TASK_LIST_FILE"  # 清空文件
    
    while IFS= read -r task_dir; do
        [[ -z "$task_dir" ]] && continue
        
        # 读取任务配置（一次性读取所有配置项，缓存到变量）
        local task_config
        task_config=$(build_task_config "$task_dir")
        
        # 从缓存的配置中提取需要的值（使用 tail -1 获取最后一个匹配，实现覆盖效果）
        local plugin=$(echo "$task_config" | grep "^POST_PROCESS_PLUGIN=" | tail -1 | cut -d'=' -f2-)
        
        # 获取数据集列表（传入配置缓存）
        local datasets_output
        datasets_output=$(collect_datasets "$task_dir" "$task_config" 2>/dev/null)
        
        # 读取第一行作为计数
        local ds_count
        ds_count=$(echo "$datasets_output" | head -1)
        [[ -z "$ds_count" ]] && ds_count=0
        
        # 写入任务行（以 * 开头），包含数据集计数
        echo "*${task_dir}|${plugin}|${ds_count}" >> "$TASK_LIST_FILE"
        
        # 写入数据集列表（跳过第一行的计数，每个数据集一行，以 - 开头，包含完成状态和运行状态）
        echo "$datasets_output" | tail -n +2 | while IFS= read -r dataset; do
            [[ -z "$dataset" ]] && continue
            
            # 检查实际完成状态并同步到列表
            local status=0  # 默认为 pending
            if is_run_completed "$task_dir/$dataset"; then
                status=2  # 已完成
            fi
            
            echo "-${dataset}|${status}" >> "$TASK_LIST_FILE"
        done
        
        ((count++)) || true
        ((total_datasets += ds_count)) || true
    done <<< "$tasks"
    
    # 写入汇总行（以 + 开头）
    echo "+summary|${count}|${total_datasets}" >> "$TASK_LIST_FILE"
    
    log_info "发现 $count 个任务目录，共 $total_datasets 个数据集，列表保存到: $TASK_LIST_FILE"
    return 0
}

# 标记任务列表中的完成状态
# 更新任务状态（通用函数）
# 参数:
#   $1: task_dir - 任务目录
#   $2: dataset - 数据集路径（相对于任务目录）
#   $3: status - 新状态值 (0=pending, 1=running, 2=completed, 3=failed)
update_task_status() {
    local task_dir="$1"
    local dataset="$2"
    local status="$3"
    
    # 使用文件锁防止并发冲突
    local lock_file="$TASK_LIST_LOCK_FILE"
    (
        # -w 5: 5秒超时，避免死锁
        flock -w 5 -x 200 || { echo "[WARN] 获取锁超时" >&2; return 1; }
        # 使用 awk 在对应的 task_dir 块内精确修改 dataset 状态
        awk -v task="$task_dir" -v ds="$dataset" -v new_status="$status" '
            /^\*/ {
                split($0, parts, "|")
                task_name = substr(parts[1], 2)  # 去掉开头的 *
                in_task = (task_name == task)
            }
            /^-/ && in_task {
                split($0, fields, "|")
                ds_name = substr(fields[1], 2)  # 去掉开头的 -
                if (ds_name == ds) {
                    print "-" ds "|" new_status
                    next
                }
            }
            { print }
        ' "$TASK_LIST_FILE" > "$TASK_LIST_FILE.tmp" && mv "$TASK_LIST_FILE.tmp" "$TASK_LIST_FILE"
    ) 200>"$lock_file"
}

# 检查任务下的所有数据集是否都已完成
all_datasets_completed() {
    local task_dir="$1"
    
    # 从任务列表文件中读取该任务的所有数据集状态
    local all_completed=1
    local found_task=0
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local prefix="${line:0:1}"
        local content="${line:1}"
        
        case "$prefix" in
            '*')
                IFS='|' read -r current_task _plugin _ds_count <<< "$content"
                if [[ "$current_task" == "$task_dir" ]]; then
                    found_task=1
                elif [[ $found_task -eq 1 ]]; then
                    # 已经遍历完该任务的所有数据集
                    break
                fi
                ;;
            '-')
                if [[ $found_task -eq 1 ]]; then
                    local dataset status
                    IFS='|' read -r dataset status <<< "$content"
                    if [[ "${status:-0}" -ne 2 ]]; then
                        all_completed=0
                        break
                    fi
                fi
                ;;
        esac
    done < "$TASK_LIST_FILE"
    
    [[ $all_completed -eq 1 ]]
}

# -------------------------------- 远程维护工具 --------------------------------

# 获取远程用户的 home 目录
get_remote_home() {
    # 如果已经设置，直接返回
    if [[ -n "$REMOTE_TASK_HOME" ]]; then
        echo "$REMOTE_TASK_HOME"
        return 0
    fi
    
    # DRY_RUN 模式下跳过 SSH 连接，直接返回默认值
    if [[ -n "${DRY_RUN:-}" ]]; then
        echo "/root"
        return 0
    fi
    
    # 尝试从远程服务器获取 home 目录
    # 使用 echo \$HOME 而不是 echo $HOME，确保在远程展开
    local remote_home
    remote_home=$(ssh -n -p "$SSH_PORT" "$SSH_HOST" 'echo $HOME' 2>/dev/null)
    
    if [[ -n "$remote_home" ]] && [[ "$remote_home" != *"Permission denied"* ]]; then
        echo "$remote_home"
    else
        # 如果无法获取，使用默认值 /root
        echo "/root"
    fi
}

# 生成唯一的远程工作目录名（基于任务路径的hash）
generate_remote_workdir() {    
    local task_path="$1"
    # 将路径转换为安全的目录名
    local safe_name
    safe_name=$(echo "$task_path" | tr '/' '_' | tr ' ' '_')
    echo "${REMOTE_TASK_HOME}/task_${safe_name}"
}

# 清理远程工作目录
cleanup_remote_workdir() {
    local remote_workdir="$1"
    
    # 检查是否启用清理
    [[ "$CLEANUP_REMOTE_WORKDIR" -ne 1 ]] && return 0
    
    # 安全检查：确保路径包含 task_ 前缀（避免误删）
    if [[ "$remote_workdir" == *"/task_"* ]]; then
        if [[ -n "${DRY_RUN:-}" ]] && [[ "${DRY_RUN}" -ge 0 ]]; then
            log_info "[DRY-RUN] 跳过清理远程工作目录: $remote_workdir"
        else
            ssh -n -p "$SSH_PORT" "$SSH_HOST" "rm -rf '$remote_workdir'" 2>/dev/null || true
        fi
    fi
}


# 获取预上传的模型路径
get_cached_model_path() {
    local task_dir="$1"
    local model_cache_dir="${REMOTE_TASK_HOME}/.model_cache"
    local task_safe_name
    task_safe_name=$(echo "$task_dir" | tr '/' '_' | tr ' ' '_')
    echo "$model_cache_dir/${task_safe_name}_model${TARGET_FILE_EXT}"
}

# 预上传模型到远程服务器的共享位置（并发模式用）
preupload_model() {
    local task_dir="$1"
    
    # 复用 get_cached_model_path 函数获取远程路径
    local remote_model_path
    remote_model_path=$(get_cached_model_path "$task_dir")
    
    local local_model_path="$SCRIPT_DIR/$task_dir/model${TARGET_FILE_EXT}"
    if [[ ! -f "$local_model_path" ]]; then
        log_warn "模型文件不存在: $local_model_path"
        return 1
    fi
    
    log_info "预上传模型: $task_dir -> $remote_model_path"
    
    # 检查远程是否已有完整模型
    # ssh -n: 防止消费外层 while read 循环的 stdin
    local local_size
    local_size=$(stat -c%s "$local_model_path" 2>/dev/null || stat -f%z "$local_model_path")
    local remote_size
    if [[ -n "${DRY_RUN:-}" ]] && [[ "${DRY_RUN}" -ge 0 ]]; then
        remote_size="0"  # DRY_RUN 模式：假设远程没有模型
    else
        remote_size=$(ssh -n -p "$SSH_PORT" "$SSH_HOST" "stat -c%s '$remote_model_path' 2>/dev/null || echo 0")
    fi
    
    if [[ "$local_size" == "$remote_size" ]] && [[ "$remote_size" != "0" ]]; then
        log_info "  模型已存在且完整，跳过上传"
        return 0
    fi
    
    # 创建目录并上传
    local remote_model_dir
    remote_model_dir=$(dirname "$remote_model_path")
    
    if [[ -n "${DRY_RUN:-}" ]] && [[ "${DRY_RUN}" -ge 0 ]]; then
        log_info "  [DRY-RUN] 跳过模型上传: $remote_model_path"
    else
        ssh -n -p "$SSH_PORT" "$SSH_HOST" "mkdir -p '$remote_model_dir'"
        
        # 压缩上传（管道输入，不能加 -n）
        gzip -c "$local_model_path" | ssh -p "$SSH_PORT" "$SSH_HOST" "gunzip -c > '$remote_model_path'"
    fi
    
    # 验证
    if [[ -n "${DRY_RUN:-}" ]] && [[ "${DRY_RUN}" -ge 0 ]]; then
        remote_size="$local_size"  # DRY_RUN 模式：假设上传成功
    else
        remote_size=$(ssh -n -p "$SSH_PORT" "$SSH_HOST" "stat -c%s '$remote_model_path' 2>/dev/null || echo 0")
    fi
    if [[ "$local_size" == "$remote_size" ]]; then
        log_info "  模型上传完成: $remote_model_path ($local_size bytes)"
        return 0
    else
        log_error "  模型上传失败: 大小不匹配 (本地: $local_size, 远程: $remote_size)"
        return 1
    fi
}

# 清理单个任务的共享模型
cleanup_task_shared_model() {
    local task_dir="$1"
    
    # 检查是否启用清理（1=任务完成后清理）
    [[ "$CLEANUP_SHARED_MODELS" -ne 1 ]] && return 0
    
    local remote_model_path
    remote_model_path=$(get_cached_model_path "$task_dir")
    
    # 安全检查：确保路径包含 .model_cache 前缀
    if [[ "$remote_model_path" == *"/.model_cache/"* ]]; then
        if [[ -n "${DRY_RUN:-}" ]] && [[ "${DRY_RUN}" -ge 0 ]]; then
            log_debug "  [DRY-RUN] 跳过删除远程模型: $remote_model_path"
        else
            ssh -n -p "$SSH_PORT" "$SSH_HOST" "rm -f '$remote_model_path'" 2>/dev/null || true
        fi
    fi
}

# 清理所有共享模型（清空 .model_cache 目录）
cleanup_all_shared_models() {
    local model_cache_dir="${REMOTE_TASK_HOME}/.model_cache"
    
    # 安全检查：确保路径包含 .model_cache
    if [[ "$model_cache_dir" == *"/.model_cache"* ]]; then
        if [[ -n "${DRY_RUN:-}" ]] && [[ "${DRY_RUN}" -ge 0 ]]; then
            log_info "[DRY-RUN] 跳过清理共享模型目录: $model_cache_dir"
        else
            ssh -n -p "$SSH_PORT" "$SSH_HOST" "rm -rf '$model_cache_dir'" 2>/dev/null || true
            log_info "已清理共享模型目录: $model_cache_dir"
        fi
    fi
}

# -------------------------------- 并行工具 --------------------------------

# 等待可用的并发槽位
wait_for_slot() {
    while true; do
        # 清理已完成的进程
        local running=0
        local new_pids=""
        if [[ -f "$PID_FILE" ]]; then
            while read -r pid; do
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    ((running++)) || true
                    new_pids+="$pid"$'\n'
                fi
            done < "$PID_FILE"
            echo -n "$new_pids" > "$PID_FILE"
        fi
        
        if [[ $running -lt $MAX_CONCURRENT ]]; then
            return 0
        fi
        
        sleep 0.1
    done
}

# 等待所有任务完成
wait_all_tasks() {
    log_info "等待所有并发任务完成..."
    if [[ -f "$PID_FILE" ]]; then
        while read -r pid; do
            if [[ -n "$pid" ]]; then
                wait "$pid" 2>/dev/null || true
            fi
        done < "$PID_FILE"
    fi
    rm -f "$PID_FILE"
    log_info "所有任务已完成"
}

# -------------------------------- 任务执行 --------------------------------

# 串行模式：执行单个评测任务
# 输出策略：根据 SAVE_RUN_LOGS 决定是否保存详细日志
run_task_serial() {
    local task_dir="$1"
    local dataset="$2"
    local plugin="$3"
    local cached_model="${4:-}"  # 可选：预上传的共享模型路径（绝对路径）
    
    local ds_path="$task_dir/$dataset"
    
    # 获取模型级共享配置（数据集级配置由 RUN_SCRIPT 自行读取）
    local env_vars
    env_vars=$(make_run_env_vars "$task_dir" "$dataset")
    
    # 如果有预上传的共享模型，覆盖 REMOTE_MODEL_FILE0 为绝对路径
    # RUN_SCRIPT 会识别绝对路径并直接使用，无需上传
    if [[ -n "$cached_model" ]]; then
        env_vars="REMOTE_MODEL_FILE0=$cached_model $env_vars"
    fi
    
    # 生成唯一的远程工作目录
    local remote_workdir
    remote_workdir=$(generate_remote_workdir "$ds_path")
    
    log_task "执行: $ds_path (插件: ${plugin:-no-plugin}, 远程目录: $remote_workdir)"
    log_info "配置: $env_vars"
    
    # 标记任务列表为正在运行
    update_task_status "$task_dir" "$dataset" 1
    
    # 设置 MODEL_DIR（任务目录）
    local model_dir="$SCRIPT_DIR/$task_dir"
    
    # 如果 env_vars 中没有 MAX_BATCH_SIZE，添加全局的 MAX_BATCH_SIZE
    if ! echo "$env_vars" | grep -q "MAX_BATCH_SIZE="; then
        env_vars="$env_vars MAX_BATCH_SIZE=$MAX_BATCH_SIZE"
    fi
    
    # 根据配置决定是否保存详细日志
    if [[ $SAVE_RUN_LOGS -eq 1 ]]; then

        # 保存日志模式：同时输出到终端和文件
        local run_log="$RUN_LOGS_DIR/${ds_path//\//_}.log"
        mkdir -p "$(dirname "$run_log")"
        log_info "详细日志: $run_log"
        
        # 重要：使用 < /dev/null 防止 RUN_SCRIPT 消费 while 循环的标准输入
        # 否则会导致循环在第一次迭代后提前退出
        if env $env_vars REMOTE_WORK_DIR="$remote_workdir" MODEL_DIR="$model_dir" \
           "$RUN_SCRIPT" "$ds_path" < /dev/null 2>&1 | tee "$run_log"; then
            # 先更新状态，再记录日志，确保监控界面能立即看到 Datasets completed +1
            update_task_status "$task_dir" "$dataset" 2
            log_info "✓ 完成: $ds_path"
            cleanup_remote_workdir "$remote_workdir"  # 清理远程工作目录
            
            # 检查该任务的所有数据集是否都已完成，如果是则清理共享模型
            if all_datasets_completed "$task_dir"; then
                cleanup_task_shared_model "$task_dir"
            fi
            return 0
        else
            log_error "✗ 失败: $ds_path (查看详细日志: $run_log)"
            echo "$ds_path" >> "$FAILED_TASKS_FILE"
            update_task_status "$task_dir" "$dataset" 3
            return 1
        fi
    # 默认模式：只输出到终端
    else
        # 重要：使用 < /dev/null 防止 RUN_SCRIPT 消费 while 循环的标准输入
        if env $env_vars REMOTE_WORK_DIR="$remote_workdir" MODEL_DIR="$model_dir" \
           "$RUN_SCRIPT" "$ds_path" < /dev/null; then
            # 先更新状态，再记录日志，确保监控界面能立即看到 Datasets completed +1
            update_task_status "$task_dir" "$dataset" 2
            log_info "✓ 完成: $ds_path"
            cleanup_remote_workdir "$remote_workdir"  # 清理远程工作目录
            
            # 检查该任务的所有数据集是否都已完成，如果是则清理共享模型
            if all_datasets_completed "$task_dir"; then
                cleanup_task_shared_model "$task_dir"
            fi
            return 0
        else
            log_error "✗ 失败: $ds_path"
            echo "$ds_path" >> "$FAILED_TASKS_FILE"
            update_task_status "$task_dir" "$dataset" 3
            return 1
        fi
    fi
}

# 并行模式：后台执行单个评测任务
# 输出策略：根据 SAVE_RUN_LOGS 决定是否保存日志
run_task_parallel() {
    local task_dir="$1"
    local dataset="$2"
    local plugin="$3"
    local cached_model="${4:-}"  # 可选：预上传的共享模型路径（绝对路径）
    
    local ds_path="$task_dir/$dataset"
    
    # 获取模型级共享配置（数据集级配置由 RUN_SCRIPT 自行读取）
    local env_vars
    env_vars=$(make_run_env_vars "$task_dir" "$dataset")
    
    # 如果有预上传的共享模型，覆盖 REMOTE_MODEL_FILE0 为绝对路径
    # RUN_SCRIPT 会识别绝对路径并直接使用，无需上传
    if [[ -n "$cached_model" ]]; then
        env_vars="REMOTE_MODEL_FILE0=$cached_model $env_vars"
    fi
    
    # 生成唯一的远程工作目录
    local remote_workdir
    remote_workdir=$(generate_remote_workdir "$ds_path")
    
    log_task "启动并行任务: $ds_path (插件: ${plugin:-no-plugin}, 远程目录: $remote_workdir)"
    
    # 设置 MODEL_DIR（任务目录）
    local model_dir="$SCRIPT_DIR/$task_dir"
    
    # 根据配置决定日志输出目标
    local log_target="/dev/null"
    if [[ $SAVE_RUN_LOGS -eq 1 ]]; then
        local run_log="$RUN_LOGS_DIR/${ds_path//\//_}.log"
        mkdir -p "$(dirname "$run_log")"
        log_target="$run_log"
        log_info "详细日志: $run_log"
    fi
    
    # 标记任务列表为正在运行
    update_task_status "$task_dir" "$dataset" 1
    
    # 如果 env_vars 中没有 MAX_BATCH_SIZE，添加全局的 MAX_BATCH_SIZE
    if ! echo "$env_vars" | grep -q "MAX_BATCH_SIZE="; then
        env_vars="$env_vars MAX_BATCH_SIZE=$MAX_BATCH_SIZE"
    fi
    
    # 后台执行（子进程自己负责状态管理）
    (
        if env $env_vars REMOTE_WORK_DIR="$remote_workdir" MODEL_DIR="$model_dir" \
           "$RUN_SCRIPT" "$ds_path" > "$log_target" 2>&1; then
            # 先更新状态，再记录日志，确保监控界面能立即看到 Datasets completed +1
            update_task_status "$task_dir" "$dataset" 2
            log_info "✓ 完成: $ds_path"
            cleanup_remote_workdir "$remote_workdir"
            
            # 检查该任务的所有数据集是否都已完成，如果是则清理共享模型
            if all_datasets_completed "$task_dir"; then
                cleanup_task_shared_model "$task_dir"
            fi
        else
            if [[ $SAVE_RUN_LOGS -eq 1 ]]; then
                log_error "✗ 失败: $ds_path (查看日志: $log_target)"
            else
                log_error "✗ 失败: $ds_path"
            fi
            echo "$ds_path" >> "$FAILED_TASKS_FILE"
            update_task_status "$task_dir" "$dataset" 3
        fi
    ) &
    
    local pid=$!
    # 只需记录 PID，不需要任务信息（子进程自己管理状态）
    echo "$pid" >> "$PID_FILE"
    log_info "  任务 PID: $pid"
}

# -------------------------------- 主函数 --------------------------------

# 主函数
main() {
    local parallel_mode=0
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--parallel)
                parallel_mode=1
                # 检查下一个参数是否是数字（并发数）
                if [[ $# -gt 1 ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    MAX_CONCURRENT="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --save-logs)
                SAVE_RUN_LOGS=1
                shift
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
            -b|--batch-size)
                MAX_BATCH_SIZE="$2"
                shift 2
                ;;
            *)
                echo "错误: 未知参数 '$1'"
                show_usage
                return 1
                ;;
        esac
    done
    
    echo ""
    echo "============================================================"
    echo "          批量评测任务执行脚本"
    echo "          开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ $parallel_mode -eq 1 ]]; then
        echo "          模式: 并发执行 (最大并发数: $MAX_CONCURRENT)"
    else
        echo "          模式: 串行执行"
    fi
    echo "============================================================"
    echo ""
    
    # 初始化远程任务目录（如果未设置，自动获取远程 home 目录）
    if [[ -z "$REMOTE_TASK_HOME" ]]; then
        log_info "获取远程用户 home 目录..."
        REMOTE_TASK_HOME=$(get_remote_home)
        log_info "远程任务目录: $REMOTE_TASK_HOME"
    fi
    
    # 初始化日志
    echo "# 批量评测日志 - $(date '+%Y-%m-%d %H:%M:%S')" > "$LOG_FILE"
    rm -f "$PID_FILE"
    rm -f "$FAILED_TASKS_FILE"
    rm -f "$LOG_LOCK_FILE"  # 清理日志锁文件
    
    # 检查任务列表是否存在，如果不存在则生成
    if [[ ! -f "$TASK_LIST_FILE" ]]; then
        log_info "任务列表不存在，自动扫描生成..."
        generate_task_list
    fi
    
    # 读取任务列表
    if [[ ! -f "$TASK_LIST_FILE" ]]; then
        log_error "无法生成任务列表"
        return 1
    fi
    
    local task_count
    task_count=$(grep -v "^SUMMARY|" "$TASK_LIST_FILE" | wc -l)
    log_info "从任务列表加载 $task_count 个任务目录"
    
    local total_success=0
    local total_failed=0
    local total_skipped=0
    local total_started=0
    
    # 根据模式选择执行函数
    # 特殊处理：-p 1 等价于串行模式
    local run_task_fn="run_task_serial"
    local is_parallel=$parallel_mode
    if [[ $is_parallel -eq 1 ]] && [[ $MAX_CONCURRENT -gt 1 ]]; then
        run_task_fn="run_task_parallel"
    else
        # -p 1 或普通串行，统一使用串行模式
        is_parallel=0
    fi
    
    # 预上传所有模型到共享目录（串行和并行模式都使用共享模型机制）
    # 优势：同一任务的多个数据集复用同一个模型，避免重复上传
    CACHED_MODELS=""  # 本地缓存：记录已上传的模型路径（格式: "本地路径:远程路径;..."）
    log_info "========== 预上传模型文件 =========="
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local prefix="${line:0:1}"
        [[ "$prefix" != "*" ]] && continue  # 只处理任务行
        
        local content="${line:1}"
        IFS='|' read -r task_dir _plugin _ds_count <<< "$content"
        
        # 跳过被标记为 .skip 的任务
        [[ -f "$SCRIPT_DIR/$task_dir/.skip" ]] && continue
        
        if preupload_model "$task_dir"; then
            cache_model_set "$task_dir" "$(get_cached_model_path "$task_dir")"
        fi
    done < "$TASK_LIST_FILE"
    log_info "模型预上传完成"
    echo ""
    
    log_info "========== 开始执行任务 =========="
    
    # 记录主进程 PID（供监控检测）
    echo "$$" > "$MAIN_PID_FILE"
    
    # 按列表顺序执行任务
    local current_task=""
    local current_plugin=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local prefix="${line:0:1}"
        local content="${line:1}"
        
        case "$prefix" in
            # 任务行
            '*') 
                IFS='|' read -r current_task current_plugin _ds_count <<< "$content"
                
                # 检查是否有 .skip 标记文件
                if [[ -f "$SCRIPT_DIR/$current_task/.skip" ]]; then
                    log_warn "跳过任务（.skip 标记）: $current_task"
                    current_task=""  # 标记为跳过
                    continue
                fi
                
                log_info "任务: $current_task"
                ;;
            # 数据集行（包含状态）
            '-')  
                [[ -z "$current_task" ]] && continue  # 任务被跳过
                
                local dataset _status
                IFS='|' read -r dataset _status <<< "$content"
                
                # 检查任务是否已完成
                if is_run_completed "$current_task/$dataset"; then
                    log_info "  跳过已完成: $dataset"
                    ((total_skipped++)) || true
                    continue
                fi
                
                # 并发模式下等待槽位
                if [[ $is_parallel -eq 1 ]]; then
                    wait_for_slot
                    $run_task_fn "$current_task" "$dataset" "$current_plugin" "$(cache_model_get "$current_task")"
                    ((total_started++)) || true
                else
                    # 串行模式：传入共享模型路径（避免重复上传）
                    if $run_task_fn "$current_task" "$dataset" "$current_plugin" "$(cache_model_get "$current_task")"; then
                        ((total_success++)) || true
                    else
                        ((total_failed++)) || true
                    fi
                fi
                ;;
            # 汇总行
            '+')  
                ;;
        esac
    done < "$TASK_LIST_FILE"
    
    # 并发模式下等待所有任务完成
    if [[ $is_parallel -eq 1 ]]; then
        wait_all_tasks
        # 统计结果
        if [[ -f "$FAILED_TASKS_FILE" ]]; then
            total_failed=$(wc -l < "$FAILED_TASKS_FILE")
        fi
        total_success=$((total_started - total_failed))
    fi
    
    # 全部任务完成后清理共享模型（如果配置为2）
    if [[ "$CLEANUP_SHARED_MODELS" -eq 2 ]]; then
        cleanup_all_shared_models
    fi
    
    # ========== 汇总报告 ==========
    echo ""
    echo "============================================================"
    echo "                    执行完成汇总"
    echo "============================================================"
    echo "  结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ $is_parallel -eq 1 ]]; then
        echo "  执行模式: 并发 (最大并发数: $MAX_CONCURRENT)"
        echo "  启动任务: $total_started"
    else
        echo "  执行模式: 串行"
    fi
    echo "  成功: $total_success"
    echo "  失败: $total_failed"
    echo "  跳过: $total_skipped"
    echo "  日志: $LOG_FILE"
    # 只在显式指定保存日志时才显示详细日志目录
    if [[ $SAVE_RUN_LOGS -eq 1 ]]; then
        echo "  任务详细日志: $RUN_LOGS_DIR/"
    fi
    if [[ -f "$FAILED_TASKS_FILE" ]]; then
        echo "  失败任务: $FAILED_TASKS_FILE"
    fi
    echo "============================================================"
    echo ""
    
    # 清理锁文件和锁目录
    rm -f "$LOG_LOCK_FILE"
    rm -f "$TASK_LIST_LOCK_FILE"
    rm -f "$MAIN_PID_FILE"  # 清理主进程 PID 文件
    rmdir "$LOCK_DIR" 2>/dev/null || true  # 尝试删除锁目录（如果为空）
    
    # 返回是否有失败
    [[ $total_failed -eq 0 ]]
}

# -------------------------------- 监控模式 --------------------------------

monitor_mode() {
    local interval="${1:-0.5}"  # 默认 0.5 秒刷新一次，更流畅的实时更新
    
    set +e
    
    # 检查任务列表
    if [[ ! -f "$TASK_LIST_FILE" ]]; then
        echo "任务列表不存在，正在生成..."
        generate_task_list
    fi
    
    # ===== ANSI 转义码定义 =====
    local CLEAR_SCREEN="\033[2J"        # 清屏
    local CURSOR_HOME="\033[H"          # 光标移到起始位置 (1,1)
    local CLEAR_LINE="\033[K"           # 清除当前行（从光标到行尾）
    local CURSOR_HIDE="\033[?25l"       # 隐藏光标
    local CURSOR_SHOW="\033[?25h"       # 显示光标
    
    # 捕获退出信号，确保恢复光标显示
    trap 'echo -e "$CURSOR_SHOW"; set -e; exit' INT TERM EXIT
    
    # ===== 初始化：清屏、定位、隐藏光标 =====
    # 关键：使用 printf 确保跨终端兼容性
    printf "%b%b%b" "${CLEAR_SCREEN}" "${CURSOR_HOME}" "${CURSOR_HIDE}"
    
    # ===== VSCode 终端兼容性处理 =====
    # 坑点：VSCode集成终端会将命令输出折叠成标题栏，占据屏幕顶部1-2行
    # 解决方案：预留2行空白，让实际内容从第3行开始，避免被折叠栏遮挡
    # 标准终端（如macOS Terminal.app）不受影响
    printf "\n\n"
    local vscode_offset=2  # 所有行号统一偏移量
    
    # 记录任务列表的行数（动态变化）
    local task_list_lines=0
    local prev_running_lines=1  # 记录上次运行任务区域的行数
    local first_render=1
    local prev_task_output=""  # 缓存上次的任务列表内容，用于对比变化
    
    # ===== 界面结构说明 =====
    # 固定布局（行号从 1+vscode_offset 开始）：
    #   第 3 行: ╔═══╗ 顶部边框
    #   第 4 行: 标题 + 时间
    #   第 5 行: ╠═══╣ 分隔线
    #   第 6~N 行: 任务列表（动态）
    #   第 N+1 行: ╠═══╣ 分隔线
    #   第 N+2 行: Progress 进度条
    #   第 N+3 行: Tasks 统计
    #   第 N+4 行: ╠═══╣ 分隔线
    #   第 N+5 行: Running 当前任务
    #   第 N+6 行: ╚═══╝ 底部边框
    #   第 N+7 行: 日志标题
    #   第 N+8~N+11 行: 日志内容（4行）
    #   第 N+12 行: 底部提示
    
    while true; do
        # ===== 检测主进程是否还在运行 =====
        # 每次循环都重新读取 main_pid，以防监控启动时主进程还没记录 PID
        local main_pid=""
        if [[ -f "$MAIN_PID_FILE" ]]; then
            main_pid=$(head -1 "$MAIN_PID_FILE" 2>/dev/null | tr -cd '0-9')
        fi
        
        if [[ -n "$main_pid" ]] && ! kill -0 "$main_pid" 2>/dev/null; then
            # 主进程已退出 - 先清屏恢复正常显示
            printf "%b%b%b" "${CLEAR_SCREEN}" "${CURSOR_HOME}" "${CURSOR_SHOW}"
            echo ""
            echo "============================================================"
            printf "%b⚠  主进程已退出 (PID: %s)%b\n" "${YELLOW}" "$main_pid" "${NC}"
            echo "============================================================"
            echo ""
            echo "可能原因："
            echo "  1. 所有任务已完成"
            echo "  2. 使用 --stop 主动停止"
            echo "  3. 主进程被意外终止（如 Ctrl+C 或 kill）"
            echo "  4. 发生错误导致主进程退出"
            echo ""
            echo "检查日志: $LOG_FILE"
            echo "查看任务列表: ./task_run.sh -l"
            echo ""
            break
        fi
        
        # ===== 收集最新状态（直接遍历，内联实现）=====
        local total_tasks=0
        local total_completed=0
        local total_failed=0
        local total_all=0
        local running_tasks_list=""
        local running_tasks_detail=""
        local task_output=""
        
        local idx=0
        local current_task=""
        local current_plugin=""
        local current_full_path=""
        local task_completed=0
        local task_total=0
        
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            
            local prefix="${line:0:1}"
            local content="${line:1}"
            
            case "$prefix" in
                '*')
                    # 输出上一个任务
                    if [[ -n "$current_task" ]]; then
                        local status_icon="○"
                        local status_color="$DIM"
                        local skip_mark=""
                        
                        if [[ -f "$current_full_path/.skip" ]]; then
                            skip_mark=" ${DIM}[SKIP]${NC}"
                        fi
                        
                        if [[ "$task_total" -gt 0 ]] && [[ "$task_completed" -eq "$task_total" ]]; then
                            status_icon="✓"
                            status_color="$GREEN"
                        elif [[ "$task_completed" -gt 0 ]]; then
                            status_icon="◐"
                            status_color="$YELLOW"
                        fi
                        
                        local plugin_display="${current_plugin:-no-plugin}"
                        task_output+="  ${status_color}${status_icon}${NC} (${task_completed}/${task_total}) ${current_task} ${DIM}[${plugin_display}]${NC}${skip_mark}"$'\n'
                    fi
                    
                    IFS='|' read -r current_task current_plugin task_ds_count <<< "$content"
                    current_full_path="$SCRIPT_DIR/$current_task"
                    task_completed=0
                    task_total=0
                    ((idx++)) || true
                    ;;
                '-')
                    ((task_total++)) || true
                    ((total_all++)) || true
                    
                    local dataset status
                    IFS='|' read -r dataset status <<< "$content"
                    
                    if [[ "${status:-0}" -eq 2 ]]; then
                        ((task_completed++)) || true
                        ((total_completed++)) || true
                    elif [[ "${status:-0}" -eq 3 ]]; then
                        ((total_failed++)) || true
                    fi
                    
                    # 收集运行中任务
                    if [[ "${status:-0}" -eq 1 ]]; then
                        local task_path="$current_task/$dataset"
                        running_tasks_list+="$task_path"$'\n'
                        
                        local full_path="$SCRIPT_DIR/$current_task/$dataset"
                        local state_file="$full_path/${RUN_STATE_NAME}.state"
                        local batch_info=""
                        if [[ -f "$state_file" ]]; then
                            # 读取第 2-9 行（8 个 RUNNING_ 字段），一次性提取所有字段
                            # 字段顺序：TOTAL_BATCHES|FAILED_BATCHES|CURRENT_BATCH|BATCH_TOTAL|BATCH_COMPLETED|BATCH_STATE|RETRY_COUNT|TIMESTAMP
                            batch_info=$(sed -n '2,9p' "$state_file" | cut -d'=' -f2 | tr '\n' '|' | sed 's/|$//')
                        fi
                        # 即使没有 state 文件或字段为空，也添加到 detail（显示默认进度）
                        running_tasks_detail+="$task_path|$batch_info"$'\n'
                    fi
                    ;;
                '+')
                    # 输出最后一个任务
                    if [[ -n "$current_task" ]]; then
                        local status_icon="○"
                        local status_color="$DIM"
                        local skip_mark=""
                        
                        if [[ -f "$current_full_path/.skip" ]]; then
                            skip_mark=" ${DIM}[SKIP]${NC}"
                        fi
                        
                        if [[ "$task_total" -gt 0 ]] && [[ "$task_completed" -eq "$task_total" ]]; then
                            status_icon="✓"
                            status_color="$GREEN"
                        elif [[ "$task_completed" -gt 0 ]]; then
                            status_icon="◐"
                            status_color="$YELLOW"
                        fi
                        
                        local plugin_display="${current_plugin:-no-plugin}"
                        task_output+="  ${status_color}${status_icon}${NC} (${task_completed}/${task_total}) ${current_task} ${DIM}[${plugin_display}]${NC}${skip_mark}"$'\n'
                    fi
                    
                    IFS='|' read -r _summary total_tasks _total_ds <<< "$content"
                    ;;
            esac
        done < "$TASK_LIST_FILE"
        
        local new_task_lines
        new_task_lines=$(echo "$task_output" | wc -l | tr -d ' ')
        
        # ===== 计算各区域的行号 =====
        # 关键：统一的行号计算系统，避免行号混乱
        local line=$((1 + vscode_offset))
        local top_border_line=$line
        local title_line=$((line + 1))
        local top_sep_line=$((line + 2))
        local task_start_line=$((line + 3))
        
        # 任务列表后的行号（动态计算）
        local task_end_line=$((task_start_line + new_task_lines - 1))
        local mid_sep1_line=$((task_end_line + 1))
        local progress_line=$((mid_sep1_line + 1))
        local stats_line=$((progress_line + 1))
        local mid_sep2_line=$((stats_line + 1))
        local running_line=$((mid_sep2_line + 1))
        
        # 计算运行任务需要的行数（标题1行 + 任务列表N行）
        local running_task_count=0
        if [[ -n "$running_tasks_list" ]]; then
            running_task_count=$(echo "$running_tasks_list" | grep -c . 2>/dev/null || echo 0)
        fi
        local running_lines=1
        if [[ $running_task_count -gt 0 ]]; then
            running_lines=$((1 + running_task_count))  # 标题 + 任务列表
        fi
        
        local bottom_border_line=$((running_line + running_lines))
        local log_title_line=$((bottom_border_line + 1))
        local log_start_line=$((log_title_line + 1))
        local footer_line=$((log_start_line + 4))
        
        # ===== 清除旧内容 =====
        # 判断任务列表是否变化
        local task_list_changed=1
        if [[ "$task_output" == "$prev_task_output" ]]; then
            task_list_changed=0
        fi
        
        if [[ $first_render -eq 1 ]]; then
            # 首次渲染：已经清屏，无需额外清除
            :
        else
            # 后续更新：清除可能变化的区域
            if [[ $task_list_changed -eq 1 ]]; then
                # 清除旧任务列表区域
                local old_task_end=$((task_start_line + task_list_lines - 1))
                for ((i=task_start_line; i<=old_task_end; i++)); do
                    printf "\033[%d;1H%b" "$i" "${CLEAR_LINE}"
                done
            fi
            
            # 清除旧的运行任务区域（如果行数变化）
            if [[ $prev_running_lines -ne $running_lines ]]; then
                local prev_running_end=$((running_line + prev_running_lines - 1))
                for ((i=running_line; i<=prev_running_end; i++)); do
                    printf "\033[%d;1H%b" "$i" "${CLEAR_LINE}"
                done
            fi
        fi
        
        # 更新任务列表行数和缓存
        task_list_lines=$new_task_lines
        prev_task_output="$task_output"
        prev_running_lines=$running_lines
        
        # ===== 绘制界面 =====
        # 关键：使用 printf 避免换行，确保跨终端兼容性
        # 坑点：不能自动换行，否则会导致终端滚动
        
        # 顶部区域
        printf "\033[%d;1H╔══════════════════════════════════════════════════════════════╗" "$top_border_line"
        printf "\033[%d;1H              📊 Task Monitor  %s" "$title_line" "$(date '+%H:%M:%S')"
        printf "\033[%d;1H╠══════════════════════════════════════════════════════════════╣" "$top_sep_line"
        
        # 任务列表 - 只有变化时才重绘
        if [[ $task_list_changed -eq 1 ]]; then
            local line_idx=0
            while IFS= read -r task_line; do
                printf "\033[%d;1H%b%b" "$((task_start_line + line_idx))" "$task_line" "${CLEAR_LINE}"
                ((line_idx++)) || true
            done <<< "$task_output"
        fi
        
        # 中间区域（进度条）- 直接覆盖，末尾清除多余内容
        printf "\033[%d;1H╠══════════════════════════════════════════════════════════════╣" "$mid_sep1_line"
        
        local progress=0
        [[ $total_all -gt 0 ]] && progress=$((total_completed * 100 / total_all))
        local bar=""
        local filled=$((progress * 30 / 100))
        for ((i=0; i<filled; i++)); do bar+="█"; done
        for ((i=filled; i<30; i++)); do bar+="░"; done
        
        printf "\033[%d;1H  Progress: [%b%s%b%s%b] %d%%%b" "$progress_line" "${GREEN}" "${bar:0:$filled}" "${DIM}" "${bar:$filled}" "${NC}" "$progress" "${CLEAR_LINE}"
        local stats_text="  Tasks: $total_tasks | Datasets: $total_completed/$total_all completed"
        if [[ $total_failed -gt 0 ]]; then
            stats_text+=", ${RED}$total_failed failed${NC}"
        fi
        printf "\033[%d;1H%b%b" "$stats_line" "$stats_text" "${CLEAR_LINE}"
        printf "\033[%d;1H╠══════════════════════════════════════════════════════════════╣" "$mid_sep2_line"
        
        # 运行状态 - 显示所有运行中的任务列表
        if [[ -n "$running_tasks_list" ]]; then
            # 统计运行中的任务数量
            local task_count
            task_count=$(echo "$running_tasks_list" | grep -c . || echo 0)
            
            # 显示标题
            if [[ "$task_count" -eq 1 ]]; then
                echo -ne "\033[${running_line};1H  ${YELLOW}▶ Running Task:${NC}${CLEAR_LINE}"
            else
                echo -ne "\033[${running_line};1H  ${YELLOW}▶ Running Tasks ($task_count):${NC}${CLEAR_LINE}"
            fi
            
            # 显示所有运行中的任务（带批次信息）
            local line_offset=1
            while IFS= read -r task_path; do
                [[ -z "$task_path" ]] && continue
                
                # 提取批次信息和进度
                # 概念说明：
                # - RUNNING_CURRENT_BATCH: 当前正在处理的批次号（1-based）
                # - RUNNING_TOTAL_BATCHES: 总批次数（数据量 / MAX_BATCH_SIZE）
                # - RUNNING_BATCH_COMPLETED: 当前批次内已完成的评测项数
                # - RUNNING_BATCH_TOTAL: 当前批次的总评测项数（即 MAX_BATCH_SIZE，最后一批可能更小）
                # - RUNNING_BATCH_STATE: 批次状态（0=上传中, -2=远程执行中, -1=开始下载, >0=已下载数量）
                # 批次进度信息读取说明：
                # batch_info 格式（固定位置，用 | 分隔）：
                #   位置 0: RUNNING_TOTAL_BATCHES       (总批次数)
                #   位置 1: RUNNING_FAILED_BATCHES      (累计失败批次数)
                #   位置 2: RUNNING_CURRENT_BATCH       (当前批次号 1-based)
                #   位置 3: RUNNING_BATCH_TOTAL         (当前批次总评测项数)
                #   位置 4: RUNNING_BATCH_COMPLETED     (当前批次已完成评测项数)
                #   位置 5: RUNNING_BATCH_STATE         (批次状态: 0=上传中, -2=远程执行中, -1=开始下载, >0=已下载数量)
                #   位置 6: RUNNING_RETRY_COUNT         (当前批次累计重试次数)
                #   位置 7: RUNNING_TIMESTAMP           (最后更新的 Unix 时间戳)
                # 完成条件：
                # - 当前批次完成：RUNNING_BATCH_COMPLETED == RUNNING_BATCH_TOTAL
                # - 所有批次完成：RUNNING_CURRENT_BATCH == RUNNING_TOTAL_BATCHES（且当前批次完成）
                local batch_info=""
                if [[ -n "$running_tasks_detail" ]]; then
                    local detail_line
                    detail_line=$(echo "$running_tasks_detail" | grep "^${task_path}|" | head -1)
                    if [[ "$detail_line" == *"|"* ]]; then
                        local batch_str="${detail_line#*|}"
                        # 使用固定位置提取字段（性能优化：避免多次 grep/cut 子进程）
                        IFS='|' read -r total_batches _ current_batch batch_total batch_completed batch_state _ _ <<< "$batch_str"
                        
                        if [[ -n "$current_batch" && -n "$total_batches" ]]; then
                            # 显示：[Batch 当前批次/总批次] 状态信息
                            batch_info=" ${CYAN}[Batch $current_batch/$total_batches]${NC}"
                            
                            # 根据 batch_state 显示详细状态
                            if [[ -n "$batch_state" ]]; then
                                if [[ "$batch_state" == "-2" ]]; then
                                    # 远程执行中
                                    batch_info+=" ${YELLOW}(执行中)${NC}"
                                elif [[ "$batch_state" == "-1" ]]; then
                                    # 开始下载
                                    batch_info+=" ${GREEN}(下载中)${NC}"
                                elif [[ "$batch_state" -gt 0 ]] && [[ -n "$batch_total" ]] && [[ "$batch_total" -gt 0 ]]; then
                                    # 下载进度 (batch_state > 0 表示已下载数量)
                                    local download_progress=$((batch_state * 100 / batch_total))
                                    batch_info+=" ${GREEN}(下载${download_progress}%)${NC}"
                                elif [[ "$batch_state" == "0" ]] && [[ -n "$batch_completed" ]] && [[ -n "$batch_total" ]] && [[ "$batch_total" -gt 0 ]]; then
                                    # 上传进度 (batch_state == 0 表示上传阶段)
                                    local upload_progress=$((batch_completed * 100 / batch_total))
                                    batch_info+=" ${DIM}(上传${upload_progress}%)${NC}"
                                fi
                            else
                                # 没有 state 信息时，使用旧的显示方式
                                local progress=0
                                if [[ -n "$batch_completed" && -n "$batch_total" && "$batch_total" -gt 0 ]]; then
                                    progress=$((batch_completed * 100 / batch_total))
                                fi
                                batch_info+=" ${DIM}(${progress}%)${NC}"
                            fi
                        fi
                    fi
                fi
                
                # 显示任务行
                local display_line=$((running_line + line_offset))
                printf "\033[%d;1H    • %b%b%b" "$display_line" "$task_path" "$batch_info" "${CLEAR_LINE}"
                ((line_offset++)) || true
            done <<< "$running_tasks_list"
        else
            printf "\033[%d;1H  %bNo task running%b%b" "$running_line" "${DIM}" "${NC}" "${CLEAR_LINE}"
        fi
        
        printf "\033[%d;1H╚══════════════════════════════════════════════════════════════╝" "$bottom_border_line"
        
        # 日志区域
        printf "\033[%d;1H%b─── Recent Log ───%b" "$log_title_line" "${DIM}" "${NC}"
        
        # 坑点：日志文件可能包含监控界面的输出（边框、任务列表等）
        # 解决方案：只提取以 [日期时间] 开头的真正日志行
        local log_lines
        log_lines=$(grep '^\[20' "$LOG_FILE" 2>/dev/null | tail -4 || true)
        
        # 固定输出4行日志（减少闪烁：每行直接覆盖+清除尾部）
        local line_num=0
        while IFS= read -r log_line; do
            # 不截断日志，显示完整内容（超出边框也可以）
            printf "\033[%d;1H%b%b%b" "$((log_start_line + line_num))" "$log_line" "${NC}" "${CLEAR_LINE}"
            ((line_num++)) || true
        done <<< "$log_lines"
        
        # 填充空行到4行（避免旧日志残留）
        while [[ $line_num -lt 4 ]]; do
            printf "\033[%d;1H%b" "$((log_start_line + line_num))" "${CLEAR_LINE}"
            ((line_num++)) || true
        done
        
        # 底部提示
        printf "\033[%d;1H%bRefresh: %ss | Ctrl+C to exit%b" "$footer_line" "${DIM}" "$interval" "${NC}"
        
        # 坑点：光标停留在底部可能触发滚动
        # 解决方案：将光标移回预留区域的第1行
        printf "\033[1;1H"
        
        first_render=0
        sleep "$interval"
    done
}

# -------------------------------- 安全停止 --------------------------------

# 安全停止后台运行的主进程
stop_execution() {
    set +e
    
    echo ""
    echo "============================================================"
    echo "                    停止执行任务"
    echo "============================================================"
    echo ""
    
    # 检查主进程是否存在
    if [[ ! -f "$MAIN_PID_FILE" ]]; then
        echo "未找到运行中的主进程（$MAIN_PID_FILE 不存在）"
        echo ""
        return 0
    fi
    
    local main_pid
    main_pid=$(head -1 "$MAIN_PID_FILE" 2>/dev/null | tr -cd '0-9')
    
    if [[ -z "$main_pid" ]]; then
        echo "主进程 PID 文件为空"
        rm -f "$MAIN_PID_FILE"
        return 0
    fi
    
    # 检查进程是否还在运行
    if ! kill -0 "$main_pid" 2>/dev/null; then
        echo "主进程 $main_pid 已不存在"
        rm -f "$MAIN_PID_FILE"
        echo ""
        return 0
    fi
    
    echo "找到运行中的主进程: PID $main_pid"
    echo ""
    
    # 发送 SIGTERM 信号（优雅退出）
    echo "正在发送停止信号 (SIGTERM)..."
    kill -TERM "$main_pid" 2>/dev/null
    
    # 等待进程结束（最多10秒）
    local count=0
    while kill -0 "$main_pid" 2>/dev/null && [[ $count -lt 20 ]]; do
        sleep 0.5
        ((count++))
        echo -n "."
    done
    echo ""
    echo ""
    
    # 检查是否成功退出
    if kill -0 "$main_pid" 2>/dev/null; then
        echo "主进程未响应 SIGTERM，发送 SIGKILL 强制终止..."
        kill -KILL "$main_pid" 2>/dev/null
        sleep 1
    fi
    
    if kill -0 "$main_pid" 2>/dev/null; then
        printf "%b✗ 无法终止主进程 %s%b\n" "${RED}" "$main_pid" "${NC}"
        echo ""
        return 1
    fi
    
    printf "%b✓ 主进程已终止%b\n" "${GREEN}" "${NC}"
    
    # 清理所有子进程（RUN_SCRIPT）
    echo ""
    echo "正在清理子进程..."
    local child_count=0
    if [[ -f "$PID_FILE" ]]; then
        while read -r pid; do
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null
                ((child_count++))
            fi
        done < "$PID_FILE"
    fi
    
    if [[ $child_count -gt 0 ]]; then
        echo "已终止 $child_count 个子进程"
        sleep 1
    fi
    
    # 将所有 running 状态改回 pending
    echo ""
    echo "正在恢复任务状态..."
    if [[ -f "$TASK_LIST_FILE" ]]; then
        local running_count=0
        running_count=$(grep -c "^-.*|1$" "$TASK_LIST_FILE" 2>/dev/null || echo 0)
        
        if [[ $running_count -gt 0 ]]; then
            sed -i '' 's/^\(-[^|]*\)|1$/\1|0/' "$TASK_LIST_FILE"
            echo "已将 $running_count 个 running 状态改回 pending"
        else
            echo "没有 running 状态的任务"
        fi
    fi
    
    # 清理 PID 文件
    rm -f "$MAIN_PID_FILE"
    rm -f "$PID_FILE"
    
    echo ""
    printf "%b✓ 清理完成%b\n" "${GREEN}" "${NC}"
    echo ""
    echo "提示："
    echo "  - 查看任务状态: ./task_run.sh -l"
    echo "  - 继续执行任务: ./task_run.sh -p N"
    echo ""
    
    set -e
}

# -------------------------------- 显示任务列表 --------------------------------

# 显示任务列表（直接输出，无缓存开销）
show_task_list() {
    set +e
    
    if [[ ! -f "$TASK_LIST_FILE" ]]; then
        log_warn "任务列表不存在，请先运行: $0 --scan"
        return 1
    fi
    
    echo ""
    echo "============================================================"
    echo "                    任务列表"
    echo "============================================================"
    
    # 直接流式输出（简单高效）
    local idx=0
    local total_tasks=0
    local total_completed=0
    local total_failed=0
    local total_all=0
    local current_task=""
    local current_plugin=""
    local current_full_path=""
    local task_completed=0
    local task_total=0
    
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        local prefix="${line:0:1}"
        local content="${line:1}"
        
        case "$prefix" in
            '*')
                # 输出上一个任务
                if [[ -n "$current_task" ]]; then
                    local status_icon="○"
                    local status_color="$DIM"
                    local skip_mark=""
                    
                    if [[ -f "$current_full_path/.skip" ]]; then
                        skip_mark=" ${DIM}[SKIP]${NC}"
                    fi
                    
                    if [[ "$task_total" -gt 0 ]] && [[ "$task_completed" -eq "$task_total" ]]; then
                        status_icon="✓"
                        status_color="$GREEN"
                    elif [[ "$task_completed" -gt 0 ]]; then
                        status_icon="◐"
                        status_color="$YELLOW"
                    fi
                    
                    local plugin_display="${current_plugin:-no-plugin}"
                    printf "  ${status_color}${status_icon}${NC} %2d. (${task_completed}/${task_total}) ${current_task} ${DIM}[${plugin_display}]${NC}${skip_mark}\n" "$idx"
                fi
                
                IFS='|' read -r current_task current_plugin task_ds_count <<< "$content"
                current_full_path="$SCRIPT_DIR/$current_task"
                task_completed=0
                task_total=0
                ((idx++)) || true
                ;;
            '-')
                ((task_total++)) || true
                ((total_all++)) || true
                
                local dataset status
                IFS='|' read -r dataset status <<< "$content"
                
                if [[ "${status:-0}" -eq 2 ]]; then
                    ((task_completed++)) || true
                    ((total_completed++)) || true
                elif [[ "${status:-0}" -eq 3 ]]; then
                    ((total_failed++)) || true
                fi
                ;;
            '+')
                # 输出最后一个任务
                if [[ -n "$current_task" ]]; then
                    local status_icon="○"
                    local status_color="$DIM"
                    local skip_mark=""
                    
                    if [[ -f "$current_full_path/.skip" ]]; then
                        skip_mark=" ${DIM}[SKIP]${NC}"
                    fi
                    
                    if [[ "$task_total" -gt 0 ]] && [[ "$task_completed" -eq "$task_total" ]]; then
                        status_icon="✓"
                        status_color="$GREEN"
                    elif [[ "$task_completed" -gt 0 ]]; then
                        status_icon="◐"
                        status_color="$YELLOW"
                    fi
                    
                    local plugin_display="${current_plugin:-no-plugin}"
                    printf "  ${status_color}${status_icon}${NC} %2d. (${task_completed}/${task_total}) ${current_task} ${DIM}[${plugin_display}]${NC}${skip_mark}\n" "$idx"
                fi
                
                IFS='|' read -r _summary total_tasks _total_ds <<< "$content"
                ;;
        esac
    done < "$TASK_LIST_FILE"
    
    echo "============================================================"
    local summary_text="  总计: $total_tasks 个任务, $total_completed/$total_all 数据集已完成"
    if [[ $total_failed -gt 0 ]]; then
        summary_text+=", ${RED}$total_failed 失败${NC}"
    fi
    echo "$summary_text"
    echo "============================================================"
    echo ""
    set -e
}

# -------------------------------- 清理和重置 --------------------------------

# 删除所有数据集的状态文件
# + 只在数据集目录下删除状态文件，不递归进入数据集子目录
remove_all_state_files() {
    local state_name
    state_name=$(get_run_state_name)
    local complete_name
    complete_name=$(get_run_state_complete_name)
    local state_count=0
    
    # 扫描任务目录
    local tasks
    tasks=$(scan_task_dirs)
    
    if [[ -n "$tasks" ]]; then
        while IFS= read -r task_dir; do
            [[ -z "$task_dir" ]] && continue
            
            # 读取任务配置
            local task_config
            task_config=$(build_task_config "$task_dir")
            
            # 收集数据集列表
            local datasets_output
            datasets_output=$(collect_datasets "$task_dir" "$task_config" 2>/dev/null)
            
            # 遍历数据集（跳过第一行的计数）
            # 使用 < <() 进程替换而非管道，避免创建子shell导致 state_count 变量无法更新
            while IFS= read -r dataset; do
                [[ -z "$dataset" ]] && continue
                
                local dataset_path="$SCRIPT_DIR/$task_dir/$dataset"
                [[ -d "$dataset_path" ]] || continue
                
                local state_file="$dataset_path/$state_name"
                local complete_file="$dataset_path/$complete_name"
                
                [[ -f "$state_file" ]] && rm -f "$state_file" && ((state_count++))
                [[ -f "$complete_file" ]] && rm -f "$complete_file" && ((state_count++))
            done < <(echo "$datasets_output" | tail -n +2)
        done <<< "$tasks"
    fi
    
    echo "$state_count"
}

# 彻底清理所有生成的文件
clean_all() {
    echo ""
    echo "============================================================"
    echo "          清理所有生成的文件"
    echo "============================================================"
    echo ""
    
    # 首先删除所有锁文件，避免后续操作被卡住
    rm -f "$TASK_LIST_LOCK_FILE" "$LOG_LOCK_FILE" 2>/dev/null
    
    # 1. 先清理其他文件（log_info 会通过 tee 输出到屏幕）
    log_info "清理本地文件..."
    
    # 清理任务列表
    [[ -f "$TASK_LIST_FILE" ]] && rm -f "$TASK_LIST_FILE" && log_info "  ✓ 删除任务列表: $TASK_LIST_FILE"
    [[ -f "$TASK_LIST_LOCK_FILE" ]] && rm -f "$TASK_LIST_LOCK_FILE" && log_info "  ✓ 删除任务列表锁文件: $TASK_LIST_LOCK_FILE"
    [[ -f "$FAILED_TASKS_FILE" ]] && rm -f "$FAILED_TASKS_FILE" && log_info "  ✓ 删除失败任务列表: $FAILED_TASKS_FILE"
    [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE" && log_info "  ✓ 删除进程ID文件: $PID_FILE"
    
    # 清理锁目录（如果为空）
    if [[ -d "$LOCK_DIR" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null && log_info "  ✓ 删除锁目录: $LOCK_DIR" || log_info "  ⚠ 锁目录非空，保留: $LOCK_DIR"
    fi
    
    # 清理详细日志目录
    if [[ -d "$RUN_LOGS_DIR" ]]; then
        rm -rf "$RUN_LOGS_DIR"
        log_info "  ✓ 删除详细日志目录: $RUN_LOGS_DIR"
    fi
    
    # 清理各个数据集下的状态文件和完成文件
    log_info "清理数据集状态文件..."
    local state_count
    state_count=$(remove_all_state_files)
    [[ $state_count -gt 0 ]] && log_info "  ✓ 删除 $state_count 个状态/完成文件"
    
    # 处理输出目录清理
    # 判断 OUT_SUBDIR 是否为统一输出目录（以 . 开头或绝对路径）
    if [[ "$OUT_SUBDIR" == .* ]] || [[ "$OUT_SUBDIR" == /* ]]; then
        # 统一输出目录，无需询问，只给日志说明
        local unified_path
        if [[ "$OUT_SUBDIR" == .* ]]; then
            unified_path="$SCRIPT_DIR/$OUT_SUBDIR"
        else
            unified_path="$OUT_SUBDIR"
        fi
        log_info "输出目录使用统一路径 ($unified_path)，不进行清理"
    else
        # 相对路径（数据集目录下的子目录），询问是否删除
        echo ""
        echo -e "${YELLOW}是否同时删除评测结果输出目录？ (y/N):${NC} \c"
        read -r response
        echo ""  # 换行，避免后续日志和提示在同一行
        response=${response:-n}  # 默认为 n
        
        if [[ "$response" =~ ^[Yy]$ ]]; then
            log_info "清理输出目录..."
            local output_count=0
            
            # 扫描任务目录
            local tasks
            tasks=$(scan_task_dirs)
            
            if [[ -n "$tasks" ]]; then
                while IFS= read -r task_dir; do
                    [[ -z "$task_dir" ]] && continue
                    
                    # 读取任务配置
                    local task_config
                    task_config=$(build_task_config "$task_dir")
                    
                    # 收集数据集列表
                    local datasets_output
                    datasets_output=$(collect_datasets "$task_dir" "$task_config" 2>/dev/null)
                    
                    # 遍历数据集
                    while IFS= read -r dataset; do
                        [[ -z "$dataset" ]] && continue
                        
                        local dataset_path="$SCRIPT_DIR/$task_dir/$dataset"
                        [[ -d "$dataset_path" ]] || continue
                        
                        # 删除输出目录（使用 OUT_SUBDIR 变量）
                        local output_dir="$dataset_path/$OUT_SUBDIR"
                        if [[ -d "$output_dir" ]]; then
                            rm -rf "$output_dir" && ((output_count++))
                        fi
                    done < <(echo "$datasets_output" | tail -n +2)
                done <<< "$tasks"
            fi
            
            [[ $output_count -gt 0 ]] && log_info "  ✓ 删除 $output_count 个输出目录"
        else
            log_info "保留输出目录"
        fi
    fi
    
    # 远程文件清理（直接清理，不询问）
    echo ""
    log_info "清理远程文件..."
    
    # 清理所有远程工作目录（task_*）
    if [[ -n "${DRY_RUN:-}" ]] && [[ "${DRY_RUN}" -ge 0 ]]; then
        log_info "  [DRY-RUN] 跳过清理远程工作目录"
    else
        local remote_dirs
        remote_dirs=$(ssh -n -p "$SSH_PORT" "$SSH_HOST" "ls -d ${REMOTE_TASK_HOME}/task_* 2>/dev/null || true")
        if [[ -n "$remote_dirs" ]]; then
            local dir_count=0
            while IFS= read -r remote_dir; do
                [[ -n "$remote_dir" ]] && ssh -n -p "$SSH_PORT" "$SSH_HOST" "rm -rf '$remote_dir'" && ((dir_count++)) || true
            done <<< "$remote_dirs"
            [[ $dir_count -gt 0 ]] && log_info "  ✓ 删除 $dir_count 个远程工作目录"
        fi
    fi
    
    # 清理共享模型目录
    cleanup_all_shared_models
    
    log_info "清理完成！"
    
    # 2. 最后删除日志文件和锁文件（不能用 log_info，直接用 echo 显示）
    if [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
        echo -e "${GREEN}[INFO]   ✓ 删除主日志: $LOG_FILE${NC}"
    fi
    if [[ -f "$LOG_LOCK_FILE" ]]; then
        rm -f "$LOG_LOCK_FILE"
        echo -e "${GREEN}[INFO]   ✓ 删除锁文件: $LOG_LOCK_FILE${NC}"
    fi
    
    # 3. 清理锁目录
    if [[ -d "$LOCK_DIR" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null && echo -e "${GREEN}[INFO]   ✓ 删除锁目录: $LOCK_DIR${NC}" || echo -e "${YELLOW}[WARN]   ⚠ 锁目录非空: $LOCK_DIR${NC}"
    fi
    
    echo ""
    echo "============================================================"
    echo ""
}

# 重置任务状态（删除状态文件，保留其他文件）
reset_tasks() {
    echo ""
    echo "============================================================"
    echo "          重置任务状态"
    echo "============================================================"
    echo ""
    
    log_info "删除数据集状态文件..."
    local state_count
    state_count=$(remove_all_state_files)
    [[ $state_count -gt 0 ]] && log_info "  ✓ 删除 $state_count 个状态/完成文件"
    
    # 重新生成任务列表（更新完成状态）
    log_info "重新生成任务列表..."
    generate_task_list
    
    echo ""
    log_info "重置完成！所有任务可重新执行"
    echo "============================================================"
    echo ""
    
    # 显示任务列表
    show_task_list
}

# 导出结果到指定目录
export_results() {
    local export_dir="$1"
    
    echo ""
    echo "============================================================"
    echo "          导出评测结果"
    echo "============================================================"
    echo ""
    
    # 检查是否为统一输出目录模式
    if [[ "$OUT_SUBDIR" == .* ]] || [[ "$OUT_SUBDIR" == /* ]]; then
        echo -e "${RED}错误: 当前使用统一输出目录模式${NC}"
        echo "  OUT_SUBDIR: $OUT_SUBDIR"
        echo ""
        echo "统一输出目录模式下，结果已集中在统一位置，无需导出。"
        echo "请直接使用统一输出目录中的结果。"
        echo ""
        exit 1
    fi
    
    log_info "检测到普通路径模式 (OUT_SUBDIR: $OUT_SUBDIR)"
    log_info "导出目录: $export_dir"
    echo ""
    
    # 询问是否需要压缩
    echo -e "${YELLOW}是否需要压缩打包输出结果？ (y/N):${NC} \c"
    read -r compress_response
    echo ""
    compress_response=${compress_response:-n}
    
    local use_compression=false
    if [[ "$compress_response" =~ ^[Yy]$ ]]; then
        use_compression=true
        log_info "将使用 zip 压缩方式导出"
    else
        log_info "将直接复制文件"
    fi
    echo ""
    
    # 扫描任务目录
    local tasks
    tasks=$(scan_task_dirs)
    
    if [[ -z "$tasks" ]]; then
        log_info "未找到任何任务"
        return 0
    fi
    
    local total_exported=0
    local total_tasks=0
    local export_dir_created=false
    
    log_info "开始扫描输出目录..."
    
    while IFS= read -r task_dir; do
        [[ -z "$task_dir" ]] && continue
        
        # 读取任务配置
        local task_config
        task_config=$(build_task_config "$task_dir")
        
        # 收集数据集列表
        local datasets_output
        datasets_output=$(collect_datasets "$task_dir" "$task_config" 2>/dev/null)
        
        # 遍历数据集
        while IFS= read -r dataset; do
            [[ -z "$dataset" ]] && continue
            
            local dataset_path="$SCRIPT_DIR/$task_dir/$dataset"
            local output_path="$dataset_path/$OUT_SUBDIR"
            
            # 检查输出目录是否存在
            if [[ ! -d "$output_path" ]]; then
                continue
            fi
            
            # 首次发现输出目录时，创建导出目录
            if [[ "$export_dir_created" == false ]]; then
                log_info "发现输出目录，创建导出目录: $export_dir"
                mkdir -p "$export_dir"
                export_dir_created=true
                echo ""
            fi
            
            ((total_tasks++))
            
            if [[ "$use_compression" == true ]]; then
                # 压缩方式：以数据集末节点目录名命名 zip 文件
                # 提取数据集的最后一个目录名
                local dataset_name="${dataset##*/}"
                
                # 构建导出路径（包含完整的子路径）
                local export_parent="$export_dir/$task_dir/$dataset"
                local export_parent_dir="${export_parent%/*}"
                mkdir -p "$export_parent_dir"
                
                # zip 文件路径
                local zip_file
                if [[ "$export_parent_dir" == /* ]]; then
                    zip_file="$export_parent_dir/$dataset_name.zip"
                else
                    zip_file="$SCRIPT_DIR/$export_parent_dir/$dataset_name.zip"
                fi
                
                log_info "  压缩: $task_dir/$dataset → $zip_file"
                
                # 使用 zip 压缩（进入输出目录，压缩所有内容）
                (cd "$output_path" && zip -r -q "$zip_file" .) && ((total_exported++))
            else
                # 复制方式：保持完整目录结构
                local export_path="$export_dir/$task_dir/$dataset"
                mkdir -p "$export_path"
                
                log_info "  复制: $task_dir/$dataset → $export_path/"
                
                # 复制所有内容
                cp -r "$output_path"/* "$export_path/" 2>/dev/null && ((total_exported++))
            fi
            
        done < <(echo "$datasets_output" | tail -n +2)
    done <<< "$tasks"
    
    echo ""
    
    # 检查是否找到任何输出目录
    if [[ $total_tasks -eq 0 ]]; then
        log_info "${YELLOW}警告: 未找到任何输出目录 (OUT_SUBDIR: $OUT_SUBDIR)${NC}"
        log_info "请先执行评测任务生成输出结果"
        echo ""
        echo "============================================================"
        echo ""
        return 0
    fi
    
    log_info "导出完成！"
    log_info "  成功: $total_exported / $total_tasks"
    if [[ "$use_compression" == true ]]; then
        log_info "  格式: ZIP 压缩包 (output.zip)"
    else
        log_info "  格式: 直接复制"
    fi
    log_info "  位置: $export_dir"
    echo ""
    echo "============================================================"
    echo ""
}

# -------------------------------- 入口 --------------------------------

# 首次运行时检查依赖（静默模式：仅在工具缺失时提示）
check_and_install_dependencies

show_usage() {
    echo "用法说明:"
    echo "  bash task_run.sh [OPTIONS]"
    echo ""
    echo "选项:"
    echo "  -p, --parallel [N]          并发执行模式 (N为并发数，默认3，N=1等价串行)"
    echo "  --save-logs                 保存任务详细日志到文件"
    echo "  -i, --input-dir DIR         指定数据集子目录名 (默认: yuv)"
    echo "  -o, --output-dir DIR        指定输出子目录名 (默认: output.wp)"
    echo "                              - 普通路径: 作为数据集的相对子目录"
    echo "                              - 以 . 开头: 统一输出到脚本所在目录的相对路径下"
    echo "                              - 绝对路径: 统一输出到指定的绝对路径下"
    echo "                                (统一输出模式自动为每个任务/数据集创建子目录)"
    echo "  -s, --suffix LIST           文件后缀列表，逗号分隔 (默认: _y.bin,_uv.bin)"
    echo "  -b, --batch-size SIZE       每批最大文件数量 (默认: 200)"
    echo "  -m, --monitor [N]           监控模式 (N秒刷新，默认0.5秒)"
    echo "  --stop                      安全停止后台运行的任务"
    echo "  -s, --scan                  扫描并生成任务列表"
    echo "  -l, --list                  显示任务列表"
    echo "  -e, --export DIR            导出普通路径模式的输出结果到指定目录"
    echo "                              (仅支持普通路径模式，统一输出模式请直接使用原目录)"
    echo "  -c, --clean                 彻底清理所有生成的文件（本地+远程）"
    echo "  -r, --reset                 重置任务状态（删除状态文件，可重新执行）"
    echo "  -h, --help                  显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  # 基本执行"
    echo "  bash task_run.sh                          # 串行执行所有任务"
    echo "  bash task_run.sh -p                       # 并发执行 (默认3个并发)"
    echo "  bash task_run.sh -p 5                     # 并发执行 (5个并发)"
    echo "  bash task_run.sh -p 1                     # 串行执行 (等价于无 -p 参数)"
    echo "  bash task_run.sh --save-logs              # 串行执行并保存日志"
    echo "  bash task_run.sh -p 5 --save-logs         # 并发执行并保存日志"
    echo ""
    echo "  # 后台执行与监控"
    echo "  bash task_run.sh -p 2 >/tmp/task.log 2>&1 &  # 后台执行"
    echo "  bash task_run.sh -m                       # 监控进度 (默认0.5秒刷新)"
    echo "  bash task_run.sh -m 2                     # 监控进度 (2秒刷新)"
    echo "  bash task_run.sh --stop                   # 安全停止后台任务"
    echo ""
    echo "  # 高级配置"
    echo "  bash task_run.sh -i raw -o results        # 指定数据集和输出目录名"
    echo "  bash task_run.sh -o .results              # 统一输出到 ./.results/task/dataset/"
    echo "  bash task_run.sh -o /tmp/task_output      # 统一输出到 /tmp/task_output/task/dataset/"
    echo "  bash task_run.sh -s '_left.yuv,_right.yuv' # 指定文件后缀列表"
    echo ""
    echo "  # 管理操作"
    echo "  bash task_run.sh -e ./export_results      # 导出结果到 ./export_results/"
    echo "  bash task_run.sh -r                       # 重置所有任务状态（可重新执行）"
    echo "  bash task_run.sh -c                       # 彻底清理所有生成的文件"
    echo ""
    echo "环境变量:"
    echo "  REMOTE_TASK_HOME            远程任务主目录 (默认: /root)"
    echo "  IN_SUBDIR                   输入数据子目录名 (默认: yuv)"
    echo "  OUT_SUBDIR                  输出子目录名 (默认: output.wp)"
    echo "                              - 普通路径: 相对于数据集目录"
    echo "                              - 以 . 开头: 统一输出（相对于脚本目录）"
    echo "                              - 绝对路径: 统一输出（绝对路径）"
    echo "  INPUT_SUFFIX_LIST           输入数据(集合)文件后缀列表 (默认: _y.bin,_uv.bin)"
    echo "  MAX_BATCH_SIZE              每批最大文件数量 (默认: 200)"
    echo "============================================================"
}

case "$1" in
    -m|--monitor)
        monitor_mode "$2"
        ;;
    --stop)
        stop_execution
        ;;
    -s|--scan)
        generate_task_list
        show_task_list
        ;;
    -l|--list)
        show_task_list
        ;;
    -e|--export)
        if [[ -z "$2" ]]; then
            echo "错误: -e 选项需要指定导出目录" >&2
            exit 1
        fi
        export_results "$2"
        ;;
    -c|--clean)
        clean_all
        ;;
    -r|--reset)
        reset_tasks
        ;;
    -h|--help)
        show_usage
        ;;
    *)
        main "$@"
        ;;
esac
