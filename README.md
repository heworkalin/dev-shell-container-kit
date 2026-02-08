markdown
  
# dev-shell-container-kit
Shell 脚本工具集，用于处理 Docker 镜像分发的网络波动问题，以及实现 Docker 镜像到标准 OCI 转换格式对齐，包含镜像手动下载和oci格式转换对齐脚本，支持断点续传、多线程下载与镜像校验。

[English README](README_en.md)

<div align="center">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT">
  <img src="https://img.shields.io/badge/shell-bash-green.svg" alt="Shell: Bash">
  <img src="https://img.shields.io/badge/platform-Ubuntu%20%7C%20Termux-orange.svg" alt="Platform: Ubuntu | Termux">
</div>

<p align="center">
  📌 项目随缘更新，仅修复严重影响使用的 bug，功能迭代视需求与精力而定
</p>

## 核心脚本功能与关联
| 脚本文件 | 功能 | 关联关系 |
|----------|------|----------|
| `docker_until/downloaddocker.sh` | 模拟 Docker 客户端拉取镜像 Blob 层文件，集成 `aria2` 多线程下载、断点续传与文件完整性校验 | **上游脚本**：输出 `vllm-blobs` 目录（含镜像层、清单、配置文件），作为转换脚本的输入源 |
| `docker_until/build_oci_with_root_links.sh` | 将 Docker 原生 Blob 格式转换为标准 OCI 镜像目录，通过根目录软链接消除跨工具兼容性问题 | **下游脚本**：读取 `vllm-blobs` 目录，生成合规 OCI 结构目录 `vllm-oci-linked`，支持 `skopeo` 校验、打包与分发 |

## 快速开始
### 环境依赖
#### 基础依赖（Ubuntu/Debian + Termux 通用）
```shell
# Ubuntu/Debian
sudo apt install -y bash curl jq aria2

# Termux
pkg install -y bash curl jq aria2
```
 
###校验/打包依赖（仅标准 Linux 环境，Termux 非必需）
 
注：skopeo 在 Termux 中无法直接安装，推荐通过 Proot 容器 运行以获得或者完整打包功能
 
```shell
# Ubuntu/Debian 安装 skopeo（用于 OCI 镜像校验、打包）
sudo apt install -y skopeo
```
 
##一键使用
 
###1.下载镜像
```shell
cd docker_until && chmod +x downloaddocker.sh && ./downloaddocker.sh
```
###2.格式转换
```shell
chmod +x build_oci_with_root_links.sh && ./build_oci_with_root_links.sh
```
###3.结果验证（标准 Linux 环境）
```shell
skopeo inspect dir:./vllm-oci-linked
```
 
#注意事项
 
##1.私有镜像仓库的认证、权限功能暂未充分测试，使用私有镜像可能存在访问异常；
##2.脚本头部提供可配置常量（镜像源、输出目录、下载线程数等），可直接修改实现自定义需求；
##3.确保执行用户对输出目录拥有读写权限，避免因权限不足导致下载或转换失败；
##4.Termux 环境下建议搭配 Proot 容器使用，以规避部分工具的兼容性限制；
##5.经测试，第一个脚本存在一定的bug，对于目前的bash可能无法正常执行，准确来说是语法问题，termux更新之后可以正常使用。
 
#许可证
 
本项目基于 MIT 许可证 开源，详见 LICENSE 文件。
 
plaintext
  
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
