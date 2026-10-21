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
- 择优时对每个候选 IP **重复探测多次**，按（真实服务通过次数↓，平均时延↑）排序；
- pin 文件**每台主机保留多个 IP**，`libpin.so` 把它们作为一个 **addrinfo 失败转移列表**返回——客户端连不上就自动试下一个。

**"能连通"不等于"能用"（本机实测，2026-10）**：候选池里存在这样的 IP——它对**任何**路径都回 `200 + text/plain "OK"`（4 字节），证书是有效的 `*.github.com`，`curl -I https://github.com` 全绿，但 `GET /` 从来不是 GitHub 的页面；另一类只对根路径回 GitHub 的错误页、对真实下载请求一律 `400`。这类 IP 在"只看 HTTP 状态码"的择优里会**排第一**（因为它最快），pin 上之后：网页/API 看着正常，`git` 报
`fatal: '…' does not appear to be a git repository`，压缩包下载失败——而失败发生在 TLS 成功**之后**的协议层，addrinfo 失败转移救不了（客户端只会去连列表里的第一个 IP）。因此探测改为两件事：
- **按主机校验"真的在提供该服务"**：探测各自**实际要用**的路径，并核对状态码 + `Content-Type` + 响应体大小（`github.com`→HTML、`api.github.com`→JSON、`codeload.github.com`→一个真实 tarball 的 `application/x-gzip`、`raw.githubusercontent.com`→一个真实文件的 `text/plain`）；
- **git 主机额外探测 git 协议端点**：`…/<公开仓库>.git/info/refs?service=git-upload-pack` 的响应必须以 pkt-line 服务宣告（`001e# service=git-upload-pack`）开头，才计入排名权重更高的那一档。

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
env LD_PRELOAD="$SO" curl -s -o /dev/null -w '%{http_code} %{content_type} %{remote_ip}\n' https://github.com
# 期望：200 text/html; charset=utf-8 <pin 文件里的某个 IP>
# 若 content_type 是 text/plain，说明 pin 到了只会回 "OK" 的负载均衡端点：
# 状态码看着正常，但 git 和下载一定会挂。

# git 必须单独验，它才是真正容易坏的那条路：
env LD_PRELOAD="$SO" git ls-remote --heads https://github.com/git/git.git | head -1

# getent 走 gethostbyname2，同样应返回 pin 里的 IP（而不是 /etc/hosts 或 DNS 的）：
env LD_PRELOAD="$SO" getent hosts github.com

# 压缩包下载（codeload 只有真正提供归档的 IP 才算可用）：
env LD_PRELOAD="$SO" curl -s -o /dev/null -w '%{http_code} %{content_type}\n' \
  https://codeload.github.com/octocat/Hello-World/tar.gz/refs/heads/master

