#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# acme.sh + Let's Encrypt + DNS-01 + Docker Nginx
#
# 功能：
#   1. 安装 acme.sh
#   2. 使用 Let's Encrypt
#   3. 使用阿里云 / 腾讯云 DNS API 完成 DNS-01 验证
#   4. 为每个域名单独签发 ECC 证书
#   5. 部署证书到 /etc/letsencrypt/live/<domain>/
#   6. 使用 acme.sh 自带 cron 自动续期
#   7. 证书续期后自动 reload Docker Nginx
#
# 使用方式：
#
#   交互模式：
#       ./install-acme.sh
#
#   参数模式：
#       ./install-acme.sh \
#         --email admin@example.com \
#         --dns aliyun \
#         --ali-key xxx \
#         --ali-secret xxx \
#         --domain example.com \
#         --domain api.example.com
#
#   完全非交互：
#       ./install-acme.sh \
#         --non-interactive \
#         --email admin@example.com \
#         --dns aliyun \
#         --ali-key xxx \
#         --ali-secret xxx \
#         --domain example.com
#
###############################################################################


###############################################################################
# 基础配置
###############################################################################

# Let's Encrypt 注册邮箱
EMAIL=""

# DNS 服务商
#
# 可选：
#   aliyun
#   tencent
#
# 留空时，交互模式会询问。
DNS_PROVIDER=""

# 阿里云 DNS
ALI_KEY=""
ALI_SECRET=""

# 腾讯云 DNS
TENCENT_SECRET_ID=""
TENCENT_SECRET_KEY=""

# 需要申请证书的域名
#
# 建议直接在这里添加，例如：
#
# DOMAINS=(
#     "example.com"
#     "api.example.com"
# )
#
# 留空时，可以通过 --domain 指定。
DOMAINS=()

# 用于加载 SSL 证书的 Docker Nginx 容器名称
# 比如 lightsmart-nginx
NGINX_CONTAINER=""

# acme.sh 工作目录
ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"

# SSL 证书部署目录
LETSENCRYPT_HOME="/etc/letsencrypt"

# acme.sh Gitee 官方镜像
ACME_INSTALL_URL="https://gitee.com/acmesh-official/acme.sh/raw/master/acme.sh"

# 非交互模式
NON_INTERACTIVE=false

# 命令行 --domain 收集
DOMAIN_ARGS=()


###############################################################################
# 日志
###############################################################################

log() {
    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo
    echo "[ERROR] $*" >&2
    exit 1
}


###############################################################################
# Root 检查
###############################################################################

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 用户运行此脚本。"
fi


###############################################################################
# 帮助
###############################################################################

usage() {
    cat <<'EOF'

Usage:

  ./install-acme.sh [options]

Options:

  --email EMAIL
      Let's Encrypt 注册邮箱

  --dns aliyun|tencent
      DNS 服务商

  --ali-key KEY
      阿里云 AccessKey ID

  --ali-secret SECRET
      阿里云 AccessKey Secret

  --tencent-secret-id ID
      腾讯云 SecretId

  --tencent-secret-key KEY
      腾讯云 SecretKey

  --domain DOMAIN
      指定证书域名，可重复使用

  --non-interactive
      完全非交互模式。
      缺少必要参数时直接失败，不会询问。

  --help
      显示帮助。


Examples:

  交互模式：

    ./install-acme.sh


  使用配置区：

    修改脚本顶部的：

      EMAIL=""
      DNS_PROVIDER=""
      DOMAINS=(
          "example.com"
          "api.example.com"
      )


  阿里云：

    ./install-acme.sh \
      --email admin@example.com \
      --dns aliyun \
      --ali-key xxx \
      --ali-secret xxx \
      --domain example.com


  多域名：

    ./install-acme.sh \
      --email admin@example.com \
      --dns aliyun \
      --ali-key xxx \
      --ali-secret xxx \
      --domain example.com \
      --domain api.example.com


  完全非交互：

    ./install-acme.sh \
      --non-interactive \
      --email admin@example.com \
      --dns aliyun \
      --ali-key xxx \
      --ali-secret xxx \
      --domain example.com

EOF
}


###############################################################################
# 参数解析
###############################################################################

