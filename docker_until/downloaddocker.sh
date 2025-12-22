#!/bin/bash
# 注意：在关键函数中临时禁用严格模式
set -euo pipefail

# ==================== 日志级别配置 ====================
LOG_LEVEL="DEBUG"  # 可选：SILENT, INFO, DEBUG, TRACE
DEBUG_LOG=$(realpath -m "./docker-mirror-debug.log")

# 统一的日志函数
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S.%3N")
    
    # 定义日志级别优先级
    declare -A log_priorities=([SILENT]=0 [INFO]=1 [DEBUG]=2 [TRACE]=3)
    declare -A level_priorities=([SILENT]=0 [INFO]=1 [DEBUG]=2 [TRACE]=3)
    
    # 检查是否应该记录
    if [[ ${level_priorities[$level]} -le ${log_priorities[$LOG_LEVEL]} ]]; then
        echo "[${timestamp}] [${level}] ${message}" | tee -a "$DEBUG_LOG"
    fi
}

# ==================== 跨平台兼容函数 ====================
# 跨平台获取文件大小
get_file_size() {
    local filepath="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        stat -f%z "$filepath" 2>/dev/null || echo 0
    elif command -v busybox >/dev/null 2>&1; then
        # Termux/busybox
        busybox stat -L -c %s "$filepath" 2>/dev/null || echo 0
    else
        # Linux
        stat -c%s "$filepath" 2>/dev/null || echo 0
    fi
}

# ========================核心常量 ======================
REGISTRY_URL="https://docker.m.daocloud.io/v2"
log_message "INFO" "设置常量 REGISTRY_URL='${REGISTRY_URL}'"
REPO="vllm/vllm-openai"
log_message "INFO" "设置常量 REPO='${REPO}'"
TAG="v0.12.0"
log_message "INFO" "设置常量 TAG='${TAG}'"
ARCH="amd64"
log_message "INFO" "设置常量 ARCH='${ARCH}'"
##更改上面选择下载什么镜象
# ==================== 用户可调整的配置 ====================
USERNAME=""  # 用于私有仓库认证
log_message "INFO" "设置变量 USERNAME='${USERNAME}' (私有仓库用户名)"
PASSWORD=""  # 密码或个人访问令牌
if [[ -n "$PASSWORD" ]]; then
    log_message "INFO" "设置变量 PASSWORD='***已设置***' (长度: ${#PASSWORD})"
else
    log_message "INFO" "设置变量 PASSWORD='' (空)"
fi

DOCKER_CLIENT_VERSION="26.1.0"
log_message "INFO" "设置变量 DOCKER_CLIENT_VERSION='${DOCKER_CLIENT_VERSION}'"
OUTPUT_DIR_ABS=$(realpath -m "./vllm-blobs")
log_message "INFO" "计算变量 OUTPUT_DIR_ABS='${OUTPUT_DIR_ABS}'"
STATE_FILE="${OUTPUT_DIR_ABS}/.state.json"
log_message "INFO" "设置变量 STATE_FILE='${STATE_FILE}'"
MAX_RETRY=3
log_message "INFO" "设置变量 MAX_RETRY=${MAX_RETRY}"
RETRY_DELAY=2
log_message "INFO" "设置变量 RETRY_DELAY=${RETRY_DELAY}"

# ==================== 内部变量（请勿修改）====================
AUTH_REALM=""
AUTH_SERVICE=""
BEARER_TOKEN=""
TOKEN_EXPIRY=0

log_message "DEBUG" "初始化内部变量: AUTH_REALM='', AUTH_SERVICE='', BEARER_TOKEN='', TOKEN_EXPIRY=0"

# 初始化环境
init_environment() {
    log_message "INFO" "===== [1/5] 初始化环境开始 ====="
    log_message "DEBUG" "函数 init_environment 被调用"
    
    log_message "TRACE" "删除目录: ${OUTPUT_DIR_ABS}"
    rm -rf "${OUTPUT_DIR_ABS}"
    
    log_message "TRACE" "创建目录: ${OUTPUT_DIR_ABS}"
    mkdir -p "${OUTPUT_DIR_ABS}"
    
    log_message "DEBUG" "初始化状态文件: ${STATE_FILE}"
    echo "{\"downloaded_blobs\": [], \"manifest_digest\": \"\"}" > "$STATE_FILE"
    log_message "TRACE" "状态文件内容: $(cat "$STATE_FILE")"
    
    log_message "INFO" "输出目录已清空并创建：${OUTPUT_DIR_ABS}"
    
    # 检查依赖
    log_message "DEBUG" "开始检查依赖命令"
    local missing_deps=()
    for cmd in jq curl sha256sum; do
        log_message "TRACE" "检查命令: ${cmd}"
        if ! command -v $cmd &>/dev/null; then
            log_message "ERROR" "缺失依赖命令: ${cmd}"
            missing_deps+=("$cmd")
        else
            log_message "TRACE" "命令 ${cmd} 存在，路径: $(command -v $cmd)"
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_message "ERROR" "缺失以下依赖: ${missing_deps[*]}"
        exit 1
    fi
    
    # 检查Termux环境下的busybox
    if [[ "$(uname -o 2>/dev/null || echo "")" == "Android" ]] && ! command -v busybox &>/dev/null; then
        log_message "WARN" "Termux环境中未找到busybox，文件大小统计可能受限"
    fi
    
    log_message "INFO" "所有依赖检查通过"
    log_message "INFO" "===== [1/5] 初始化环境完成 ====="
}