crontab -l | grep github-road-linux     # 看到 */30 那条
cat ~/.hermes/github-pin                # 看到 github.com / api.github.com 等主机的 IP 列表
cat ~/.hermes/github-candidates         # 每轮验证过的 IP 会沉淀在这里，下轮优先作为候选
```

## 常用操作

| 目的 | 命令 |
|---|---|
| 立即修复（重选 IP 并验证） | `bash files/fix-now.sh` |
| 仅在当前 shell 激活 | `source files/gh-road-env.sh` |
| 手动重选 IP | `bash files/select-github-ip.sh` |
| 钉住/补充候选 IP | `echo 'github.com 20.205.243.166' >> ~/.hermes/github-candidates` |
| 查看当前候选学习池 | `cat ~/.hermes/github-candidates` |
| 无 cron 时启动常驻自愈 | `nohup bash files/github-road-daemon.sh >> ~/.hermes/github-road.log 2>&1 &` |
| 停止常驻自愈 | `kill $(cat ~/.hermes/.github-road-daemon.lock)` |
| 查看自愈日志 | `tail -f ~/.hermes/github-road.log` |
| 卸载（去 bashrc/crontab） | `bash files/uninstall.sh` |

## 关键设计说明

- **pin 文件** `~/.hermes/github-pin`：`<hostname> <ip>` 每行一条，同主机可多行（按优先级从上到下）。`libpin.so` 运行期读取，**改 IP 无需重新编译**。
- **`libpin.so`**：同时拦截 `getaddrinfo`（curl/git/libcurl 走这条，返回完整失败转移列表）和 `gethostbyname`/`gethostbyname2` 及其 `_r` 线程安全变体（`getent hosts`、老程序走这条，返回首个 pin IP）；其它域名一律走真实解析，对系统无副作用。
- **受管主机**：默认 `github.com api.github.com raw.githubusercontent.com objects.githubusercontent.com codeload.github.com gist.github.com`，可用 `GITHUB_ROAD_HOSTS` 覆盖。
- **候选 IP 四级来源（按优先级）**：**已验证学习池** → 本地 DNS 当前答案 → 公共 DoH（AliDNS / Cloudflare / DNSPod，用 `curl --resolve` 钉住 DoH 自身 IP，防被污染 DNS 劫持，同时保留证书校验）→ 硬编码兜底池。每主机上限 `GITHUB_ROAD_MAX_CANDIDATES`（默认 16）。
- **学习池** `~/.hermes/github-candidates`：`<hostname> <ip>` 每行一条（格式同 pin 文件，**可手工粘贴你知道的好 IP**）。每轮择优结束后，把**本轮通过服务校验**的 IP 前置写入（去重、每主机上限 `GITHUB_ROAD_MAX_LEARNED` 默认 12、`mktemp` + `mv` 原子替换）。存在的意义：硬编码池是一台运行中的机器上没人去更新的快照，而顶替它的 DoH 本身也是"能不能通"的问题（写这行时本机 3 个 DoH 里 Cloudflare 已不通）——没有沉淀，一个靠 DoH 发现的可用 IP 会在 DoH 不再返回它的那天永久消失。只收 IPv4（与 `libpin.so` 一致），非 IPv4 的行直接忽略，所以文件被写坏也不会把垃圾送进 curl 参数。
- **判定"可用"的尺度是服务本身，不是状态码**：`HOST_PROBE` 表为每台主机声明 `路径:可接受状态码:必需的 Content-Type` 前缀，外加响应体下限 `GITHUB_ROAD_MIN_BODY`（默认 64 字节）。未列出的主机退回 `/:200:` + 体积下限，光凭下限就能否掉 4 字节的 `"OK"` 端点。改探测路径/期望值只动这张表，不用改逻辑。
- **git 端点单独计分**：`github.com` 这类 git 主机除服务校验外还要过 `probe_git`（pkt-line 头匹配）。排序是（git 通过↓，服务通过↓，时延↑），所以"网页快但不懂 git"的 IP 永远不会挤掉真正能 `clone/push` 的 IP；若本轮**没有**任何 IP 提供 git 协议，脚本会明确输出"仅可用于 curl/API，git 仍需代理"，而不是假装成功。只验 `upload-pack`（fetch）**不验 `receive-pack`**（push）：健康的边缘对匿名 push 一律回 `401 No anonymous write access`，加这条检查会把所有候选判成坏的、结果一个 IP 都 pin 不上。
- **`objects.githubusercontent.com` 复用 `raw` 的结论**：它的 URL 全部带签名，没有稳定路径可探；但和 `raw` 是同一个 Fastly anycast 边缘（同为 `185.199.10x.133`），所以直接继承 `raw` 胜出的 IP（`HOST_ALIAS`）。作为别名主机它不再消耗自己的候选探测预算，且**必须排在被别名主机之后**。
- **last-known-good 保留**：某主机本轮全部候选都不可达时，**保留上一轮的 pin 并标注 `# stale since`**，而不是清空回退 DNS——这类机器上坏的恰恰是 DNS，回退等于把"慢"变成"彻底断"。
- **`GITHUB_ROAD_PIN`**：可指定 pin 文件位置；`libpin.so` 遵循同一环境变量（技能包内所有脚本一致）。
- 可用 `GITHUB_ROAD_PROBES`（默认 5）调服务探测次数、`GITHUB_ROAD_GIT_PROBES`（默认 2）调 git 端点探测次数、`GITHUB_ROAD_TOP_K`（默认 3）调每主机保留的 IP 数、`GITHUB_ROAD_INTERVAL`（默认 1800s）调常驻 loop 间隔。

