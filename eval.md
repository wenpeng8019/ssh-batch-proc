# Eval - 远程评测执行脚本

## 📋 概述

`eval.sh` 是一个远程评测自动化脚本，负责将本地数据和模型上传到远程服务器，执行评测任务，并下载结果。支持断点续传、批量处理、压缩传输、MD5 校验等高级特性。

**核心特性**：
- 🚀 批量上传处理（可配置批次大小）
- 🔄 断点续传（支持中断恢复）
- ✅ MD5 完整性校验（确保数据准确）
- 📦 Gzip 压缩传输（节省 50% 传输时间）
- 🔌 后处理插件系统
- 📊 实时状态追踪
- 🛡️ 原子性保证（状态文件）

---

## Hello World - 快速入门

```bash
# 1. 准备数据结构
# 工作目录/
# ├── eval.sh              # 本脚本
# ├── taskA/               # 任务目录
# │   ├── model.hbm        # 模型文件
# │   └── dataset1/        # 数据集目录
# │       └── yuv/         # 数据子目录（IN_SUBDIR）
# │           ├── img001_y.bin
# │           ├── img001_uv.bin
# │           ├── img002_y.bin
# │           └── img002_uv.bin

# 2. 基础执行（使用默认配置）
bash eval.sh taskA/dataset1

# 3. 自定义配置执行
IN_SUBDIR=yuv OUT_SUBDIR=output.wp bash eval.sh taskA/dataset1

# 4. 使用配置文件
# 在 taskA/dataset1/ 下创建 .eval_config
echo "IN_SUBDIR=yuv" > taskA/dataset1/.eval_config
echo "OUT_SUBDIR=output.wp" >> taskA/dataset1/.eval_config
bash eval.sh taskA/dataset1

# 5. 查看输出结果
ls taskA/dataset1/output.wp/
```

---

## Cheat Sheet

```bash
# ========== 基础用法 ==========

# 执行评测（使用默认配置）
bash eval.sh path/to/dataset

# 指定数据集和输出目录
IN_SUBDIR=yuv OUT_SUBDIR=output bash eval.sh path/to/dataset

# 指定批次大小
MAX_BATCH_SIZE=100 bash eval.sh path/to/dataset

# ========== 压缩传输 ==========

# 启用压缩传输（默认开启，节省约50%时间）
ENABLE_COMPRESSION=true bash eval.sh path/to/dataset

# 禁用压缩传输
ENABLE_COMPRESSION=false bash eval.sh path/to/dataset

# ========== 远程配置 ==========

# 指定SSH主机和端口
SSH_HOST=user@192.168.1.100 SSH_PORT=2222 bash eval.sh path/to/dataset

# 使用SSH密钥
SSH_KEY=/path/to/private_key bash eval.sh path/to/dataset

# 指定远程工作目录
REMOTE_WORK_DIR=/data/eval bash eval.sh path/to/dataset

# ========== 模型配置 ==========

# 单个模型（默认）
REMOTE_MODEL_FILE0=model/model.hbm bash eval.sh path/to/dataset

# 多个模型
REMOTE_MODEL_FILE0=model/model1.hbm \
REMOTE_MODEL_FILE1=model/model2.hbm \
bash eval.sh path/to/dataset

# ========== 后处理插件 ==========

# 使用后处理插件
POST_PROCESS_PLUGIN=psnr bash eval.sh path/to/dataset

# ========== 文件后缀配置 ==========

# 单后缀文件
INPUT_SUFFIX_LIST=.bin bash eval.sh path/to/dataset

# 多后缀文件（默认）
INPUT_SUFFIX_LIST=_y.bin,_uv.bin bash eval.sh path/to/dataset

# ========== 调试模式 ==========

# 启用详细日志
VERBOSE=true bash eval.sh path/to/dataset

# 远程日志级别（0=DEBUG, 2=WARN）
REMOTE_LOG_LEVEL=0 bash eval.sh path/to/dataset

# DRY-RUN 模式（模拟运行，不实际执行远程命令）
./eval.sh -y path/to/dataset                    # 启用 DRY-RUN，无延迟
./eval.sh -y 2 path/to/dataset                  # 启用 DRY-RUN，每个操作延迟2秒

# ========== 测试功能（仅用于开发测试）==========

# 模拟指定批次失败（测试失败重试机制）
DRY_RUN_FAIL_BATCH=3 ./eval.sh -y path/to/dataset

# 模拟随机失败（30%概率）
DRY_RUN_FAIL_RATE=30 ./eval.sh -y path/to/dataset
```

