# CS2 快速重建着色器缓存工具

流程依据小黑盒帖子：[《CS更新后掉帧严重？一张图片解决你的问题！》](https://www.xiaoheihe.cn/app/bbs/link/3be9704d089b)（作者：忧郁美男子，2025-05-17）

适用于 **Windows + Steam 版 CS2**，用于解决 CS2 更新后掉帧、卡顿的问题。

## 下载使用

1. 打开本仓库页面，点绿色 **Code** 按钮 → **Download ZIP**，解压到任意文件夹（也可以在 Releases 页下载打包版）；
2. 双击 `一键重建CS2着色器缓存.bat`，按提示操作即可。

> 首次运行如果弹出 SmartScreen 或杀毒软件提示，属于脚本类工具的常见误报，点击"仍要运行 / 允许"即可。工具无需安装，也不依赖 git 或 PowerShell 7。

## 使用方法

1. **完全退出 CS2**（游戏本体和后台都要退）。
2. 双击 `一键重建CS2着色器缓存.bat`（一般无需管理员权限；若提示无法删除文件，则右键"以管理员身份运行"）。
3. 按黑窗口里的提示操作即可，需要人工参与的只有 4 处：
   - 打开工具后按一次回车开始；
   - 等 Steam 校验完文件后按一次回车；
   - 在 Steam 控制台输入 `shader_build 730` 后按一次回车；
   - 两个"是否"提示直接回车选"是"。

也可以用命令行运行（支持参数）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Rebuild-CS2ShaderCache.ps1            # 正式执行
powershell -NoProfile -ExecutionPolicy Bypass -File .\Rebuild-CS2ShaderCache.ps1 -DryRun    # 演练模式，不实际改动
powershell -NoProfile -ExecutionPolicy Bypass -File .\Rebuild-CS2ShaderCache.ps1 -AppId 730 # 指定其他 Steam 游戏 AppId
```

## 工具自动化的内容（对应教程流程）

| 教程步骤 | 工具做的事 |
|---|---|
| 库中右键 CS2 → 浏览本地文件 → game → core | 自动从注册表和 `libraryfolders.vdf` 定位安装目录，进入 `game\core` |
| 删除 shaders 开头的文件 | 自动列出并移出所有 `shaders*` 文件（先移到备份目录，不是直接永久删除） |
| 属性 → 验证文件完整性 | 自动打开 `steam://validate/730`，被删文件会自动重新下载 |
| 开始菜单磁盘清理 → 删除 C 盘 DirectX 着色器缓存 | 直接清理 `%LOCALAPPDATA%\Microsoft\DirectX Shader Cache`（即磁盘清理里那一项），可选同时清理 NVIDIA/AMD/Intel 驱动着色器缓存 |
| Win+R → `steam://open/console` → 控制台输入 `shader_build 730` | 自动打开 Steam 控制台并提示输入命令（该命令需人工输入，Steam 界面无法安全自动化） |
| 打开单机模式跑图 | 自动请求启动 CS2，并提醒先跑 1-2 局离线人机让着色器重新编译 |

## 注意事项

- **一定要跑图**：`shader_build 730` 只是预编译，教程强调完成后必须进游戏跑图，否则实战仍可能掉帧。
- **效果因人而异**：原帖作者也说"每个人的配置都不同，有些人可能用了会没有效果，这是正常的"。
- **如果更卡了**：教程原话——帧数非但没有提升反而下降，重下游戏即可。
- 清理 DirectX / 显卡着色器缓存会影响**所有游戏**：其他游戏首次启动时也会重新编译着色器，属正常现象。
- 备份位置：`%LOCALAPPDATA%\CS2ShaderCacheTool\backup_时间戳`。校验完整性完成后这些备份就没用了，可手动删除。
- Steam 控制台那条命令是 Steam 客户端内置命令，必须在 Steam 窗口里手动输入，工具无法替代。
