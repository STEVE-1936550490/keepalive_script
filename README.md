# 多主机 keepalive

Bash 5+ / Linux。每台主机在有限时间内制造温和 CPU 和磁盘活动，不保证云服务商因此保留实例。默认目标整机 CPU 70%，单次时长以 60 分钟为中心、在 45–75 分钟内随机。无需 Python、Node 或常驻远程 agent。

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

`--once` 是快速测试模式：第一台立即执行，后续主机随机错开几秒，按顺序运行且不会重叠；不等待两小时。常驻 `run` / `start` 在每次进程启动后立即执行第一轮，后续轮次采用原有分钟调度。`run --dry-run` 查看启动首轮计划；`run --once --dry-run` 查看测试调度。dry-run 不运行 worker、不产生 CPU/磁盘测试负载，但会做 SSH 连通性探测并写日志。只需 30 秒测试时务必加 `--once`。

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
| ACTIVE_DURATION_MIN | 60 | 每台每次持续时长的中心分钟 |
| ACTIVE_DURATION_SPREAD_MIN | 15 | 时长随机范围为中心 ± 此值；0 表示固定时长 |
| INTERVAL_MEAN_MIN | 120 | 本轮起点之后的调度中心分钟 |
| INTERVAL_SPREAD_MIN | 35 | 调度中心两侧范围 |
| MIN_FREE_MB | 1024 | 写入后需保留的最小空间 |
| WORK_DIR | /tmp/keepalive_io | 专用临时目录，不要填写业务目录 |
| LOG_MAX_BYTES | 10485760 | 主日志轮转阈值 |

每台主机每轮独立抽取时长：将 6 个 `$RANDOM` 的平均值映射到中心 ± spread，形成有界、近似正态的中心分布，以秒为单位，多数值集中在 60 分钟附近。`ACTIVE_DURATION_SEC=30 ./keepalive.sh run --once` 或 `--duration 30` 明确固定持续时间，不再随机，CLI 优先。`KEEPALIVE_CONFIG_DIR=/absolute/path` 可换配置目录。settings.env 中显式值优先于同名环境变量。

每次进程启动或重启，先随机生成整轮主机顺序和各台时长，然后立即执行第一台。首轮始终串行，上一台结束或跳过后便执行下一台，不插入调度等待；日志和页面按前面各台预计时长累计显示计划时间，实际会随连接开销、提前结束或失败跳过而变化。对已经运行的服务再次执行 `start` 不会重置调度。

从第二轮开始，沿用原有规则：将 `[mean-spread, mean+spread]` 划分为 N 个时间槽，每槽以 6 个 `$RANDOM` 平均生成中心偏向的随机时间，时间有序且互不相同。每轮使用 Fisher–Yates 完全打乱主机顺序，保持每台恰好执行一次。所有 offset 相对于本轮起点；主机串行执行，若前一台未结束则下一台延迟。每台执行一次后开启下一轮并等待其计划时间。**120 分钟是轮内 offset 的中心，不是单台两次启动的固定周期**；实际重复间隔还包含上一轮等待和执行时间。当前 9 台机器、单次平均 60 分钟，首轮约 9 小时，之后一轮约 10 小时。页面时间为计划估计，实际还需等待前一台结束。

## 负载与清理

CPU 用 `/proc/stat`（不重复统计 guest），`nproc` 个 Bash busy/sleep 循环按 200ms duty cycle 运作，分散相位；每 3 秒反馈修正，已有业务负载计入目标。达到 MAX_CPU 后最多一个 duty cycle 内暂停新增负载，业务降下来后恢复。80% 是采样保护阈值，无法限制业务自身负载或承诺瞬时 CPU 永不超阈值。容器 quota、CPU affinity 和宿主 `/proc/stat` 范围不一致时可能无法达到整机目标；日志提示 affinity 限制，不追求目标而无限增加占空比。

启动后约 3 秒做一次磁盘检查，以便短测覆盖 I/O，此后每 30–90 秒随机一次。每次写/读 32–128 MiB；实际空闲需覆盖文件大小和 MIN_FREE_MB，不足时跳过。使用 fdatasync；读可能命中缓存，不保证物理磁盘读流量。每个 dd 有 15 秒超时，文件属于独立 mktemp 子目录，退出删除。

主控用 flock 防重复启动，PID 文件记录 Linux 进程启动标识以识别过期 PID。TERM/INT/HUP 清理自身子进程。远程 Bash 通过 SSH stdin 传送，无需长期存储脚本，唯一 run id 对应 `/tmp/keepalive_ctl_<uid>_<runid>/`，stop 经另一个 SSH 连接写 cancel 标记；网络断开时靠 worker 自身 duration+10 秒 watchdog 和远端 timeout 自动终止。主控整体 activation 另有 duration+30 秒限时。SIGKILL、断电或不可中断内核 I/O 无法保证即时清理；常规退出无需人工清理。

日志 `logs/keepalive.log` 包含时间、级别、round、host、start/cpu/disk/finish/error。超过 10MiB 在下一条写入时轮转为 `.1`，保留一份。后台 stdout 丢弃，所有业务日志仍汇总到上述文件。

## systemd（可选）

```bash
./keepalive.sh stop
sudo ./scripts/install-systemd.sh
./keepalive.sh start
./keepalive.sh status
./keepalive.sh stop
./keepalive.sh restart
```

