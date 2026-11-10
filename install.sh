#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# NaiveProxy install.sh — 多 VPS 部署 / 升级
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/Studenthero/NaiveProxy/main/install.sh)
# ============================================================

INSTALL_DIR="/usr/local/naive"
BINARY="$INSTALL_DIR/naive"
CONFIG="$INSTALL_DIR/naive.json"
HTML_DIR="$INSTALL_DIR/html"
CERT_DIR="/etc/naive/certs"
SERVICE_NAME="naive"
REPO="Studenthero/NaiveProxy"

# --- 工具函数 ---
info()  { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()   { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

# --- 检测是否已有安装 ---
IS_UPGRADE=false
if [ -f "$CONFIG" ]; then
  IS_UPGRADE=true
  info "检测到已有安装，进入升级模式"
  OLD_VERSION=$("$BINARY" version 2>/dev/null | awk '{print $1}' || echo "unknown")
fi

# --- 下载最新二进制 ---
info "获取最新版本..."
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -oP '"tag_name":\s*"\K[^"]+')
[ -n "$LATEST_TAG" ] || err "无法获取最新版本号"
info "最新版本: $LATEST_TAG"

if [ "$IS_UPGRADE" = true ] && [ "$OLD_VERSION" = "$LATEST_TAG" ]; then
  info "已是最新版本 $LATEST_TAG，无需升级"
  exit 0
fi

TMP_BINARY=$(mktemp /tmp/naive.XXXXXX)
info "下载二进制..."
curl -fsSL -o "$TMP_BINARY" "https://github.com/$REPO/releases/download/$LATEST_TAG/caddy"
chmod +x "$TMP_BINARY"

NEW_VERSION=$(bash "$TMP_BINARY" version 2>/dev/null | awk '{print $1}')
info "新版本: $NEW_VERSION"

# --- 交互输入（仅新部署时） ---
if [ "$IS_UPGRADE" = false ]; then
  echo ""
  echo "========== 新部署配置 =========="
  read -rp "域名 (如 la.example.com): " DOMAIN
  read -rp "端口 (默认 8443): " PORT
  PORT=${PORT:-8443}
  read -rp "用户名: " USERNAME
  read -rp "密码: " PASSWORD
  read -rp "启用 HTTP/3 (QUIC)? [y/N] (默认 N): " ENABLE_H3
  ENABLE_H3=$(echo "$ENABLE_H3" | tr '[:upper:]' '[:lower:]')
  [ -z "$ENABLE_H3" ] && ENABLE_H3="n"

  read -rp "证书方式: 1=ACME自动 2=自定义路径 (默认 1): " CERT_MODE
  CERT_MODE=${CERT_MODE:-1}
  if [ "$CERT_MODE" = "2" ]; then
    read -rp "证书路径 (cert.crt): " CERT_FILE
    read -rp "密钥路径 (private.key): " KEY_FILE
  else
    CERT_FILE="$CERT_DIR/cert.crt"
    KEY_FILE="$CERT_DIR/private.key"
  fi
else
  # 升级模式：从现有配置读取参数
  info "从现有配置读取参数..."
  DOMAIN=$(grep -oP '"sni":\s*\[\s*"\K[^"]+' "$CONFIG" | head -1)
  PORT=$(grep -oP '"listen":\s*\[\s*":\K[0-9]+' "$CONFIG" | head -1)
  ENABLE_H3="n"
  if ! grep -q '"protocols"' "$CONFIG"; then
    ENABLE_H3="y"
  fi
  CERT_FILE=$(grep -oP '"certificate":\s*"\K[^"]+' "$CONFIG" | head -1)
  KEY_FILE=$(grep -oP '"key":\s*"\K[^"]+' "$CONFIG" | head -1)
  info "域名=$DOMAIN 端口=$PORT H3=$ENABLE_H3"
fi

# --- 计算 auth_credentials (base64) ---
AUTH_B64=$(echo -n "${USERNAME}:${PASSWORD}" | base64 -w0)

# --- 生成 naive.json ---
info "生成配置..."
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/file_system" "$HTML_DIR"

# 备份旧配置
if [ -f "$CONFIG" ]; then
  cp "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  info "已备份旧配置"
fi

# 构建 protocols 行
if [ "$ENABLE_H3" = "y" ]; then
  PROTOCOLS_JSON=""
else
  PROTOCOLS_JSON="\"protocols\": [\"h1\", \"h2\"],"
fi

cat > "$CONFIG" <<EOF
{
  "admin": { "disabled": true },
  "logging": {
    "sink": { "writer": { "output": "stderr" } },
    "logs": { "default": { "writer": { "output": "stderr" } } }
  },
  "storage": { "module": "file_system", "root": "$INSTALL_DIR/file_system/" },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":$PORT"],
          $PROTOCOLS_JSON
          "routes": [
            {
              "handle": [
                {
                  "handler": "subroute",
                  "routes": [
                    {
                      "handle": [
                        {
                          "auth_credentials": ["$AUTH_B64"],
                          "handler": "forward_proxy",
                          "hide_ip": true,
                          "hide_via": true,
                          "probe_resistance": {}
                        }
                      ]
                    },
                    {
                      "match": [{ "host": ["$DOMAIN"] }],
                      "handle": [
                        {
                          "handler": "file_server",
                          "root": "$HTML_DIR/",
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
            { "match": { "sni": ["$DOMAIN"] } }
          ],
          "automatic_https": { "disable": true }
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [
          {
            "certificate": "$CERT_FILE",
            "key": "$KEY_FILE"
          }
        ]
      }
    }
  }
}
EOF

# --- 生成默认伪装页（仅当不存在时） ---
if [ ! -f "$HTML_DIR/index.html" ]; then
  info "生成默认伪装页..."
  cat > "$HTML_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Cloudbase - Cloud SaaS Platform</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#333}
.nav{display:flex;justify-content:space-between;align-items:center;padding:20px 60px;background:#fff;border-bottom:1px solid #eee}
.logo{font-size:22px;font-weight:700;color:#1a73e8}
.nav a{color:#555;text-decoration:none;margin-left:24px;font-size:14px}
.hero{text-align:center;padding:100px 20px;background:linear-gradient(135deg,#f5f7fa 0%,#e4e8ec 100%)}
.hero h1{font-size:48px;margin-bottom:16px;color:#1a1a2e}
.hero p{font-size:18px;color:#666;max-width:600px;margin:0 auto 32px}
.btn{display:inline-block;padding:14px 32px;background:#1a73e8;color:#fff;border-radius:6px;text-decoration:none;font-size:16px}
.features{display:grid;grid-template-columns:repeat(3,1fr);gap:32px;padding:80px 60px;max-width:1100px;margin:0 auto}
.feature{text-align:center;padding:24px}
.feature h3{margin-bottom:12px;font-size:18px}
.feature p{font-size:14px;color:#777}
footer{text-align:center;padding:40px;border-top:1px solid #eee;color:#999;font-size:13px}
</style>
</head>
<body>
<nav class="nav">
<span class="logo">Cloudbase</span>
<div><a href="#">Products</a><a href="#">Solutions</a><a href="#">Pricing</a><a href="#">Docs</a><a href="#">Login</a></div>
</nav>
<section class="hero">
<h1>Build on the Cloud,<br>Scale Without Limits</h1>
<p>Enterprise-grade cloud infrastructure with serverless functions, managed databases, and global CDN — all in one platform.</p>
<a href="#" class="btn">Start Free Trial</a>
</section>
<section class="features">
<div class="feature"><h3>Serverless Functions</h3><p>Deploy code without managing servers. Auto-scales from zero to millions of requests.</p></div>
<div class="feature"><h3>Managed Databases</h3><p>Fully managed MySQL, PostgreSQL, and Redis with automatic backups and failover.</p></div>
<div class="feature"><h3>Global CDN</h3><p>200+ edge locations worldwide for ultra-low latency content delivery.</p></div>
</section>
<footer>© 2026 Cloudbase Inc. All rights reserved. | Privacy | Terms | Status</footer>
</body>
</html>
HTMLEOF
fi

# --- 安装二进制 ---
if [ -f "$BINARY" ]; then
  cp "$BINARY" "${BINARY}.old"
  info "已备份旧二进制"
fi
mv "$TMP_BINARY" "$BINARY"
chmod +x "$BINARY"

# --- 证书 ---
if [ "$CERT_MODE" = "1" ]; then
  mkdir -p "$CERT_DIR"
  if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    info "证书不存在，尝试 acme.sh 签发..."
    if command -v acme.sh &>/dev/null; then
      acme.sh --issue -d "$DOMAIN" --webroot "$HTML_DIR" 2>/dev/null || \
      acme.sh --issue -d "$DOMAIN" -l standalone 2>/dev/null
      acme.sh --install-cert -d "$DOMAIN" \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" 2>/dev/null
      info "证书签发完成"
    else
      warn "acme.sh 未安装，请手动放置证书到 $CERT_FILE / $KEY_FILE"
    fi
  else
    info "证书已存在，跳过签发"
  fi
fi

# --- 防火墙 ---
if command -v ufw &>/dev/null; then
  ufw allow "$PORT/tcp" >/dev/null
  if [ "$ENABLE_H3" = "y" ]; then
    ufw allow "$PORT/udp" >/dev/null
    info "ufw: 放行 $PORT/tcp + $PORT/udp (H3 开启)"
  else
    # 确保 UDP 不放行
    ufw delete allow "$PORT/udp" >/dev/null 2>&1 || true
    info "ufw: 放行 $PORT/tcp (H3 关闭，UDP 已封)"
  fi
fi

# --- systemd 服务 ---
cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=NaiveProxy (Caddy forwardproxy)
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$BINARY run --config $CONFIG
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# --- 启动 & 验证 ---
info "启动服务..."
systemctl restart "$SERVICE_NAME"
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME"; then
  info "✅ 服务启动成功"
  echo ""
  echo "========== 部署完成 =========="
  echo "  版本:   $NEW_VERSION"
  echo "  域名:   $DOMAIN"
  echo "  端口:   $PORT/TCP"
  echo "  H3:     $([ "$ENABLE_H3" = "y" ] && echo "开启" || echo "关闭")"
  echo "  配置:   $CONFIG"
  echo "  伪装页: $HTML_DIR/index.html"
  echo ""
  echo "  客户端: naive+https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}"
  echo "==============================="
else
  err "服务启动失败！正在回滚..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  if [ -f "${BINARY}.old" ]; then
    mv "${BINARY}.old" "$BINARY"
    info "已回滚二进制"
  fi
  LATEST_BAK=$(ls -t "${CONFIG}.bak."* 2>/dev/null | head -1)
  if [ -n "$LATEST_BAK" ]; then
    cp "$LATEST_BAK" "$CONFIG"
    info "已回滚配置"
  fi
  systemctl restart "$SERVICE_NAME"
  err "请手动检查: $BINARY run --config $CONFIG"
fi

rm -f "$TMP_BINARY"