# 1. 获取认证 Token (支持私有仓库)
get_bearer_token() {
    log_message "INFO" "===== [2/5] 获取认证令牌开始 ====="
    log_message "DEBUG" "函数 get_bearer_token 被调用"
    
    local scope="repository:${REPO}:pull"
    log_message "DEBUG" "构建 scope 参数: ${scope}"
    
    # 首先探测认证服务端点
    local probe_url="${REGISTRY_URL}/${REPO}/manifests/${TAG}"
    log_message "DEBUG" "构建探测URL: ${probe_url}"
    
    local resp_headers=$(mktemp)
    log_message "TRACE" "创建临时文件 resp_headers: ${resp_headers}"
    
    log_message "DEBUG" "发送探测请求到: ${probe_url}"
    # 修复：使用更简单的curl命令，避免解析问题
    local http_code=$(curl -sI -X GET \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "User-Agent: docker/${DOCKER_CLIENT_VERSION}" \
        -w "%{http_code}" \
        -o /dev/null \
        "$probe_url" 2>&1 | tail -n1)
    
    log_message "DEBUG" "探测请求HTTP状态码: ${http_code}"
    
    # 获取完整的响应头
    curl -sI -X GET \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "User-Agent: docker/${DOCKER_CLIENT_VERSION}" \
        "$probe_url" > "$resp_headers" 2>/dev/null
    
    log_message "TRACE" "完整响应头文件内容:\n$(cat "$resp_headers")"
    
    # 修复：使用更健壮的认证头提取方法
    local auth_header_raw=$(grep -i "^www-authenticate:" "$resp_headers" | head -n1)
    # 清理认证头，移除回车和换行
    local auth_header=$(echo "$auth_header_raw" | sed 's/^www-authenticate: //i' | tr -d '\r' | sed 's/\\//g')
    log_message "DEBUG" "清理后的认证头: '${auth_header}'"
    
    if [[ -z "$auth_header" ]]; then
        log_message "INFO" "仓库无需认证 (公开或已匿名许可)"
        BEARER_TOKEN=""
        log_message "TRACE" "设置 BEARER_TOKEN=''"
        rm -f "$resp_headers"
        log_message "INFO" "===== [2/5] 获取认证令牌完成 (无需认证) ====="
        return 0
    fi
    
    # 解析认证信息 - 使用更健壮的解析方法
    log_message "DEBUG" "开始解析认证头信息"
    
    # 提取realm
    if [[ "$auth_header" =~ realm=\"([^\"]*)\" ]]; then
        AUTH_REALM="${BASH_REMATCH[1]}"
        log_message "INFO" "提取 AUTH_REALM='${AUTH_REALM}'"
    else
        # 尝试没有引号的情况
        if [[ "$auth_header" =~ realm=([^,]*)(,|$) ]]; then
            AUTH_REALM="${BASH_REMATCH[1]}"
            log_message "INFO" "提取 AUTH_REALM='${AUTH_REALM}' (无引号)"
        else
            log_message "WARN" "无法从认证头提取 realm: ${auth_header}"
        fi
    fi
    
    # 提取service
    if [[ "$auth_header" =~ service=\"([^\"]*)\" ]]; then
        AUTH_SERVICE="${BASH_REMATCH[1]}"
        log_message "INFO" "提取 AUTH_SERVICE='${AUTH_SERVICE}'"
    else
        if [[ "$auth_header" =~ service=([^,]*)(,|$) ]]; then
            AUTH_SERVICE="${BASH_REMATCH[1]}"
            log_message "INFO" "提取 AUTH_SERVICE='${AUTH_SERVICE}' (无引号)"
        else
            log_message "WARN" "无法从认证头提取 service: ${auth_header}"
        fi
    fi
    
    # 修复：如果realm或service为空，使用默认值
    if [[ -z "$AUTH_REALM" ]]; then
        log_message "WARN" "AUTH_REALM为空，使用默认值"
        AUTH_REALM="https://m.daocloud.io/auth/token"
    fi
    
    if [[ -z "$AUTH_SERVICE" ]]; then
        log_message "WARN" "AUTH_SERVICE为空，使用默认值"
        AUTH_SERVICE="docker.m.daocloud.io"
    fi
    
    # 构建Token请求URL
    local token_url="${AUTH_REALM}?service=${AUTH_SERVICE}&scope=${scope}"
    log_message "DEBUG" "构建Token请求URL: ${token_url}"
    
    local auth_flag=""
    if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
        log_message "DEBUG" "使用用户名密码进行Basic认证"
        local basic_auth=$(echo -n "${USERNAME}:${PASSWORD}" | base64 | tr -d '\n')
        log_message "TRACE" "Basic认证字符串: ${basic_auth}"
        auth_flag="-H \"Authorization: Basic ${basic_auth}\""
        log_message "DEBUG" "设置认证标志: ${auth_flag}"
    else
        log_message "DEBUG" "未提供用户名密码，使用匿名认证"
    fi
    
    # 请求Token
    log_message "INFO" "发送Token请求到: ${token_url}"
    local token_response
    log_message "TRACE" "执行curl命令: curl -s -m 15 ${auth_flag} \"${token_url}\""
    token_response=$(curl -s -m 15 $auth_flag "$token_url") || {
        log_message "ERROR" "Token请求失败"
        return 1
    }
    
    log_message "TRACE" "Token响应原始内容: ${token_response}"
    
    # 修复：尝试多种方式提取token
    BEARER_TOKEN=$(echo "$token_response" | jq -r '.token // .access_token // empty' 2>/dev/null || echo "")
    
    if [[ -z "$BEARER_TOKEN" ]]; then
        # 如果jq失败，尝试手动提取
        log_message "DEBUG" "jq提取失败，尝试手动提取token"
        if [[ "$token_response" =~ \"token\"\s*:\s*\"([^\"]+)\" ]]; then
            BEARER_TOKEN="${BASH_REMATCH[1]}"
        elif [[ "$token_response" =~ \"access_token\"\s*:\s*\"([^\"]+)\" ]]; then
            BEARER_TOKEN="${BASH_REMATCH[1]}"
        fi
    fi
    
    log_message "DEBUG" "从响应中提取 BEARER_TOKEN (长度: ${#BEARER_TOKEN})"
    
    if [[ -z "$BEARER_TOKEN" || "$BEARER_TOKEN" == "null" ]]; then
        log_message "ERROR" "无法从响应中提取Token"
        log_message "TRACE" "完整响应: ${token_response}"
        return 1
    fi
    
    # 解码JWT以检查过期时间 - 修复base64url解码
    log_message "DEBUG" "开始解析JWT Token"
    local payload_base64=$(echo "$BEARER_TOKEN" | cut -d'.' -f2)
    log_message "TRACE" "JWT payload base64: ${payload_base64}"
    
    # 修复：处理base64url编码（JWT使用base64url，不是标准base64）
    local payload_base64_std=$(echo "$payload_base64" | tr '_-' '/+')
    
    # 添加填充
    local padding=$((4 - ${#payload_base64_std} % 4))
    if [[ $padding -eq 4 ]]; then
        padding=0
    fi
    
    local padding_chars=""
    for ((i=0; i<padding; i++)); do
        padding_chars+="="
    done
    
    payload_base64_std="${payload_base64_std}${padding_chars}"
    log_message "TRACE" "转换后的标准base64: ${payload_base64_std}"
    
    # 解码payload
    local payload=$(echo "$payload_base64_std" | base64 -d 2>/dev/null || echo "{}")
    log_message "TRACE" "JWT payload 解码后: ${payload}"
    
    # 尝试使用jq解析payload，如果失败则跳过
    TOKEN_EXPIRY=$(echo "$payload" | jq -r '.exp // 0' 2>/dev/null || echo "0")
    log_message "INFO" "提取 Token过期时间: ${TOKEN_EXPIRY}"
    
    if [[ "$TOKEN_EXPIRY" != "0" ]]; then
        local expiry_date=$(date -d "@${TOKEN_EXPIRY}" 2>/dev/null || echo "无法解析日期")
        log_message "INFO" "Token过期时间: ${expiry_date}"
    else
        log_message "INFO" "Token无过期时间或解析失败"
    fi
    
    local token_prefix="${BEARER_TOKEN:0:50}"
    log_message "INFO" "令牌获取成功 (长度: ${#BEARER_TOKEN}, 前缀: ${token_prefix}...)"
    
    rm -f "$resp_headers"
    log_message "INFO" "===== [2/5] 获取认证令牌完成 ====="
    return 0
}

# 2. 获取并解析Manifest
get_and_parse_manifest() {
    log_message "INFO" "===== [3/5] 获取镜像清单开始 ====="
    log_message "DEBUG" "函数 get_and_parse_manifest 被调用，架构: ${ARCH}"
    
    local manifest_url="${REGISTRY_URL}/${REPO}/manifests/${TAG}"
    log_message "DEBUG" "构建Manifest URL: ${manifest_url}"
    
    local manifest_file="${OUTPUT_DIR_ABS}/manifest_${ARCH}.json"
    log_message "DEBUG" "设置Manifest保存路径: ${manifest_file}"
    
    # 构建curl命令
    local curl_cmd="curl -s -f -L"
    curl_cmd+=" -H \"Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json\""
    curl_cmd+=" -H \"User-Agent: docker/${DOCKER_CLIENT_VERSION}\""
    
    if [[ -n "$BEARER_TOKEN" ]]; then
        local token_prefix="${BEARER_TOKEN:0:20}..."
        curl_cmd+=" -H \"Authorization: Bearer ${BEARER_TOKEN}\""
        log_message "DEBUG" "curl命令添加认证头，Token前缀: ${token_prefix}"
    else
        log_message "DEBUG" "curl命令未添加认证头 (BEARER_TOKEN为空)"
    fi
    
    curl_cmd+=" -o \"${manifest_file}\""
    curl_cmd+=" \"${manifest_url}\""
    
    log_message "TRACE" "执行curl命令: ${curl_cmd}"
    
    if ! eval "$curl_cmd"; then
        log_message "ERROR" "获取Manifest失败"
        return 1
    fi
    
    local manifest_size=$(get_file_size "$manifest_file")
    log_message "DEBUG" "Manifest文件大小: ${manifest_size} 字节"
    
    # 检查是否为多架构清单列表
    local media_type=$(jq -r '.mediaType // ""' "$manifest_file")
    log_message "DEBUG" "检测到Manifest mediaType: ${media_type}"
    
    if [[ "$media_type" == "application/vnd.docker.distribution.manifest.list.v2+json" ]]; then
        log_message "INFO" "检测到多架构清单，查找 ${ARCH} 架构..."
        
        local arch_digest=$(jq -r --arg arch "$ARCH" '.manifests[] | select(.platform.architecture == $arch) | .digest' "$manifest_file")
        log_message "DEBUG" "找到 ${ARCH} 架构的digest: ${arch_digest}"
        
        if [[ -z "$arch_digest" ]]; then
            log_message "ERROR" "在多架构清单中未找到 ${ARCH} 架构"
            log_message "TRACE" "所有可用架构: $(jq -r '.manifests[] | .platform.architecture' "$manifest_file")"
            return 1
        fi
        
        # 获取具体架构清单
        log_message "INFO" "获取具体架构清单: ${arch_digest}"
        local arch_manifest_url="${REGISTRY_URL}/${REPO}/manifests/${arch_digest}"
        log_message "DEBUG" "架构Manifest URL: ${arch_manifest_url}"
        
        curl_cmd="curl -s -f -L"
        curl_cmd+=" -H \"Accept: application/vnd.docker.distribution.manifest.v2+json\""
        curl_cmd+=" -H \"User-Agent: docker/${DOCKER_CLIENT_VERSION}\""
        
        if [[ -n "$BEARER_TOKEN" ]]; then
            curl_cmd+=" -H \"Authorization: Bearer ${BEARER_TOKEN}\""
        fi
        
        curl_cmd+=" -o \"${manifest_file}\""
        curl_cmd+=" \"${arch_manifest_url}\""
        
        log_message "TRACE" "执行架构Manifest请求: ${curl_cmd}"
        
        if ! eval "$curl_cmd"; then
            log_message "ERROR" "获取架构清单失败"
            return 1
        fi
        
        local arch_manifest_size=$(get_file_size "$manifest_file")
        log_message "DEBUG" "架构Manifest文件大小: ${arch_manifest_size} 字节"
    fi
    
    # 提取配置层和数据层
    local config_digest=$(jq -r '.config.digest' "$manifest_file")
    local config_size=$(jq -r '.config.size' "$manifest_file")
    
    log_message "INFO" "提取配置层: ${config_digest} (${config_size} 字节)"
    
    # 更新状态文件中的manifest摘要
    log_message "DEBUG" "更新状态文件中的manifest摘要: ${config_digest}"
    jq --arg digest "$config_digest" '.manifest_digest = $digest' "$STATE_FILE" > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    
    log_message "TRACE" "状态文件更新后内容: $(cat "$STATE_FILE")"
    
    # 解析所有需要下载的层
    log_message "DEBUG" "开始解析所有layers"
    local layers=$(jq -r '.layers[] | "\(.digest)|\(.size)"' "$manifest_file")
    local layer_count=$(echo "$layers" | wc -l)
    log_message "INFO" "找到 ${layer_count} 个layers"
    
    echo "${config_digest}|${config_size}"$'\n'"${layers}" > "${OUTPUT_DIR_ABS}/blobs.list"
    log_message "DEBUG" "Blobs列表保存到: ${OUTPUT_DIR_ABS}/blobs.list"
    
    local total_blobs=$((layer_count + 1))
    log_message "INFO" "总计需下载: ${total_blobs} 个blobs (1个配置, ${layer_count}个层)"
    
    # 记录详细blob信息
    log_message "TRACE" "Blobs列表内容:"
    echo "${config_digest}|${config_size}"$'\n'"${layers}" | while IFS='|' read -r digest size; do
        log_message "TRACE" "  - ${digest} (${size} 字节)"
    done
    
    log_message "INFO" "===== [3/5] 获取镜像清单完成 ====="
    return 0
}

# 3. 下载单个Blob (支持断点续传) - 修复Termux兼容性
# 3. 下载单个Blob (使用 aria2c 多线程下载，替代原 curl 版本)
download_single_blob() {
    # 临时禁用严格模式，避免单个命令失败导致整体退出
    set +euo pipefail
    
    local digest="$1"
    local expected_size="$2"
    local retry_count=0
    local success=0

    # ========== aria2 多线程配置 (可根据带宽调整) ==========
    local ARIA2_THREADS=4        # 每任务线程数，推荐 4-8
    local ARIA2_MIN_SPLIT=2M     # 最小分片大小
    local ARIA2_TIMEOUT=120      # 超时时间(秒)
    # =======================================================
    
    log_message "DEBUG" "函数 download_single_blob (aria2) 被调用"
    log_message "DEBUG" "参数: digestDEBUG" "参数: digest='${digest}', expected_size='${expected_size}', 线程数=${ARIA2_THREADS}"
    
    local blob_url="${REGISTRY_URL}/${REPO}/blobs/${digest}"
    log_message "DEBUG" "构建Blob URL: ${blob_url}"
    
    local filename="${digest//:/_}"
    log_message "DEBUG" "生成文件名: ${filename} (从digest: ${digest})"
    
    local filepath="${OUTPUT_DIR_ABS}/${filename}"
    local aria2_temp_file="${filepath}.aria2"  # aria2 控制文件
    log_message "DEBUG" "文件路径: ${filepath}"
    log_message "DEBUG" "临时控制文件路径: ${aria2_temp_file}"
    
    log_message "INFO" "开始处理 (aria2 多线程): ${filename} (期望大小: ${expected_size})"
    
    # 检查是否已成功下载并验证 (原逻辑完全保留)
    log_message "DEBUG" "检查状态文件是否已记录此blob"
    local already_downloaded=false
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        if jq -e --arg digest "$digest" '.downloaded_blobs[] | select(.digest == $digest)' "$STATE_FILE" > /dev/null 2>&1; then
            already_downloaded=true
        fi
    fi
    
    if $already_downloaded; then
        log_message "INFO" "此blob已记录为成功下载，跳过"
        set -euo pipefail  # 恢复严格模式
        return 0
    fi
    
    # 检查文件是否存在且完整 (原逻辑完全保留)
    log_message "DEBUG" "检查文件是否已存在: ${filepath}"
    if [[ -f "$filepath" ]]; then
        log_message "DEBUG" "文件存在，开始验证"
        local actual_size=$(get_file_size "$filepath")
        local actual_hash=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1 || echo "")
        local expected_hash="${digest#sha256:}"
        
        log_message "TRACE" "文件验证: 实际大小=${actual_size}, 期望大小=${expected_size}"
        log_message "TRACE" "文件验证: 实际哈希=${actual_hash:0:16}..., 期望哈希=${expected_hash:0:16}..."
        
        if [[ $actual_size -eq $expected_size ]] && [[ "$actual_hash" == "$expected_hash" ]]; then
            log_message "INFO" "文件已存在且校验通过，跳过下载"
            # 记录到状态
            if [[ -f "$STATE_FILE" ]]; then
                jq --arg digest "$digest" --arg path "$filepath" '.downloaded_blobs += [{"digest": $digest, "path": $path}]' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null
                if [[ $? -eq 0 ]]; then
                    mv "${STATE_FILE}.tmp" "$STATE_FILE"
                fi
            fi
            set -euo pipefail  # 恢复严格模式
            return 0
        else
            log_message "WARN" "文件存在但校验失败，重新下载"
            rm -f "$filepath" "$aria2_temp_file"
            log_message "TRACE" "已删除旧文件和 aria2 临时控制文件"
        fi
    else
        log_message "DEBUG" "文件不存在，需要下载"
    fi
    
    # 断点续传: 检查 aria2 临时控制文件 (适配 aria2 断点逻辑)
    local has_aria2_temp=false
    if [[ -f "$aria2_temp_file" ]]; then
        has_aria2_temp=true
        log_message "INFO" "发现 aria2 断点续传文件，支持恢复下载"
    fi
    
    while [[ $retry_count -lt $MAX_RETRY && $success -eq 0 ]]; do
        ((retry_count++))
        log_message "INFO" "尝试第 ${retry_count}/${MAX_RETRY} 次下载 (aria2 线程数: ${ARIA2_THREADS})..."
        
        # ========== 核心修改：构建 aria2c 命令数组 ==========
        local aria2_args=()
        # 多线程与分片配置
        aria2_args+=("-x${ARIA2_THREADS}")          # 每服务器最大连接数
        aria2_args+=("-s${ARIA2_THREADS}")          # 任务分片数
        aria2_args+=("-k${ARIA2_MIN_SPLIT}")        # 最小分片大小
        # 断点续传与重试
        aria2_args+=("-c")                          # 启用断点续传
        aria2_args+=("--max-tries=1")               # 单轮重试交给外层循环
        aria2_args+=("--retry-wait=${RETRY_DELAY}") # 重试等待时间
        # 超时配置
        aria2_args+=("--timeout=${ARIA2_TIMEOUT}")
        aria2_args+=("--connect-timeout=30")
        # 文件配置
        aria2_args+=("--allow-overwrite=true")
        aria2_args+=("--auto-file-renaming=false")
        aria2_args+=("--file-allocation=none")      # Termux/轻量文件系统友好
        # 日志与静默配置
        aria2_args+=("--log-level=warn")
        aria2_args+=("--summary-interval=0")
        # 输出路径
        aria2_args+=("-d" "$(dirname "${filepath}")")
        aria2_args+=("-o" "$(basename "${filepath}")")
        # HTTP 头部 (保持与 Docker Registry 兼容)
        aria2_args+=("--header=User-Agent: docker/${DOCKER_CLIENT_VERSION}")
        aria2_args+=("--header=Accept: application/octet-stream")
        if [[ -n "${BEARER_TOKEN}" ]]; then
            aria2_args+=("--header=Authorization: Bearer ${BEARER_TOKEN}")
            log_message "TRACE" "aria2 命令添加认证头"
        fi
        # 目标 URL
        aria2_args+=("${blob_url}")
        # =======================================================
        
        log_message "TRACE" "执行命令: aria2c ${aria2_args[*]}"
        
        # 执行 aria2 下载
        log_message "DEBUG" "开始 aria2 多线程下载请求"
        aria2c "${aria2_args[@]}"
        local aria2_exit_code=$?
        
        log_message "DEBUG" "aria2 退出码: ${aria2_exit_code}"
        
        # 判定 aria2 执行结果 (0=成功, 3=断点续传未完成, 其他=失败)
        if [[ $aria2_exit_code -eq 0 ]]; then
            log_message "DEBUG" "aria2 下载完成"
            
            # 验证文件 (原逻辑完全保留)
            local actual_size=$(get_file_size "$filepath")
            local actual_hash=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1 || echo "")
            local expected_hash="${digest#sha256:}"
            
            log_message "DEBUG" "文件验证 - 实际大小: ${actual_size}, 期望大小: ${expected_size}"
            log_message "TRACE" "文件验证 - 实际哈希: ${actual_hash:0:12}..., 期望哈希: ${expected_hash:0:12}..."
            
            if [[ $actual_size -eq $expected_size ]] && [[ "$actual_hash" == "$expected_hash" ]]; then
                log_message "INFO" "✅ 下载成功且校验通过!"
                # 更新状态文件
                if [[ -f "$STATE_FILE" ]]; then
                    jq --arg digest "$digest" --arg path "$filepath" '.downloaded_blobs += [{"digest": $digest, "path": $path}]' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null
                    if [[ $? -eq 0 ]]; then
                        mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        log_message "TRACE" "状态文件已更新"
                    else
                        log_message "WARN" "更新状态文件失败"
                    fi
                fi
                success=1
                # 清理 aria2 临时控制文件
                rm -f "$aria2_temp_file" 2>/dev/null
            else
                log_message "ERROR" "❌ 下载文件校验失败 (大小: ${actual_size}/${expected_size})"
                rm -f "$filepath" "$aria2_temp_file"
                log_message "TRACE" "已删除校验失败的文件和临时控制文件"
            fi
        elif [[ $aria2_exit_code -eq 3 ]]; then
            log_message "WARN" "aria2 下载被中断，保留断点续传文件"
        else
            log_message "WARN" "aria2 下载请求失败 (尝试: ${retry_count}, 退出码: ${aria2_exit_code})"
            # 非断点中断，清理临时文件
            if [[ $retry_count -eq $MAX_RETRY ]]; then
                rm -f "$aria2_temp_file" 2>/dev/null
            fi
            [[ $retry_count -lt $MAX_RETRY ]] && sleep "$RETRY_DELAY"
        fi
    done
    
    # 恢复严格模式
    set -euo pipefail
    
    if [[ $success -eq 0 ]]; then
        log_message "ERROR" "❌ 下载失败: ${filename} (重试 ${MAX_RETRY} 次)"
        return 1
    fi
    
    log_message "DEBUG" "函数 download_single_blob (aria2) 成功完成"
    return 0
}

# 4. 主下载流程
download_all_blobs() {
    # 临时禁用严格模式
    set +euo pipefail
    
    log_message "INFO" "===== [4/5] 下载所有镜像层开始 ====="
    log_message "DEBUG" "函数 download_all_blobs 被调用"
    
    if [[ ! -f "${OUTPUT_DIR_ABS}/blobs.list" ]]; then
        log_message "ERROR" "Blobs列表文件不存在: ${OUTPUT_DIR_ABS}/blobs.list"
        set -euo pipefail
        return 1
    fi
    
    log_message "DEBUG" "检查blobs.list文件内容和格式"
    local file_lines=$(wc -l < "${OUTPUT_DIR_ABS}/blobs.list" 2>/dev/null || echo 0)
    log_message "TRACE" "文件行数: ${file_lines}"
    
    # 修复：使用更简单的方法读取文件
    local blobs_array=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            blobs_array+=("$line")
            log_message "TRACE" "添加到数组: '$line'"
        fi
    done < "${OUTPUT_DIR_ABS}/blobs.list"
    
    local total_blobs=${#blobs_array[@]}
    log_message "INFO" "从文件中读取的blobs数量: ${total_blobs}"
    
    if [[ $total_blobs -eq 0 ]]; then
        log_message "ERROR" "没有有效的blobs需要下载"
        set -euo pipefail
        return 1
    fi
    
    local current=0
    local failed_blobs=()
    
    log_message "INFO" "开始逐个下载blobs"
    for blob_line in "${blobs_array[@]}"; do
        ((current++))
        log_message "INFO" "=================================================="
        log_message "INFO" "处理第 ${current}/${total_blobs} 个blob"
        log_message "DEBUG" "原始行: '${blob_line}'"
        
        # 使用awk分割字符串，更可靠
        local digest=$(echo "$blob_line" | awk -F'|' '{print $1}')
        local size=$(echo "$blob_line" | awk -F'|' '{print $2}')
        
        log_message "DEBUG" "解析结果: digest='${digest}', size='${size}'"
        
        if [[ -z "$digest" ]] || [[ -z "$size" ]]; then
            log_message "ERROR" "无法解析blob行: ${blob_line}"
            failed_blobs+=("解析失败: ${blob_line}")
            continue
        fi
        
        # 验证digest格式
        if [[ ! "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]]; then
            log_message "WARN" "digest格式可能不正确: ${digest}"
        fi
        
        # 验证size是数字
        if [[ ! "$size" =~ ^[0-9]+$ ]]; then
            log_message "WARN" "size不是有效数字: ${size}"
        fi
        
        log_message "INFO" "开始下载: ${digest:0:16}... (${size} 字节)"
        
        download_single_blob "$digest" "$size"
        local download_result=$?
        
        if [[ $download_result -ne 0 ]]; then
            log_message "ERROR" "blob下载失败: ${digest}"
            failed_blobs+=("$digest")
        else
            log_message "INFO" "blob下载成功: ${digest}"
        fi
        
        log_message "INFO" "第 ${current}/${total_blobs} 个blob处理完成"
        log_message "INFO" "=================================================="
        
        # 添加短暂延迟，避免请求过快
        sleep 0.5
    done
    
    # 结果汇总
    log_message "INFO" "===== 下载完成总结 ====="
    local downloaded_count=0
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        downloaded_count=$(jq '.downloaded_blobs | length' "$STATE_FILE" 2>/dev/null || echo 0)
    fi
    log_message "INFO" "成功下载: ${downloaded_count}/${total_blobs}"
    
    set -euo pipefail  # 恢复严格模式
    
    if [[ ${#failed_blobs[@]} -gt 0 ]]; then
        log_message "ERROR" "失败的blobs (${#failed_blobs[@]}个):"
        for blob in "${failed_blobs[@]}"; do
            log_message "ERROR" "  - ${blob}"
        done
        log_message "INFO" "===== [4/5] 下载所有镜像层完成 (有失败) ====="
        return 1
    else
        log_message "INFO" "所有blobs下载成功!"
        log_message "INFO" "===== [4/5] 下载所有镜像层完成 ====="
        return 0
    fi
}

# 5. 最终完整性验证
final_validation() {
    log_message "INFO" "===== [5/5] 最终完整性验证开始 ====="
    log_message "DEBUG" "函数 final_validation 被调用"
    
    local all_valid=true
    local validated_file="${OUTPUT_DIR_ABS}/validated.list"
    
    log_message "DEBUG" "创建验证记录文件: ${validated_file}"
    echo "# 完整性验证记录 - $(date)" > "$validated_file"
    echo "# 格式: 文件路径 | 预期摘要 | 实际摘要 | 状态" >> "$validated_file"
    
    # 从状态文件中读取所有已记录的blobs进行验证
    local blob_count=0
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        blob_count=$(jq '.downloaded_blobs | length' "$STATE_FILE" 2>/dev/null || echo 0)
    fi
    
    log_message "INFO" "需要验证的blobs数量: ${blob_count}"
    
    for ((i=0; i<blob_count; i++)); do
        log_message "DEBUG" "验证第 $((i+1))/${blob_count} 个blob"
        
        local blob_entry=$(jq -r ".downloaded_blobs[$i] | \"\(.digest)|\(.path)\"" "$STATE_FILE" 2>/dev/null || echo "||")
        IFS='|' read -r digest filepath <<< "$blob_entry"
        
        log_message "TRACE" "验证条目: digest='${digest}', path='${filepath}'"
        
        if [[ -f "$filepath" ]]; then
            log_message "DEBUG" "文件存在: ${filepath}"
            local actual_hash=$(sha256sum "$filepath" 2>/dev/null | cut -d' ' -f1 || echo "")
            local expected_hash="${digest#sha256:}"
            
            log_message "TRACE" "哈希比较 - 实际: ${actual_hash:0:16}..., 期望: ${expected_hash:0:16}..."
            
            if [[ "$actual_hash" == "$expected_hash" ]]; then
                log_message "INFO" "✅ ${filepath##*/} 验证通过"
                echo "${filepath} | ${digest} | sha256:${actual_hash} | PASS" >> "$validated_file"
            else
                log_message "ERROR" "❌ ${filepath##*/} 验证失败!"
                echo "${filepath} | ${digest} | sha256:${actual_hash} | FAIL" >> "$validated_file"
                all_valid=false
            fi
        else
            log_message "ERROR" "❌ ${filepath##*/} 文件不存在!"
            echo "${filepath} | ${digest} | FILE_MISSING | FAIL" >> "$validated_file"
            all_valid=false
        fi
    done
    
    log_message "DEBUG" "验证完成，结果: all_valid=${all_valid}"
    
    if $all_valid; then
        log_message "INFO" "🎉 所有文件完整性验证通过!"
        log_message "INFO" "📋 验证报告: ${validated_file}"
        
        # 生成合并tar包的示例命令（可选）
        local manifest_digest=""
        if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
            manifest_digest=$(jq -r '.manifest_digest' "$STATE_FILE" 2>/dev/null || echo "")
        fi
        
        if [[ -n "$manifest_digest" ]]; then
            log_message "DEBUG" "manifest摘要: ${manifest_digest}"
        fi
        
        log_message "INFO" "💡 你可以使用以下命令重新打包镜像:"
        log_message "INFO" "  # 保存镜像配置"
        log_message "INFO" "  jq . '${OUTPUT_DIR_ABS}/manifest_${ARCH}.json' > manifest.json"
        log_message "INFO" "  # 创建镜像tar包 (示例)"
        log_message "INFO" "  tar -cvf vllm-image.tar manifest.json \\"
        
        for ((i=0; i<blob_count; i++)); do
            local path=$(jq -r ".downloaded_blobs[$i].path" "$STATE_FILE" 2>/dev/null || echo "")
            if [[ -n "$path" ]]; then
                log_message "INFO" "    -C ${OUTPUT_DIR_ABS} $(basename "$path") \\"
            fi
        done
        
        log_message "INFO" "===== [5/5] 最终完整性验证完成 (成功) ====="
    else
        log_message "ERROR" "⚠️ 完整性验证失败，请检查上述错误"
        log_message "INFO" "===== [5/5] 最终完整性验证完成 (失败) ====="
        return 1
    fi
    
    return 0
}

# ==================== 主执行流程 ====================
main() {
    log_message "INFO" "=================================================="
    log_message "INFO" "===== vLLM 镜像下载开始 | $(date) ====="
    log_message "INFO" "=================================================="
    log_message "INFO" "仓库: ${REPO}"
    log_message "INFO" "标签: ${TAG}"
    log_message "INFO" "架构: ${ARCH}"
    log_message "INFO" "输出目录: ${OUTPUT_DIR_ABS}"
    log_message "INFO" "日志级别: ${LOG_LEVEL}"
    log_message "INFO" "当前工作目录: $(pwd)"
    log_message "INFO" "用户: $(whoami)"
    log_message "INFO" "主机名: $(hostname)"
    
    # 按步骤执行
    init_environment
    get_bearer_token
    get_and_parse_manifest
    download_all_blobs
    final_validation
    
    log_message "INFO" "=================================================="
    log_message "INFO" "===== 脚本执行完成 | $(date) ====="
    log_message "INFO" "=================================================="
    log_message "INFO" "📁 输出目录: ${OUTPUT_DIR_ABS}"
    log_message "INFO" "📋 状态文件: ${STATE_FILE}"
    log_message "INFO" "📄 调试日志: ${DEBUG_LOG}"
    
    # 最终统计
    local total_files=$(find "${OUTPUT_DIR_ABS}" -type f -name "sha256_*" 2>/dev/null | wc -l)
    local total_size=$(du -sh "${OUTPUT_DIR_ABS}" 2>/dev/null | cut -f1 || echo "未知")
    log_message "INFO" "📊 最终统计: ${total_files} 个文件，总大小: ${total_size}"
}

# 执行主函数
log_message "INFO" "脚本启动，参数: $@"
main "$@"
exit_code=$?
log_message "INFO" "脚本退出，状态码: ${exit_code}"
exit $exit_code