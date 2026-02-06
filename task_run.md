# Task Run - 批量任务执行脚本

## Hello World - 快速入门

```bash
# 1. 扫描任务（首次运行）
bash task_run.sh -s

# 2. 查看任务列表
bash task_run.sh -l

# 3.1 前台执行任务模式（可另开终端监控）

# 3.1.1 串行执行（调试/小规模）
bash task_run.sh

# 3.1.2 并发执行（生产/大规模，推荐）
bash task_run.sh -p 5

# 3.2 后台执行任务模式（可通过监控模式来查看状态）

# 3.2.1 串行执行并保存日志
bash task_run.sh --save-logs >/tmp/task.log 2>&1 &

# 3.2.2 并发执行并保存日志
bash task_run.sh -p 5 --save-logs >/tmp/task.log 2>&1 &

# 4. 监控执行状态（默认0.5秒刷新）
bash task_run.sh -m

# 5. 安全停止后台任务
bash task_run.sh --stop

# 6. 查看执行日志
tail -f task_run.log
```

---

## Cheat Sheet

```bash
# ========== 基础用法 ==========

# 串行执行所有任务
bash task_run.sh

# 并发执行
bash task_run.sh -p                # 默认3个并发
bash task_run.sh -p 5              # 指定5个并发

# 保存详细日志
bash task_run.sh --save-logs
bash task_run.sh -p 5 --save-logs  # 并发 + 保存日志

# ========== 任务管理 ==========

# 扫描并生成任务列表
bash task_run.sh -s
bash task_run.sh --scan

# 显示任务列表和完成状态
bash task_run.sh -l
bash task_run.sh --list

# 实时监控任务执行状态
bash task_run.sh -m                # 默认0.5秒刷新（更实时）
bash task_run.sh -m 2              # 2秒刷新

# ========== 后台执行与停止 ==========

# 后台执行任务
bash task_run.sh -p 2 >/tmp/task.log 2>&1 &

# 安全停止后台任务
bash task_run.sh --stop            # 优雅停止主进程和所有子进程
                                    # 自动将 running 状态改回 pending

# ========== 跳过特定任务 ==========

# 创建 .skip 标记文件跳过某个任务，注意该文件不会被清理和重置
touch taskA/.skip

# ========== 清理和重置 ==========

# 重置所有任务状态（删除状态文件，可重新执行）
bash task_run.sh -r
bash task_run.sh --reset

# 彻底清理所有生成的文件（本地+远程）
bash task_run.sh -c
bash task_run.sh --clean

# ========== 自定义配置 ==========

# 指定数据集和输出目录
bash task_run.sh -i yuv -o output.wp

# 统一输出目录（所有结果集中在一处）
# 方式1: 以 . 开头（相对于脚本目录）
bash task_run.sh -o .results
# 方式2: 绝对路径
bash task_run.sh -o /tmp/unified_output

# 指定文件后缀
bash task_run.sh -s '_y.bin,_uv.bin'

# 指定批次大小
bash task_run.sh -b 100

# ========== 环境变量控制 ==========

# 不清理远程工作目录（调试用）
CLEANUP_REMOTE_WORKDIR=0 bash task_run.sh

# 任务完成后清理共享模型（默认）
CLEANUP_SHARED_MODELS=1 bash task_run.sh

# 全部完成后清空 .model_cache
CLEANUP_SHARED_MODELS=2 bash task_run.sh

# 自定义远程任务目录（默认为空，会自动获取远程 $HOME）
REMOTE_TASK_HOME=/data bash task_run.sh

# ========== 帮助信息 ==========

bash task_run.sh -h
bash task_run.sh --help
```

---

## 📖 功能说明

### 1. 核心功能

#### 1.1 自动任务发现
- **目的**：自动扫描工作目录，发现所有评测任务
- **原理**：
  - 递归遍历目录（最多2层），查找包含模型文件的目录作为任务目录
  - 模型文件扩展名从 `eval.sh` 中的 `MODEL_FILE_EXT` 读取
  - 在任务目录下查找包含数据集子目录的目录作为评测数据集
  - 数据集子目录名从 `eval.sh` 中的 `IN_SUBDIR` 读取
  - 生成任务列表文件（`.task_list`），记录任务和数据集的映射关系
- **性能优化**：
  - 使用 `find -maxdepth 1 -quit` 快速检测，找到第一个匹配即退出
  - 避免深入遍历数据集目录（可能包含大量文件）
  - 跳过隐藏目录和 `out*` 开头的输出目录

