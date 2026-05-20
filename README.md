# dev-shell-container-kit

Shell 脚本工具集，用于处理 Docker 镜像分发的网络波动问题，以及实现 Docker 镜像到标准 OCI 格式的对齐转换。  
包含镜像分层下载和 OCI 格式规范化转换脚本，原生支持**断点续传**、**多线程下载**与**文件哈希完整性校验**。

- English README  
- License: MIT  
- Shell: Bash  
- Platform: Ubuntu | Termux  

> 📌 项目随缘更新，仅修复严重影响使用的 bug，功能迭代视需求与精力而定。

## 核心脚本功能与关联

| 脚本文件 | 功能 | 关联关系 |
|---------|------|----------|
| `docker_until/downloaddocker.sh` | 模拟 Docker 客户端拉取镜像分层 Blob 文件，集成 aria2 多线程下载、断点续传、哈希完整性校验 | **上游前置脚本**：输出镜像分层目录，作为格式转换脚本的唯一合法输入源 |
| `docker_until/build_oci_with_root_links.sh` | 将 Docker 原生分层结构规整为标准合规的 OCI 镜像目录，通过软链接解决多工具兼容问题，支持 skopeo 校验、导出标准 OCI 打包镜像 | **下游转换脚本**：读取分层目录，生成可通用导入的规范 OCI 结构，适配各类容器环境导入识别 |

## 环境依赖说明

### 一、镜像下载依赖（全平台通用）

适用于 `downloaddocker.sh`，Ubuntu / Termux 均可正常安装使用。

```bash
# Ubuntu / Debian
sudo apt install -y bash curl jq coreutils aria2

# Termux
pkg install -y bash curl jq coreutils aria2
```

二、OCI 格式转换 & 打包依赖

适用于 build_oci_with_root_links.sh，skopeo 为核心打包校验工具。

重要说明：Termux 原生无 skopeo 软件源，无法直接安装。可在本机 Proot 容器内安装使用，或切换至标准 Linux 环境执行镜像打包导出操作。

```bash
# Ubuntu / Debian 完整安装
sudo apt install -y jq gawk coreutils skopeo
```

三、Bash 版本要求

本工具集使用了 关联数组、正则表达式 等 Bash 4.0 及以上版本引入的特性。
必须使用 Bash 4.0+ 才能完整执行所有脚本（低版本 Bash 或 /bin/sh 会导致运行失败）。

· 查看当前 Bash 版本：bash --version
· Ubuntu 18.04+ / Debian 10+ / Termux 默认 Bash 版本均满足要求。
· 若版本过低，请通过系统包管理器升级 Bash。

脚本完整参数说明

1. 镜像下载脚本 downloaddocker.sh

```text
用法: $0 [选项]

选项:
  --registry URL        Docker 镜像仓库地址 (默认: https://docker.m.daocloud.io/v2)
  --repo REPO           镜像仓库名称 (必填，示例: library/nginx)
  --tag TAG             镜像版本标签 (默认: latest)
  --arch ARCH           指定目标系统架构 (默认: amd64)
  --username USER       私有镜像仓库登录用户名
  --password PASS       私有镜像仓库密码 / Token
  --output-dir DIR      自定义输出目录 (默认自动生成：<仓库名>-blobs)
  --log-level LEVEL     日志输出级别：SILENT|INFO|DEBUG|TRACE (默认: DEBUG)
  --max-retry N         下载失败最大重试次数 (默认: 3)
  --retry-delay SEC     重试等待间隔秒数 (默认: 2)
  --client-version VER  模拟 Docker 客户端版本 (默认: 26.1.0)
  --help, -h            查看帮助文档

运行依赖工具:
  jq  curl  sha256sum  aria2c

示例:
  # 基础下载镜像
  $0 --repo library/nginx --tag latest

  # 指定架构下载
  $0 --repo nginx/nginx --tag latest --arch arm64

  # 私有仓库认证下载
  $0 --username myuser --password mytoken --repo private/app --tag v1.0

  # 自定义目录与日志级别
  $0 --repo library/busybox --output-dir ./my-blobs --log-level INFO
```