---

## 📖 功能说明

### 1. 核心功能

#### 1.1 批量上传处理
- **目的**：将大量数据分批上传，避免单次传输文件过多导致失败
- **原理**：
  - 扫描数据集目录，按文件前缀分组（例如 `img001` 包含 `img001_y.bin` 和 `img001_uv.bin`）
  - 按 `MAX_BATCH_SIZE` 参数将数据分成多个批次
  - 每批独立上传、评测、下载结果
  - 批次信息记录在状态文件中，支持断点续传

- **批次大小选择**：
  - 小批次（50-100）：适合网络不稳定环境，失败重试成本低
  - 中批次（100-200）：默认推荐值，平衡性能和可靠性
  - 大批次（200-500）：适合稳定网络，减少上传次数

#### 1.2 断点续传机制
- **目的**：脚本中断后可以从断点继续执行，无需重新开始
- **支持场景**：
  - 手动中断（Ctrl+C）
  - 网络中断
  - 远程服务器故障
  - 脚本崩溃

- **原理**：
  - 状态文件（`.eval_task.state`）记录每个批次的执行状态和最后上传的文件
  - 重新执行时检测状态文件：
    - `running` 状态：从最后成功上传的文件后继续
    - `failed` 状态：检查远程数据 MD5，如果一致则跳过上传直接重试评测
    - `completed` 状态：跳过该批次
  - 每上传一个数据项，更新状态文件中的进度信息

- **断点续传流程**：
  ```
  1. 检测状态文件
     ├─ 不存在 → 全新任务，生成状态文件
     ├─ completed → 跳过
     ├─ failed → MD5校验 → 决定是否重新上传
     └─ running → 读取 BATCH_X_LAST_PREFIX → 从断点继续
  
  2. MD5 校验
     ├─ 本地文件 MD5 → 上传前计算
     ├─ 远程文件 MD5 → ssh 远程执行 md5sum
     └─ 对比一致性 → 决定是否跳过上传
  
  3. 续传执行
     └─ 跳过已上传的前缀 → 从下一个前缀开始上传
  ```

#### 1.3 MD5 完整性校验
- **目的**：确保上传的数据完整无损
- **校验时机**：
  - 上传前：计算本地文件 MD5 并保存到 `.md5` 文件
  - 上传后：远程计算 MD5 并与本地对比
  - 断点续传：校验最后上传的文件，决定续传策略

- **校验方式**：
  ```bash
  # 本地计算
  md5sum file.bin > file.bin.md5
  
  # 远程校验
  ssh remote "cd /path && md5sum -c file.bin.md5"
  
  # 批量校验
  ssh remote "cd /path && md5sum -c *.md5"
  ```

- **失败处理**：
  - MD5 不匹配：重新上传该文件
  - 评测失败：自动重试最多 3 次（跳过上传直接重试评测）
  - 3 次重试后仍失败：标记批次为 failed，记录到状态文件

#### 1.4 远程环境保护机制

- **目的**：保护远程服务器的现有环境，确保任务中断或失败后不影响其他任务执行
  
- **核心原理**：
  - **首次执行**：备份远程现有的输入/输出目录（如果存在）
  - **任务未完成**：将当前工作目录重命名保存，恢复原备份环境
  - **续传执行**：恢复上次保存的工作环境，继续执行
  - **任务完成**：清理工作目录，恢复原备份环境