#### 1.2 串行/并发执行模式
- **串行模式**（默认）：
  - 按顺序逐个执行任务
  - 输出直接显示在终端
  - 适合调试和小规模任务
  
- **并发模式**（`-p N`）：
  - 同时执行多个任务，最大并发数可配置
  - 使用进程 ID 文件（`.running_pids`）跟踪后台任务
  - 动态槽位管理：任务完成后自动释放槽位，启动新任务
  - 适合大规模任务批处理

#### 1.3 任务状态管理
- **状态定义**（`.task_list` 文件中的 status 字段）：
  - `0` = pending（待执行）
  - `1` = running（运行中）
  - `2` = completed（已完成）
  - `3` = failed（失败）

- **完成状态检查**：
  - 检查完成标记文件（`${RUN_STATE_NAME}.complete.state`）
  - 自动跳过已完成的任务
  - 注意：`is_run_completed` 检查完成标记文件，不依赖 status 字段

- **运行状态跟踪**：
  - 任务列表文件记录每个数据集的状态（pending/running/completed/failed）
  - 失败任务自动标记为 failed 状态（status=3），便于识别
  - 监控模式实时显示各状态任务数量和详情

- **跳过任务机制**（`.skip`）：
  - **用途**：手动标记需要跳过的任务目录
  - **使用方式**：在任务目录下创建 `.skip` 文件（`touch taskA/.skip`） 
  - **生效时机**：任务列表生成时自动识别并排除带有 `.skip` 文件的任务
  - **持久性**：`.skip` 文件不会被清理（`-c`）或重置（`-r`）删除
  - **典型场景**：临时禁用某些任务、调试特定任务、分批执行任务

#### 1.4 监控模式
- **实时监控界面**：
  - 使用 ANSI 转义码实现无闪烁刷新
  - 显示任务进度、完成/失败/运行中统计
  - 显示运行任务的批次进度和详细信息
  - 显示最近日志（自动过滤监控界面输出）
  - VSCode 终端兼容性处理（预留折叠栏空间）
  - **默认刷新间隔 0.5 秒**（可通过参数调整）

- **主进程监控**：
  - 实时检测后台运行的主进程是否存活
  - 主进程退出时自动显示友好提示
  - 提示可能原因和后续操作建议

- **性能优化**：
  - 只在任务列表变化时重绘
  - 直接覆盖固定区域，减少闪烁
  - 缓存上次输出，对比差异

#### 1.5 安全停止功能
- **目的**：安全地停止后台运行的任务，避免状态不一致
- **使用方式**：`bash task_run.sh --stop`
- **工作流程**：
  1. 读取主进程 PID（`.main_pid` 文件）
  2. 发送 SIGTERM 信号优雅停止（等待最多10秒）
  3. 超时则发送 SIGKILL 强制终止
  4. 清理所有子进程（eval.sh）
  5. 将所有 running(1) 状态改回 pending(0)
  6. 清理 PID 文件和锁文件

- **安全保障**：
  - 不直接使用 `pkill`，避免误杀其他进程
  - 自动恢复任务状态，可继续执行
  - 显示清理进度和统计信息

- **使用场景**：
  - 需要暂停任务，稍后继续
  - 发现配置错误，需要修改后重新执行
  - 系统资源紧张，需要释放资源

#### 1.6 清理和重置功能
- **重置任务状态（`-r, --reset`）**：
  - **目的**：允许重新执行所有任务，而不需要删除输出结果
  - **原理**：
    - 递归查找并删除所有状态文件（`${RUN_STATE_NAME}.state`）
    - 删除所有完成文件（`${RUN_STATE_NAME}.complete.state`）
    - 重新生成任务列表，所有任务标记为未完成
    - 自动显示更新后的任务列表
  - **保留文件**：
    - 日志文件（方便查看历史记录）
    - 远程文件（避免重复上传模型）
    - 输出结果文件

- **彻底清理（`-c, --clean`）**：
  - **目的**：恢复工作目录到干净状态，仅保留源文件
  - **原理**：
    - **本地清理**：
      - 任务列表文件（`.task_list`）
      - 所有日志文件（`task_run.log`, `.task_logs/`）
      - 状态和完成文件（递归查找删除）
      - 失败任务列表、进程ID文件、锁文件
    - **远程清理**：
      - 所有远程工作目录（`$REMOTE_TASK_HOME/task_*`）
      - 共享模型缓存目录（`$REMOTE_TASK_HOME/.model_cache/`）
  - **安全机制**：
    - 清理前检查文件是否存在
    - 远程清理使用通配符匹配，避免误删
    - 显示详细清理信息和统计

