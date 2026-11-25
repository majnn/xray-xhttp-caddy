# xray-xhttp-caddy

适用于 Debian / Ubuntu（含 Oracle Cloud ARM64）的 **Caddy + 本地监听 Xray-core (`VLESS + XHTTP`)** 一键部署与交互式终端管理菜单。

## 架构特点

- **真实网站伪装**：Caddy 监听公网 `80/443`，自动申请并续期真实 TLS 证书，其余路径返回静态网页，外部探测无破绽。
- **Xray 本地监听**：Xray 仅监听 `127.0.0.1:10000`（不配 TLS、不对外暴露端口），由 Caddy 通过 `h2c`（`flush_interval -1`）反代指定隐蔽路径。
- **即装即用管理菜单**：安装后可通过 `xmenu` 或 `xh` 随时呼出菜单管理用户、路径、服务状态与 BBR。

---

## 一键安装并打开菜单

### `wget` 方式
```bash
bash <(wget -qO- https://raw.githubusercontent.com/majnn/xray-xhttp-caddy/main/install.sh)
```

### `curl` 方式
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/majnn/xray-xhttp-caddy/main/install.sh)
```

> 如果是全新 VPS，打开菜单后选择 **`9. 全新一键部署`**，输入已解析到本机的域名即可全自动完成部署。

---

## 日常快捷命令

安装完成后，脚本会保存在 `/usr/local/bin/xmenu` 并创建快捷命令 `/usr/local/bin/xh`：

```bash
# 打开交互式管理菜单
xmenu
# 或
xh

# 命令行直接查看状态摘要
xmenu status

# 命令行直接输出所有客户端导入链接
xmenu links
```

---

## 菜单功能列表

1. **查看节点配置与导入链接**：自动生成直连推荐版（`mode=auto`）和 Cloudflare CDN 备用版（`mode=packet-up`）的 `vless://` 链接。
2. **新增用户**：自动生成 UUID 并支持备注名称，安全修改 JSON 并校验后重启 Xray。
3. **删除用户**：按编号删除指定用户，修改前自动备份并在校验失败时回滚。
4. **修改 XHTTP 隐蔽路径**：支持随机生成或自定义路径，同步修改 Xray 与 Caddy 配置并双校验。
5. **服务管理**：重启、重载、停止 Xray & Caddy，查看状态与端口监听。
6. **查看服务日志**：查看或实时跟踪 Xray / Caddy 日志。
7. **开启系统原生 BBR**：写入 `/etc/sysctl.d/99-bbr.conf`（`fq` + `bbr`）并立即生效，不换内核。
8. **更新 Xray-core 与 Caddy**：保留现有配置升级到最新版。
9. **全新一键部署**：在新 VPS 上一键完成防火墙放行、Xray + Caddy + 静态伪装站 + BBR 全套部署。

---

## 甲骨文云（Oracle Cloud）使用提示

1. 部署前请先在甲骨文云控制台对应子网的 **安全列表（Security List）** 中放行入站 **TCP 80**、**TCP 443**（以及可选 **UDP 443** 用于 HTTP/3）。
2. 如在 Cloudflare 解析域名，建议直连节点先关闭橙色云朵（灰云仅 DNS）；若需套 CDN 防封，再开启橙色云朵并使用菜单输出中的 `mode=packet-up` 链接。