- **环境管理流程**：
  ```
  首次执行：
  1. 检查远程是否有 test_data 和 out 目录
  2. 如有 → 备份为 test_data.20260206_120000 和 out.20260206_120000
  3. 创建新的 test_data 和 out 目录
  4. 上传模型和数据，执行评测
  
  任务失败/中断：
  1. 将当前 test_data 和 out 重命名为 test_data.20260206_120500.failed
  2. 记录到状态文件：FAILED_INPUT_DIR, FAILED_OUTPUT_DIR, FAILED_TIMESTAMP
  3. 恢复原备份：test_data.20260206_120000 → test_data
  4. 远程环境恢复到执行前状态
  
  续传执行：
  1. 检测状态文件中的 FAILED_INPUT_DIR
  2. 备份当前远程环境（如果有）
  3. 恢复失败环境：test_data.20260206_120500.failed → test_data
  4. 继续执行未完成的批次
  
  任务成功：
  1. 删除工作目录 test_data 和 out
  2. 恢复原备份：test_data.20260206_120000 → test_data
  3. 清除状态文件中的 FAILED_ 记录
  4. 重命名状态文件为 .complete.state
  ```

- **保存的环境标识**：
  - `.failed` 后缀：表示任务失败时保存
  - `.pending` 后缀：表示任务中断时保存
  - 时间戳：用于区分不同执行批次（格式：YYYYMMDD_HHMMSS）

- **状态文件记录**：
  ```bash
  FAILED_INPUT_DIR=test_data.20260206_120500.failed
  FAILED_OUTPUT_DIR=out.20260206_120500.failed
  FAILED_TIMESTAMP=20260206_120500
  ```

- **优势**：
  - **隔离性**：每次执行的工作目录互不影响
  - **可调试性**：失败环境被保存，可以登录远程查看调试
  - **安全性**：原环境始终被保护，任务失败不影响其他任务
  - **可恢复性**：续传时精确恢复到失败时的环境状态

#### 1.5 失败重试机制
- **目的**：处理临时性失败（网络抖动、远程服务暂时不可用），提高任务成功率
- **重试策略**：
  - **最大重试次数**：每个批次最多重试 3 次
  - **重试条件**：评测命令返回非零退出码
  - **智能跳过上传**：
    - 重试前先验证远程数据 MD5
    - MD5 一致：跳过上传，直接重试评测（快速重试）
    - MD5 不一致：重新上传后再评测

- **重试流程**：
  
  ```
  批次评测失败
     ↓
  检查重试次数 < 3
     ↓
  验证远程数据 MD5
     ├─ MD5 一致 → 跳过上传 → 直接评测
     └─ MD5 不一致 → 重新上传 → 评测
     ↓
  评测成功 → 标记完成
     ↓
  评测失败 → 增加重试计数 → 继续重试
     ↓
  重试 3 次后仍失败 → 标记 failed
  ```
  
- **重试日志示例**：
  ```
  [ERROR] 第 3 批评测失败 (重试 0/3)
  [INFO] 批次 3 第 1 次重试
  [INFO] 远程数据 MD5 验证通过，跳过上传直接重试评测
  [INFO] 第 3 批处理完成
  ```

#### 1.6 压缩传输
- **目的**：减少网络传输量，加快上传下载速度
- **性能提升**：平均节省 50% 传输时间（取决于数据压缩率）
- **双向支持**：
  - **上传压缩**：本地 gzip 压缩 → 传输 `.gz` → 远程解压
  - **下载压缩**：远程打包压缩 → 传输 `.tar.gz` → 本地解压

- **上传压缩流程**：
  
  ```
  本地压缩（批量并行）
     ├─ 遍历数据文件
     ├─ gzip -k file.bin → file.bin.gz
     └─ 保留原文件（-k参数）
  
  上传 .gz 文件
     └─ scp *.gz remote:/path/
  
  远程解压（批量）
     ├─ cd /path
     ├─ gunzip *.gz
     └─ 删除 .gz 文件
  ```
  
- **下载压缩流程**：
  
  ```
  远程压缩打包
     ├─ cd $REMOTE_OUTPUT_DIR
     ├─ tar czf /tmp/output_${prefix}.tar.gz ${prefix}*
     └─ 生成压缩包
  
  下载压缩包
     └─ scp remote:/tmp/output.tar.gz local/
  
  本地解压
     ├─ tar xzf output.tar.gz -C output_dir/
     └─ 删除 .tar.gz 文件
     └─ 删除 .gz 文件
  ```
  
- **配置选项**：
  - `ENABLE_COMPRESSION=true`：启用压缩（默认）
  - `ENABLE_COMPRESSION=false`：禁用压缩（小文件或已压缩数据）
  - `COMPRESSION_TEMP_DIR`：本地压缩临时目录