### 2. 高级特性

#### 2.1 实时状态追踪机制
- **目的**：在监控模式下实时显示任务执行进度，无需重复计算
- **原理**：
  - `eval.sh` 负责维护实时状态：每上传一个数据项（包含多个后缀文件），更新状态文件中的 7 个 `RUNNING_` 字段
  - `task_run.sh` 负责读取状态：监控模式直接读取状态文件，获取实时进度信息
  - 避免实时计算：无需扫描文件、统计数量，直接读取预先维护的状态数据

- **状态文件结构**（`${RUN_STATE_NAME}.state`）：
  ```bash
  # 第 1 行:   # 评测任务状态文件（注释行）
  # 第 2-8 行: RUNNING_ 字段（固定7个，快速访问区）
  RUNNING_CURRENT_BATCH=3         # 当前执行的批次号（1-based）
  RUNNING_TOTAL_BATCHES=10        # 总批次数
  RUNNING_BATCH_COMPLETED=5       # 当前批次已完成的批数
  RUNNING_BATCH_TOTAL=20          # 当前批次总批数
  RUNNING_FAILED_BATCHES=1        # 累计失败批次数
  RUNNING_RETRY_COUNT=2           # 累计重试次数
  RUNNING_TIMESTAMP=1709543210    # 最后更新的 Unix 时间戳
  # 第 9+ 行:  固定配置和批次列表
  MAX_BATCH_SIZE=200
  TOTAL_DATA=1000
  ...
  ```

- **原子性保证**：
  - `eval.sh` 使用"临时文件 + mv 原子替换"模式更新状态
  - 保证 `task_run.sh` 读取时不会看到不完整的中间状态
  - `mv` 在同一文件系统内是原子操作（单个系统调用修改 inode 指针）

- **性能优化**：
  - 固定位置读取：监控模式使用 `sed -n '2,8p'` 直接读取第 2-8 行，避免 grep 过滤
  - 细粒度更新：`eval.sh` 每上传一个数据项就更新状态，实时性强
  - 缓存机制：监控模式缓存上次读取结果，只在变化时重绘界面

- **监控模式显示**：
  ```
  正在运行的任务 (3):
    taskA/dataset1  [批次 3/10] [当前批 5/20] [失败 1] [重试 2]
    taskB/dataset2  [批次 1/5]  [当前批 10/15] [失败 0] [重试 0]
    taskC/dataset3  [批次 7/8]  [当前批 18/18] [失败 0] [重试 1]
  ```

#### 2.2 共享模型机制
- **目的**：避免重复上传模型，提升性能
- **原理**：
  - 预上传：任务开始前，将所有模型上传到远程服务器的共享目录（`$REMOTE_TASK_HOME/.model_cache/`）
  - 命名规则：`${task_safe_name}_model.hbm`（路径中的 `/` 转换为 `_`，避免冲突）
  - 复用：同一任务的多个数据集共享同一个模型
  - 性能提升：串行模式从 N 次上传降到 1 次（节省 80%+ 时间）

- **清理策略**（`CLEANUP_SHARED_MODELS`）：
  - `0`：保留所有共享模型，方便重跑
  - `1`（默认）：任务的所有数据集完成后，清理该任务的模型
  - `2`：全部任务完成后，清空整个 `.model_cache` 目录

#### 2.2 统一输出目录
- **目的**：将所有数据集的输出集中到一个目录，便于管理
- **使用方式**：
  - **方式1**：`-o` 参数以 `.` 开头（如 `-o .results`）→ 相对于脚本目录
  - **方式2**：`-o` 参数为绝对路径（如 `-o /tmp/task_output`）→ 绝对路径
- **原理**：
  - 检测到统一输出模式后，构建完整路径：
    - 以 `.` 开头：`SCRIPT_DIR/OUT_SUBDIR/task_dir/dataset`
    - 绝对路径：`OUT_SUBDIR/task_dir/dataset`
  - 以绝对路径形式传给 `eval.sh`
  - `eval.sh` 检测到绝对路径，直接使用该路径作为输出目录

