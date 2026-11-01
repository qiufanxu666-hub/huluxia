# 阶段 4 变更记录

- 版本升级到 0.4.0。
- 新增 Objective-C 原生脚本存储类 `HXScriptStore`。
- 脚本保存在 App 沙盒 `Documents/LuaScripts/`，独立于网页 localStorage。
- 支持列出、保存、读取、删除 Lua 文件；界面接入保存和加载。
- 新增“Lua 脚本库”入口，保存当前编辑器内容并从原生目录加载脚本。
- 单个脚本 UTF-8 内容限制 4 MB，采用原子写入。
- 加载只填入编辑器，不会自动执行。
- 尚未执行 Theos/iOS SDK 编译或设备实测。