## ⚠️ 局限性（如实说明）

- **探测依赖两个公开仓库**：`raw` 用 `git/git/master/README.md`，`codeload` 用 `octocat/Hello-World` 的 tarball（258 字节）。它们若改名/删除，对应主机会"探测全失败 → 不 pin → 回退 DNS"，是**失效安全**方向，但要恢复该主机得改 `HOST_PROBE` 里的路径（或用 `GITHUB_ROAD_HOSTS` 先去掉它）。同理，GitHub 调整某主机的 `Content-Type` 也会让它暂时选不出 IP——判断依据是"这台主机是否在提供它该提供的内容"，宁可空着也不 pin 一个假端点。
- **SSH 推送（`ssh github.com` 22 或 443）无法在本方案下修复**：这类网络对 GitHub 的 SSH 端口整体超时/重置，与按 IP 轮换无关。请把远端改成 **HTTPS**（`https://github.com/<org>/<repo>.git`）。
- **不经 libc 的程序拦不住**：静态链接且自带 DNS 解析的程序（如 Go 纯 Go resolver 编译的单体）、直接用 `res_query` 的工具（`dig`/`nslookup`）不调 `getaddrinfo`/`gethostbyname`，shim 对它们无效。测试时别用 dig 判断成败，用 `curl -w '%{remote_ip}'`。
- **无 cron 守护进程时 crontab 自愈不执行**（容器/proot 常见）：`install.sh` 会警告，用 `github-road-daemon.sh` 常驻替代；机器重启后 daemon 需自行拉起（无 systemd 时放进启动脚本）。
- 若运营商升级为"对 github.com 全量封锁"（所有 IP 全 reset），择优脚本会保留旧 pin 并标注 stale；候选全部失效且旧 pin 也过期时，需更新兜底池或改用代理。**更新兜底池不必改脚本**：把可用 IP 追加进 `~/.hermes/github-candidates` 即可（它优先级最高）；反之，网络恢复后新一轮择优会自动把重新验证通过的 IP 排到该文件最前。
- **`LD_PRELOAD` 全局注入**：安装脚本把它写进 `~/.bashrc`，只重写 pin 中的域名，风险低；若担心，可改用 `gh-road-env.sh` 按需 `source`。
- 择优结果依赖**当下**的探测；网络剧烈抖动时，每 30 分钟会重新择优劣化。

## 📁 文件说明（files/）

| 文件 | 用途 |
|---|---|
| `libpin.c` | `LD_PRELOAD` shim：拦截 `getaddrinfo`（多 IP 失败转移）与 `gethostbyname`/`gethostbyname2`（含 `_r` 变体，返回首个 pin IP）；读取 pin 文件。 |
| `libpin.so` | `install.sh` 用 gcc 编译产物（运行期依赖，不纳入版本库）。 |
| `select-github-ip.sh` | 择优核心：学习池/本地 DNS/DoH/兜底池四级候选，并行探测；按"该主机是否真的提供对应服务"（`HOST_PROBE`）+ git 协议端点计分，排序写 top-K，并把验证过的 IP 沉淀回学习池；全挂时保留旧 pin（stale 标注）。 |
| `install.sh` | 一键安装：编译 + 初次择优 + bashrc 钩子 + crontab 自愈（幂等）+ cron 守护进程检测。 |
| `github-road-daemon.sh` | 常驻自愈 loop（flock 单实例，TERM 立即退出）：无 cron 守护进程时替代 crontab。 |
| `uninstall.sh` | 卸载 bashrc / crontab 钩子。 |
| `fix-now.sh` | 立即重选并验证：既验 `curl https://github.com`，也验 `git ls-remote`（200 通过但 git 失效的 IP 只有这一步能发现）。 |
| `gh-road-env.sh` | 当前 shell 激活（`source`）。 |

> 本技能是 Windows 版 [`GitHub-Road`](../GitHub-Road/SKILL.md) 的 Linux 等价实现，二者可共存。