- **示例**：
  ```bash
  # 传统模式（相对于数据集目录）
  bash task_run.sh -o output.wp
  # 输出: taskA/dataset1/output.wp/
  #       taskA/dataset2/output.wp/
  
  # 统一输出模式 - 相对路径
  bash task_run.sh -o .results
  # 输出: ./results/taskA/dataset1/
  #       ./results/taskA/dataset2/
  #       ./results/taskB/dataset1/
  
  # 统一输出模式 - 绝对路径
  bash task_run.sh -o /tmp/task_output
  # 输出: /tmp/task_output/taskA/dataset1/
  #       /tmp/task_output/taskA/dataset2/
  #       /tmp/task_output/taskB/dataset1/
  ```

#### 2.3 资源清理管理
- **远程工作目录清理**（`CLEANUP_REMOTE_WORKDIR`）：
  - 每个任务生成唯一的远程工作目录：`$REMOTE_TASK_HOME/task_taskA_datasetB/`
  - 默认清理（`1`），避免累积占用磁盘空间
  - 调试时可设为 `0` 保留，方便排查问题

- **共享模型清理**（见 2.1）

- **安全机制**：
  - 路径验证：确保删除路径包含特定前缀（`/task_`、`/.model_cache/`）
  - 防止误删重要文件

#### 2.4 日志管理
- **主日志**（`task_run.log`）：
  - 记录所有任务的执行状态、配置信息
  - 使用 `flock` 文件锁防止并发写入冲突（锁文件位于`/tmp`目录）
  - 5秒超时机制防止死锁
  - 带时间戳和颜色标记

- **详细日志**（`--save-logs`）：
  - 保存每个任务的完整输出到独立文件（`.task_logs/`）
  - 串行模式：同时输出到终端和文件（使用 `tee`）
  - 并发模式：后台执行，输出重定向到文件

- **失败任务列表**（`failed_tasks.txt`）：
  - 自动记录失败的任务路径
  - 方便重试或排查问题

### 3. 配置系统

#### 3.1 配置分层架构

`task_run.sh` 本身不关注具体的评测配置（如模型参数、数据集格式等），其角色是**配置传递者**，负责将任务级配置传递给各个数据集的 `eval.sh` 执行。具体配置的解析和使用由 `eval.sh` 负责。

**配置层级**（从上到下）：

```
1. 任务级配置（taskA/.run_config）
   ├─ 作用范围：任务目录下的所有数据集
   ├─ 读取者：task_run.sh
   └─ 传递方式：通过环境变量传给 eval.sh

2. 数据集级配置（taskA/dataset1/.run_config）
   ├─ 作用范围：单个数据集
   ├─ 读取者：eval.sh
   └─ 优先级：最高（会重载任务级配置）
```

**核心机制**：
- `task_run.sh` 读取任务目录下的 `.run_config`，通过环境变量传递给所有数据集的 `eval.sh`
- `eval.sh` 执行时先使用传入的任务级配置，再读取数据集目录下的 `.run_config` 进行重载
- 最终生效优先级：**数据集配置 > 任务配置 > eval.sh 默认值**

#### 3.2 配置传递机制

**任务级配置示例**（`taskA/.run_config`）：
```bash
IN_SUBDIR=yuv
OUT_SUBDIR=output.wp
POST_PROCESS_PLUGIN=plugin1
MAX_BATCH_SIZE=100
```

**传递流程**：
```
1. task_run.sh 扫描到任务目录 taskA/
   └─ 读取 taskA/.run_config

2. 执行 taskA/dataset1 时
   └─ env IN_SUBDIR=yuv OUT_SUBDIR=output.wp POST_PROCESS_PLUGIN=plugin1 \
         MAX_BATCH_SIZE=100 MODEL_DIR=/path/to/taskA \
         REMOTE_WORK_DIR=$REMOTE_TASK_HOME/task_taskA_dataset1 \
      eval.sh /path/to/taskA/dataset1

3. eval.sh 内部处理
   ├─ 读取环境变量（任务级配置）
   ├─ 读取 dataset1/.run_config（如果存在）
   └─ 数据集配置覆盖任务配置（优先级更高）
```

