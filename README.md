# dev-shell-container-kit
Shell 脚本工具集，当前包含 **Docker 镜像手动下载** 和 **OCI 格式标准化转换** 两个核心脚本，解决网络波动、镜像格式兼容问题。

## 核心脚本功能与关联
<table>
  <tr>
    <<th>脚本文件</</th>
    <<th>功能</</th>
    <<th>关联关系</</th>
  </tr>
  <tr>
    <td><code>docker_until/downloaddocker.sh</code></td>
    <td>模拟 Docker 客户端手动下载镜像 Blob 文件，支持断点续传、多线程（aria2）、完整性校验</td>
    <td><strong>上游脚本</strong>：输出 <code>vllm-blobs</code> 目录（含镜像层、清单文件），作为转换脚本的输入源</td>
  </tr>
  <tr>
    <td><code>docker_until/build_oci_with_root_links.sh</code></td>
    <td>将 Docker 格式 Blob 文件转换为标准 OCI 目录，创建根目录软链接保证工具兼容性</td>
    <td><strong>下游脚本</strong>：读取 <code>vllm-blobs</code> 目录，生成合规 OCI 目录 <code>vllm-oci-linked</code>，支持 <code>skopeo</code> 校验和打包</td>
  </tr>
</table>

## 快速使用
<ol>
  <li>
    <strong>下载镜像</strong>
    <pre><code>cd docker_until && chmod +x downloaddocker.sh && ./downloaddocker.sh</code></pre>
  </li>
  <li>
    <strong>转换为 OCI 格式</strong>
    <pre><code>chmod +x build_oci_with_root_links.sh && ./build_oci_with_root_links.sh</code></pre>
  </li>
  <li>
    <strong>验证</strong>
    <pre><code>skopeo inspect dir:./vllm-oci-linked</code></pre>
  </li>
</ol>

## 依赖
<ul>
  <li>
    <strong>Ubuntu/Debian</strong>
    <pre><code>sudo apt install -y bash curl jq aria2 skopeo</code></pre>
  </li>
  <li>
    <strong>Termux</strong>
    <pre><code>pkg install -y bash curl jq aria2 skopeo</code></pre>
  </li>
</ul>

## 注意事项
<ul>
  <li>私有仓库功能未经过测试，使用时可能存在认证、权限相关问题</li>
  <li>可直接修改脚本头部的常量参数，切换镜像源、调整输入输出目录</li>
</ul>

## 许可证
<p>MIT License</p>
<pre>
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
</pre>
