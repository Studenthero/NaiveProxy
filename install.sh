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
    x86_64|aarch64) BINARY="caddy" ;;
    *) error "不支持的架构: $ARCH"; exit 1 ;;
esac

# 获取最新 Release 下载链接
get_latest_download_url() {
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    curl -fsSL "$api_url" | grep -o "\"browser_download_url\": *\"[^\"]*${BINARY}\"" | head -1 | cut -d'"' -f4
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

# 生成 naive.json（根据参数）
generate_config() {
    local domain="$1"
    local port="$2"
    local auth="$3"
    local cert_mode="$4"   # "acme" 或 "custom"
    local cert_path="$5"
    local key_path="$6"
    local email="$7"
    local ssl_issuer="$8"  # "zerossl" 或 "letsencrypt"

    # 根据证书方式生成不同的 tls 配置
    local tls_config
    if [ "$cert_mode" = "acme" ]; then
        tls_config=$(cat << TLEOF
    "tls": {
      "certificates": {
        "automate": ["${domain}"]
      },
      "automation": {
        "policies": [
          {
            "issuers": [
              {
                "module": "${ssl_issuer}",
                "email": "${email}"
              }
            ]
          }
        ]
      }
    }
TLEOF
)
    else
        tls_config=$(cat << TLEOF
    "tls": {
      "certificates": {
        "load_files": [
          {
            "certificate": "${cert_path}",
            "key": "${key_path}"
          }
        ]
      }
    }
TLEOF
)
    fi

    cat > "$CONFIG_FILE" << CONFEOF
{
  "admin": {
    "disabled": true
  },
  "logging": {
    "sink": {
      "writer": {
        "output": "stderr"
      }
    },
    "logs": {
      "default": {
        "writer": {
          "output": "stderr"
        }
      }
    }
  },
  "storage": {
    "module": "file_system",
    "root": "${INSTALL_DIR}/file_system/"
  },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":${port}"],
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": ["${auth}"],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [
                        {
                          "host": ["${domain}"]
                        }
                      ],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "${HTML_DIR}/",
                          "index_names": ["index.html", "index.htm"]
                        }
                      ],
                      "terminal": true
                    }
                  ]
                }
              ]
            }
          ],
          "tls_connection_policies": [
            {
              "match": {
                "sni": ["${domain}"]
              }
            }
          ],
          "automatic_https": {
            "disable": true
          }
        }
      }
    },
${tls_config}
  }
}
CONFEOF
    info "配置已写入: $CONFIG_FILE"
}