#### 1.7 状态文件管理
- **文件位置**：`EVAL_DIR/.eval_task.state`
- **文件结构**：
  
  ```bash
  # 第 1 行: 注释
  # 评测任务状态文件
  
  # 第 2-8 行: RUNNING_ 字段（实时更新）
  RUNNING_CURRENT_BATCH=3
  RUNNING_TOTAL_BATCHES=10
  RUNNING_BATCH_COMPLETED=5
  RUNNING_BATCH_TOTAL=20
  RUNNING_FAILED_BATCHES=1
  RUNNING_RETRY_COUNT=2
  RUNNING_TIMESTAMP=1709543210
  
  # 第 9+ 行: 固定配置
  MAX_BATCH_SIZE=200
  TOTAL_DATA=1000
  TOTAL_FILES=2000
  SUFFIX_LIST="_y.bin,_uv.bin"
  
  # 批次列表
  BATCH_0_STATUS=completed
  BATCH_0_PREFIXES="img001|img002|img003"
  BATCH_1_STATUS=running
  BATCH_1_PREFIXES="img004|img005|img006"
  BATCH_1_LAST_PREFIX="img005"  # 断点续传标记
  ```
  
- **原子性保证**：
  - 使用"临时文件 + mv 原子替换"模式更新
  - 确保 `task_eval.sh` 读取时不会看到不完整状态
  - `mv` 是原子操作（单个系统调用修改 inode 指针）

- **状态说明**：
  - `completed`：批次已完成
  - `running`：批次执行中（可续传）
  - `failed`：批次失败（可重试）
  - `BATCH_X_LAST_PREFIX`：记录最后成功上传的文件前缀，用于断点续传

### 2. 高级特性

#### 2.1 多模型支持
- **目的**：支持需要多个模型文件的评测任务
- **配置方式**：
  ```bash
  REMOTE_MODEL_FILE0=model/encoder.hbm
  REMOTE_MODEL_FILE1=model/decoder.hbm
  REMOTE_MODEL_FILE2=model/postprocess.hbm
  REMOTE_MODEL_FILE3=model/auxiliary.hbm
  ```

- **自动上传**：
  - 扫描 `MODEL_DIR` 目录（由 task_eval.sh 自动设置）
  - 提取模型文件名（从路径中提取）
  - 上传到远程 `REMOTE_WORK_DIR/model/` 目录
  - 支持绝对路径模型（task_eval.sh 的共享模型机制）

- **路径处理**：
  ```bash
  # 相对路径（需要上传）
  REMOTE_MODEL_FILE0=model/model.hbm
  → 本地: $MODEL_DIR/model.hbm
  → 远程: $REMOTE_WORK_DIR/model/model.hbm
  
  # 绝对路径（跳过上传，直接使用）
  REMOTE_MODEL_FILE0=/root/.model_cache/taskA_model.hbm
  → 远程: /root/.model_cache/taskA_model.hbm
  ```

#### 2.2 后处理插件系统
- **目的**：在评测完成后执行自定义后处理逻辑（如 PSNR、SSIM 计算）
- **配置方式**：
  ```bash
  POST_PROCESS_PLUGIN=psnr  # 插件名称
  ```

- **插件机制**：
  - 插件名称通过环境变量传递给远程评测工具
  - 远程工具根据插件名称执行相应的后处理逻辑
  - 后处理结果与评测输出一起下载

- **典型插件**：
  - `psnr`：计算 PSNR 指标
  - `ssim`：计算 SSIM 指标
  - `custom`：自定义后处理

#### 2.3 远程评测命令定制
- **目的**：支持不同的远程评测工具
- **配置方式**：通过 `REMOTE_EVAL_CMD` 环境变量
- **变量替换**：
  
  ```bash
  {MODEL_PATH0}   # 第一个模型完整路径
  {MODEL_PATH1}   # 第二个模型完整路径
  {INPUT_PATH}    # 输入目录完整路径
  {OUTPUT_PATH}   # 输出目录完整路径
  {INPUT_NUM}     # 输入 tensor 文件数量
  {INPUT_SUFFIX}  # 文件后缀列表
  {POST_PLUGIN}   # 后处理插件名称
  {LOG_LEVEL}     # 日志级别
  {WORK_DIR}      # 远程工作目录
  ```
  
