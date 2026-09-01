# vpsinit

面向全新 Debian VPS 的两个独立中文交互式管理工具。

## 支持范围

- 官方 Debian 12/13
- `amd64/x86_64`
- systemd
- root 用户执行

第一版本不支持 Ubuntu、ARM、Docker、无人值守模式、Komari Agent 或定期安全巡检。

## vpsinit

负责系统更新、安全加固和 Xray 管理：

- root 密码与单行 SSH 公钥
- SSH 高位端口，必须手动输入
- UFW、Fail2ban、自动安全更新
- LLMNR/5355 检查与关闭
- 公网 IPv6 检测；检测到 IPv6 时可选择关闭，并阻止在 IPv6 SSH 会话中误操作
- Xray VLESS + TCP + REALITY + Vision
- Xray UUID 和 Short ID 必须明确选择自动生成或手动输入
- REALITY 公私钥默认进入手动输入流程，也可选择自动生成
- REALITY 目标域名必须手动输入，不内置默认站点
- Xray 安装、升级、修改、卸载、状态和日志
- Xray 客户端链接和 Mihomo 配置仅写入当前终端，不进入工具日志或状态文件

首次安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chenqingjian/vpsinit/main/vpsinit.sh)
```

后续命令：

```bash
vpsinit
vpsinit system
vpsinit xray install
vpsinit xray upgrade
vpsinit xray configure
vpsinit xray uninstall
vpsinit xray status
vpsinit xray logs
vpsinit self-update
vpsinit self-uninstall
```

Xray 默认使用 `443/tcp`。如果端口已被其他服务占用，安装流程要求手动输入其他端口，不会停止或覆盖原服务。

## kmrinit

负责 Nginx、Let's Encrypt 证书和 Komari Server：

- Komari 官方最新稳定版 `linux-amd64` 二进制
- Komari 默认监听 `127.0.0.1:30774`
- Nginx固定使用 `80/443`
- IPv6 已关闭时自动省略 Nginx 的 IPv6 监听
- 仅指定域名可访问，直接 IP 和未知 Host 被拒绝
- 域名 A 记录检查、证书签发和自动续期
- 安装、升级、修改、卸载、状态和日志
- 修改域名或内部端口失败时自动恢复原 Komari、Nginx 和状态配置
- 安装前已经存在的同名证书或 Certbot 软件包不由 kmrinit 删除

首次安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chenqingjian/vpsinit/main/kmrinit.sh)
```

后续命令：

```bash
kmrinit
kmrinit install
kmrinit upgrade
kmrinit configure
kmrinit uninstall
kmrinit status
kmrinit logs nginx
kmrinit logs komari
kmrinit self-update
kmrinit self-uninstall
```

如果 Xray 已占用 `443`，`kmrinit` 会停止安装并提示先执行 `vpsinit xray configure` 修改 Xray 端口。

## 重要风险

- 修改 SSH 端口前，必须先在云厂商安全组放行新端口。
- 按当前需求，SSH 端口会一次性切换，不保留旧端口等待二次登录验证。
- 覆盖 root 公钥、卸载 Xray、卸载 Komari 整套服务等操作必须输入大写 `YES`。
- Komari 卸载会删除 Nginx、证书及全部 Komari 数据，不创建备份。
- 两个工具只面向基本干净的系统，检测到既有复杂配置时会停止，不自动接管。

## 本地检查

```bash
bash -n vpsinit.sh
bash -n kmrinit.sh
bash tests/static/test_vpsinit.sh
bash tests/static/test_kmrinit.sh
bash tests/static/test_public_repo.sh
```

完整设计与验收边界保存在本地 `docs/VPS初始化与Komari部署工具_方案设计.md`。`docs/` 目录仅用于本地方案材料，不提交到 Git。
