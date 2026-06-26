# xui-sync

一个面向 `3x-ui` 多服务器场景的同步脚本集合。

本项目的设计目标很明确：

- 本地服务器不运行 `3x-ui`，只作为命令执行端
- 远程服务器运行 `3x-ui`
- 其中一台远程服务器由 `CONFIG_MASTER_NODE` 指定为配置主节点
- 用户识别按 `@` 前缀归并，例如 `USER@1`、`USER@2`、`USER@3` 视为同一用户家族
- 只同步用户流量和配置，不修改 `x-ui.db` 的数据结构

## 能做什么

- 同步各远程服务器上的用户流量
- 同步用户的当前流量和累计流量
- 重置所有用户流量，或按用户家族重置指定用户
- 从配置主节点同步 `users`、`inbounds`、`settings`
- 在本地命令端为配置主节点添加用户
- 删除某个用户家族
- 查看某个用户当前连接到哪些服务器

## 项目文件

- [`xui-sync.sh`](/D:/Documents/Codex/xui-sync/xui-sync.sh)：主脚本
- [`xui-sync.ps1`](/D:/Documents/Codex/xui-sync/xui-sync.ps1)：Windows PowerShell 启动器
- [`xui-sync.cmd`](/D:/Documents/Codex/xui-sync/xui-sync.cmd)：Windows 启动器，供 PowerShell / CMD 直接调用
- [`xui-sync.conf.example`](/D:/Documents/Codex/xui-sync/xui-sync.conf.example)：配置示例
- [`tests/smoke_sync.py`](/D:/Documents/Codex/xui-sync/tests/smoke_sync.py)：本地 smoke test

## 快速开始

### 1. 安装依赖

在每台 `3x-ui` 服务器上准备这些依赖：

```bash
apt-get update
apt-get install -y sqlite3 tar openssh-client openssh-server
```

### 2. 安装脚本

默认安装到 `/usr/local/bin`：

```bash
./xui-sync.sh install
```

指定本地安装目录：

```bash
./xui-sync.sh install /opt/bin
```

如果要拷贝到远程服务器：

```bash
./xui-sync.sh install --remote hostess.195522.xyz /root/bin 522
```

如果远端登录用户不是当前用户名，可以先设置 `INSTALL_REMOTE_USER=root`，或者直接用 `user@host` 形式的主机名。

如果你在 Windows 上把项目目录加入 `PATH`，建议直接用：

```powershell
xui-sync master
```

PowerShell 会优先调用仓库里的 `xui-sync.ps1`，再转到 Bash 主脚本。  
如果你在 `cmd.exe` 里执行，也可以直接用 `xui-sync.cmd master`。

### 3. 准备配置

复制配置文件：

```bash
cp xui-sync.conf.example xui-sync.conf
```

编辑 `xui-sync.conf`，配置节点列表：

```bash
NODES=(
  "sg-01|203.0.113.10|root|22|/usr/local/bin/xui-sync.sh"
  "jp-01|203.0.113.11|root|22|/usr/local/bin/xui-sync.sh"
)
CONFIG_MASTER_NODE="sg-01"
```

字段含义：

```text
节点名|服务器地址|SSH 用户|SSH 端口|远程脚本路径
```

## 核心命令

### 流量同步

```bash
./xui-sync.sh master
```

行为：

1. 远程执行每台节点的 `export`
2. 拉回各节点的数据库快照
3. 汇总所有节点的用户流量
4. 写回到各个在线节点

同步规则：

- 汇总用户的 `up`、`down`、`all_time`
- `last_online` 也会一起保留和同步
- 以 `email` / `username` 的 `@` 前缀作为同一用户家族
- 离线节点会跳过，不会强行覆盖

查看汇总结果：

```bash
./xui-sync.sh summary /var/lib/xui-sync/master/merged-traffic.db
```

`summary` 里的 `up`、`down`、`all_time` 也会以 `M` 为单位显示。
`summary` 里的 `last_online` 会改为东八区（UTC+8）的可读时间。
`summary` 输出列为 `user_key`、`up(M)`、`down(M)`、`all_time(M)`、`last_online_time`、`seen_count`。

### 流量重置

重置全部用户流量：

```bash
./xui-sync.sh reset-traffic
```

重置指定用户家族：

```bash
./xui-sync.sh reset-traffic USER
```

主服务器批量重置：

```bash
./xui-sync.sh master-reset-traffic
./xui-sync.sh master-reset-traffic USER
```

说明：