**自动传递的参数**：
- `MODEL_DIR`：任务目录的绝对路径（task_run.sh 自动设置）
- `REMOTE_WORK_DIR`：唯一的远程工作目录（task_run.sh 自动生成）
- 任务级 `.run_config` 中的所有配置项（通过环境变量传递给 eval.sh）
- `MAX_BATCH_SIZE`：批次大小。配置优先级为（从低到高）：
  1. 从 `eval.sh` 读取的默认值
  2. 环境变量 `MAX_BATCH_SIZE`
  3. task_run.sh 命令行参数 `-b/--batch-size`（修改全局 `MAX_BATCH_SIZE`）
  4. 任务级 `.run_config` 中的 `MAX_BATCH_SIZE`
  5. eval.sh 加载的数据集级的 `.run_config` 中的 `MAX_BATCH_SIZE`


#### 3.3 使用场景

**场景1：统一任务配置**

```bash
# taskA/.run_config
OUT_SUBDIR=output.v1
POST_PROCESS_PLUGIN=psnr

# 该任务下所有数据集（dataset1, dataset2, dataset3）
# 都使用相同的输出目录和后处理插件
```

**场景2：数据集特殊配置**
```bash
# taskA/.run_config（任务级）
OUT_SUBDIR=output.v1
MAX_BATCH_SIZE=200

# taskA/dataset1/.run_config（数据集级）
MAX_BATCH_SIZE=50  # 该数据集文件较大，减小批次

# 结果：dataset1 使用 MAX_BATCH_SIZE=50
#       dataset2, dataset3 使用 MAX_BATCH_SIZE=200
```

**场景3：跨任务不同配置**

```bash
# taskA/.run_config
POST_PROCESS_PLUGIN=psnr

# taskB/.run_config
POST_PROCESS_PLUGIN=ssim

# 不同任务使用不同的后处理插件
```

#### 3.4 task_run.sh 专用配置

以下配置由 `task_run.sh` 使用，不传递给 `eval.sh`：

- `REMOTE_TASK_HOME`：远程任务主目录（默认自动获取远程 `$HOME`）
- `CLEANUP_REMOTE_WORKDIR`：是否清理远程工作目录（默认 `1`）
- `CLEANUP_SHARED_MODELS`：共享模型清理策略（默认 `0`）
  - `0`：保留所有共享模型
  - `1`：任务完成后清理该任务的模型
  - `2`：全部任务完成后清空 `.model_cache`

这些配置控制 `task_run.sh` 的行为，与具体评测逻辑无关。

### 4. 跨平台支持

#### 4.1 macOS/Linux 兼容
- 操作系统检测：自动识别 macOS 和 Linux
- `sed -i` 语法差异处理：macOS 需要 `-i ''`，Linux 只需 `-i`
- `stat` 命令差异：macOS 使用 `-f%z`，Linux 使用 `-c%s`

#### 4.2 依赖工具检查
- 自动检测必要工具（`flock`、`gzip`）
- 缺失时提示安装，支持 Homebrew/apt/yum
- 串行模式可在缺少 `flock` 时运行（并发模式可能出现日志混乱）

---

## 📁 附录：生成文件说明

### 1. 任务列表文件 `.task_list`

**格式说明**：
```
# 任务行（以 * 开头）
*task_dir|plugin|ds_count

# 数据集行（以 - 开头）
-dataset_path|status

# 汇总行（以 + 开头）
+summary|total_tasks|total_datasets
```

**字段说明**：
- **任务行**：
  - `task_dir`：任务目录路径（相对于工作目录）
  - `plugin`：后处理插件名称（可选）
  - `ds_count`：该任务下的数据集数量

- **数据集行**：
  - `dataset_path`：数据集路径（相对于任务目录）
  - `status`：任务状态
    - `0` = pending（待执行）
    - `1` = running（运行中）
    - `2` = completed（已完成）
    - `3` = failed（失败）

- **汇总行**：
  - `total_tasks`：总任务数
  - `total_datasets`：总数据集数

**示例**：
```
*taskA|plugin1|3
-dataset1|2
-dataset2|1
-dataset3|0
*taskB||2
-dataset1|3
-dataset2|0
+summary|2|5
```

**用途**：
- 记录任务和数据集的映射关系
- 跟踪完成状态和运行状态
- 支持断点续传和增量执行
- 监控模式实时读取状态

### 2. 主进程 PID 文件 `.main_pid`

**格式**：单行，包含主进程 PID
```
12345
```

**用途**：
- 记录后台运行的主进程 PID
- 监控模式检测主进程是否存活
- `--stop` 命令用于定位并终止主进程
- 主进程正常结束时自动清理

