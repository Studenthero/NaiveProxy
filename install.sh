#!/bin/bash
set -e

# ==================== 配置区 ====================
REPO="Studenthero/NaiveProxy"
INSTALL_DIR="/usr/local/naive"
SERVICE_FILE="/etc/systemd/system/naive.service"
CONFIG_FILE="${INSTALL_DIR}/naive.json"
HTML_DIR="${INSTALL_DIR}/html"
CERTS_DIR="/etc/naive/certs"
# ================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)  BINARY="caddy" ;;
    aarch64) BINARY="caddy" ;;
    *) error "不支持的架构: $ARCH"; exit 1 ;;
esac

# 获取最新 Release 下载链接
get_latest_download_url() {
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local asset_name="$BINARY"
    curl -fsSL "$api_url" | grep -o "\"browser_download_url\": *\"[^\"]*${asset_name}\"" | head -1 | cut -d'"' -f4
}

# 下载二进制
download_binary() {
    local url="$1"
    info "下载二进制: $url"
    curl -fsSL "$url" -o "${INSTALL_DIR}/naive.new"
    chmod +x "${INSTALL_DIR}/naive.new"
}

# 写 systemd 服务
write_service() {
    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=naive Service
After=network.target
Wants=network.target

[Service]
Type=simple
Environment=HOME=/root
WorkingDirectory=/usr/local/naive/
ExecStart=/usr/local/naive/naive run --config /usr/local/naive/naive.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 交互式配置（首次安装时）
interactive_config() {
    local domain port username password cert_path key_path

    echo ""
    info "配置 NaiveProxy（直接回车使用默认值）"
    read -p "  域名 [la.8888981.xyz]: " domain
    domain="${domain:-la.8888981.xyz}"

    read -p "  端口 [8443]: " port
    port="${port:-8443}"

    read -p "  用户名 [ID5E6B9]: " username
    username="${username:-ID5E6B9}"

    read -p "  密码 [R57SBS]: " password
    password="${password:-R57SBS}"

    read -p "  证书路径 [/etc/naive/certs/cert.crt]: " cert_path
    cert_path="${cert_path:-/etc/naive/certs/cert.crt}"

    read -p "  密钥路径 [/etc/naive/certs/private.key]: " key_path
    key_path="${key_path:-/etc/naive/certs/private.key}"

    # 生成 base64 认证
    local auth
    auth=$(echo -n "${username}:${password}" | base64)

    # 生成 naive.json
    cat > "$CONFIG_FILE" << EOF
{
  "admin": { "disabled": true },
  "logging": {
    "sink": { "writer": { "output": "stderr" } },
    "logs": { "default": { "writer": { "output": "stderr" } } }
  },
  "storage": { "module": "file_system", "root": "${INSTALL_DIR}/file_system/" },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":${port}"],
          "protocols": ["http1", "http2"],
          "routes": [{
            "handle": [{
              "handler": "subroute",
              "routes": [
                { "handle": [{
                    "auth_credentials": ["${auth}"],
                    "handler": "forward_proxy",
                    "hide_ip": true,
                    "hide_via": true,
                    "probe_resistance": {}
                }] },
                { "match": [{ "host": ["${domain}"] }],
                  "handle": [
                    {
                      "handler": "header",
                      "strip": ["Server", "Alt-Svc"]
                    },
                    {
                      "handler": "file_server",
                      "root": "${HTML_DIR}/",
                      "index_names": ["index.html", "index.htm"]
                    }
                  ],
                  "terminal": true
                }
              ]
            }]
          }],
          "tls_connection_policies": [{ "match": { "sni": ["${domain}"] } }],
          "automatic_https": { "disable": true }
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [{
          "certificate": "${cert_path}",
          "key": "${key_path}"
        }]
      }
    }
  }
}
EOF
    info "配置已写入: $CONFIG_FILE"
}

# 创建伪装站点目录
setup_html() {
    if [ ! -d "$HTML_DIR" ]; then
        mkdir -p "$HTML_DIR"
        warn "已创建伪装站点目录: $HTML_DIR"
        warn "请放入你的 index.html（不要留空，否则返回 404）"
    fi
}

# 主逻辑
main() {
    echo "============================================"
    echo "  NaiveProxy 安装/升级脚本"
    echo "  仓库: ${REPO}"
    echo "============================================"

    # 检测是否已安装
    local is_upgrade=false
    if [ -f "$INSTALL_DIR/naive" ]; then
        is_upgrade=true
        info "检测到已安装，执行升级"
    fi

    # 创建目录
    mkdir -p "$INSTALL_DIR" "$CERTS_DIR" "$HTML_DIR"

    # 下载二进制
    local url
    url=$(get_latest_download_url)
    if [ -z "$url" ]; then
        error "无法获取最新 Release 下载链接"
        error "请确认仓库 ${REPO} 有 Release 且包含文件: $BINARY"
        exit 1
    fi

    download_binary "$url"

    # 替换二进制
    if [ -f "$INSTALL_DIR/naive" ]; then
        mv "$INSTALL_DIR/naive" "${INSTALL_DIR}/naive.bak"
    fi
    mv "${INSTALL_DIR}/naive.new" "${INSTALL_DIR}/naive"
    info "二进制已更新: $(./${INSTALL_DIR}/naive version 2>/dev/null || echo 'version unknown')"

    # 写 systemd
    write_service

    # 配置
    if [ ! -f "$CONFIG_FILE" ]; then
        info "首次安装，进入配置"
        interactive_config
    else
        info "已有配置文件，跳过（如需重新配置请删除 $CONFIG_FILE 后重跑）"
    fi

    # 伪装站点
    setup_html

    # 启动
    systemctl enable naive
    systemctl restart naive
    sleep 2

    if systemctl is-active --quiet naive; then
        info "✅ NaiveProxy 运行正常"
        local port
        port=$(grep -oP '":\K[0-9]+' "$CONFIG_FILE" | head -1)
        local domain
        domain=$(grep -oP '"host":\s*\[\s*"\K[^"]+' "$CONFIG_FILE" | head -1)
        echo ""
        info "验证: curl -skI https://${domain}:${port}"
        curl -skI "https://${domain}:${port}" 2>/dev/null | head -3
    else
        error "❌ 服务启动失败，查看日志: journalctl -u naive -n 20"
        systemctl status naive
        # 回滚
        if [ -f "${INSTALL_DIR}/naive.bak" ]; then
            warn "回滚到旧版本"
            mv "${INSTALL_DIR}/naive.bak" "${INSTALL_DIR}/naive"
            systemctl restart naive
        fi
        exit 1
    fi

    # 清理备份
    rm -f "${INSTALL_DIR}/naive.bak"
    echo ""
    info "完成！"
}

main "$@"   
