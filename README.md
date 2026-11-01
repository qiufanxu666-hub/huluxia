# HuluXia Native — 阶段 5：Lua 引擎自检

本工程基于用户提供的 `葫芦侠（24）.html`。0.5.0 在 0.4.0 原生容器与原生 Lua 脚本库基础上，为现有 Fengari Lua 5.3 引擎增加隔离式自检。

> 本项目仍为源码工程，不是已编译、签名或验证可安装的 `.deb`。当前环境没有 Theos/iOS SDK，也未进行越狱设备实测。

## 阶段 5 新增

Lua 执行器新增“引擎自检”按钮。自检创建独立临时 Lua state，运行完后关闭，不复用用户当前运行状态，也不调用 H5GG 宿主功能。

七项检查：
1. Lua 5.3 整数除法 `//`
2. Lua 位运算
3. 元表 `__index`
4. 协程 `yield/resume`
5. UTF-8 标准库
6. `bit32` 兼容库
7. `string.pack/unpack`

每项通过/失败会写入 Lua 输出面板，并汇总到引擎状态栏。自检通过只证明本地 Lua VM 对这些语言特性可执行，不证明 `gg`/`h5gg` 的目标宿主 API 已连接。

## 前序功能

- Objective-C UIKit App + WKWebView 本地加载原 HTML。
- 原生桥接：toast、alert、剪贴板、日志、基础信息、文件导入/导出。
- 原生 Lua 脚本库：`Documents/LuaScripts/`，保存/加载/删除 API，4 MB 单文件限制。
- Rootless / Rootful Theos 工程入口与授权 Bundle ID 构建过滤配置。

## 尚未实现或验证

- Fengari 仍由原 HTML 内嵌并在 WKWebView 中执行，不是 Objective-C 原生 Lua VM。
- h5gg 的真实进程枚举、内存扫描、读写、冻结等宿主能力未移植。
- 任意进程注入、目标进程内存修改、通用游戏变速未实现。
- iOS 15–18 / iOS 26 越狱环境兼容性均需对应设备和工具链实测。
- 尚未运行 Theos 编译、代码签名或安装验证。

## 构建入口

```sh
export THEOS="$HOME/theos"
export TARGET_BUNDLES="com.example.authorizedapp,com.example.testhost"
THEOS_PACKAGE_SCHEME=rootless ./scripts/build.sh
THEOS_PACKAGE_SCHEME=rootful ./scripts/build.sh
```

当前 Tweak 是非侵入式占位入口。请仅在自己拥有或明确获准测试的设备与 App 上进行测试。
