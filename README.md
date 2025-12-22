dev-shell-container-kit
 
Shell 脚本工具集，当前包含 Docker 镜像手动下载 和 OCI 格式标准化转换 两个核心脚本，解决网络波动、镜像格式兼容问题。
 
核心脚本功能与关联
 
脚本文件 功能 关联关系 
 docker_until/downloaddocker.sh  模拟 Docker 客户端手动下载镜像 Blob 文件，支持断点续传、多线程（aria2）、完整性校验 上游脚本：输出  vllm-blobs  目录（含镜像层、清单文件），作为转换脚本的输入源 
 docker_until/build_oci_with_root_links.sh  将 Docker 格式 Blob 文件转换为标准 OCI 目录，创建根目录软链接保证工具兼容性 下游脚本：读取  vllm-blobs  目录，生成合规 OCI 目录  vllm-oci-linked ，支持  skopeo  校验和打包 
 
快速使用
 
1. 下载镜像
bash  
cd docker_until && chmod +x downloaddocker.sh && ./downloaddocker.sh
 
2. 转换为 OCI 格式
bash  
chmod +x build_oci_with_root_links.sh && ./build_oci_with_root_links.sh
 
3. 验证
bash  
skopeo inspect dir:./vllm-oci-linked
 
 
依赖
 
Ubuntu/Debian:
 
bash  
sudo apt install -y bash curl jq aria2 skopeo
 
 
Termux:
 
bash  
pkg install -y bash curl jq aria2 skopeo
 
 
注意
 
- 私有仓库功能未测试
- 脚本内可修改镜像源、目录路径等参数
 
许可证
 
MIT License
 
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
 
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.