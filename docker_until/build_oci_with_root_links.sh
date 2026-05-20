#!/bin/bash
# 脚本: build_oci_with_root_links.sh
# 功能：构建标准OCI目录 → 软链接 → 自动打包 docker/oci archive
# 搭配 downloaddocker.sh 使用，一键完成从下载到打包全流程

set -euo pipefail

# ==================== 默认配置 ====================
SOURCE_DIR=""
TARGET_DIR=""
IMAGE_NAME=""
IMAGE_TAG="latest"
ARCH=""
AUTO_PACKAGE=true

# ==================== 全局依赖预检 ====================
NEED_TOOLS=("jq" "awk" "sha256sum")
$AUTO_PACKAGE && NEED_TOOLS+=("skopeo")
LOST_TOOLS=()
for _t in "${NEED_TOOLS[@]}"; do
    command -v "$_t" &>/dev/null || LOST_TOOLS+=("$_t")
done
HAS_LOST=$([[ ${#LOST_TOOLS[@]} -gt 0 ]] && echo 1 || echo 0)

# ==================== 命令行参数解析 ====================
usage() {
    cat <<EOF
用法: $0 --source-dir DIR [选项]

选项:
  --source-dir DIR      downloaddocker.sh 输出的 blobs 目录 (必填)
  --target-dir DIR      生成的 OCI 目录 (默认: 从源目录名推断)
  --image-name NAME     镜像名 (默认: 从源目录名推断)
  --tag TAG             镜像标签 (默认: latest)
  --arch ARCH           目标架构 (默认: 自动从 manifest 文件名检测)
  --no-package          仅构建 OCI 目录，不自动打包
  --help, -h            显示此帮助信息

运行依赖工具:
  jq  awk  sha256sum  skopeo
EOF
    if [[ "$HAS_LOST" -eq 1 ]]; then
        cat <<EOF

当前环境缺失部分依赖，安装参考：
  Debian/Ubuntu: apt install -y jq gawk coreutils skopeo
  CentOS/RHEL:   yum install -y jq gawk coreutils skopeo
  Alpine Linux:  apk add --no-cache jq gawk coreutils skopeo
  Termux:        pkg install jq gawk coreutils #由于他不存在这个工具skopeo所以，你需要自行启动容器或切换到标准liunx执行本工具,proot的内部都可以
  无安装权限请联系相关运维人员部署。
EOF
    fi
    cat <<EOF

示例:
  $0 --source-dir ./hello-world-blobs
  $0 --source-dir ./my-blobs --image-name myapp --tag v1.0
  $0 --source-dir ./nginx-blobs --no-package
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir) SOURCE_DIR="$2"; shift 2 ;;
        --target-dir) TARGET_DIR="$2"; shift 2 ;;
        --output-dir) TARGET_DIR="$2"; shift 2 ;;   # 兼容旧名称
        --image-name) IMAGE_NAME="$2"; shift 2 ;;
        --tag)        IMAGE_TAG="$2"; shift 2 ;;
        --arch)       ARCH="$2"; shift 2 ;;
        --no-package) AUTO_PACKAGE=false; shift ;;
        --help|-h)    usage ;;
        *) echo "未知参数: $1 (使用 --help 查看帮助)"; exit 1 ;;
    esac
done

# ==================== 依赖检测（最先执行）====================
REQUIRED_TOOLS=("jq" "awk" "sha256sum")
$AUTO_PACKAGE && REQUIRED_TOOLS+=("skopeo")
check_dependencies() {
    local missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "=============================================="
        echo "  错误: 缺少必需工具: ${missing[*]}"
        echo "=============================================="
        echo ""
        echo "请使用对应系统命令安装:"
        echo ""
        echo "  Debian/Ubuntu:"
        echo "    apt install -y jq gawk coreutils skopeo"
        echo ""
        echo "  CentOS/RHEL:"
        echo "    yum install -y jq gawk coreutils skopeo"
        echo ""
        echo "  Alpine Linux:"
        echo "    apk add --no-cache jq gawk coreutils skopeo"
        echo ""
        echo "  Termux:"
        echo "    pkg install jq gawk coreutils skopeo"
        echo ""
        echo "如无网络或权限不足，请联系运维人员协助安装。"
        echo "=============================================="
        exit 1
    fi
    echo "[CHECK] 环境工具检测正常"
}
check_dependencies