安装器同时安装 keepalive 和 Dashboard 两个服务，配置开机联动启动，不立即启动负载。安装后，`keepalive.sh` 和 `dashboard.sh` 的 `start/stop/restart/status` 都统一管理两个服务，并等待两者完成启停；status 分别显示两者状态。关闭 SSH 终端不会停止它们。停止后 3000 端口也关闭，启动或重启会重新生成首轮调度并立即开始活跃。

`keepalive.service` 启动时拉起 Dashboard，Dashboard 的 `PartOf` 依赖传播主控停止和重启；两者各自异常时由 systemd 重启。默认以 root 运行；若改 User，需同时更改安装目录、日志、密钥等权限。systemd 模式下启动参数从配置文件读取，`start --once` 等参数会被拒绝；临时测试仍使用 `run --once --duration 30`，需先停止已有主控以释放锁。未安装本目录的 systemd 服务时，两个脚本保留各自独立的 nohup 启停模式。

## 验证

```bash
bash -n keepalive.sh worker.sh scripts/install-systemd.sh
bash tests/smoke.sh
bash tests/schedule.sh
bash tests/randomization.sh
bash tests/lifecycle.sh
bash tests/service-control.sh
bash tests/guards.sh
# 已安装 systemd 时的联动测试：会启停服务、触发首轮负载并重置调度；活跃任务存在时跳过。
sudo bash tests/systemd-lifecycle.sh
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

## Dashboard：3000 端口监控

使用本机已有的 BusyBox httpd + Bash CGI，不需要 Python/Node 或 npm 包。网页只读，不会因打开页面而启动负载或 SSH 探测。安装上述 systemd 服务后，Dashboard 与 keepalive 一起启停：

```bash
./dashboard.sh start
./dashboard.sh status
./dashboard.sh stop
./dashboard.sh restart
```

默认监听 `0.0.0.0:3000`，浏览器打开 `http://主控服务器IP:3000`。首次启动自动生成独立访问密码，只有一个密码输入框，无需用户名：

```bash
# 仅在本机查看首次生成的 Dashboard 密码：
cat config/dashboard.password
# 交互式修改密码，不会回显，旧登录立即失效：
./dashboard.sh password
```

自定义密码支持 1–256 个字符，纯字母、纯数字或混合均可，不要求至少 12 位或包含特殊字符；只拒绝空密码及超长输入。

首次密码文件、密码哈希、会话均为私有文件并排除 Git。修改密码后删除首次密码文件；实际校验使用 `config/dashboard.auth` 中的 SHA-512 crypt 哈希。登录有效期 8 小时，Cookie 使用 HttpOnly / SameSite=Strict，每个来源 IP 在 5 分钟内连续失败 10 次后限制登录。该页面不使用任何服务器 SSH 密码，也不读取 secrets.env。

服务本身使用 HTTP；若跨公网访问，需在反向代理上配置 HTTPS，或使用 SSH 隧道以加密密码及会话传输。只开放给本机可执行：

```bash
DASHBOARD_BIND=127.0.0.1 ./dashboard.sh restart
# 在自己的电脑执行（替换主控服务器地址）：
ssh -N -L 3000:127.0.0.1:3000 root@主控服务器IP
# 然后打开 http://127.0.0.1:3000
```

直接从其他设备访问时，需要云安全组/防火墙允许你的来源地址访问 TCP 3000；脚本不会自动修改防火墙。上述环境变量启动方式仅适用于未安装 systemd 的 nohup 模式，该模式不会自动配置开机启动。

当前服务器使用联动的 systemd 服务托管调度和监控页，推荐通过 `./keepalive.sh` 统一管理。也可查看详细服务状态：

```bash
sudo systemctl status keepalive-dashboard.service
# 在其他服务器安装（兼容入口，也会安装两个服务）：
sudo ./scripts/install-dashboard-systemd.sh
./keepalive.sh start
```

systemd 模式下修改地址/端口请使用 `systemctl edit keepalive-dashboard.service` 设置 `[Service]` 的 `Environment=DASHBOARD_BIND=127.0.0.1` 或 `Environment=DASHBOARD_PORT=3001`，然后执行 `./keepalive.sh restart`。命令行环境变量不会自动传入 systemd 服务。

页面每 5 秒刷新主控 PID 与启动标识、启用状态、最近连接检查时间、当前轮次活跃状态、计划执行时间、最近 CPU 曲线、磁盘活动及事件。明确区分“最近登录成功”和“实时在线”，CPU 数据为最近活跃采样而非持续监控。远程主机尚未启用时显示“未启用”，Dashboard 不会替你启用它们。日志轮转或裁剪后，仅保留可读取的历史；断网时页面标记数据过期。

Dashboard 验证（测试使用已安装的 jq/curl；它们不是网页服务的运行依赖）：

```bash
bash tests/dashboard.sh
bash tests/dashboard-auth.sh
# HTTP 测试使用隔离目录和临时端口 13000，不停止正式 Dashboard：
bash tests/dashboard-http.sh
# 可选：仅当已有 Node 时验证浏览器兼容性；服务运行不依赖 Node：
node tests/dashboard-browser.cjs
# Dashboard 已运行时：模拟代理保持连接，验证 JSON 响应有明确长度：
node tests/dashboard-framing.cjs
```