- **示例**：
  
  ```bash
  REMOTE_EVAL_CMD='cd {WORK_DIR} && ./custom_eval \
      --model {MODEL_PATH0} \
      --input {INPUT_PATH} \
      --output {OUTPUT_PATH} \
      --plugin {POST_PLUGIN}'
  ```

#### 2.4 配置文件支持
- **位置**：`EVAL_DIR/.eval_config`
- **格式**：`key=value`（每行一个配置项）
- **支持的配置**：
  - `IN_SUBDIR`：数据集子目录名
  - `OUT_SUBDIR`：输出子目录名
  - `INPUT_SUFFIX_LIST`：文件后缀列表
  - `POST_PROCESS_PLUGIN`：后处理插件
  - `MAX_BATCH_SIZE`：批次大小

- **配置优先级**（从低到高）：
  1. 脚本默认值
  2. 配置文件（`.eval_config`）
  3. 环境变量
  4. task_eval.sh 传递的环境变量

- **示例**：
  ```bash
  # .eval_config
  IN_SUBDIR=yuv
  OUT_SUBDIR=output.wp
  MAX_BATCH_SIZE=100
  POST_PROCESS_PLUGIN=psnr
  INPUT_SUFFIX_LIST=_y.bin,_uv.bin
  ```

### 3. 工作流程

#### 3.1 完整执行流程
```
1. 初始化阶段
   ├─ 解析命令行参数
   ├─ 加载配置文件（.eval_config）
   ├─ 应用环境变量
   ├─ 验证配置完整性
   └─ 检测/生成状态文件

2. 准备阶段
   ├─ 扫描数据集文件（按前缀分组）
   ├─ 计算批次划分
   ├─ 上传模型文件（如果不是绝对路径）
   └─ 创建远程目录结构

3. 批次执行循环
   对每个批次:
   ├─ 检查批次状态（completed/running/failed）
   ├─ 断点续传处理
   │   ├─ 读取 BATCH_X_LAST_PREFIX
   │   ├─ MD5 校验已上传文件
   │   └─ 确定续传起点
   ├─ 数据上传
   │   ├─ 压缩（如果启用）
   │   ├─ 计算 MD5
   │   ├─ 上传文件和 MD5
   │   ├─ 远程 MD5 校验
   │   ├─ 远程解压（如果启用）
   │   └─ 更新状态（BATCH_X_LAST_PREFIX）
   ├─ 远程评测
   │   ├─ 构建评测命令
   │   ├─ SSH 执行远程命令
   │   └─ 检查评测结果
   ├─ 结果下载
   │   ├─ 远程压缩输出
   │   ├─ 下载压缩包
   │   ├─ 本地解压
   │   └─ 清理临时文件
   └─ 更新批次状态（completed/failed）

4. 完成阶段
   ├─ 清理远程工作目录（可选）
   ├─ 生成完成标记文件（.eval_task.complete.state）
   ├─ 清理本地临时文件
   └─ 输出统计信息
```

#### 3.2 断点续传流程
```
场景1: 上传中断
   ├─ 检测到 BATCH_X_STATUS=running
   ├─ 读取 BATCH_X_LAST_PREFIX="img005"
   ├─ MD5 校验 img005 的所有文件
   │   ├─ 通过 → 从 img006 开始上传
   │   └─ 失败 → 从 img005 重新上传
   └─ 继续后续流程

场景2: 评测失败重试
   ├─ 检测到 BATCH_X_STATUS=failed
   ├─ 批量 MD5 校验远程所有文件
   │   ├─ 全部通过 → 跳过上传，直接重新评测
   │   └─ 有失败 → 重新上传该批次
   └─ 重试计数 +1（最多3次）

场景3: 完全中断后恢复
   ├─ 读取状态文件
   ├─ 批次0: completed → 跳过
   ├─ 批次1: running → 续传
   ├─ 批次2: pending → 正常执行
   └─ 批次3-N: pending → 正常执行
```