- 重置的是用户流量，不是服务器流量
- 会同时清零 `up`、`down`、`all_time`、`last_online`
- `reset-traffic-all` / `master-reset-traffic-all` 会额外清零 `inbounds` 里的流量字段

### 配置同步

```bash
./xui-sync.sh config-sync
```

它会：

1. 从所有节点导出配置快照
2. 从 `CONFIG_MASTER_NODE` 选择配置源
3. 同步到其他远程节点

会同步的配置表：

- `users`
- `inbounds`
- `settings`

不会修改的内容：

- `client_traffics`
- 任何 `x-ui.db` 的表结构

### 添加用户

```bash
./xui-sync.sh config-add-user alice StrongPassword123
```

这个命令会先在配置主节点添加或更新用户，然后再执行一次 `config-sync`。

### 删除用户

```bash
./xui-sync.sh delete-user USER
```

会按用户家族删除相关记录：

- `users`
- `client_traffics`
- `inbound_client_ips`
- 相关同步状态

### 查看在线状态

```bash
./xui-sync.sh user-status USER
```

会按 `online`、`seen`、`offline`、`not-found` 分组输出该用户在每台服务器上的状态，以及当前连接痕迹。
连不上的节点会单独出现在 `connection errors` 分组里。
每个分组都会重复输出自己的列头，方便单独复制查看。
输出中的 `last_online_time` 是按东八区（UTC+8）转换后的可读时间。
`user-status` 里的 `up`、`down`、`all_time` 会以 `M` 为单位显示。

这里的“在线”判断优先看当前连接痕迹；如果当前没有连接痕迹，但 `last_online` 还在最近窗口内，也会算作 `online`。
`last_online` 只作为上次在线时间展示，不会把很久以前的记录算成当前在线。
如果某个用户当前没有在线信号，但曾经出现过，`user-status` 可能显示为 `seen`。

### 查看最后在线时间

```bash
./xui-sync.sh user-last-online USER
```

这个命令只查看每台服务器上的最后在线时间，不判断当前是否在线。
输出中的 `last_online_time` 同样使用东八区（UTC+8）。

## 本地自检

可以在本地先跑 smoke test：

```bash
python tests/smoke_sync.py
```

它会检查这些关键行为：

- 配置同步按列名复制，兼容字段顺序变化
- `config-add-user` 的 upsert 行为
- 指定用户流量重置
- 删除用户家族
- 用户在线状态识别

## 环境变量

常用环境变量如下：

```bash
DB_PATH=/etc/x-ui/x-ui.db
WORKDIR=/var/lib/xui-sync
STATE_DB=/var/lib/xui-sync/state.db
MASTER_STATE_DB=/var/lib/xui-sync/master/state.db
SSH_CONNECT_TIMEOUT=5
USER_STATUS_ONLINE_GRACE_MS=60000
SYNC_INBOUND_TRAFFIC=0
CONFIG_MASTER_NODE=sg-01
SERVICE_NAME=x-ui
SERVER_ID=$(hostname -f 2>/dev/null || hostname)
STOP_SERVICE_ON_APPLY=1
```

## 备份与回滚

每次执行修改类命令前，脚本都会自动备份数据库到：

```text
/var/lib/xui-sync/backups/<UTC 时间>/x-ui.db
```

如果需要手工回滚：

```bash
systemctl stop x-ui
cp /var/lib/xui-sync/backups/<UTC 时间>/x-ui.db /etc/x-ui/x-ui.db
systemctl start x-ui
```

## 注意事项

- 远程节点需要能被本地命令端 SSH 访问
- 建议先用 `ssh` 单独验证每台节点连通性
- 不要把真实的 `xui-sync.conf` 和 `x-ui.db` 提交到公开仓库
- 用户家族是按 `@` 前缀匹配，不是按完整 email 字符串匹配
- 如果某台节点离线，脚本会按 `SSH_CONNECT_TIMEOUT` 等待后跳过
- `user-status` 把最近 `USER_STATUS_ONLINE_GRACE_MS` 毫秒内出现过的 `last_online` 视为当前在线

## Release Notes

### v0.1.0

这是当前公开版本，主要包含：

- 多节点用户流量汇总与同步
- 用户当前流量和累计流量同步
- 按用户家族进行流量重置
- 配置主节点驱动的配置同步
- 本地命令端添加用户
- 删除用户家族
- 查看用户在线状态

已知约束：

- 不修改 `x-ui.db` 的表结构
- 本地服务器只做命令执行端
- 远程节点离线时会跳过，不会强制写回