### 3. 运行进程文件 `.running_pids`

**格式**：每行一个进程 ID
```
12345
12346
12347
```

**用途**：
- 并发模式下跟踪后台任务进程
- 动态槽位管理：检查进程是否存在，释放已完成的槽位
- 等待所有任务完成

### 4. 主日志文件 `task_run.log`

**格式**：
```
[2026-02-04 10:30:15] [INFO] 扫描任务目录...
[2026-02-04 10:30:16] [TASK] 执行: taskA/dataset1 (插件: plugin1, 远程目录: /root/task_taskA_dataset1)
[2026-02-04 10:30:25] [INFO] ✓ 完成: taskA/dataset1
[2026-02-04 10:30:26] [ERROR] ✗ 失败: taskB/dataset2
```

**用途**：
- 记录所有任务的执行历史
- 带时间戳，便于排查问题
- 监控模式显示最近日志

### 5. 失败任务列表 `failed_tasks.txt`

**格式**：每行一个失败的任务路径
```
taskA/dataset2
taskB/dataset1
```

**用途**：
- 自动记录失败的任务
- 方便重试或排查问题
- 汇总报告中显示失败任务

### 6. 详细日志目录 `.task_logs/`

**结构**：
```
.task_logs/
├── taskA_dataset1.log
├── taskA_dataset2.log
└── taskB_dataset1.log
```

**用途**：
- 保存每个任务的完整输出（`--save-logs` 开启）
- 独立文件，不会混乱
- 失败时提示日志路径

### 7. 日志和锁文件

#### 6.1 锁文件存储位置

**位置**：`/tmp/task_locks_<MD5>/`
- 基于工作目录路径生成唯一的MD5标识
- 存储在系统临时目录，避免被某些对文件进行实时监控的程序（如 Docker）干扰
- 示例：`/tmp/task_locks_1e102d029bbb0a10d177cd287c3b3da2/`

**背景说明**：
- 某些对文件进行实时监控的程序（如 Docker）会实时监控特定目录（如`/Users/*/Downloads`）
- 监控进程会立即打开新创建的文件（包括锁文件），以读模式持有文件句柄
- 这会导致`flock`独占锁请求冲突，造成脚本阻塞
- 将锁文件移到`/tmp`目录可避免此问题，因为这些对文件进行实时监控的程序通常不监控临时目录

#### 6.2 主日志锁文件

**文件名**：`task_run.log.lock`
**位置**：`/tmp/task_locks_<MD5>/task_run.log.lock`

**用途**：
- `flock` 文件锁，防止并发写入主日志时混乱
- 5秒超时机制，避免死锁（超时后降级为直接输出到终端）
- 自动管理，无需手动操作
- 清理命令会自动删除

#### 6.3 任务列表锁文件

**文件名**：`eval_tasks.lock`
**位置**：`/tmp/task_locks_<MD5>/task_tasks.lock`

**用途**：
- `flock` 文件锁，防止并发更新任务列表（`.task_list`）时发生冲突
- 并发模式下多个进程同时标记任务状态时使用
- 5秒超时机制，避免死锁（超时后返回错误）
- 自动管理，无需手动操作
- 清理命令会自动删除

#### 6.4 锁文件清理

**自动清理时机**：
1. 脚本正常结束时
2. 执行`-c`清理命令时（会先删除锁文件和锁目录）
3. 锁目录在为空时会被自动删除

### 8. 远程服务器文件

#### 7.1 远程工作目录
```
$REMOTE_TASK_HOME/task_taskA_dataset1/
$REMOTE_TASK_HOME/task_taskA_dataset2/
...
```

**用途**：
- 每个任务生成唯一的远程工作目录
- `eval.sh` 在此目录下执行评测
- 默认自动清理（`CLEANUP_REMOTE_WORKDIR=1`）

#### 7.2 共享模型缓存
```
$REMOTE_TASK_HOME/.model_cache/
├── taskA_model.hbm
├── taskB_model.hbm
└── dir1_taskC_model.hbm
```

**用途**：
- 预上传的共享模型
- 同一任务的多个数据集复用
- 命名规则：路径中的 `/` 转换为 `_`

---

## 🔧 工作原理

### 1. 任务发现流程