#### 3.3 实时状态更新
```
每上传一个数据项:
   ├─ 调用 update_batch_last_prefix()
   ├─ 更新 BATCH_X_LAST_PREFIX="current_prefix"
   └─ 调用 update_running_info()
       ├─ 更新 RUNNING_CURRENT_BATCH
       ├─ 更新 RUNNING_BATCH_COMPLETED
       ├─ 更新 RUNNING_TIMESTAMP
       └─ 原子写入状态文件（临时文件 + mv）

task_eval.sh 监控模式:
   └─ 每10秒读取状态文件
       └─ 读取第2-8行 RUNNING_ 字段
           └─ 显示实时进度
```

---

## 📁 目录结构与文件说明

### 1. 输入目录结构
```
EVAL_DIR/                    # 评测集目录（例如 taskA/dataset1）
├── .eval_config             # 配置文件（可选）
├── IN_SUBDIR/               # 数据集子目录（默认 yuv）
│   ├── img001_y.bin
│   ├── img001_uv.bin
│   ├── img002_y.bin
│   ├── img002_uv.bin
│   └── ...
└── .eval_task.state         # 状态文件（自动生成）
```

### 2. 输出目录结构
```
EVAL_DIR/
├── OUT_SUBDIR/              # 输出子目录（默认 output）
│   ├── img001_out.bin       # 评测输出
│   ├── img002_out.bin
│   └── ...
├── .eval_task.state         # 状态文件
└── .eval_task.complete.state  # 完成标记文件
```

### 3. 远程目录结构
```
REMOTE_WORK_DIR/             # 远程工作目录（例如 /root/eval_taskA_dataset1）
├── model/
│   └── model.hbm            # 上传的模型文件
├── REMOTE_INPUT_DIR/        # 输入目录（默认 test_data）
│   ├── img001_y.bin
│   ├── img001_uv.bin
│   ├── img001_y.bin.md5     # MD5 校验文件
│   └── img001_uv.bin.md5
└── REMOTE_OUTPUT_DIR/       # 输出目录（默认 out）
    └── img001_out.bin
```

---

## 🔧 配置参数详解

### 1. 远程评测配置
| 参数 | 默认值 | 说明 |
|------|--------|------|
| `MODEL_FILE_EXT` | `.hbm` | 模型文件扩展名 |
| `REMOTE_MODEL_FILE0` | `model/model.hbm` | 第一个模型路径（相对于远程工作目录） |
| `REMOTE_MODEL_FILE1-3` | 空 | 额外模型路径（多模型场景） |
| `REMOTE_WORK_DIR` | `/root` | 远程工作目录 |
| `REMOTE_INPUT_DIR` | `test_data` | 远程输入目录（相对路径） |
| `REMOTE_OUTPUT_DIR` | `out` | 远程输出目录（相对路径） |
| `INPUT_SUFFIX_LIST` | `_y.bin,_uv.bin` | 文件后缀列表（逗号分隔） |
| `INPUT_NUM` | 自动计算 | 输入 tensor 文件数量 |
| `POST_PROCESS_PLUGIN` | 空 | 后处理插件名称 |
| `REMOTE_LOG_LEVEL` | `2` | 远程日志级别（0=DEBUG, 2=WARN） |
| `REMOTE_EVAL_CMD` | 见脚本 | 远程评测命令模板 |

### 2. 本地脚本配置
| 参数 | 默认值 | 说明 |
|------|--------|------|
| `SSH_HOST` | `root@10.2.101.112` | SSH 主机地址 |
| `SSH_PORT` | `22` | SSH 端口 |
| `SSH_KEY` | 空 | SSH 私钥路径（可选） |
| `MAX_BATCH_SIZE` | `200` | 每批最大文件数量 |
| `ENABLE_COMPRESSION` | `true` | 是否启用压缩传输 |
| `COMPRESSION_TEMP_DIR` | `/tmp/eval_compress` | 压缩临时目录 |
| `IN_SUBDIR` | `yuv` | 本地数据集子目录名 |
| `OUT_SUBDIR` | `output` | 本地输出子目录名 |
| `MODEL_DIR` | 空 | 模型文件目录（由 task_eval.sh 设置） |
| `VERBOSE` | `false` | 是否启用详细日志 |

