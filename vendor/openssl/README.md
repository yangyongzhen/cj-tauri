# vendor/openssl —— 随包分发的 OpenSSL 3 x64 运行库

`libssl-3-x64.dll` / `libcrypto-3-x64.dll`（OpenSSL **3.4.7**，x64）：

仓颉运行时的 TLS（`stdx.net.tls`）在 Windows 上**按名字加载**这两个 DLL
（`LoadLibrary("libssl-3-x64.dll")`），**不在任何 PE 导入表里**——递归解析导入表收依赖
会漏掉它们，缺了的症状极隐蔽：窗口照起、页面照加载、http 接口照 200，**只有 https 全灭**：

```
TlsException: Can not load openssl library or function CRYPTO_get_ex_new_index.
```

SDK 与 stdx 都不带这两个文件，所以作为仓库资源随包分发：

- `scripts/winbuild.sh`（Linux 交叉打包）打出 exe 后，把它们拷到 `dist-single/` 与 exe 并排
  （`LoadLibrary` 的搜索顺序里 exe 目录最优先）；
- 目录式便携包 `scripts/pack-win.sh` 早已覆盖同一对文件（见其 `openssl_dirs`）。

来源：OpenSSL Project 的 Windows x64 官方二进制（Apache-2.0 许可，见
`README.OpenSource` 的 "OpenSSL" 条目）；本仓现存文件取自 cjh 项目 Windows 发行包的随包副本，
未做任何修改。升级时直接替换这两个文件并在 `README.OpenSource` 更新版本号。