while [[ $# -gt 0 ]]; do

    case "$1" in

        --email)
            [[ $# -ge 2 ]] || die "--email 缺少参数"
            EMAIL="$2"
            shift 2
            ;;

        --dns)
            [[ $# -ge 2 ]] || die "--dns 缺少参数"
            DNS_PROVIDER="$2"
            shift 2
            ;;

        --ali-key)
            [[ $# -ge 2 ]] || die "--ali-key 缺少参数"
            ALI_KEY="$2"
            shift 2
            ;;

        --ali-secret)
            [[ $# -ge 2 ]] || die "--ali-secret 缺少参数"
            ALI_SECRET="$2"
            shift 2
            ;;

        --tencent-secret-id)
            [[ $# -ge 2 ]] || die "--tencent-secret-id 缺少参数"
            TENCENT_SECRET_ID="$2"
            shift 2
            ;;

        --tencent-secret-key)
            [[ $# -ge 2 ]] || die "--tencent-secret-key 缺少参数"
            TENCENT_SECRET_KEY="$2"
            shift 2
            ;;

        --domain)
            [[ $# -ge 2 ]] || die "--domain 缺少参数"
            DOMAIN_ARGS+=("$2")
            shift 2
            ;;

        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            die "未知参数：$1，请使用 --help 查看帮助。"
            ;;

    esac

done


###############################################################################
# 命令行 --domain 覆盖配置区 DOMAINS
###############################################################################

if [[ ${#DOMAIN_ARGS[@]} -gt 0 ]]; then
    DOMAINS=("${DOMAIN_ARGS[@]}")
fi


###############################################################################
# 基础依赖检查
###############################################################################

command -v curl >/dev/null 2>&1 \
    || die "缺少 curl，请先安装 curl。"

command -v crontab >/dev/null 2>&1 \
    || die "缺少 crontab。acme.sh 需要 cron 才能实现自动续期，请先安装 cron/cronie。"

if command -v openssl >/dev/null 2>&1; then
    HAS_OPENSSL=true
else
    HAS_OPENSSL=false
    warn "未找到 openssl，仅影响证书信息显示，不影响 acme.sh 核心功能。"
fi


###############################################################################
# 交互输入
###############################################################################

prompt_if_empty() {

    local var_name="$1"
    local prompt="$2"
    local value="${!var_name}"

    if [[ -z "${value}" ]]; then

        if [[ "${NON_INTERACTIVE}" == true ]]; then
            die "${var_name} 未设置，非交互模式下不能询问。"
        fi

        read -r -p "${prompt}: " value

        [[ -n "${value}" ]] \
            || die "${var_name} 不能为空。"

        printf -v "${var_name}" '%s' "${value}"
    fi
}


prompt_secret_if_empty() {

    local var_name="$1"
    local prompt="$2"
    local value="${!var_name}"

    if [[ -z "${value}" ]]; then

        if [[ "${NON_INTERACTIVE}" == true ]]; then
            die "${var_name} 未设置，非交互模式下不能询问。"
        fi

        read -r -s -p "${prompt}: " value
        echo

        [[ -n "${value}" ]] \
            || die "${var_name} 不能为空。"

        printf -v "${var_name}" '%s' "${value}"
    fi
}


###############################################################################
# 邮箱
###############################################################################

prompt_if_empty \
    EMAIL \
    "请输入 Let's Encrypt 注册邮箱"


###############################################################################
# DNS Provider
###############################################################################

if [[ -z "${DNS_PROVIDER}" ]]; then

    if [[ "${NON_INTERACTIVE}" == true ]]; then
        die "DNS_PROVIDER 未设置，请使用 --dns aliyun 或 --dns tencent。"
    fi

    echo
    echo "请选择 DNS 服务商："
    echo
    echo "  1) 阿里云 DNS"
    echo "  2) 腾讯云 DNS"
    echo

    while true; do

        read -r -p "请选择 [1-2]: " dns_choice

        case "${dns_choice}" in

            1)
                DNS_PROVIDER="aliyun"
                break
                ;;

            2)
                DNS_PROVIDER="tencent"
                break
                ;;

            *)
                echo "请输入 1 或 2。"
                ;;

        esac

    done

fi


###############################################################################
# DNS Provider 标准化
###############################################################################

DNS_PROVIDER="${DNS_PROVIDER,,}"

case "${DNS_PROVIDER}" in

    aliyun|ali|alibaba)
        DNS_PROVIDER="aliyun"
        ;;

    tencent|tx)
        DNS_PROVIDER="tencent"
        ;;

    *)
        die "不支持的 DNS 服务商：${DNS_PROVIDER}"
        ;;

esac


###############################################################################
# DNS API 参数
###############################################################################

case "${DNS_PROVIDER}" in

    aliyun)

        prompt_if_empty \
            ALI_KEY \
            "请输入阿里云 AccessKey ID"

        prompt_secret_if_empty \
            ALI_SECRET \
            "请输入阿里云 AccessKey Secret"

        DNS_PLUGIN="dns_ali"

        ;;

    tencent)

        prompt_if_empty \
            TENCENT_SECRET_ID \
            "请输入腾讯云 SecretId"

        prompt_secret_if_empty \
            TENCENT_SECRET_KEY \
            "请输入腾讯云 SecretKey"

        DNS_PLUGIN="dns_tencent"

        ;;

esac


###############################################################################
# 域名检查
###############################################################################

[[ ${#DOMAINS[@]} -gt 0 ]] \
    || die "没有配置任何域名。

请在脚本顶部配置：

  DOMAINS=(
      \"example.com\"
  )

或者运行：

  ./install-acme.sh --domain example.com
"


###############################################################################
# 显示配置
###############################################################################

echo
echo "============================================================"
echo " acme.sh SSL 自动化安装"
echo "============================================================"
echo
echo "邮箱：        ${EMAIL}"
echo "DNS：         ${DNS_PROVIDER}"
echo "域名："

for domain in "${DOMAINS[@]}"; do
    echo "  - ${domain}"
done

echo
echo "证书目录：    ${LETSENCRYPT_HOME}"
echo "Nginx 容器：  ${NGINX_CONTAINER}"
echo "ACME Home：   ${ACME_HOME}"
echo


###############################################################################
# DNS API 环境变量
###############################################################################

case "${DNS_PROVIDER}" in

    aliyun)

        export Ali_Key="${ALI_KEY}"
        export Ali_Secret="${ALI_SECRET}"

        ;;

    tencent)

        export Tencent_SecretId="${TENCENT_SECRET_ID}"
        export Tencent_SecretKey="${TENCENT_SECRET_KEY}"

        ;;

esac


###############################################################################
# 安装 acme.sh
###############################################################################

if [[ ! -x "${ACME_BIN}" ]]; then

    log "开始安装 acme.sh..."

    curl -fsSL "${ACME_INSTALL_URL}" \
        | sh -s -- "email=${EMAIL}"

    [[ -x "${ACME_BIN}" ]] \
        || die "acme.sh 安装失败。"

else

    info "检测到已有 acme.sh：${ACME_BIN}"

fi


###############################################################################
# 检查 acme.sh cron
###############################################################################

log "检查 acme.sh 自动续期任务..."

CRON_CONTENT="$(crontab -l 2>/dev/null || true)"

if ! printf '%s\n' "${CRON_CONTENT}" \
    | grep -Fq "${ACME_BIN}"; then

    die "没有检测到 acme.sh 的 cron 自动续期任务。

请检查：

  crontab -l

acme.sh 必须存在每日 cron 才能实现无人值守自动续期。
"

fi

info "已检测到 acme.sh 自动续期 cron。"


###############################################################################
# 设置 Let's Encrypt 为默认 CA
###############################################################################

log "设置默认 CA：Let's Encrypt"

"${ACME_BIN}" \
    --set-default-ca \
    --server letsencrypt


###############################################################################
# 创建证书目录
###############################################################################

mkdir -p "${LETSENCRYPT_HOME}/live"


###############################################################################
# Nginx reload command
#
# 设计：
#   - Nginx 正常运行：nginx -t 后 reload
#   - Nginx 没运行：跳过
#   - Nginx 配置异常：输出 WARNING，不影响证书续期
###############################################################################

RELOAD_CMD="
if command -v docker >/dev/null 2>&1 &&
   docker ps --format '{{.Names}}' | grep -qx '${NGINX_CONTAINER}'; then

    if docker exec '${NGINX_CONTAINER}' nginx -t >/dev/null 2>&1; then
        docker exec '${NGINX_CONTAINER}' nginx -s reload >/dev/null 2>&1 \
            || echo '[WARN] Nginx reload 失败，请手动检查。'
    else
        echo '[WARN] Nginx 配置检查失败，跳过 reload。'
    fi

fi
"


###############################################################################
# 签发 / 部署证书
###############################################################################

for DOMAIN in "${DOMAINS[@]}"; do

    log "处理域名：${DOMAIN}"

    CERT_DIR="${LETSENCRYPT_HOME}/live/${DOMAIN}"

    mkdir -p "${CERT_DIR}"


    ###########################################################################
    # Issue
    ###########################################################################

    log "申请 Let's Encrypt ECC 证书：${DOMAIN}"

    "${ACME_BIN}" \
        --issue \
        --server letsencrypt \
        --dns "${DNS_PLUGIN}" \
        -d "${DOMAIN}" \
        --keylength ec-256


    ###########################################################################
    # Install Cert
    ###########################################################################

    log "部署证书：${DOMAIN}"

    "${ACME_BIN}" \
        --install-cert \
        -d "${DOMAIN}" \
        --key-file "${CERT_DIR}/privkey.pem" \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --reloadcmd "${RELOAD_CMD}"


    ###########################################################################
    # 验证证书文件
    ###########################################################################

    [[ -s "${CERT_DIR}/privkey.pem" ]] \
        || die "${DOMAIN} 私钥不存在：${CERT_DIR}/privkey.pem"

    [[ -s "${CERT_DIR}/fullchain.pem" ]] \
        || die "${DOMAIN} 证书不存在：${CERT_DIR}/fullchain.pem"


    ###########################################################################
    # 输出证书信息
    ###########################################################################

    echo
    echo "------------------------------------------------------------"
    echo "域名：${DOMAIN}"
    echo "证书：${CERT_DIR}/fullchain.pem"
    echo "私钥：${CERT_DIR}/privkey.pem"

    if [[ "${HAS_OPENSSL}" == true ]]; then

        openssl x509 \
            -in "${CERT_DIR}/fullchain.pem" \
            -noout \
            -subject \
            -issuer \
            -dates

    fi

    echo "------------------------------------------------------------"

done


###############################################################################
# 最后检查 Nginx
###############################################################################

if command -v docker >/dev/null 2>&1; then

    if docker ps --format '{{.Names}}' \
        | grep -qx "${NGINX_CONTAINER}"; then

        log "检测到 Nginx 容器正在运行，执行最终配置检查..."

        if docker exec "${NGINX_CONTAINER}" nginx -t; then

            info "Nginx 配置检查通过。"

            docker exec "${NGINX_CONTAINER}" nginx -s reload \
                || warn "Nginx reload 失败，请手动检查。"

        else

            warn "Nginx 配置检查失败，但 SSL 证书已经成功部署。"

        fi

    else

        info "Nginx 容器当前未运行，跳过 reload。"

    fi

else

    info "未检测到 Docker，跳过 Nginx 检查。"

fi


###############################################################################
# 清理当前 shell 中的 DNS API 敏感变量
###############################################################################

unset Ali_Key
unset Ali_Secret

unset Tencent_SecretId
unset Tencent_SecretKey

ALI_KEY=""
ALI_SECRET=""
TENCENT_SECRET_ID=""
TENCENT_SECRET_KEY=""


###############################################################################
# 完成
###############################################################################

echo
echo "============================================================"
echo " acme.sh SSL 自动化配置完成"
echo "============================================================"
echo
echo "ACME Home："
echo "  ${ACME_HOME}"
echo
echo "证书目录："

for DOMAIN in "${DOMAINS[@]}"; do
    echo "  ${LETSENCRYPT_HOME}/live/${DOMAIN}/"
done

echo
echo "自动续期："
echo "  acme.sh cron 已启用"
echo
echo "证书续期后："
echo "  自动部署新证书"
echo "  自动 reload ${NGINX_CONTAINER}"
echo
echo "以后无需再次运行此安装脚本。"
echo "============================================================"
echo