```
1. 扫描目录（最多2层）
   ├─ 查找模型文件（*.hbm）→ 发现任务目录
   └─ 查找数据集子目录（yuv/）→ 发现评测数据集

2. 生成任务列表（.task_list）
   ├─ 任务行：记录任务目录、插件、数据集数量
   ├─ 数据集行：记录数据集路径、完成状态、运行状态
   └─ 汇总行：记录总任务数、总数据集数

3. 读取任务配置
   ├─ 全局默认配置（eval.sh）
   ├─ 任务级配置（.run_config）
   └─ 命令行参数（最高优先级）
```

### 2. 任务执行流程

#### 串行模式
```
1. 预上传所有模型到共享目录
   └─ $REMOTE_TASK_HOME/.model_cache/taskA_model.hbm

2. 按顺序执行任务
   ├─ 生成远程工作目录：$REMOTE_TASK_HOME/task_taskA_dataset1/
   ├─ 构建环境变量（包含共享模型路径）
   ├─ 调用 eval.sh 执行评测
   ├─ 检查完成状态
   │   ├─ 成功 → 标记完成、清理工作目录
   │   └─ 失败 → 记录到 failed_tasks.txt
   └─ 检查任务所有数据集是否完成 → 清理共享模型（可选）

3. 全部完成后清理
   └─ 清空 .model_cache（CLEANUP_SHARED_MODELS=2）
```

#### 并发模式
```
1. 预上传所有模型到共享目录（同串行）

2. 动态槽位管理
   ├─ 检查可用槽位（MAX_CONCURRENT）
   ├─ 有槽位 → 启动后台任务
   │   ├─ 生成远程工作目录
   │   ├─ 后台执行 eval.sh
   │   └─ 记录进程 ID（.running_pids）
   └─ 无槽位 → 等待2秒，清理已完成的进程

3. 等待所有任务完成
   ├─ 读取 .running_pids
   ├─ 逐个 wait 进程
   └─ 统计成功/失败数量

4. 全部完成后清理（同串行）
```

### 3. 监控模式原理

```
1. 初始化
   ├─ 清屏、隐藏光标
   ├─ 预留 VSCode 折叠栏空间（2行）
   └─ 计算各区域行号

2. 循环刷新（默认30秒）
   ├─ 读取任务列表文件（.task_list）
   ├─ 渲染任务状态（带颜色和图标）
   │   ├─ ○ 未开始（灰色）
   │   ├─ ◐ 进行中（黄色）
   │   └─ ✓ 已完成（绿色）
   ├─ 计算进度条（已完成/总数 × 100%）
   ├─ 显示运行任务（从 ${RUN_STATE_NAME}.state 读取批次信息）
   └─ 显示最近日志（过滤监控界面输出）

3. 性能优化
   ├─ 只在任务列表变化时重绘
   ├─ 直接覆盖固定区域（避免闪烁）
   └─ 光标移回顶部（避免触发滚动）
```

### 4. 统一输出目录原理

```
1. 检测统一输出模式
   ├─ 方式1：OUT_SUBDIR 以 . 开头（如 -o .results）
   └─ 方式2：OUT_SUBDIR 为绝对路径（如 -o /tmp/output）

2. 构建完整路径
   方式1（相对路径）：
   ├─ SCRIPT_DIR：/path/to/task_test
   ├─ OUT_SUBDIR：.results
   ├─ task_dir：taskA
   ├─ dataset：dataset1
   └─ 结果：/path/to/task_test/.results/taskA/dataset1
   
   方式2（绝对路径）：
   ├─ OUT_SUBDIR：/tmp/output
   ├─ task_dir：taskA
   ├─ dataset：dataset1
   └─ 结果：/tmp/output/taskA/dataset1

3. 传给 eval.sh
   └─ OUT_SUBDIR=<完整绝对路径>

4. eval.sh 判断
   ├─ 以 / 开头 → 直接使用（统一输出模式）
   └─ 否则 → 相对于数据集目录（传统模式）
```

---

## 📦 依赖要求

### 必需文件
- **eval.sh**：核心评测脚本，必须存在于同目录下
  - 脚本启动时会检查 `eval.sh` 是否存在
  - 如果不存在，会立即报错退出
  - 多数配置项（如模型扩展名、目录名等）从此文件读取

### 必需工具
- `ssh`、`scp`：远程连接和文件传输
- `find`、`grep`、`sed`：文件搜索和文本处理
- `flock`（可选）：并发模式下防止日志冲突（串行模式可不安装）

---

**版本**: 1.4  
**最后更新**: 2026-02-05
