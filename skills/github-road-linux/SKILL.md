---
name: github-road-linux
description: 让普通用户（无需 root、无需代理）在中国大陆的 Linux 机器上稳定访问 GitHub。这是 Windows 技能 GitHub-Road 的 Linux 移植版：用 getaddrinfo 的 LD_PRELOAD shim 替代 hosts 改写（免 root），用 crontab 替代计划任务，并保留"多 IP 实测择优 + 定时自愈"，另加多 IP 失败转移以对抗封锁抖动。当用户说"Linux 上 GitHub 打不开/连不上/DNS 指向的 IP 是黑洞/连接被 reset"、需要 git push 到 GitHub 官网但 SSH 被墙、或想把 GitHub-Road 用到服务器/集群节点上时使用。覆盖 HTTPS 网页与 git over HTTPS 推送；SSH(22/443) 推送在这类网络下无法修复。
---

# 🛣️ github-road-linux：Linux（无 root）稳定访问 GitHub

> 这是 Windows 技能 [`GitHub-Road`](../GitHub-Road/SKILL.md) 的 Linux 移植版。核心逻辑一致（**实测择优 + 定时自愈**），但两处 Windows 专属机制被替换：
> **改 `C:\...\hosts` → `getaddrinfo` 的 `LD_PRELOAD` shim**（无需 root）；**计划任务 → `crontab`**。

## 何时使用

- Linux 服务器 / HPC 集群节点上 `github.com` 打不开：DNS 能解析，但连上就 reset / 超时。
- `git clone`/`git push` 走 `git@github.com`（SSH）被墙，想改走 HTTPS 官网。
- 没有 root（改不了 `/etc/hosts`）、不想折腾代理。
- 从 Windows 的 `GitHub-Road` 迁移过来，需要等价能力。

## 为什么 Linux 版要这样改（原理）

**问题本质**：运营商对 `github.com` 按 **IP / SNI** 做封锁，且**被封锁的 IP 集合会轮换**。所以"把某个 IP 写死到 hosts"注定过一阵失效——这正是原技能要自愈的原因。

**Linux 上的两个现实约束**：
1. **写 `/etc/hosts` 需要 root**。集群/服务器上普通用户往往没有 root，`sudo` 也要密码 → 不能照搬 hosts 方案。
   → 用 **`LD_PRELOAD` 拦截 `getaddrinfo`**：任何用 getaddrinfo 的程序（`curl`、`git`/libcurl 等）解析 `github.com` 时，被重定向到 pin 文件里的 IP。**完全用户态，无需 root。**
2. **没有 Windows 计划任务**。
   → 用 **`crontab`** 每 30 分钟重跑择优脚本（本机无 user-systemd，故不用 systemd timer）。容器 / proot / 无 cron 守护的机器上 crontab 条目**装了也不会执行**：`install.sh` 会检测 cron/crond 是否真在跑，没有就明确警告，并给出 `github-road-daemon.sh` 常驻 loop 作为替代。

**针对"封锁抖动"的关键增强（相对原版）**：某些网络下**任何单个 IP 都可能在几分钟内从可用变 reset**。因此：
- 择优时对每个候选 IP **重复探测多次**，按（通过次数↓，平均时延↑）排序；
- pin 文件**每台主机保留多个 IP**，`libpin.so` 把它们作为一个 **addrinfo 失败转移列表**返回——客户端连不上就自动试下一个。

## 前置条件

- Linux（已在 CentOS 7 / x86_64 验证），普通用户即可，**无需 root**。
- `bash`、`curl`（系统自带）、`gcc`（仅安装时编译一次，之后运行不需要）、`crontab`（有守护进程在跑才有自愈；没有则装完用 `github-road-daemon.sh` 常驻替代）。
- 网络本身通（能开国内网站）。

## 安装（一次）

```bash
cd <本技能目录>/files
bash install.sh
```

`install.sh` 会：
1. 编译 `libpin.so` 并做健全性检查；
2. 运行一次 `select-github-ip.sh` 生成 `~/.hermes/github-pin`；
3. 在 `~/.bashrc` 追加一段 **幂等** 的激活块（存在 `libpin.so` 与 pin 文件时才 `export LD_PRELOAD`）；
4. 追加一条 **幂等** 的 crontab（`*/30 * * * *` 重跑择优）；
5. 检测 cron/crond 守护进程是否真在运行——没有则警告并给出常驻 loop 替代命令。

安装后：`source ~/.bashrc`（或开新 shell）使当前会话生效。

## 验证

```bash
SO="<本技能目录>/files/libpin.so"
env LD_PRELOAD="$SO" curl -s -o /dev/null -w '%{http_code} %{remote_ip}\n' https://github.com
# 期望：200 <pin 文件里的某个 IP>

# getent 走 gethostbyname2，同样应返回 pin 里的 IP（而不是 /etc/hosts 或 DNS 的）：
env LD_PRELOAD="$SO" getent hosts github.com

crontab -l | grep github-road-linux     # 看到 */30 那条
cat ~/.hermes/github-pin                # 看到 github.com / api.github.com 等主机的 IP 列表
```

## 常用操作

