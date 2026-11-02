# DeskPet 🐣 — Windows 版

用 [Tauri 2](https://tauri.app) 写的 Windows 版：Rust 负责状态和系统功能，宠物和设置界面是普通的 HTML / CSS / JS（不需要 npm）。
同一份代码也能在 macOS 上运行，方便开发调试。

## 现在能做什么

- 透明、置顶、不占任务栏的宠物窗口，头顶 Cindy 风格血条；拖动、双击戳、右键菜单
- 只有宠物本身接收鼠标，窗口的透明部分点击会穿透到后面的程序
- 规则和 macOS 版一致：宵禁期间使用电脑扣血、久坐扣血、整晚没违规早上回血
- 三种攻击连击（雷击 / 连环耳光 / 丢易拉罐 / 随机），节奏和 macOS 版相同；受击时切换「受击」状态图
- 系统托盘：悬停显示 HP，菜单与右键菜单相同
- 设置：通用（开机启动、语言）、形象（状态图和特效素材选择、导入）、素材生成、规则、记录（30 天最低血量折线图 + 扣血记录）、备份
- 素材生成：AI 设置（OpenAI 兼容接口 / Google Gemini、Key、模型、代理）放在页面顶部；从照片生成满血形象后自动生成另外 3 个状态，特效素材分两批生成（小人的抛起 / 投掷以待机图为参考）。提示词可编辑、可恢复默认，也能「复制提示词」去网页版生成。没有 API Key 时选照片会直接使用原图（macOS 版的本地卡通滤镜在 Windows 上没有）
- 备份：导入 / 导出整套配置，和 macOS 版的配置文件通用（`deskpet-config` v1）
- 内置默认素材（仓库根目录的 `assets/defaults/`，与 macOS 版共用），首次启动装进素材库
- 中文 / English，切换立即生效

还没做：攻击后持续的威胁状态（乌云停留、小人抛罐）、更丰富的粒子特效。

## 在 Windows 上构建

需要：Windows 10/11（自带 WebView2）、[Rust](https://rustup.rs)、Visual Studio C++ 生成工具（rustup 安装时会提示）。

```powershell
cargo install tauri-cli --version "^2" --locked
cd windows\src-tauri
cargo tauri dev      # 开发运行
cargo tauri build    # 生成安装包：target\release\bundle\nsis\DeskPet_0.1.0_x64-setup.exe
```

安装包按「当前用户」安装，不需要管理员权限。

也可以直接用 GitHub 构建：`.github/workflows/build.yml` 每次推送都会编译，推送 `v*` 标签时发布到 Releases（见根目录 README 的「下载」）。

## 在 macOS 上开发调试

```bash
cd windows/src-tauri
cargo build && ./target/debug/deskpet
```

在 macOS 上运行时数据放在 `~/Library/Application Support/DeskPet-Tauri/`，不会碰 macOS 原生版的数据。

## 数据位置

`%APPDATA%\DeskPet\`：

| 文件 | 内容 |
|---|---|
| `settings.json` | 设置（键名与 macOS 版相同） |
| `state.json` | 当前 HP、扣血记录、夜间结算状态 |
| `hp_history.json` | 每日最低血量（格式与 macOS 版相同） |
| `Library/pet/<状态>/`、`Library/fx/<素材>/` | 素材库（结构与 macOS 版相同），可以直接往文件夹里放图片 |

## 代码结构

- `src-tauri/src/main.rs` — 启动、插件、窗口事件
- `pet.rs` — HP、攻击连击队列、回血、说话、记录（对应 macOS 的 PetStore）
- `monitor.rs` — 每分钟一次的规则判断（对应 BehaviorMonitor），空闲时间用 `GetLastInputInfo`
- `library.rs` — 素材库：扫描、选择、导入、删除到回收站、安装默认素材
- `settings.rs` — settings.json 和语言
- `history.rs` — 每日最低血量
- `tray.rs` — 托盘图标和菜单（右键菜单共用）
- `windows.rs` — 宠物窗口位置、鼠标穿透、设置窗口
- `ai.rs` — OpenAI 兼容接口和 Gemini 请求、白底抠图、代理
- `generate.rs` — 从照片创建形象、并行生成状态图和特效素材
- `prompts.rs` — 默认提示词和对应的设置项（与 macOS 版相同）
- `config.rs` — 配置导入导出（含单元测试：`cargo test`）
- `commands.rs` — 给网页调用的命令
- `ui/` — `pet.html/css/js`（宠物、血条、特效）、`settings.*`（设置窗口）、`common.js`（中英文、素材类型）

## 已知限制

- 目前只在 macOS 上实际运行过，并对 Windows 目标做了编译检查；透明窗口、鼠标穿透、托盘在真实 Windows 上的表现还需要验证。
