#!/bin/bash
# 脚本: build_oci_with_root_links.sh
# 功能：构建标准OCI目录，并将所有Blob文件软链接到根目录供skopeo访问
# 目标：零额外存储，完全兼容
#下载脚本是downloaddocker.sh

set -e
#原始目录
SOURCE_DIR="vllm-blobs"
#新目录
TARGET_DIR="vllm-oci-linked"

echo "=== 构建OCI目录（根目录软链接版） ==="
echo "源目录: $SOURCE_DIR"
echo "目标目录: $TARGET_DIR"
echo ""

# 1. 清理与准备
echo "[1/7] 准备目录结构..."
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR/blobs/sha256"
echo "  创建目录: $TARGET_DIR/"
echo "  创建目录: $TARGET_DIR/blobs/sha256/"
echo ""

# 2. 创建基础OCI文件
echo "[2/7] 创建 oci-layout..."
echo '{"imageLayoutVersion": "1.0.0"}' > "$TARGET_DIR/oci-layout"
echo "  已创建: $TARGET_DIR/oci-layout"
echo ""

# 3. 复制并重命名所有层文件到 blobs/sha256/
echo "[3/7] 复制所有镜像层文件到 blobs/sha256/..."
COPIED=0
for blob in "$SOURCE_DIR"/sha256_*; do
    if [ -f "$blob" ]; then
        filename=$(basename "$blob")
        pure_hash="${filename#sha256_}"
        cp "$blob" "$TARGET_DIR/blobs/sha256/$pure_hash"
        COPIED=$((COPIED + 1))
    fi
done
echo "  已复制 $COPIED 个层文件到 blobs/sha256/"
echo ""

# 4. 处理清单文件：转换格式并存入 blobs/sha256/
echo "[4/7] 转换并存储清单文件..."
MANIFEST_SOURCE="$SOURCE_DIR/manifest_amd64.json"

if [ ! -f "$MANIFEST_SOURCE" ]; then
    echo "  ❌ 错误: 找不到清单文件"
    exit 1
fi

# 转换格式 (Docker -> OCI)
CONVERTED="$TARGET_DIR/blobs/sha256/manifest_converted.json"
if ! command -v jq &> /dev/null; then
    echo "  使用 sed 转换 mediaType..."
    sed '
    s|"mediaType": "application/vnd.docker.distribution.manifest.v2+json"|"mediaType": "application/vnd.oci.image.manifest.v1+json"|;
    s|"mediaType": "application/vnd.docker.container.image.v1+json"|"mediaType": "application/vnd.oci.image.config.v1+json"|;
    s|"mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip"|"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip"|
    ' "$MANIFEST_SOURCE" > "$CONVERTED"
else
    echo "  使用 jq 转换 mediaType..."
    jq '
    .mediaType = "application/vnd.oci.image.manifest.v1+json" |
    .config.mediaType = "application/vnd.oci.image.config.v1+json" |
    .layers |= map(.mediaType = "application/vnd.oci.image.layer.v1.tar+gzip")
    ' "$MANIFEST_SOURCE" > "$CONVERTED"
fi

# 计算摘要并重命名
MANIFEST_DIGEST=$(sha256sum "$CONVERTED" | awk '{print "sha256:" $1}')
MANIFEST_SIZE=$(stat -c%s "$CONVERTED")
PURE_HASH=${MANIFEST_DIGEST#sha256:}
mv "$CONVERTED" "$TARGET_DIR/blobs/sha256/$PURE_HASH"

echo "  清单存储为: blobs/sha256/$PURE_HASH"
echo "  摘要: $MANIFEST_DIGEST"
echo "  大小: $MANIFEST_SIZE 字节"
echo ""

# 5. 创建 index.json
echo "[5/7] 创建 index.json..."
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
        "architecture": "amd64",
        "os": "linux"
      }
    }
  ]
}
EOF
echo "  已创建: $TARGET_DIR/index.json"
echo ""

# 6. 关键步骤：为所有 blobs/sha256/ 下的文件创建根目录软链接
echo "[6/7] 为所有Blob文件创建根目录软链接..."
cd "$TARGET_DIR"
LINK_COUNT=0
for blob_file in blobs/sha256/*; do
    if [ -f "$blob_file" ]; then
        filename=$(basename "$blob_file")
        # 在根目录创建同名软链接
        ln -sf "$blob_file" "$filename"
        LINK_COUNT=$((LINK_COUNT + 1))
    fi
done
cd - > /dev/null
echo "  已在根目录创建 $LINK_COUNT 个软链接"
echo ""

# 7. 特殊处理：确保 manifest.json 软链接存在（部分工具需要）
echo "[7/7] 确保 manifest.json 存在..."
cd "$TARGET_DIR"
# 如果根目录还没有 manifest.json，创建指向清单文件的链接
if [ ! -e "manifest.json" ]; then
    ln -sf "blobs/sha256/$PURE_HASH" manifest.json
    echo "  已创建 manifest.json -> blobs/sha256/$PURE_HASH"
else
    echo "  manifest.json 已存在（可能是软链接）"
fi
cd - > /dev/null

# 完成
echo ""
echo "=== 构建完成 ==="
echo "生成的目标目录: $TARGET_DIR"
echo ""
echo "目录结构示例:"
echo "  $TARGET_DIR/"
echo "  ├── oci-layout"
echo "  ├── index.json"
echo "  ├── manifest.json (软链接)"
echo "  ├── 0c19f07f0c8601... (软链接 -> blobs/sha256/0c19f07f0c8601...)"
echo "  ├── 66587c81b81a58... (软链接 -> blobs/sha256/66587c81b81a58...)"
echo "  ├── ... (更多软链接)"
echo "  └── blobs/sha256/"
echo "      ├── 0c19f07f0c8601... (实际文件)"
echo "      ├── 66587c81b81a58... (实际文件)"
echo "      └── ... (更多实际文件)"
echo ""
echo "=== 验证与使用 ==="
echo "1. 进入目录:"
echo "   cd $TARGET_DIR"
echo ""
echo "2. 列出根目录文件 (应该看到很多软链接):"
echo "   ls -l | head -10"
echo ""
echo "3. 验证目录是否可被识别:"
echo "   skopeo inspect dir:./"
echo ""
echo ""# 查看归档文件信息（以 docker-archive 为例）
# 进入已验证的目录
echo "cd ~/$TARGET_DIR"
echo "#创建 Docker 格式的 tar 归档文件，并命名为 vllm-image.tar"
echo "skopeo copy dir:./ docker-archive:$TARGET_DIR-image.tar:vllm:latest"
echo "skopeo inspect docker-archive:$TARGET_DIR-image.tar"
echo ""
echo ""
echo ""

# 或对于 OCI 归档
echo "cd ~/$TARGET_DIR"
echo "#创建 OCI 格式的 tar 归档文件"
echo "skopeo copy dir:./ oci-archive:$TARGET_DIR-oci-image.tar:vllm:latest"
echo "skopeo inspect oci-archive:$TARGET_DIR-oci-image.tar"
echo "✅ 脚本执行完毕。所有Blob文件已通过软链接在根目录可访问。"