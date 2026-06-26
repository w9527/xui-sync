# 3x-ui 多服务器流量/配置同步脚本

这个项目用于从本地命令端同步多台服务器上的 `MHSanaei/3x-ui` SQLite 数据库信息，包含两类能力：

- **流量同步（Traffic Sync）**：汇总多节点用户流量，写回到各节点数据库
- **配置同步（Config Sync）**：以某台节点作为“配置主节点”，把配置覆盖同步到其他节点

默认行为偏安全：

- 每台远程节点先用 SQLite `.backup` 导出 `/etc/x-ui/x-ui.db` 快照（以及可选的本机状态库）。
- 本地命令端通过 SSH 拉取所有节点快照并合并。
- 用户流量按 `client_traffics.email` 的 `@` 前缀汇总 `up/down/all_time/last_online`，其中 `up/down` 是当前流量，`all_time` 是累计流量。
- 默认只同步用户流量字段；入站总流量与配置同步需要显式运行对应命令。
- 通过主服务器状态库记录“已计入基线”，避免每轮重复累计。

## 文件

- `xui-sync.sh`：主脚本，部署到主服务器和所有节点
- `xui-sync.conf.example`：主服务器节点配置示例（复制成 `xui-sync.conf` 使用）
- `tests/smoke_sync.py`：本地 smoke test，验证配置按列名同步和重置策略

## 节点准备

在每台 3x-ui 服务器上安装依赖：

```bash
apt-get update
apt-get install -y sqlite3 tar openssh-client openssh-server
```

复制脚本：

```bash
install -m 0755 xui-sync.sh /usr/local/bin/xui-sync.sh
```

测试本机导出：

```bash
/usr/local/bin/xui-sync.sh export
```

## 本地自检

如果你只想先验证脚本的核心逻辑，可以运行仓库里的 smoke test：

```bash
python tests/smoke_sync.py
```

它不依赖真实的 3x-ui 节点，只会在本地临时 SQLite 数据库里检查几个关键行为：

- 配置同步按列名复制，兼容字段顺序变化
- `inbounds` 的 `listen` / `enable` / `remark` 回填逻辑
- 批量重置失败时保留主服务器基线

如果 3x-ui 数据库不在默认路径，可以设置：

```bash
DB_PATH=/etc/x-ui/x-ui.db /usr/local/bin/xui-sync.sh export
```

## 主服务器配置

复制配置文件：

```bash
cp xui-sync.conf.example xui-sync.conf
```

编辑 `xui-sync.conf`：

```bash
NODES=(
  "sg-01|203.0.113.10|root|22|/usr/local/bin/xui-sync.sh"
  "jp-01|203.0.113.11|root|22|/usr/local/bin/xui-sync.sh"
)
```

字段含义：

```text
节点名|服务器地址|SSH 用户|SSH 端口|远程脚本路径
```

主服务器需要能免密 SSH 到每台节点。建议先逐台测试：

```bash
ssh root@203.0.113.10 '/usr/local/bin/xui-sync.sh export'
```

## 流量同步（Traffic Sync）

### 执行同步

在主服务器项目目录运行：

```bash
chmod +x ./xui-sync.sh
./xui-sync.sh master
```

同步过程：

1. 主服务器远程执行每台节点的 `export`
2. 主服务器通过 `scp` 拉回快照
3. 主服务器生成 `/var/lib/xui-sync/master/merged-traffic-<run_id>.db`
4. 主服务器把汇总库推送到每台节点
5. 节点备份当前数据库，停止 `x-ui`，写入汇总流量，启动 `x-ui`
6. 节点在独立状态库中记录本次写回后的基线状态，避免下一轮重复累计

### 避免重复合并（基线机制）

脚本不会每轮简单地把所有节点当前流量相加。主服务器会在独立状态库中维护全局总量和每个节点的已计入基线：

- 主服务器：`/var/lib/xui-sync/master/state.db`
- 节点本机：`/var/lib/xui-sync/state.db`

下一轮合并时大致按下面方式计算：

```text
新全局总量 = 上次全局总量 + 所有节点的新增量
节点新增量 = 节点当前值 - 主服务器记录的该节点已计入基线值
```

如果某台节点离线，本轮会跳过并不写回该节点，避免覆盖它离线期间的本地新增；下次上线成功导出后再计入全局汇总。

状态库路径可通过环境变量覆盖：

```bash
STATE_DB=/var/lib/xui-sync/state.db ./xui-sync.sh master
MASTER_STATE_DB=/var/lib/xui-sync/master/state.db ./xui-sync.sh master
SYNC_INBOUND_TRAFFIC=0 ./xui-sync.sh master
```

### 查看汇总结果

查看本机数据库前 20 个流量用户：

```bash
./xui-sync.sh summary /etc/x-ui/x-ui.db
```

查看主服务器生成的汇总库：

```bash
./xui-sync.sh summary /var/lib/xui-sync/master/merged-traffic-20260527T120000Z.db
```

### 入站总流量同步（可选）