---

## 📝 常见场景

### 场景1：基础评测
```bash
# 使用默认配置
bash eval.sh path/to/dataset

# 评测完成后查看结果
ls path/to/dataset/output/
```

### 场景2：自定义配置
```bash
# 使用环境变量
IN_SUBDIR=raw_data \
OUT_SUBDIR=results \
MAX_BATCH_SIZE=100 \
POST_PROCESS_PLUGIN=psnr \
bash eval.sh path/to/dataset
```

### 场景3：使用配置文件
```bash
# 创建配置文件
cat > path/to/dataset/.eval_config << EOF
IN_SUBDIR=yuv
OUT_SUBDIR=output.wp
MAX_BATCH_SIZE=150
POST_PROCESS_PLUGIN=ssim
INPUT_SUFFIX_LIST=_y.bin,_uv.bin
EOF

# 执行评测
bash eval.sh path/to/dataset
```

### 场景4：断点续传
```bash
# 第一次执行（中断）
bash eval.sh path/to/dataset
# Ctrl+C 中断

# 第二次执行（自动续传）
bash eval.sh path/to/dataset
# 输出: 检测到上次中断，最后上传的前缀: img050
# 输出: MD5 验证通过，从下一个前缀继续上传
```

### 场景5：远程配置调整
```bash
# 更换远程服务器
SSH_HOST=user@192.168.1.200 \
SSH_PORT=2222 \
REMOTE_WORK_DIR=/data/eval \
bash eval.sh path/to/dataset
```

### 场景6：多模型评测
```bash
# 配置多个模型
REMOTE_MODEL_FILE0=model/encoder.hbm \
REMOTE_MODEL_FILE1=model/decoder.hbm \
bash eval.sh path/to/dataset
```

### 场景7：禁用压缩（小文件或已压缩数据）
```bash
ENABLE_COMPRESSION=false bash eval.sh path/to/dataset
```

---

## ⚠️ 注意事项

1. **SSH 免密登录**：确保已配置 SSH 密钥，避免交互式输入密码
2. **远程工作目录**：确保有写权限，建议使用专用目录避免冲突
3. **磁盘空间**：
   - 本地压缩临时目录需要足够空间（约为数据集大小）
   - 远程工作目录需要容纳输入+输出数据
4. **网络稳定性**：
   - 不稳定网络建议减小 `MAX_BATCH_SIZE`
   - 启用 `ENABLE_COMPRESSION` 减少传输量
5. **状态文件**：
   - 不要手动编辑 `.eval_task.state`
   - 需要重新开始时删除该文件
6. **断点续传**：
   - 只支持同一批次内续传
   - 不支持跨批次回退
7. **并发执行**：
   - 同一数据集不要并发执行多个 eval.sh
   - 可以并发执行不同数据集（通过 task_eval.sh）

---

## 🐛 故障排查

### 1. 上传失败
**现象**：文件上传中断或 MD5 校验失败

**排查步骤**：
1. 检查网络连接：`ssh $SSH_HOST echo "test"`
2. 检查磁盘空间：`ssh $SSH_HOST df -h`
3. 检查权限：`ssh $SSH_HOST "ls -la $REMOTE_WORK_DIR"`
4. 禁用压缩重试：`ENABLE_COMPRESSION=false bash eval.sh ...`

### 2. 断点续传失败
**现象**：重新执行时没有从断点继续

**排查步骤**：
1. 检查状态文件是否存在：`ls -la path/to/dataset/.eval_task.state`
2. 查看状态文件内容：`cat path/to/dataset/.eval_task.state`
3. 检查 `BATCH_X_LAST_PREFIX` 字段
4. 手动清理状态文件重新开始：`rm path/to/dataset/.eval_task.state`

### 3. 评测命令执行失败
**现象**：远程评测工具返回非零退出码

**排查步骤**：
1. 启用详细日志：`VERBOSE=true bash eval.sh ...`
2. 检查远程评测工具：`ssh $SSH_HOST "which ./run"`
3. 手动执行评测命令：`ssh $SSH_HOST "cd /root && ./run eval --help"`
4. 检查 `REMOTE_EVAL_CMD` 配置是否正确

