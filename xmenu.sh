#!/usr/bin/env bash
# Xray (VLESS + XHTTP) + Caddy 交互式管理菜单
# 适用于 Debian / Ubuntu（含 Oracle Cloud ARM64）
# 采用独立多实例配置 (/usr/local/etc/xray/xhttp.json + xray@xhttp.service)，不干扰原有 Xray/sing-box 实例

XRAY_CONF="/usr/local/etc/xray/xhttp.json"
XRAY_SVC="xray@xhttp"
CADDY_CONF="/etc/caddy/Caddyfile"
BBR_CONF="/etc/sysctl.d/99-bbr.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[信息]${NC} $*"; }
warn()  { echo -e "${YELLOW}[警告]${NC} $*"; }
err()   { echo -e "${RED}[错误]${NC} $*"; }

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        err "请使用 root 权限运行（例如: sudo xmenu）"
        exit 1
    fi
}

require_python3() {
    if ! command -v python3 >/dev/null 2>&1; then
        warn "未检测到 python3，正在安装..."
        apt-get update -qq && apt-get install -y -qq python3
    fi
}

pause_enter() {
    echo ""
    read -rp "按回车键返回菜单..." _
}

# 读取当前运行状态到环境变量: CUR_DOMAIN, CUR_LISTEN, CUR_PORT, CUR_PATH, CUR_MODE, CUR_USER_COUNT
load_state() {
    CUR_DOMAIN="未配置"
    CUR_LISTEN="127.0.0.1"
    CUR_PORT="10000"
    CUR_PATH="未配置"
    CUR_MODE="auto"
    CUR_USER_COUNT="0"

    if [[ -f "$CADDY_CONF" ]] && command -v python3 >/dev/null 2>&1; then
        CUR_DOMAIN=$(python3 - "$CADDY_CONF" <<'PY'
import re, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            m = re.match(r'^([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?\s*\{', s)
            if m:
                print(m.group(1))
                sys.exit(0)
            m2 = re.match(r'^https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?\s*\{', s)
            if m2:
                print(m2.group(1))
                sys.exit(0)
except Exception:
    pass
print("未配置")
PY
)
    fi

    if [[ -f "$XRAY_CONF" ]] && command -v python3 >/dev/null 2>&1; then
        eval "$(python3 - "$XRAY_CONF" <<'PY'
import json, shlex, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    ib = (cfg.get("inbounds") or [{}])[0]
    listen = ib.get("listen", "127.0.0.1")
    port = str(ib.get("port", 10000))
    clients = (ib.get("settings") or {}).get("clients") or []
    ss = ib.get("streamSettings") or {}
    xs = ss.get("xhttpSettings") or {}
    path = xs.get("path", "未配置")
    mode = xs.get("mode", "auto")
    print(f"CUR_LISTEN={shlex.quote(str(listen))}")
    print(f"CUR_PORT={shlex.quote(port)}")
    print(f"CUR_PATH={shlex.quote(str(path))}")
    print(f"CUR_MODE={shlex.quote(str(mode))}")
    print(f"CUR_USER_COUNT={shlex.quote(str(len(clients)))}")
except Exception:
    pass
PY
)"
    fi
}

get_bbr_status() {
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]]; then
        echo -e "${GREEN}已开启 (${cc} / ${qdisc})${NC}"
    else
        echo -e "${YELLOW}未开启 (${cc} / ${qdisc})${NC}"
    fi
}

get_svc_badge() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    elif systemctl cat "$svc" >/dev/null 2>&1; then
        echo -e "${RED}已停止${NC}"
    else
        echo -e "${YELLOW}未安装${NC}"
    fi
}

get_xray_ver() {
    if command -v xray >/dev/null 2>&1; then
        xray version 2>/dev/null | head -n1 | awk '{print $2}'
    else
        echo "未安装"
    fi
}

get_caddy_ver() {
    if command -v caddy >/dev/null 2>&1; then
        caddy version 2>/dev/null | awk '{print $1}'
    else
        echo "未安装"
    fi
}

