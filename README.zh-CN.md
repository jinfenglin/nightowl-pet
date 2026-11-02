# DeskPet 🐣

**监督你自律的桌面宠物。** 用一张照片做出卡通形象，住在你的桌面上，头顶带着血条。你的坏习惯会变成对它的攻击：过了宵禁还在用电脑、连续久坐，它就会被雷劈、被扇耳光、被易拉罐砸头；好好睡一觉，它才能回血。

[English](README.md)

| 平台 | 状态 | 技术 |
|---|---|---|
| **macOS** 14+ | ✅ 功能完整 | Swift · SwiftUI · AppKit（[详细说明](mac/README.md)） |
| **Windows** 10/11 | 🚧 除攻击后的持续威胁效果外都已完成 | Tauri 2 · Rust · HTML/JS（[详细说明](windows/README.md)） |

## 功能

- **桌面宠物**：透明、置顶的角色，头顶漫画风血条。随意拖动，双击戳它，右键打开常用操作；菜单栏 / 系统托盘显示 HP。
- **习惯规则**（都可以调）：
  | 规则 | 默认 |
  |---|---|
  | 宵禁期间使用电脑 | 00:00–06:00，每活跃 1 分钟 −2 HP |
  | 久坐 | 连续使用 90 分钟后每分钟 −1 HP，离开 5 分钟才算休息 |
  | 整晚没违规 | 第二天早上 +30 HP |
- **攻击连击**，特效可选：⚡️ 乌云雷击、🖐️ 连环耳光、🥫 远处小人一边抛罐一边扔过来、🎲 随机。HP 随每一下命中逐段下降，带白闪、震动、伤害数字和漫画爆炸框。
- **状态图**：满血、残血、受击、阵亡；缺少的状态用滤镜代替（变灰、倒下、染红）。
- **素材库**：每种素材按类型放在固定文件夹里，随时切换版本，也可以直接把图片拖进文件夹。
- **血量看板**：最近 30 天每天的最低血量。
- **AI 生成**：从照片生成形象，再生成其他状态图和特效插画；支持 OpenAI 兼容接口和 Google Gemini，提示词可编辑，也能「复制提示词」去网页版生成。
- **配置导入导出**、**开机启动**、**中文 / English** 界面。

## 下载

**Windows**：每次推送 `windows/` 或 `assets/` 都会运行 [Windows 构建流程](.github/workflows/windows.yml)。在 **Actions** 里打开最近一次运行，下载 `DeskPet-windows`，里面是 `DeskPet_x.y.z_x64-setup.exe`。按当前用户安装，不需要管理员权限。

**macOS**：从源码构建（见下），暂时没有签名的发布版。

## 从源码构建

### macOS
需要 Xcode Command Line Tools（不需要完整 Xcode）。
```bash
cd mac
./build_app.sh                          # 生成 DeskPet.app
./DeskPet.app/Contents/MacOS/DeskPet    # 或把 DeskPet.app 移到「应用程序」
```

### Windows
需要 [Rust](https://rustup.rs)（安装时按提示装 Visual Studio C++ 生成工具）；Windows 10/11 自带 WebView2。
```powershell
cargo install tauri-cli --version "^2" --locked
cd windows\src-tauri
cargo tauri dev      # 开发运行
cargo tauri build    # 安装包在 target\release\bundle\nsis\
```
Windows 版也能在 macOS 上运行调试：`cd windows/src-tauri && cargo build && ./target/debug/deskpet`。

## 仓库结构

```
assets/defaults/   两个版本共用的内置素材：pet/<状态>.png、fx/<特效>.png
mac/               macOS 原生版（Swift Package + build_app.sh）
windows/           Windows 版（Tauri：src-tauri/ 是 Rust，ui/ 是 HTML/CSS/JS）
.github/workflows/ Windows 安装包构建
```

两个版本使用相同的数据格式：素材库结构（`Library/pet/<状态>/`、`Library/fx/<特效>/`）、每日血量文件 `hp_history.json`，设置项名称也相同。

## 数据位置

| | macOS | Windows |
|---|---|---|
| 素材、血量记录 | `~/Library/Application Support/DeskPet/` | `%APPDATA%\DeskPet\` |
| 设置 | `defaults read com.deskpet.app` | `%APPDATA%\DeskPet\settings.json` |

## 隐私

一切都在本地运行。DeskPet 只读取「距离上次键盘 / 鼠标输入过了多久」（不记录按键，也不看屏幕内容），不需要任何特殊权限。只有在使用 AI 生成时，图片和提示词才会发送给你配置的服务商。API Key 保存在上面的本地设置里。

## 路线图（Windows）

- [x] 第 1 阶段：宠物窗口、HP、规则、托盘、设置、默认素材、开机启动、中英文
- [ ] 第 2 阶段：攻击后的持续威胁（乌云停留闪烁、小人抛罐）、更丰富的粒子特效
- [x] 第 3 阶段：素材生成页（OpenAI / Gemini）
- [x] 第 4 阶段：配置导入导出（与 macOS 版文件格式相同）

## 致谢

`assets/defaults/` 里的内置素材由项目作者提供：猫猫状态图是抠图后的照片，特效插画（乌云、易拉罐、扔罐小人）由 Google Gemini 生成。

## 许可证

还没有选择许可证。在添加之前，保留所有权利。
