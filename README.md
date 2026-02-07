# SSH-BATCH-PROC - 远程评测自动化工具集

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)

远程评测自动化工具集，提供数据上传、模型部署、任务执行、结果下载的一站式解决方案。

## ✨ 核心功能

### 📦 eval.sh - 远程评测执行脚本
- 🚀 **批量上传处理** - 可配置批次大小，智能分组
- 🔄 **断点续传** - 支持中断恢复，避免重复传输
- ✅ **MD5 完整性校验** - 确保数据传输准确性
- 📦 **Gzip 压缩传输** - 节省约 50% 传输时间
- 🔌 **后处理插件系统** - 灵活扩展数据处理流程
- 📊 **实时状态追踪** - 完整的执行日志和进度跟踪
- 🛡️ **原子性保证** - 状态文件确保操作一致性

### 🔧 task_run.sh - 批量任务管理脚本
- 📋 **任务扫描与管理** - 自动发现和组织任务
- ⚡ **并发执行** - 支持多任务并行处理
- 📊 **实时监控** - 动态刷新任务执行状态
- 🔄 **断点续传** - 支持任务中断后继续执行
- 📝 **日志系统** - 完整的执行日志记录
- 🛑 **安全停止** - 优雅终止后台任务

## 🚀 快速开始

### eval.sh - 单个数据集评测

```bash
# 准备目录结构
# taskA/
# ├── model.xyz          # 模型文件
# └── dataset1/          # 数据集
#     └── yuv/           # 输入数据
#         ├── img001_y.bin
#         └── img001_uv.bin

# 基础执行
bash eval.sh taskA/dataset1

# 自定义配置
IN_SUBDIR=yuv OUT_SUBDIR=output bash eval.sh taskA/dataset1

# 启用压缩传输（推荐）
ENABLE_COMPRESSION=true bash eval.sh taskA/dataset1
```

### task_run.sh - 批量任务执行

```bash
# 1. 扫描任务
bash task_run.sh -s

# 2. 查看任务列表
bash task_run.sh -l

# 3. 并发执行（推荐）
bash task_run.sh -p 5

# 4. 监控执行状态
bash task_run.sh -m

# 5. 查看日志
tail -f task_run.log
```

## 📖 详细文档

- [eval.sh 完整文档](eval.md) - 远程评测脚本详细说明
- [task_run.sh 完整文档](task_run.md) - 批量任务管理脚本详细说明
- [配置示例](eval.config.example) - 配置文件模板

## ⚙️ 环境要求

- Bash 4.0+
- SSH 客户端
- rsync（用于文件传输）
- 可选：gzip（用于压缩传输）

## 📝 配置说明

### 全局配置

创建 `eval.config` 或 `.eval_config` 文件：

```bash
# 远程服务器配置
SSH_HOST=user@remote-server
SSH_PORT=22
SSH_KEY=/path/to/private_key

# 数据目录配置
IN_SUBDIR=yuv
OUT_SUBDIR=output

# 传输配置
MAX_BATCH_SIZE=100
ENABLE_COMPRESSION=true

# 模型配置
MODEL_FILE_EXT=.xyz
REMOTE_MODEL_FILE0=model/model.xyz
```

### 配置优先级

1. 命令行环境变量（最高优先级）
2. 数据集目录下的 `.eval_config`
3. 任务目录下的 `eval.config`
4. 脚本默认值（最低优先级）

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

MIT License

## 👤 作者

**wen.peng** - [wen.peng@me.com](mailto:wen.peng@me.com)

## 🌟 Star History

如果这个项目对你有帮助，欢迎点个 Star ⭐️