2. OCI 格式转换脚本 build_oci_with_root_links.sh

```text
用法: $0 --source-dir DIR [可选参数]

选项:
  --source-dir DIR      下载脚本导出的 blobs 分层目录 (必填)
  --target-dir DIR      生成 OCI 镜像存放目录 (默认自动推断生成)
  --image-name NAME     自定义镜像名称 (默认从源目录自动识别)
  --tag TAG             自定义镜像标签 (默认: latest)
  --arch ARCH           强制指定架构 (默认自动读取清单文件识别)
  --no-package          仅构建标准 OCI 目录，不自动执行打包操作
  --help, -h            查看帮助文档

运行依赖工具:
  jq  awk  sha256sum  skopeo

示例:
  # 快速转换
  $0 --source-dir ./hello-world-blobs

  # 自定义镜像名与标签
  $0 --source-dir ./my-blobs --image-name myapp --tag v1.0

  # 仅构建目录不打包
  $0 --source-dir ./nginx-blobs --no-package
```

一键执行流程

1. 进入工作目录并赋予执行权限

```bash
cd docker_until
chmod +x downloaddocker.sh build_oci_with_root_links.sh
```

1. 执行镜像分层下载

```bash
./downloaddocker.sh --repo library/busybox
```

1. 执行标准 OCI 格式转换

```bash
./build_oci_with_root_links.sh --source-dir ./busybox-blobs
```

1. 标准 Linux 环境镜像合规验证

生成的 OCI 结构可直接被容器工具识别导入，校验命令：

```bash
skopeo inspect dir:./busybox-oci-linked
```

校验通过即代表镜像完全符合 OCI 行业规范，可直接导入容器套件正常使用。

前置检测机制说明

1. 依赖检测
   · 所有依赖齐全：仅输出 [CHECK] 环境工具检测正常，无多余冗余提示。
   · 缺失依赖：自动弹出对应系统安装命令，区分 Termux 特殊环境限制。
2. 帮助文档动态适配
   · 环境正常仅展示所需工具名，不展示安装命令。
   · 环境缺失依赖自动追加全平台安装方案与运维协助提示。
3. 统一缺失依赖提示文案

```text
当前环境缺失部分依赖，安装参考：
  Debian/Ubuntu: apt install -y jq curl coreutils aria2
  CentOS/RHEL:   yum install -y jq curl coreutils aria2
  Alpine Linux:  apk add --no-cache jq curl coreutils aria2
  Termux:        pkg install jq curl coreutils aria2
  无安装权限请联系相关运维人员部署。

当前环境缺失部分依赖，安装参考：
  Debian/Ubuntu: apt install -y jq gawk coreutils skopeo
  CentOS/RHEL:   yum install -y jq gawk coreutils skopeo
  Alpine Linux:  apk add --no-cache jq gawk coreutils skopeo
  Termux:        pkg install jq gawk coreutils   # 由于原生termux无 skopeo，可自行启动 Proot 容器或切换至标准 Linux 环境执行打包功能
```

注意事项

1. 私有镜像仓库登录认证功能暂未完成全量测试，生产环境使用私有仓库请自行调试权限。
2. 脚本头部内置镜像源、下载线程、超时时间等常量，可直接修改源码自定义配置。
3. 确保执行用户对输出目录拥有完整读写权限，避免权限不足导致下载、转换中断。
4. Termux 环境仅建议做镜像分层下载，镜像规范化打包导出优先使用内置 Proot 容器运行。
5. 部分旧版 Bash 存在语法兼容问题，更新系统 Bash 版本即可正常运行（要求 Bash 4.0+）。
6. 经本工具 + skopeo 规范打包生成的 *-oci-image.tar 镜像包，全部符合容器强制识别规范，可直接导入各类兼容容器环境使用。

开源许可证

本项目基于 MIT 开源许可证 开源。

```text
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
