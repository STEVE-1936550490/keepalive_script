# 多主机 keepalive

Bash 5+ / Linux。每台主机在有限时间内制造温和 CPU 和磁盘活动，不保证云服务商因此保留实例。默认目标整机 CPU 70%，每次 10 分钟。无需 Python、Node 或常驻远程 agent。

## 快速开始

```bash
cp -n config/hosts.conf.example config/hosts.conf
# 首次 checkout 创建密码文件；不要覆盖已有密码：
touch config/secrets.env
chmod 600 config/secrets.env
./keepalive.sh run --once --dry-run
./keepalive.sh run --once --host local --duration 30
./keepalive.sh start
./keepalive.sh status
./keepalive.sh stop
./keepalive.sh restart
```

`--once` 是快速测试模式：第一台立即执行，后续主机随机错开几秒，按顺序运行且不会重叠；不等待两小时。常驻 `run` / `start` 才采用正式分钟调度。`run --dry-run` 可查看正式调度；`run --once --dry-run` 查看测试调度。dry-run 不运行 worker、不产生 CPU/磁盘测试负载，但会做 SSH 连通性探测并写日志。只需 30 秒测试时务必加 `--once`。

## 主机和密码

编辑 `config/hosts.conf`，每行 10 个竖线分隔字段：

```text
# NAME|TYPE|USER|PRIVATE_IP|PUBLIC_IP|PORT|AUTH|PASSWORD_ENV|KEY_FILE|ENABLED
local|local|||||local|||1
cloud01|remote|root|10.10.0.11|1.2.3.4|22|password|CLOUD01_PASSWORD||1
cloud02|remote|ubuntu|10.10.0.12|5.6.7.8|22|password|CLOUD02_PASSWORD||1
cloud03|remote|root||9.9.9.9|22|key||/root/.ssh/id_rsa|1
```

示例远程条目默认禁用，改为真实地址并将末尾改为 `1`。不要把同一物理机器配置为多个条目或同时部署多个主控。真实 hosts.conf 和 secrets.env 均忽略提交。

仅在 `config/secrets.env` 中填写密码：

```bash
CLOUD01_PASSWORD='your-password'
CLOUD02_PASSWORD='your-password'
```

这是可信 Bash 文件，密码里的单引号需按 Bash 规则转义。设置 `chmod 600 config/secrets.env`。密码通过 sshpass 的环境变量传递，不进入参数或日志；同用户/root 仍可能读取进程环境。不要开启 shell tracing，也不要在配置里打印秘密。

主控密码模式需要 `sshpass`：`sudo apt-get update && sudo apt-get install -y sshpass`。key 模式直接 `ssh -i`，支持 RSA 和 Ed25519；加密私钥请预先加载 ssh-agent。远程机器无需 sshpass。首次连接接受新 host key，已变更的 key 会拒绝；known_hosts 由 OpenSSH 管理。

先用 `./keepalive.sh run --once --host cloud01 --dry-run` 验证地址，再用 `./keepalive.sh run --once --host cloud01 --duration 30` 测试一台。内网优先，连接超时 5 秒，单次探测总限时 8 秒；失败自动尝试公网。本轮激活复用选中 IP，下轮重新探测。连接失败记 WARN、继续其他主机；单轮有失败时返回非零。

## 参数与调度

编辑 `config/settings.env`（可信 Bash 文件）：

| 参数 | 默认 | 含义 |
|---|---:|---|
| TARGET_CPU | 70 | 整机 CPU 目标百分比 |
| MAX_CPU | 80 | 采样达到此值暂停自身 CPU 负载，不允许大于 80 |
| ACTIVE_DURATION_MIN | 10 | 每台每次持续分钟 |
| INTERVAL_MEAN_MIN | 120 | 本轮起点之后的调度中心分钟 |
| INTERVAL_SPREAD_MIN | 35 | 调度中心两侧范围 |
| MIN_FREE_MB | 1024 | 写入后需保留的最小空间 |
| WORK_DIR | /tmp/keepalive_io | 专用临时目录，不要填写业务目录 |
| LOG_MAX_BYTES | 10485760 | 主日志轮转阈值 |

`ACTIVE_DURATION_SEC=30 ./keepalive.sh run --once` 或 `--duration 30` 覆盖持续时间。`KEEPALIVE_CONFIG_DIR=/absolute/path` 可换配置目录。settings.env 中显式值优先于同名环境变量。