# 创建伪装站点目录
setup_html() {
    if [ ! -d "$HTML_DIR" ]; then
        mkdir -p "$HTML_DIR"
    fi

    # 如果没有 index.html，生成默认页面
    if [ ! -f "${HTML_DIR}/index.html" ]; then
        cat > "${HTML_DIR}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Home</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#1e293b;line-height:1.6}
a{text-decoration:none;color:inherit}
nav{background:#0f172a;padding:1rem 2.5rem;display:flex;justify-content:space-between;align-items:center}
.logo{color:#fff;font-size:1.25rem;font-weight:700}
.nav-links{display:flex;gap:2rem}
.nav-links a{color:#94a3b8;font-size:.9rem}
.nav-links a:hover{color:#fff}
.hero{background:linear-gradient(180deg,#0f172a 0%,#1e1b4b 100%);padding:5rem 2.5rem 4rem;text-align:center;color:#fff}
.hero h1{font-size:2.5rem;font-weight:800;max-width:600px;margin:0 auto 1rem;line-height:1.2}
.hero p{font-size:1.05rem;color:#94a3b8;max-width:480px;margin:0 auto 2rem}
.btn{display:inline-block;background:#6366f1;color:#fff;padding:.75rem 2rem;border-radius:8px;font-weight:600;font-size:.95rem}
.features{padding:4rem 2.5rem;max-width:900px;margin:0 auto}
.features h2{text-align:center;font-size:1.8rem;font-weight:700;margin-bottom:2rem}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:1.5rem}
.card{background:#f8fafc;border:1px solid #e2e8f0;border-radius:10px;padding:1.5rem}
.card h3{font-size:1rem;font-weight:600;margin-bottom:.5rem}
.card p{font-size:.85rem;color:#64748b}
footer{background:#0f172a;color:#64748b;text-align:center;padding:2rem;font-size:.8rem}
@media(max-width:768px){.nav-links{display:none}.hero h1{font-size:1.8rem}}
</style>
</head>
<body>
<nav>
<div class="logo">Acme Studio</div>
<div class="nav-links">
<a href="#">Services</a>
<a href="#">Work</a>
<a href="#">About</a>
<a href="#">Contact</a>
</div>
</nav>
<div class="hero">
<h1>Digital products that matter</h1>
<p>Acme Studio is a small team helping startups launch polished web experiences.</p>
<a href="#" class="btn">Get in Touch</a>
</div>
<div class="features">
<h2>What We Do</h2>
<div class="grid">
<div class="card"><h3>Web Development</h3><p>Custom websites and applications built with modern frameworks. Performance-first and accessible.</p></div>
<div class="card"><h3>Brand Design</h3><p>Logos, design systems, and visual identity that make your product stand out.</p></div>
<div class="card"><h3>Ongoing Support</h3><p>Monthly retainers for updates, monitoring, and iterative improvements after launch.</p></div>
</div>
</div>
<footer>&copy; 2025 Acme Studio. All rights reserved.</footer>
</body>
</html>
HTMLEOF
        info "已生成默认伪装页面: ${HTML_DIR}/index.html"
        warn "建议替换为你自己的页面以获得更好的伪装效果"
    fi
}   

# 交互式配置
interactive_config() {
    local domain port username password cert_mode cert_path key_path email ssl_issuer

    echo ""
    echo "============================================"
    echo "  NaiveProxy 配置（直接回车使用默认值）"
    echo "============================================"
    echo ""

    read -p "  域名: " domain
    if [ -z "$domain" ]; then
        error "域名不能为空"
        exit 1
    fi

    read -p "  端口 [8443]: " port
    port="${port:-8443}"

    read -p "  用户名: " username
    if [ -z "$username" ]; then
        error "用户名不能为空"
        exit 1
    fi

    read -p "  密码: " password
    if [ -z "$password" ]; then
        error "密码不能为空"
        exit 1
    fi

    echo ""
    echo "  证书方式:"
    echo "    1) 自动生成（ACME，域名需已解析到本机 IP）"
    echo "    2) 自定义证书（手动指定 cert/key 路径）"
    read -p "  选择 [1/2] [1]: " cert_choice
    cert_choice="${cert_choice:-1}"

    if [ "$cert_choice" = "1" ]; then
        cert_mode="acme"
        read -p "  签发机构 (zerossl/letsencrypt) [zerossl]: " ssl_issuer
        ssl_issuer="${ssl_issuer:-zerossl}"
        read -p "  邮箱（用于 ACME 注册）: " email
        if [ -z "$email" ]; then
            error "ACME 模式必须提供邮箱"
            exit 1
        fi
        cert_path=""
        key_path=""
    else
        cert_mode="custom"
        read -p "  证书路径 (cert.crt): " cert_path
        if [ -z "$cert_path" ] || [ ! -f "$cert_path" ]; then
            error "证书文件不存在: $cert_path"
            exit 1
        fi
        read -p "  密钥路径 (private.key): " key_path
        if [ -z "$key_path" ] || [ ! -f "$key_path" ]; then
            error "密钥文件不存在: $key_path"
            exit 1
        fi
        ssl_issuer=""
        email=""
    fi

    # 生成 base64 认证
    local auth
    auth=$(echo -n "${username}:${password}" | base64)

    generate_config "$domain" "$port" "$auth" "$cert_mode" "$cert_path" "$key_path" "$email" "$ssl_issuer"
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
        error "请确认仓库 ${REPO} 有 Release 且包含文件: ${BINARY}"
        exit 1
    fi

    download_binary "$url"

    # 替换二进制
    if [ -f "$INSTALL_DIR/naive" ]; then
        mv "$INSTALL_DIR/naive" "${INSTALL_DIR}/naive.bak"
    fi
    mv "${INSTALL_DIR}/naive.new" "${INSTALL_DIR}/naive"
    info "二进制已更新: $(./${INSTALL_DIR}/naive version 2>/dev/null | awk '{print $1}' || echo 'unknown')"

    # 写 systemd
    write_service

    # 配置
    if [ ! -f "$CONFIG_FILE" ]; then
        info "首次安装，进入配置"
        interactive_config
    else
        info "已有配置文件，跳过（如需重新配置请删除 ${CONFIG_FILE} 后重跑）"
    fi

    # 伪装站点
    setup_html

    # 启动
    systemctl enable naive
    systemctl restart naive
    sleep 2

    if systemctl is-active --quiet naive; then
        info "✅ NaiveProxy 运行正常"
        echo ""
        info "验证: curl -skI https://<你的域名>:<端口>"
    else
        error "❌ 服务启动失败"
        warn "查看日志: journalctl -u naive -n 20"
        warn "自动回滚到旧版本..."
        if [ -f "${INSTALL_DIR}/naive.bak" ]; then
            mv "${INSTALL_DIR}/naive.bak" "${INSTALL_DIR}/naive"
            systemctl restart naive
            sleep 2
            if systemctl is-active --quiet naive; then
                info "已回滚到旧版本，服务恢复"
            else
                error "回滚后仍失败，请手动排查"
            fi
        fi
        exit 1
    fi

    # 清理备份
    rm -f "${INSTALL_DIR}/naive.bak"
    echo ""
    info "完成！"
}

main "$@"   