# ==================== 参数验证与自动推断 ====================
if [[ -z "$SOURCE_DIR" ]]; then
    echo "错误: --source-dir 为必填参数"
    usage
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "错误: 源目录不存在: $SOURCE_DIR"
    exit 1
fi

# 从源目录名推断镜像名
if [[ -z "$IMAGE_NAME" ]]; then
    IMAGE_NAME=$(basename "$SOURCE_DIR" | sed 's/-blobs$//')
fi

# 从源目录名推断目标目录
if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="${IMAGE_NAME}-oci"
fi

# 自动发现 manifest 文件并检测架构
MANIFEST_SOURCE=""
if [[ -n "$ARCH" ]]; then
    MANIFEST_SOURCE="$SOURCE_DIR/manifest_${ARCH}.json"
    [[ ! -f "$MANIFEST_SOURCE" ]] && MANIFEST_SOURCE=""
fi

if [[ -z "$MANIFEST_SOURCE" ]]; then
    for candidate in "$SOURCE_DIR"/manifest_*.json "$SOURCE_DIR"/manifest.json "$SOURCE_DIR"/index.json; do
        if [[ -f "$candidate" ]]; then
            MANIFEST_SOURCE="$candidate"
            base=$(basename "$candidate" .json)
            if [[ "$base" =~ manifest_(.+) ]]; then
                ARCH="${BASH_REMATCH[1]}"
            fi
            break
        fi
    done
fi

if [[ -z "$MANIFEST_SOURCE" ]] || [[ ! -f "$MANIFEST_SOURCE" ]]; then
    echo "错误: 在 $SOURCE_DIR 中找不到 manifest 文件"
    ls -la "$SOURCE_DIR"/ 2>/dev/null || true
    exit 1
fi

ARCH="${ARCH:-amd64}"

echo "=== 构建OCI目录（自动打包版） ==="
echo "源目录:   $SOURCE_DIR"
echo "目标目录: $TARGET_DIR"
echo "镜像名:   $IMAGE_NAME"
echo "标签:     $IMAGE_TAG"
echo "架构:     $ARCH"
echo "清单文件: $(basename "$MANIFEST_SOURCE")"
echo "自动打包: $AUTO_PACKAGE"
echo ""

# ==================== [1/6] 准备目录结构 ====================
echo "[1/6] 准备目录结构..."
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR/blobs/sha256"
echo ""

# ==================== [2/6] 创建 oci-layout ====================
echo "[2/6] 创建 oci-layout..."
echo '{"imageLayoutVersion": "1.0.0"}' > "$TARGET_DIR/oci-layout"
echo ""

# ==================== [3/6] 复制 blob 文件 ====================
echo "[3/6] 复制镜像层文件到 blobs/sha256/..."
COPIED=0
FAILED=0
TOTAL_BLOBS=0

if [[ -f "$SOURCE_DIR/blobs.list" ]]; then
    echo "  从 blobs.list 读取 blob 列表..."
    while IFS='|' read -r digest size; do
        [[ -z "$digest" ]] && continue
        blob_name="${digest//:/_}"
        blob_path="$SOURCE_DIR/$blob_name"
        pure_hash="${digest#sha256:}"
        if [[ -f "$blob_path" ]]; then
            cp "$blob_path" "$TARGET_DIR/blobs/sha256/$pure_hash" && COPIED=$((COPIED + 1)) || FAILED=$((FAILED + 1))
        else
            echo "  警告: blob 文件不存在，跳过: $blob_name"
            FAILED=$((FAILED + 1))
        fi
        TOTAL_BLOBS=$((TOTAL_BLOBS + 1))
    done < "$SOURCE_DIR/blobs.list"
else
    echo "  未找到 blobs.list，扫描 sha256_* 文件..."
    for blob in "$SOURCE_DIR"/sha256_*; do
        if [[ -f "$blob" ]]; then
            filename=$(basename "$blob")
            pure_hash="${filename#sha256_}"
            cp "$blob" "$TARGET_DIR/blobs/sha256/$pure_hash" && COPIED=$((COPIED + 1)) || FAILED=$((FAILED + 1))
            TOTAL_BLOBS=$((TOTAL_BLOBS + 1))
        fi
    done
fi
echo "  已复制 $COPIED/$TOTAL_BLOBS 个文件到 blobs/sha256/"
[[ $FAILED -gt 0 ]] && echo "  警告: $FAILED 个文件复制失败"
echo ""