| 目的 | 命令 |
|---|---|
| 立即修复（重选 IP 并验证） | `bash files/fix-now.sh` |
| 仅在当前 shell 激活 | `source files/gh-road-env.sh` |
| 手动重选 IP | `bash files/select-github-ip.sh` |
| 无 cron 时启动常驻自愈 | `nohup bash files/github-road-daemon.sh >> ~/.hermes/github-road.log 2>&1 &` |
| 停止常驻自愈 | `kill $(cat ~/.hermes/.github-road-daemon.lock)` |
| 查看自愈日志 | `tail -f ~/.hermes/github-road.log` |
| 卸载（去 bashrc/crontab） | `bash files/uninstall.sh` |

## 关键设计说明

- **pin 文件** `~/.hermes/github-pin`：`<hostname> <ip>` 每行一条，同主机可多行（按优先级从上到下）。`libpin.so` 运行期读取，**改 IP 无需重新编译**。
- **`libpin.so`**：同时拦截 `getaddrinfo`（curl/git/libcurl 走这条，返回完整失败转移列表）和 `gethostbyname`/`gethostbyname2` 及其 `_r` 线程安全变体（`getent hosts`、老程序走这条，返回首个 pin IP）；其它域名一律走真实解析，对系统无副作用。
- **受管主机**：默认 `github.com api.github.com raw.githubusercontent.com objects.githubusercontent.com codeload.github.com gist.github.com`，可用 `GITHUB_ROAD_HOSTS` 覆盖。
- **候选 IP 三级来源**：本地 DNS 当前答案 + 公共 DoH（AliDNS / Cloudflare / DNSPod，用 `curl --resolve` 钉住 DoH 自身 IP，防被污染 DNS 劫持，同时保留证书校验）+ 硬编码兜底池。每主机上限 `GITHUB_ROAD_MAX_CANDIDATES`（默认 16）。被污染/错误的候选会在探测阶段因 TLS/HTTP 不通过自动出局。
- **last-known-good 保留**：某主机本轮全部候选都不可达时，**保留上一轮的 pin 并标注 `# stale since`**，而不是清空回退 DNS——这类机器上坏的恰恰是 DNS，回退等于把"慢"变成"彻底断"。
- **`GITHUB_ROAD_PIN`**：可指定 pin 文件位置；`libpin.so` 遵循同一环境变量（技能包内所有脚本一致）。
- 可用 `GITHUB_ROAD_PROBES`（默认 5）调探测次数、`GITHUB_ROAD_TOP_K`（默认 3）调每主机保留的 IP 数、`GITHUB_ROAD_INTERVAL`（默认 1800s）调常驻 loop 间隔。

## ⚠️ 局限性（如实说明）

- **SSH 推送（`ssh github.com` 22 或 443）无法在本方案下修复**：这类网络对 GitHub 的 SSH 端口整体超时/重置，与按 IP 轮换无关。请把远端改成 **HTTPS**（`https://github.com/<org>/<repo>.git`）。
- **不经 libc 的程序拦不住**：静态链接且自带 DNS 解析的程序（如 Go 纯 Go resolver 编译的单体）、直接用 `res_query` 的工具（`dig`/`nslookup`）不调 `getaddrinfo`/`gethostbyname`，shim 对它们无效。测试时别用 dig 判断成败，用 `curl -w '%{remote_ip}'`。
- **无 cron 守护进程时 crontab 自愈不执行**（容器/proot 常见）：`install.sh` 会警告，用 `github-road-daemon.sh` 常驻替代；机器重启后 daemon 需自行拉起（无 systemd 时放进启动脚本）。
- 若运营商升级为"对 github.com 全量封锁"（所有 IP 全 reset），择优脚本会保留旧 pin 并标注 stale；候选全部失效且旧 pin 也过期时，需更新兜底池或改用代理。
- **`LD_PRELOAD` 全局注入**：安装脚本把它写进 `~/.bashrc`，只重写 pin 中的域名，风险低；若担心，可改用 `gh-road-env.sh` 按需 `source`。
- 择优结果依赖**当下**的探测；网络剧烈抖动时，每 30 分钟会重新择优劣化。

## 📁 文件说明（files/）

| 文件 | 用途 |
|---|---|
| `libpin.c` | `LD_PRELOAD` shim：拦截 `getaddrinfo`（多 IP 失败转移）与 `gethostbyname`/`gethostbyname2`（含 `_r` 变体，返回首个 pin IP）；读取 pin 文件。 |
| `libpin.so` | `install.sh` 用 gcc 编译产物（运行期依赖，不纳入版本库）。 |
| `select-github-ip.sh` | 择优核心：DoH/本地 DNS/兜底池三级候选，并行探测，按通过次数/时延排序写 top-K；全挂时保留旧 pin（stale 标注）。 |
| `install.sh` | 一键安装：编译 + 初次择优 + bashrc 钩子 + crontab 自愈（幂等）+ cron 守护进程检测。 |
| `github-road-daemon.sh` | 常驻自愈 loop（flock 单实例，TERM 立即退出）：无 cron 守护进程时替代 crontab。 |
| `uninstall.sh` | 卸载 bashrc / crontab 钩子。 |
| `fix-now.sh` | 立即重选并验证。 |
| `gh-road-env.sh` | 当前 shell 激活（`source`）。 |

> 本技能是 Windows 版 [`GitHub-Road`](../GitHub-Road/SKILL.md) 的 Linux 等价实现，二者可共存。