默认不汇总入站流量。只有设置 `SYNC_INBOUND_TRAFFIC=1` 时，才会按 `inbounds.tag` 汇总入站 `up/down`（要求各节点 `tag` 一致）。

## 重置流量（清零）

> 注意：此操作会修改数据库并删除同步状态库，请确保你理解风险并提前做好备份。

### 仅清零用户流量（client_traffics）

- 本机节点执行：

```bash
./xui-sync.sh reset-traffic
```

- 主服务器批量执行（按 `NODES` 逐台 SSH 到节点执行）：

```bash
./xui-sync.sh master-reset-traffic
```

该批量命令会：
- 对每台节点执行 `reset-traffic`（清零 `client_traffics` 的流量字段）
- 删除每台节点的同步状态库（默认 `/var/lib/xui-sync/state.db`）
- 只有当所有节点都重置成功后，才会删除主服务器全局状态库（默认 `/var/lib/xui-sync/master/state.db`）
- 如果中途有节点失败，主服务器会保留全局状态库并返回失败，方便下一步人工检查或重试

如果要重置指定用户，可以直接传入用户键：

```bash
./xui-sync.sh master-reset-traffic alice bob
```

这里的用户键按 `client_traffics.email` 的 `@` 前缀匹配。

### 清零用户 + 入站流量（client_traffics + inbounds）

- 本机节点执行：

```bash
./xui-sync.sh reset-traffic-all
```

- 主服务器批量执行：

```bash
./xui-sync.sh master-reset-traffic-all
```

`reset-traffic-all` 会在清零 `client_traffics` 的同时，把 `inbounds` 表里的 `up/down/all_time`（存在这些列才会清零）一并清零，并删除同步状态库。

### 删除用户

删除某个用户家族时，可以直接在本地命令端运行：

```bash
./xui-sync.sh delete-user BENZY
```

这里的 `BENZY` 是用户键前缀，脚本会把 `BENZY@1`、`BENZY@2` 这类同前缀记录视为同一用户家族处理。

删除会同步清理：

- 各节点 `users` 表里的对应用户
- 各节点 `client_traffics` 和 `inbound_client_ips` 中同前缀记录
- 各节点本地流量状态库里的对应基线
- 本地命令端保存的主状态库里的对应基线

## 配置同步（Config Sync）

除了流量同步外，本脚本还支持同步 x-ui 配置（`users`、`inbounds`、`settings` 等表）。

### 配置主节点

编辑 `xui-sync.conf`，指定配置主节点：

```bash
CONFIG_MASTER_NODE="sg-01"   # 必须是 NODES 中的 node_name
```

> `CONFIG_SYNC_ENABLED` 不作为运行开关（保留字段/兼容用途）；是否同步配置取决于你是否执行 `config-sync` 命令。

### 配置同步流程

在主服务器上执行：

```bash
./xui-sync.sh config-sync
```

同步过程：

1. 主服务器远程执行每台节点的 `config-export`
2. 主服务器通过 `scp` 拉回配置快照
3. 主服务器从指定配置主节点提取配置，生成 `/var/lib/xui-sync/master/config-merged-<run_id>.db`
4. 主服务器把配置推送到其他节点并执行 `config-apply`

### 添加用户

如果你要在主配置节点上新增一个 `users` 里的用户，可以直接在本地命令端执行：

```bash
./xui-sync.sh config-add-user alice StrongPassword123
```

脚本会先把用户写入 `CONFIG_MASTER_NODE`，再执行一次 `config-sync` 同步到其他节点。

### 查看在线状态

查看某个用户当前连接到哪些服务器：

```bash
./xui-sync.sh user-status BENZY
```

脚本会按用户前缀检查各节点上的 `client_traffics` 和 `inbound_client_ips`，输出每个节点的在线状态、匹配到的 email、以及当前连接痕迹。

### 配置同步的约定

- 配置主节点是唯一真源，覆盖其他节点配置
- 导出和应用时按列名复制数据，尽量兼容 3x-ui 后续新增字段
- 同步的表：
  - `users`：系统用户（完全覆盖）
  - `inbounds`：入站配置（完全覆盖，但保留本地 `listen` / `enable` / `remark`）
  - `settings`：全局设置（完全覆盖）
- 不同步的表：`client_traffics`、`outbound_traffics`、`inbound_client_ips`、`history_of_seeders` 等本地数据表

### 定时执行（示例）

流量同步 cron（每 10 分钟）：

```cron
*/10 * * * * cd /root/xui-sync && /usr/local/bin/xui-sync.sh master >> /var/log/xui-sync.log 2>&1
```

配置同步 cron（每天 02:00）：

```cron
0 2 * * * cd /root/xui-sync && /usr/local/bin/xui-sync.sh config-sync >> /var/log/xui-sync-config.log 2>&1
```

## 回滚

每次应用汇总流量或配置前都会备份数据库：

```text
/var/lib/xui-sync/backups/<UTC 时间>/x-ui.db
```

需要回滚时：

```bash
systemctl stop x-ui
cp /var/lib/xui-sync/backups/<UTC 时间>/x-ui.db /etc/x-ui/x-ui.db
systemctl start x-ui
```
