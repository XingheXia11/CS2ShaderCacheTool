# CS2 快速重建着色器缓存工具

流程依据小黑盒帖子：[《CS更新后掉帧严重？一张图片解决你的问题！》](https://www.xiaoheihe.cn/app/bbs/link/3be9704d089b)（作者：忧郁美男子，2025-05-17）

适用于 **Windows + Steam 版 CS2**，用于解决 CS2 更新后掉帧、卡顿的问题。

## 下载使用

1. 打开本仓库页面，点绿色 **Code** 按钮 → **Download ZIP**，解压到任意文件夹（也可以在 Releases 页下载打包版）；
2. 双击 `Rebuild-CS2-Shader-Cache.bat`，按提示操作即可。

> 仓库结构：根目录的 `Rebuild-CS2-Shader-Cache.bat` 是唯一入口，脚本和本说明都在 `src\` 里。只需双击根目录那个 bat，不用进 `src\`。

> 首次运行如果弹出 SmartScreen 或杀毒软件提示，属于脚本类工具的常见误报，点击"仍要运行 / 允许"即可。工具无需安装，也不依赖 git 或 PowerShell 7。

## 使用方法

1. **完全退出 CS2**（游戏本体和后台都要退）。
2. 双击 `Rebuild-CS2-Shader-Cache.bat`（一般无需管理员权限；若提示无法删除文件，则右键"以管理员身份运行"）。
3. 按黑窗口里的提示操作即可，需要人工参与的只有 4 处：
   - 开场按回车=从第 1 步跑全流程（也可以输入步骤编号只跑后面几步）；
   - 等 Steam 校验完文件后按一次回车；
   - 在 Steam 控制台按 Ctrl+V 粘贴 `shader_build 730`（工具已自动复制到剪贴板）后回车；
   - 途中的"是否"提示直接回车选"是"（未检测到显卡驱动缓存时，清理那项会自动跳过）。

### 只想重跑后面几步

等 Steam 校验、进游戏跑图都很耗时，中断后不必从头再来：在开场那个提示里直接输入步骤编号（1-5），就从那一步开始。例如校验已经做完了，输入 `3` 即从"清理着色器缓存"开始。

前置检查和定位游戏目录每次都会先跑（不占编号，后面每一步都依赖它）；被跳过的步骤会印一行 `[!] 已跳过第 1-n 步 (视为已完成)`，不会静默略过。步骤之间的先后顺序工具不替你判断——比如没做步骤 1 就直接跑步骤 4 也是允许的。

也可以用命令行运行（支持参数）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Rebuild-CS2ShaderCache.ps1            # 正式执行
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Rebuild-CS2ShaderCache.ps1 -DryRun    # 演练模式，不实际改动
powershell -NoProfile -ExecutionPolicy Bypass -File .\src\Rebuild-CS2ShaderCache.ps1 -AppId 730 # 指定其他 Steam 游戏 AppId
```

## 工具自动化的内容（对应教程流程）

| 教程步骤 | 工具做的事 |
|---|---|
| 库中右键 CS2 → 浏览本地文件 → game → core | 自动从注册表和 `libraryfolders.vdf` 定位安装目录，进入 `game\core` |
| 删除 shaders 开头的文件 | 自动列出并移出所有 `shaders*` 文件（先移到备份目录，不是直接永久删除） |
| 属性 → 验证文件完整性 | 自动打开 `steam://validate/730`，被删文件会自动重新下载 |
| 开始菜单磁盘清理 → 删除 C 盘 DirectX 着色器缓存 | 直接清理 `%LOCALAPPDATA%\Microsoft\DirectX Shader Cache`（即磁盘清理里那一项），可选同时清理 NVIDIA/AMD/Intel 驱动着色器缓存 |
| Win+R → `steam://open/console` → 控制台输入 `shader_build 730` | 自动打开 Steam 控制台，并把 `shader_build 730` 复制到剪贴板，Ctrl+V 粘贴即可（粘贴执行那一下需人工，Steam 界面无法安全自动化） |
| 打开单机模式跑图 | 自动请求启动 CS2，并提醒先跑 1-2 局离线人机让着色器重新编译 |

## 注意事项

- **一定要跑图**：`shader_build 730` 只是预编译，教程强调完成后必须进游戏跑图，否则实战仍可能掉帧。
- **效果因人而异**：原帖作者也说"每个人的配置都不同，有些人可能用了会没有效果，这是正常的"。
- **如果更卡了**：教程原话——帧数非但没有提升反而下降，重下游戏即可。
- 清理 DirectX / 显卡着色器缓存会影响**所有游戏**：其他游戏首次启动时也会重新编译着色器，属正常现象。
- 备份位置：`%LOCALAPPDATA%\CS2ShaderCacheTool\backup_时间戳`。校验完整性完成后这些备份就没用了，可手动删除。
- Steam 控制台那条命令是 Steam 客户端内置命令，必须在 Steam 窗口里执行；工具会自动把它复制到剪贴板，粘贴回车即可。
