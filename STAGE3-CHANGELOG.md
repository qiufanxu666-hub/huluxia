# 阶段 3 变更记录

- 版本号升级到 0.3.0。
- 新增 `UniformTypeIdentifiers` 系统框架依赖。
- 新增原生文本文档导入：单文件、UTF-8、最大 4 MB。
- 新增系统分享/存储导出：生成临时 `.lua` / `.txt` 文件，分享完成后清理。
- 通过 WKUserScript 在容器内适配原页面 `triggerImportLua()` 和 `exportLuaFile()`，原始 HTML 资源本身保持不变。
- JavaScript 桥接脚本已通过 Node.js `--check` 语法检查。
- 尚未执行 iOS SDK / Theos 编译，尚未进行设备实测。