# ==================== [4/6] 转换并存储 manifest ====================
echo "[4/6] 转换并存储清单文件..."
CONVERTED="$TARGET_DIR/blobs/sha256/manifest_converted.json"
MANIFEST_MT=$(jq -r '.mediaType // ""' "$MANIFEST_SOURCE" 2>/dev/null || echo "")
echo "  清单 mediaType: ${MANIFEST_MT:-未知}"

case "$MANIFEST_MT" in
    application/vnd.oci.image.manifest.v1+json)
        echo "  已是 OCI 格式，直接复制..."
        cp "$MANIFEST_SOURCE" "$CONVERTED"
        ;;
    *)
        echo "  转换 Docker → OCI 格式..."
        jq '
        .mediaType = "application/vnd.oci.image.manifest.v1+json" |
        .config.mediaType = "application/vnd.oci.image.config.v1+json" |
        .layers |= map(.mediaType = "application/vnd.oci.image.layer.v1.tar+gzip")
        ' "$MANIFEST_SOURCE" > "$CONVERTED"
        ;;
esac

MANIFEST_DIGEST=$(sha256sum "$CONVERTED" | awk '{print "sha256:" $1}')
MANIFEST_SIZE=$(stat -c%s "$CONVERTED" 2>/dev/null || stat -f%z "$CONVERTED" 2>/dev/null)
PURE_HASH=${MANIFEST_DIGEST#sha256:}
mv "$CONVERTED" "$TARGET_DIR/blobs/sha256/$PURE_HASH"
echo "  清单摘要: $MANIFEST_DIGEST"
echo "  清单大小: $MANIFEST_SIZE 字节"
echo ""

# ==================== [5/6] 创建 index.json ====================
echo "[5/6] 创建 index.json..."
cat > "$TARGET_DIR/index.json" << EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "size": $MANIFEST_SIZE,
      "digest": "$MANIFEST_DIGEST",
      "platform": {
        "architecture": "$ARCH",
        "os": "linux"
      }
    }
  ]
}
EOF
echo ""

# ==================== [6/6] 创建根目录软链接 ====================
echo "[6/6] 创建根目录软链接..."
cd "$TARGET_DIR"
LINK_COUNT=0
for blob_file in blobs/sha256/*; do
    if [[ -f "$blob_file" ]]; then
        filename=$(basename "$blob_file")
        ln -sf "blobs/sha256/$filename" "$filename"
        LINK_COUNT=$((LINK_COUNT + 1))
    fi
done
ln -sf "blobs/sha256/$PURE_HASH" "manifest.json"
cd - > /dev/null
echo "  已创建 $LINK_COUNT 个 blob 软链接 + 1 个 manifest.json"
echo ""

# ==================== 自动打包 ====================
if $AUTO_PACKAGE; then
    echo "=== 自动打包 ==="
    cd "$TARGET_DIR"

    DOCKER_ARCHIVE="${IMAGE_NAME}-${ARCH}-image.tar"
    echo "[package] 生成 Docker archive: $DOCKER_ARCHIVE"
    skopeo copy "dir:./" "docker-archive:${DOCKER_ARCHIVE}:${IMAGE_NAME}:${IMAGE_TAG}"
    echo "  -> $(realpath "$DOCKER_ARCHIVE")"

    OCI_ARCHIVE="${IMAGE_NAME}-${ARCH}-oci-image.tar"
    echo "[package] 生成 OCI archive: $OCI_ARCHIVE"
    skopeo copy "dir:./" "oci-archive:${OCI_ARCHIVE}:${IMAGE_NAME}:${IMAGE_TAG}"
    echo "  -> $(realpath "$OCI_ARCHIVE")"

    cd - > /dev/null
    echo ""
    echo "=== 全部完成 ==="
    echo "OCI 目录:  $TARGET_DIR"
    echo "Docker 包: $TARGET_DIR/$DOCKER_ARCHIVE"
    echo "OCI 包:    $TARGET_DIR/$OCI_ARCHIVE"
else
    echo "=== 构建完成（跳过自动打包） ==="
    echo "OCI 目录: $TARGET_DIR"
    echo ""
    echo "手动打包:"
    echo "  cd $TARGET_DIR"
    echo "  skopeo copy dir:./ docker-archive:${IMAGE_NAME}-${ARCH}-image.tar:${IMAGE_NAME}:${IMAGE_TAG}"
fi
