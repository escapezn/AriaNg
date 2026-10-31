# Aria2 自动化文件清理脚本 (Aria2 Cleaner)

针对 Aria2 与 AriaNg 用户日常使用中常见的文件残留痛点，本项目提供了 `scripts/clean.sh` 自动化清理脚本。该脚本基于 Aria2 原生事件钩子（Hook Scripts）实现，能够精准、安全地完成以下 4 项清理任务：

1. **删除正在下载的任务**：自动删除未完成的文件碎片、专属子目录及 `.aria2` 控制文件。
2. **下载出错**：自动删除失败残留的未完成文件及 `.aria2` 控制文件。
3. **下载完成**：自动删除可能遗留的 `.aria2` 控制文件。
4. **下载完成**：自动清理下载目录中由 Aria2 保存的 `.torrent` 种子元数据文件。

---

## 核心安全特性

- **严格区分「暂停」与「删除」**：
  Aria2 的 `on-download-stop` 在任务被「暂停（pause）」时同样会被触发。本脚本内置通过 Aria2 RPC 实时查询任务状态的机制。若检测到任务当前为 `paused`，将**严格跳过并完整保留所有已下载分片**，绝不误删。
- **BT 做种保护**：
  当 BT 任务下载达到 100% 仍在做种（seeding）期间，脚本不会强行删除相关种子元数据，待做种结束或用户手动移除时才执行清理，避免打断做种。
- **多文件与目录安全防护**：
  对于包含独立子目录的多文件 BT 任务，仅清理该任务专属的子目录，绝不会向上越级误删共享根下载目录（如 `/downloads`）。
- **三级依赖容错解析**：
  脚本优先使用 `jq` 解析 JSON-RPC 响应；若宿主机未安装 `jq`，自动回退至 `python3/python`；若无 Python 则回退至原生 POSIX 正则，完美适配极简 Docker 容器、Alpine Linux 及嵌入式 NAS 环境。

---

## 部署指南

### 1. 放置脚本并赋予执行权限

将 `scripts/clean.sh` 放置在运行 `aria2c` 的主机或容器内（例如 `/etc/aria2/clean.sh`）：

```bash
cp scripts/clean.sh /etc/aria2/clean.sh
chmod +x /etc/aria2/clean.sh
```

### 2. 配置环境变量（可选）

打开脚本或通过环境变量配置你的 Aria2 RPC 连接信息（默认适用于本机免密或默认端口）：

```bash
# Aria2 JSON-RPC 接口地址（默认为本地 6800 端口）
ARIA2_RPC_URL="http://127.0.0.1:6800/jsonrpc"

# Aria2 RPC 密钥令牌（若在 aria2.conf 中设置了 rpc-secret，请填在此处）
ARIA2_RPC_SECRET="your_secret_token_here"

# 调试日志开关（排查问题时可设为 true）
ENABLE_LOG="false"
LOG_FILE="/tmp/aria2_clean.log"
```

### 3. 在 `aria2.conf` 中添加事件钩子

在你的 `aria2.conf` 配置文件中添加以下配置项：

```ini
# 任务停止时执行（处理删除正在下载任务、做种结束清理）
on-download-stop=/etc/aria2/clean.sh

# 下载出错时执行（处理错误未完成文件清理）
on-download-error=/etc/aria2/clean.sh

# 普通下载完成时执行（清理残留 .aria2 文件）
on-download-complete=/etc/aria2/clean.sh

# （可选）BT下载完成时执行
# on-bt-download-complete=/etc/aria2/clean.sh
```

保存配置文件后，**重启 `aria2c` 守护进程**即可生效。

---

## Docker 容器部署示例

若您的 Aria2 运行在 Docker 容器中（例如 `p3terx/aria2-pro` 或其他标准镜像），可通过 Volume 挂载引入脚本：

```yaml
version: "3.8"
services:
  aria2:
    image: p3terx/aria2-pro
    container_name: aria2
    environment:
      - RPC_SECRET=your_token
      - ARIA2_RPC_SECRET=your_token
    volumes:
      - /path/to/aria2/config:/config
      - /path/to/downloads:/downloads
      - /path/to/scripts/clean.sh:/config/clean.sh:ro
    restart: unless-stopped
```

在容器的 `aria2.conf` 中引用：
```ini
on-download-stop=/config/clean.sh
on-download-error=/config/clean.sh
on-download-complete=/config/clean.sh
```

---

## 行为开关说明

脚本头部提供了以下功能开关，可按需微调：

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `DELETE_ON_REMOVE` | `true` | 删除任务时是否自动删除未完成的文件 |
| `DELETE_ON_ERROR` | `true` | 下载出错时是否自动删除未完成的文件 |
| `DELETE_CONTROL_FILE`| `true` | 是否自动清理 `.aria2` 控制文件 |
| `DELETE_TORRENT_FILE`| `true` | 是否自动清理已完成任务关联的 `.torrent` 种子文件 |

---

## 常见问题排查 (FAQ)

1. **为什么在 AriaNg 中暂停任务后，文件没有被删？**
   - 这是特意设计的安全机制。脚本识别到任务状态为 `paused`，会立即跳过清理，以保障断点续传能力。
2. **执行后没有删除文件？**
   - 检查脚本是否有执行权限：`chmod +x /etc/aria2/clean.sh`；
   - 检查 `aria2.conf` 中的 `rpc-secret` 是否与脚本内的 `ARIA2_RPC_SECRET` 一致；
   - 将 `ENABLE_LOG="true"` 打开，观察 `/tmp/aria2_clean.log` 的执行日志以定位原因。