### 4. 结果下载失败
**现象**：输出目录为空或部分文件缺失

**排查步骤**：
1. 检查远程输出目录：`ssh $SSH_HOST "ls -la $REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR"`
2. 检查本地输出目录权限：`ls -la path/to/dataset/`
3. 手动下载测试：`scp $SSH_HOST:$REMOTE_WORK_DIR/$REMOTE_OUTPUT_DIR/* ./`

### 5. 压缩传输问题
**现象**：压缩上传/下载失败

**排查步骤**：
1. 检查 gzip 是否可用：`which gzip`
2. 检查远程是否支持：`ssh $SSH_HOST "which gunzip"`
3. 检查临时目录空间：`df -h /tmp`
4. 禁用压缩重试：`ENABLE_COMPRESSION=false bash eval.sh ...`

---

## 🧪 测试功能

### DRY-RUN 模式
用于测试脚本流程，不实际执行远程命令（SSH 连接、文件上传等）

```bash
# 启用 DRY-RUN，无延迟（立即完成）
./eval.sh -y path/to/dataset

# 启用 DRY-RUN，每个操作延迟2秒（模拟实际执行时间）
./eval.sh -y 2 path/to/dataset
```

**DRY-RUN 模式特性**：
- SSH 命令不实际执行，直接返回成功
- 文件上传/下载模拟为生成空文件
- MD5 校验返回本地文件的真实 MD5
- 支持设置延迟，方便观察批次处理流程
- 状态文件正常生成和更新

### 失败模拟（仅用于开发测试）
用于测试失败重试机制，必须配合 DRY-RUN 模式使用

```bash
# 模拟指定批次失败（批次3）
DRY_RUN_FAIL_BATCH=3 ./eval.sh -y path/to/dataset

# 模拟随机失败（30%概率）
DRY_RUN_FAIL_RATE=30 ./eval.sh -y path/to/dataset
```

**测试示例**：
```bash
# 测试批次3失败重试3次的场景
DRY_RUN_FAIL_BATCH=3 ./eval.sh -y -b 2 path/to/dataset

# 输出示例：
# [INFO] ========== 处理第 3/5 批 ==========
# [WARN] [DRY-RUN] 模拟批次 3 评测失败（指定批次）
# [ERROR] 第 3 批评测失败 (重试 0/3)
# [INFO] 批次 3 第 1 次重试
# [INFO] 远程数据 MD5 验证通过，跳过上传直接重试评测
# [WARN] [DRY-RUN] 模拟批次 3 评测失败（指定批次）
# ... (重复3次)
# [WARN] 失败: 1 个
```

---

## 📦 依赖要求

### 必需工具
- `bash` (4.0+)
- `ssh` / `scp`
- `md5sum`（Linux）或 `md5`（macOS）
- `gzip`（如果启用压缩）
- `find` / `grep` / `sed` / `awk`

### 远程服务器要求
- SSH 服务
- 评测工具（如 `./run eval`）
- `md5sum`（用于校验）
- `gunzip` / `tar`（如果使用压缩传输）
- 足够的磁盘空间

---

## 📝 版本历史

### v2.0 (2026-02-04)
- ✨ 新增失败重试机制（最多3次，智能跳过上传）
- ✨ 新增下载压缩功能（compress_download）
- ✨ 新增远程环境保护机制（备份和恢复 input/output/model）
- 🔧 DRY_RUN 改为数字参数（-1=关闭，>=0=启用，支持延迟）
- 🔧 变量命名统一化（DS_* → INPUT_*/IN_*）
- 🐛 修复 macOS 兼容性问题（移除 declare -a/-A）
- 🐛 修复 final_cleanup 无法找到完成状态文件的问题
- 🧪 新增失败模拟功能（DRY_RUN_FAIL_BATCH/RATE，用于测试）

### v1.0 (2026-01-15)
- 初始版本
- 支持批量上传、断点续传、MD5 校验
- 支持压缩传输（上传）
- 状态文件管理

---

**当前版本**: v2.0  
**最后更新**: 2026-02-04  
**配套脚本**: task_eval.sh v1.3
**兼容性**: macOS (bash 3.2+), Linux (bash 4.0+)