xray_supports_xhttp() {
    command -v xray >/dev/null 2>&1 || return 1
    local tmp_cfg rc=1
    tmp_cfg=$(mktemp /tmp/xray-xhttp-check.XXXXXX.json)
    cat > "$tmp_cfg" <<'EOF'
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 19999,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "00000000-0000-0000-0000-000000000000"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/test",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    if xray run -test -c "$tmp_cfg" >/dev/null 2>&1; then
        rc=0
    fi
    rm -f "$tmp_cfg"
    return "$rc"
}

ensure_xray_template_unit() {
    if [[ -f /etc/systemd/system/xray@.service || -f /lib/systemd/system/xray@.service || -f /usr/lib/systemd/system/xray@.service ]]; then
        return 0
    fi
    local xray_bin run_user run_group
    xray_bin=$(command -v xray)
    if id xray >/dev/null 2>&1; then
        run_user="xray"
        run_group="xray"
    else
        run_user="nobody"
        run_group="nogroup"
    fi
    cat > /etc/systemd/system/xray@.service <<EOF
[Unit]
Description=Xray Service (%i)
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
User=${run_user}
Group=${run_group}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
ExecStart=${xray_bin} run -config /usr/local/etc/xray/%i.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

print_status_box() {
    load_state
    local xray_st caddy_st xray_v caddy_v bbr_st
    xray_st=$(get_svc_badge "$XRAY_SVC")
    caddy_st=$(get_svc_badge caddy)
    xray_v=$(get_xray_ver)
    caddy_v=$(get_caddy_ver)
    bbr_st=$(get_bbr_status)

    echo -e "${CYAN}============================================================${NC}"
    echo -e "${BOLD}         Xray (VLESS + XHTTP) + Caddy 管理菜单${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo -e "  域名      : ${BOLD}${CUR_DOMAIN}${NC}"
    echo -e "  Xray      : ${xray_st} (实例: ${XRAY_SVC}, 版本: ${xray_v}) | 监听: ${CUR_LISTEN}:${CUR_PORT}"
    echo -e "  Caddy     : ${caddy_st} (版本: ${caddy_v}) | 端口: 80 / 443"
    echo -e "  XHTTP路径 : ${BOLD}${CUR_PATH}${NC} (mode: ${CUR_MODE})"
    echo -e "  配置文件  : ${XRAY_CONF}"
    echo -e "  用户数量  : ${CUR_USER_COUNT} 个"
    echo -e "  BBR 状态  : ${bbr_st}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
}

print_links() {
    require_python3
    load_state
    if [[ ! -f "$XRAY_CONF" ]]; then
        err "未找到 Xray 配置文件: $XRAY_CONF"
        return 1
    fi
    if [[ "$CUR_DOMAIN" == "未配置" ]]; then
        warn "未能从 $CADDY_CONF 解析到域名，链接中的域名将以 <DOMAIN> 占位。"
    fi

    python3 - "$XRAY_CONF" "$CUR_DOMAIN" <<'PY'
import json, sys, urllib.parse

conf_path, domain = sys.argv[1], sys.argv[2]
with open(conf_path, 'r', encoding='utf-8') as f:
    cfg = json.load(f)

ib = (cfg.get("inbounds") or [{}])[0]
clients = (ib.get("settings") or {}).get("clients") or []
xs = (ib.get("streamSettings") or {}).get("xhttpSettings") or {}
path = xs.get("path", "/")
mode = xs.get("mode", "auto")
enc_path = urllib.parse.quote(path, safe='')

if not clients:
    print("当前没有任何客户端用户。")
    sys.exit(0)

host = domain if domain != "未配置" else "<YOUR_DOMAIN>"
short_tag = host.split(".")[0] if "." in host else host

print(f"域名: {host} | 端口: 443 | 传输: xhttp | TLS: tls | Path: {path}")
print("-" * 60)
for idx, c in enumerate(clients, 1):
    uid = c.get("id", "")
    remark = c.get("email", "").strip()
    label = f"{short_tag}-{remark}" if remark else f"{short_tag}-xhttp"
    if len(clients) > 1 and not remark:
        label = f"{short_tag}-xhttp-{idx}"
    direct_link = (
        f"vless://{uid}@{host}:443"
        f"?encryption=none&security=tls&sni={host}&fp=chrome"
        f"&type=xhttp&path={enc_path}&mode={mode}#{urllib.parse.quote(label)}"
    )
    cf_link = (
        f"vless://{uid}@{host}:443"
        f"?encryption=none&security=tls&sni={host}&fp=chrome"
        f"&type=xhttp&path={enc_path}&mode=packet-up#{urllib.parse.quote(label + '-cf')}"
    )
    print(f"[{idx}] 备注: {remark or '(无)'} | UUID: {uid}")
    print(f"  直连推荐 (mode={mode}):")
    print(f"    {direct_link}")
    print(f"  CF橙云备用 (mode=packet-up):")
    print(f"    {cf_link}")
    print()
PY
}

list_users_brief() {
    python3 - "$XRAY_CONF" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    cfg = json.load(f)
clients = ((cfg.get("inbounds") or [{}])[0].get("settings") or {}).get("clients") or []
for idx, c in enumerate(clients, 1):
    uid = c.get("id", "")
    remark = c.get("email", "").strip() or "(无备注)"
    print(f"  [{idx}] {uid}  ({remark})")
PY
}

add_user() {
    require_python3
    if [[ ! -f "$XRAY_CONF" ]]; then
        err "未找到 Xray 配置文件: $XRAY_CONF"
        return 1
    fi
    local new_uuid remark
    new_uuid=$(xray uuid)
    read -rp "请输入用户备注 (可直接回车留空，例如 phone/mac): " remark
    remark=$(echo "$remark" | tr -d '\r\n' | xargs)

    cp -a "$XRAY_CONF" "${XRAY_CONF}.bak"
    if python3 - "$XRAY_CONF" "$new_uuid" "$remark" <<'PY'
import json, sys
conf_path, uid, remark = sys.argv[1], sys.argv[2], sys.argv[3]
with open(conf_path, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
clients = cfg["inbounds"][0]["settings"].setdefault("clients", [])
entry = {"id": uid}
if remark:
    entry["email"] = remark
clients.append(entry)
with open(conf_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    then
        if xray run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
            systemctl restart "$XRAY_SVC"
            info "用户添加成功！UUID: $new_uuid"
            echo ""
            print_links
        else
            err "Xray 配置校验失败，已自动回滚。"
            mv -f "${XRAY_CONF}.bak" "$XRAY_CONF"
        fi
    else
        err "写入配置失败，已自动回滚。"
        mv -f "${XRAY_CONF}.bak" "$XRAY_CONF"
    fi
}

del_user() {
    require_python3
    if [[ ! -f "$XRAY_CONF" ]]; then
        err "未找到 Xray 配置文件: $XRAY_CONF"
        return 1
    fi
    load_state
    if [[ "$CUR_USER_COUNT" -le 1 ]]; then
        warn "当前仅剩 1 个用户，不允许全部删空。如需更换凭证请先新增一个用户再删除旧用户。"
        return 0
    fi
    echo "当前用户列表："
    list_users_brief
    echo ""
    local idx
    read -rp "请输入要删除的用户编号 (输入 0 取消): " idx
    if [[ "$idx" == "0" || -z "$idx" ]]; then
        info "已取消。"
        return 0
    fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        err "请输入有效数字编号。"
        return 1
    fi

    cp -a "$XRAY_CONF" "${XRAY_CONF}.bak"
    local removed_uid
    if removed_uid=$(python3 - "$XRAY_CONF" "$idx" <<'PY'
import json, sys
conf_path, idx = sys.argv[1], int(sys.argv[2])
with open(conf_path, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
clients = cfg["inbounds"][0]["settings"].get("clients") or []
if idx < 1 or idx > len(clients):
    sys.exit(2)
removed = clients.pop(idx - 1)
with open(conf_path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(removed.get("id", ""))
PY
    ); then
        if xray run -test -c "$XRAY_CONF" >/dev/null 2>&1; then
            systemctl restart "$XRAY_SVC"
            info "已删除用户: $removed_uid"
        else
            err "Xray 配置校验失败，已自动回滚。"
            mv -f "${XRAY_CONF}.bak" "$XRAY_CONF"
        fi
    else
        err "编号无效或更新失败，已回滚。"
        mv -f "${XRAY_CONF}.bak" "$XRAY_CONF"
    fi
}

change_path() {
    require_python3
    if [[ ! -f "$XRAY_CONF" || ! -f "$CADDY_CONF" ]]; then
        err "缺少 Xray 或 Caddy 配置文件。"
        return 1
    fi
    load_state
    echo -e "当前 XHTTP 路径为: ${BOLD}${CUR_PATH}${NC}"
    local new_path
    read -rp "请输入新路径 (直接回车则自动生成随机路径): " new_path
    new_path=$(echo "$new_path" | tr -d '\r\n' | xargs)
    if [[ -z "$new_path" ]]; then
        new_path="/api/v2/sync-$(openssl rand -hex 4)"
    fi
    [[ "$new_path" != /* ]] && new_path="/${new_path}"
    new_path="${new_path%/}"
    if [[ -z "$new_path" || "$new_path" == "/" || "$new_path" =~ [[:space:]\"\'] ]]; then
        err "路径不合法（不能为根路径 /，也不能包含空格或引号）。"
        return 1
    fi

    cp -a "$XRAY_CONF" "${XRAY_CONF}.bak"
    cp -a "$CADDY_CONF" "${CADDY_CONF}.bak"

    if python3 - "$XRAY_CONF" "$CADDY_CONF" "$new_path" <<'PY'
import json, re, sys
xconf, cconf, new_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(xconf, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
cfg["inbounds"][0]["streamSettings"]["xhttpSettings"]["path"] = new_path
with open(xconf, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

with open(cconf, 'r', encoding='utf-8') as f:
    caddy_txt = f.read()

pattern = re.compile(r'^(\s*@xhttp\s+path\s+).*$', re.MULTILINE)
if not pattern.search(caddy_txt):
    raise RuntimeError("Caddyfile 中未找到 @xhttp path 指令")
caddy_txt = pattern.sub(rf'\g<1>{new_path} {new_path}/*', caddy_txt, count=1)
with open(cconf, 'w', encoding='utf-8') as f:
    f.write(caddy_txt)
PY
    then
        if xray run -test -c "$XRAY_CONF" >/dev/null 2>&1 && caddy validate --config "$CADDY_CONF" >/dev/null 2>&1; then
            systemctl restart "$XRAY_SVC"
            systemctl reload caddy
            info "路径已成功更改为: $new_path"
            echo ""
            print_links
        else
            err "新配置校验失败，已回滚 Xray 和 Caddy 配置。"
            mv -f "${XRAY_CONF}.bak" "$XRAY_CONF"
            mv -f "${CADDY_CONF}.bak" "$CADDY_CONF"
        fi
    else
        err "修改配置文件失败，已回滚。"
        mv -f "${XRAY_CONF}.bak" "$XRAY_CONF"
        mv -f "${CADDY_CONF}.bak" "$CADDY_CONF"
    fi
}

service_menu() {
    load_state
    echo ""
    echo "1) 重启 Xray (${XRAY_SVC}) 和 Caddy"
    echo "2) 仅重启 Xray (${XRAY_SVC})"
    echo "3) 仅平滑重载 Caddy"
    echo "4) 停止 Xray (${XRAY_SVC}) 和 Caddy"
    echo "5) 查看服务状态与端口监听"
    echo "0) 返回主菜单"
    local sub
    read -rp "请选择 [0-5]: " sub
    case "$sub" in
        1)
            systemctl restart "$XRAY_SVC" caddy
            info "已重启 ${XRAY_SVC} 和 Caddy。"
            systemctl is-active "$XRAY_SVC" caddy
            ;;
        2)
            systemctl restart "$XRAY_SVC"
            info "已重启 ${XRAY_SVC}: $(systemctl is-active "$XRAY_SVC")"
            ;;
        3)
            caddy validate --config "$CADDY_CONF" && systemctl reload caddy
            info "已重载 Caddy: $(systemctl is-active caddy)"
            ;;
        4)
            systemctl stop "$XRAY_SVC" caddy
            warn "已停止 ${XRAY_SVC} 和 Caddy。"
            ;;
        5)
            systemctl --no-pager -l status "$XRAY_SVC" caddy || true
            echo "--- 端口监听 ---"
            ss -tulpn | grep -E ":80 |:443 |:${CUR_PORT:-10000} " || ss -tulpn | grep -E 'xray|caddy' || true
            ;;
        0|"") return 0 ;;
        *) warn "无效选项。" ;;
    esac
}

logs_menu() {
    echo ""
    echo "1) 查看 Xray (${XRAY_SVC}) 最近 50 行日志"
    echo "2) 实时跟踪 Xray (${XRAY_SVC}) 日志 (Ctrl+C 退出)"
    echo "3) 查看 Caddy 最近 50 行日志"
    echo "4) 实时跟踪 Caddy 日志 (Ctrl+C 退出)"
    echo "0) 返回主菜单"
    local sub
    read -rp "请选择 [0-4]: " sub
    case "$sub" in
        1) journalctl -u "$XRAY_SVC" -n 50 --no-pager ;;
        2) trap 'echo ""' INT; journalctl -u "$XRAY_SVC" -f; trap - INT ;;
        3) journalctl -u caddy -n 50 --no-pager ;;
        4) trap 'echo ""' INT; journalctl -u caddy -f; trap - INT ;;
        0|"") return 0 ;;
        *) warn "无效选项。" ;;
    esac
}

enable_bbr() {
    cat > "$BBR_CONF" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null
    local cc qdisc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]]; then
        info "系统原生 BBR 已开启 (${cc} / ${qdisc})。"
    else
        warn "已写入配置，但当前内核返回: ${cc} / ${qdisc}，可能需要重启系统或检查内核支持。"
    fi
}

update_components() {
    info "正在更新 Xray-core（保留现有 config.json 与 ${XRAY_CONF}）..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    ensure_xray_template_unit
    info "正在更新 Caddy..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy
    systemctl restart "$XRAY_SVC" caddy
    info "更新完成！Xray: $(get_xray_ver) | Caddy: $(get_caddy_ver)"
}

open_firewall_ports() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null || true
        ufw allow 443/tcp >/dev/null || true
        ufw allow 443/udp >/dev/null || true
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -L INPUT -n 2>/dev/null | grep -qiE "REJECT|DROP"; then
        local reject_line
        reject_line=$(iptables -L INPUT -n --line-numbers | awk '/REJECT|DROP/{print $1; exit}')
        if [[ -n "$reject_line" ]]; then
            iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT "$reject_line" -p tcp --dport 80 -j ACCEPT
            iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT "$reject_line" -p tcp --dport 443 -j ACCEPT
            iptables -C INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT "$reject_line" -p udp --dport 443 -j ACCEPT
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1 || true
            elif [[ -d /etc/iptables ]]; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
        fi
    fi
}

is_port_in_use() {
    local p="$1"
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
}

fresh_deploy() {
    require_python3
    load_state
    local domain port web_root confirm ts reuse_self_port=0
    read -rp "请输入已解析到本机的域名 (例如 example.com): " domain
    domain=$(echo "$domain" | tr -d '\r\n' | xargs)
    domain=${domain#https://}
    domain=${domain#http://}
    domain=${domain%%/*}
    if [[ -z "$domain" ]]; then
        err "域名不能为空。"
        return 1
    fi

    while true; do
        read -rp "Xray 本地监听端口 [默认 10000]: " port
        port=${port:-10000}
        if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
            err "请输入 1024-65535 之间的端口号。"
            continue
        fi
        if is_port_in_use "$port"; then
            if [[ "$port" == "$CUR_PORT" ]] && systemctl is-active --quiet "$XRAY_SVC" 2>/dev/null; then
                info "端口 ${port} 当前正由本菜单管理的 ${XRAY_SVC} 占用，继续部署将停止旧实例并复用该端口。"
                reuse_self_port=1
                break
            fi
            warn "端口 ${port} 已被本机其他进程占用，请换一个未占用的本地端口（例如 10086）。"
            continue
        fi
        break
    done

    read -rp "伪装静态网站目录 [默认 /var/www/site]: " web_root
    web_root=${web_root:-/var/www/site}

    if [[ -f "$XRAY_CONF" || -f "$CADDY_CONF" ]]; then
        read -rp "检测到已有 ${XRAY_CONF} 或 ${CADDY_CONF}，继续将自动备份后覆盖（不会触碰 config.json），确认? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消。" && return 0
        ts=$(date +%Y%m%d%H%M%S)
        [[ -f "$XRAY_CONF" ]] && cp -a "$XRAY_CONF" "${XRAY_CONF}.bak.${ts}"
        [[ -f "$CADDY_CONF" ]] && cp -a "$CADDY_CONF" "${CADDY_CONF}.bak.${ts}"
    fi

    if [[ "$reuse_self_port" -eq 1 ]]; then
        systemctl stop "$XRAY_SVC" 2>/dev/null || true
    fi

    info "1/5 检查并放行防火墙 80/443 端口..."
    open_firewall_ports

    info "2/5 检查并准备 Xray-core（独立实例 ${XRAY_SVC}）..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl openssl gnupg debian-keyring debian-archive-keyring apt-transport-https

    if xray_supports_xhttp; then
        info "检测到本机已安装支持 XHTTP 的 Xray ($(get_xray_ver))，将直接复用（不重装、不改动原有 config.json）。"
    else
        info "未检测到支持 XHTTP 的 Xray，正在安装最新 Xray-core..."
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
    ensure_xray_template_unit

    local uuid secret_path
    uuid=$(xray uuid)
    secret_path="/api/v2/sync-$(openssl rand -hex 4)"
    mkdir -p /usr/local/etc/xray
    cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${secret_path}",
          "mode": "auto"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
    chmod 644 "$XRAY_CONF"
    xray run -test -c "$XRAY_CONF"
    systemctl enable --now "$XRAY_SVC"
    systemctl restart "$XRAY_SVC"

    info "3/5 安装并配置 Caddy 与伪装静态站..."
    if ! command -v caddy >/dev/null 2>&1; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy
    fi

    mkdir -p "$web_root"
    if [[ ! -f "${web_root}/index.html" ]]; then
        cat > "${web_root}/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Field Notes — Systems &amp; Edge Tooling</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 720px; margin: 56px auto; padding: 0 20px; line-height: 1.65; color: #1e293b; background: #f8fafc; }
    h1 { margin-bottom: 6px; }
    .sub { color: #64748b; margin-top: 0; }
    article { background: #fff; border: 1px solid #e2e8f0; border-radius: 10px; padding: 18px 22px; margin: 18px 0; }
    h2 { margin: 0 0 6px; font-size: 1.1rem; color: #2563eb; }
  </style>
</head>
<body>
  <h1>Field Notes</h1>
  <p class="sub">Engineering memos on telemetry pipelines and edge caching.</p>
  <article>
    <h2>Backpressure-Aware Ingestion Queues</h2>
    <p>Bounded ring buffers combined with adaptive batching keep memory footprints predictable under burst load.</p>
  </article>
  <article>
    <h2>HTTP/2 Connection Reuse</h2>
    <p>Disabling unnecessary proxy response buffering avoids head-of-line stalls for long-lived streams.</p>
  </article>
  <footer><small>&copy; 2026 ${domain}</small></footer>
</body>
</html>
HTML
        chmod -R 755 "$web_root"
    fi

    cat > "$CADDY_CONF" <<CADDY
${domain} {
    @xhttp path ${secret_path} ${secret_path}/*
    handle @xhttp {
        reverse_proxy h2c://127.0.0.1:${port} {
            flush_interval -1
        }
    }

    handle {
        encode gzip zstd
        root * ${web_root}
        file_server
    }
}
CADDY
    caddy validate --config "$CADDY_CONF"
    systemctl enable --now caddy
    systemctl restart caddy

    info "4/5 开启系统原生 BBR..."
    enable_bbr

    info "5/5 等待 Caddy 自动签发 TLS 证书 (约 6 秒)..."
    sleep 6
    echo ""
    print_links
}

change_domain() {
    require_python3
    if [[ ! -f "$CADDY_CONF" ]]; then
        err "未找到 Caddy 配置文件: $CADDY_CONF"
        return 1
    fi
    load_state
    echo -e "当前域名为: ${BOLD}${CUR_DOMAIN}${NC}"
    local new_domain
    read -rp "请输入新的域名 (请确认已解析到本机 IP): " new_domain
    new_domain=$(echo "$new_domain" | tr -d '\r\n' | xargs)
    new_domain=${new_domain#https://}
    new_domain=${new_domain#http://}
    new_domain=${new_domain%%/*}
    new_domain=$(echo "$new_domain" | tr '[:upper:]' '[:lower:]')

    if [[ -z "$new_domain" ]]; then
        err "域名不能为空。"
        return 1
    fi
    if ! [[ "$new_domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
        err "域名格式不合法: ${new_domain}"
        return 1
    fi
    if [[ "$new_domain" == "$CUR_DOMAIN" ]]; then
        info "新域名与当前域名一致，无需修改。"
        return 0
    fi

    cp -a "$CADDY_CONF" "${CADDY_CONF}.bak"
    if python3 - "$CADDY_CONF" "$new_domain" <<'PY'
import re, sys
cconf, new_dom = sys.argv[1], sys.argv[2]
with open(cconf, 'r', encoding='utf-8') as f:
    lines = f.readlines()

pat = re.compile(r'^(\s*)(?:https?://)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})((?::\d+)?\s*\{.*)$')
replaced = False
for i, line in enumerate(lines):
    s = line.strip()
    if not s or s.startswith('#'):
        continue
    m = pat.match(line)
    if m:
        lines[i] = f"{m.group(1)}{new_dom}{m.group(3)}\n"
        replaced = True
        break

if not replaced:
    raise RuntimeError("未能在 Caddyfile 中定位到站点域名行")

with open(cconf, 'w', encoding='utf-8') as f:
    f.writelines(lines)
PY
    then
        if caddy validate --config "$CADDY_CONF" >/dev/null 2>&1; then
            systemctl reload caddy
            info "域名已更换为 ${new_domain}，正在等待 Caddy 自动签发新证书 (约 6 秒)..."
            sleep 6
            echo ""
            print_links
        else
            err "Caddyfile 校验失败，已自动回滚。"
            mv -f "${CADDY_CONF}.bak" "$CADDY_CONF"
        fi
    else
        err "更新 Caddyfile 失败，已自动回滚。"
        mv -f "${CADDY_CONF}.bak" "$CADDY_CONF"
    fi
}

extract_caddy_web_root() {
    if [[ -f "$CADDY_CONF" ]] && command -v python3 >/dev/null 2>&1; then
        python3 - "$CADDY_CONF" <<'PY'
import re, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        for line in f:
            s = line.strip()
            if s.startswith('#'):
                continue
            m = re.match(r'^root\s+\*\s+(\S+)', s)
            if m:
                print(m.group(1))
                sys.exit(0)
except Exception:
    pass
PY
    fi
}

uninstall_menu() {
    load_state
    echo ""
    echo -e "${YELLOW}--- 卸载与释放端口 ---${NC}"
    echo "1) 仅停止并禁用服务（立即释放 80/443/本地端口，保留配置文件）"
    echo "2) 安全卸载本套 XHTTP + Caddy（保留原有 Xray 程序与 config.json）"
    echo "3) 彻底卸载（含 Xray-core 本体，仅限无其他 Xray 节点时使用）"
    echo "0) 返回主菜单"
    local sub confirm_rm rm_caddy rm_menu web_root
    read -rp "请选择 [0-3]: " sub
    case "$sub" in
        1)
            systemctl disable --now "$XRAY_SVC" caddy 2>/dev/null || true
            info "已停止并禁用 ${XRAY_SVC} 和 caddy。"
            echo "--- 当前端口检查 ---"
            if ss -tulpn | grep -E ":80 |:443 |:${CUR_PORT:-10000} "; then
                warn "仍有部分端口处于监听状态，请检查上方进程。"
            else
                info "80 / 443 / ${CUR_PORT:-10000} 端口已全部释放。"
            fi
            ;;
        2)
            read -rp "确认停止服务并删除本套 XHTTP 配置 (${XRAY_CONF})? [y/N]: " confirm_rm
            [[ ! "$confirm_rm" =~ ^[Yy]$ ]] && info "已取消。" && return 0
            web_root=$(extract_caddy_web_root)
            systemctl disable --now "$XRAY_SVC" caddy 2>/dev/null || true
            rm -f "$XRAY_CONF" "${XRAY_CONF}.bak"*
            info "已删除 ${XRAY_CONF}（未触碰原有 /usr/local/etc/xray/config.json）。"

            read -rp "是否一并卸载 Caddy 软件包并删除 Caddy 配置及伪装网页目录? [y/N]: " rm_caddy
            if [[ "$rm_caddy" =~ ^[Yy]$ ]]; then
                DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq caddy || true
                rm -rf /etc/caddy /var/lib/caddy
                if [[ -n "$web_root" && "$web_root" != "/" && "$web_root" == /var/www/* ]]; then
                    rm -rf "$web_root"
                fi
                info "已卸载 Caddy 并清理相关目录。"
            fi

            read -rp "是否一并删除管理脚本 (/usr/local/bin/xmenu 与 /usr/local/bin/xh)? [y/N]: " rm_menu
            if [[ "$rm_menu" =~ ^[Yy]$ ]]; then
                rm -f /usr/local/bin/xmenu /usr/local/bin/xh
                info "已移除 xmenu 与 xh，卸载完成。"
                exit 0
            fi
            info "安全卸载完成。"
            ;;
        3)
            warn "警告：此操作会彻底删除 Xray-core 本体及 /usr/local/etc/xray 下所有配置（含 config.json）！"
            read -rp "请输入大写 DELETE 确认彻底卸载: " confirm_rm
            if [[ "$confirm_rm" != "DELETE" ]]; then
                info "确认文字不匹配，已取消。"
                return 0
            fi
            web_root=$(extract_caddy_web_root)
            systemctl disable --now "$XRAY_SVC" xray caddy 2>/dev/null || true
            bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
            rm -f /etc/systemd/system/xray@.service
            rm -rf /usr/local/etc/xray
            systemctl daemon-reload
            DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq caddy || true
            rm -rf /etc/caddy /var/lib/caddy
            if [[ -n "$web_root" && "$web_root" != "/" && "$web_root" == /var/www/* ]]; then
                rm -rf "$web_root"
            fi
            rm -f /usr/local/bin/xmenu /usr/local/bin/xh
            info "已彻底卸载 Xray-core、Caddy 与管理脚本。"
            exit 0
            ;;
        0|"") return 0 ;;
        *) warn "无效选项。" ;;
    esac
}

show_menu() {
    while true; do
        clear 2>/dev/null || true
        print_status_box
        echo "   1. 查看节点配置与导入链接 (含直连 / CF 备用)"
        echo "   2. 新增用户 (生成新 UUID + 可选备注)"
        echo "   3. 删除用户"
        echo "   4. 修改 XHTTP 隐蔽路径 (同步更新 Xray & Caddy)"
        echo "   5. 服务管理 (重启 / 重载 / 停止 / 状态)"
        echo "   6. 查看服务日志 (Xray / Caddy)"
        echo "   7. 开启系统原生 BBR"
        echo "   8. 更新 Xray-core 与 Caddy 到最新版"
        echo "   9. 全新一键部署 (独立实例 xray@xhttp，不影响旧配置)"
        echo "  10. 更换域名 (自动重新签发真实 TLS 证书)"
        echo "  11. 卸载与释放端口 (停止释放 / 安全卸载 / 彻底卸载)"
        echo "   0. 退出"
        echo -e "${CYAN}============================================================${NC}"
        read -rp "请输入选项 [0-11]: " choice
        case "$choice" in
            1) echo ""; print_links; pause_enter ;;
            2) echo ""; add_user; pause_enter ;;
            3) echo ""; del_user; pause_enter ;;
            4) echo ""; change_path; pause_enter ;;
            5) service_menu; pause_enter ;;
            6) logs_menu; pause_enter ;;
            7) echo ""; enable_bbr; pause_enter ;;
            8) echo ""; update_components; pause_enter ;;
            9) echo ""; fresh_deploy; pause_enter ;;
            10) echo ""; change_domain; pause_enter ;;
            11) uninstall_menu; pause_enter ;;
            0) echo "已退出。"; exit 0 ;;
            *) warn "无效选项，请输入 0-11。"; sleep 1 ;;
        esac
    done
}

main() {
    require_root
    case "${1:-}" in
        status)
            print_status_box
            ;;
        links)
            print_links
            ;;
        -h|--help|help)
            echo "用法: xmenu [status|links|help]"
            echo "  无参数运行  : 进入交互式管理菜单 (快捷别名: xh)"
            echo "  xmenu status: 查看当前运行状态摘要"
            echo "  xmenu links : 输出所有用户的 VLESS+XHTTP 导入链接"
            ;;
        "")
            show_menu
            ;;
        *)
            err "未知参数: $1"
            echo "使用 xmenu --help 查看用法。"
            exit 1
            ;;
    esac
}

main "$@"