正式调度将 `[mean-spread, mean+spread]` 划分为 N 个时间槽，每槽以 6 个 `$RANDOM` 平均生成中心偏向的随机时间，时间有序且互不相同，再随机轮换主机分配。所有 offset 相对于本轮起点；主机串行执行，若前一台未结束则下一台延迟。每台执行一次后开启下一轮。**120 分钟是轮内 offset 的中心，不是单台两次启动的固定周期**；实际重复间隔还包含上一轮等待和执行时间。

## 负载与清理

CPU 用 `/proc/stat`（不重复统计 guest），`nproc` 个 Bash busy/sleep 循环按 200ms duty cycle 运作，分散相位；每 3 秒反馈修正，已有业务负载计入目标。达到 MAX_CPU 后最多一个 duty cycle 内暂停新增负载，业务降下来后恢复。80% 是采样保护阈值，无法限制业务自身负载或承诺瞬时 CPU 永不超阈值。容器 quota、CPU affinity 和宿主 `/proc/stat` 范围不一致时可能无法达到整机目标；日志提示 affinity 限制，不追求目标而无限增加占空比。

启动后约 3 秒做一次磁盘检查，以便短测覆盖 I/O，此后每 30–90 秒随机一次。每次写/读 32–128 MiB；实际空闲需覆盖文件大小和 MIN_FREE_MB，不足时跳过。使用 fdatasync；读可能命中缓存，不保证物理磁盘读流量。每个 dd 有 15 秒超时，文件属于独立 mktemp 子目录，退出删除。

主控用 flock 防重复启动，PID 文件记录 Linux 进程启动标识以识别过期 PID。TERM/INT/HUP 清理自身子进程。远程 Bash 通过 SSH stdin 传送，无需长期存储脚本，唯一 run id 对应 `/tmp/keepalive_ctl_<uid>_<runid>/`，stop 经另一个 SSH 连接写 cancel 标记；网络断开时靠 worker 自身 duration+10 秒 watchdog 和远端 timeout 自动终止。主控整体 activation 另有 duration+30 秒限时。SIGKILL、断电或不可中断内核 I/O 无法保证即时清理；常规退出无需人工清理。

日志 `logs/keepalive.log` 包含时间、级别、round、host、start/cpu/disk/finish/error。超过 10MiB 在下一条写入时轮转为 `.1`，保留一份。后台 stdout 丢弃，所有业务日志仍汇总到上述文件。

## systemd（可选）

```bash
./keepalive.sh stop
sudo ./scripts/install-systemd.sh
sudo systemctl start keepalive.service
sudo systemctl status keepalive.service
sudo systemctl stop keepalive.service
```

安装器只安装并 enable，不立即启动负载。默认以 root 运行；若改 User，需同时更改安装目录、日志、密钥等权限。使用 systemd 时由 systemctl 管理启停，避免与 nohup 混用。

## 验证

```bash
bash -n keepalive.sh worker.sh scripts/install-systemd.sh
bash tests/smoke.sh
bash tests/schedule.sh
bash tests/lifecycle.sh
bash tests/guards.sh
# 仅在已安装时：
command -v shellcheck >/dev/null && shellcheck *.sh scripts/*.sh
./keepalive.sh run --once --dry-run
./keepalive.sh run --once --host local --duration 30
./keepalive.sh run --once --host cloud01 --duration 30
```

还需要 Linux 常用 coreutils/procps 工具：sleep、df、mktemp、mkfifo、stat、mkdir、mv、rm，以及 bash、ssh、awk、grep、dd、nproc、date、timeout、nohup、flock。无需额外大型环境。

2026-09-18 本机验证：Ubuntu 24.04，32 核；30 秒真实测试 CPU 采样 68%–71%，85MiB 磁盘读写，正常退出后临时文件与控制目录均已清理。后台重复启动、活动中停止、调度等待中停止、三主机错峰、低空间跳过和 CPU 暂停保护均通过。保护测试降低阈值为 2%，以轻量负载触发分支，不会刻意把系统推到 80%。未安装 shellcheck；没有真实远程配置，远程上线验证尚未进行。sshpass 已通过临时 Ubuntu 官方源安装，系统原有源配置未修改。

## GitHub 备份

`.gitignore` 排除真实 hosts、密码、日志、PID、常见私钥。每次提交前检查 staged diff。

```bash
git add .
git diff --cached
git commit -m "feat: add multi-host keepalive scheduler"
# 已有 origin：
git push
# 没有 origin，需安装并登录 GitHub CLI：
gh auth login
gh repo create keepalive_script --private --source=. --remote=origin --push
```
