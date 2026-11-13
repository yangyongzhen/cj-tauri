package ionic_movie_app

/* 单文件打包的**空存根**：仓库内正常构建按相对路径读盘（textOrFile 的读盘分支）；
   scripts/winbuild.sh 打单文件包时会把本文件重写成非空 base64（内嵌模式）。
   声明了哪几个常量打包器就生成哪几个——本示例不嵌 vendor 资源，不写 PACKED_VENDOR_B64。 */
public let PACKED_UI_B64: String = ""
public let PACKED_CAPS_B64: String = ""
