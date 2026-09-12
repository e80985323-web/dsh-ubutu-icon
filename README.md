# dsh-ubutu-icon

把 DSH 的界面徽标换成**蓝色空心 ChatGPT 结**（`#1E6FEB`），并且在 **DSH 更新 / npm 重装之后自动重新打上**。
这是 [`dsh-gpt-icon`](https://github.com/e80985323-web/dsh-gpt-icon)（Windows 版）的 **Ubuntu / Linux 移植版**。

一套东西，两半：

| 半边 | 作用 | 载体 |
| --- | --- | --- |
| **徽标插件** | 网页 UI 的 favicon、应用内 `FishLogo`、`BrandWordmark`、技能徽章 → 蓝结 | DSH 插件（`lib/index.js`），每次启动自动修复 |
| **桌面启动器** | 菜单/程序坞里一个蓝结图标，点一下打开 DSH Web GUI | `.desktop` + hicolor 图标 + 纯 bash 启动器 |

![icon](assets/icon.png)

## 为什么需要它

DSH 自己没有换徽标的入口，所以只能改文件；而 DSH 一更新，这些文件就被覆盖回鲸鱼。
这个插件解决的就是"改完又被打回去"这件事：**每次启动后 3 秒自动重新打一遍**，幂等、带备份、可一键还原。

## 和 Windows 版的区别（重要，先看这段）

Windows 版改的是 `D:\dsh desktop\resources\...` 里的 exe 图标、启动闪屏 GIF、托盘图标。
**Ubuntu 上没有这些东西**，硬套会全是"文件不存在"。Linux 这边真实情况是：

- **DSH Desktop 是 AppImage，而且它不打包网页 UI。**
  实测进程树：AppImage（Electron）→ `npm exec @deepseek-ai/dsh web --port 3080` → 浏览器看到的页面由
  `node_modules/@deepseek-ai/dsh-web-frontend/dist` 提供。这个目录**可写**，所以徽标就住在这里。
  npm/npx 重装会整个替换它 —— 这正是"更新后要重新打"的根源，和 Windows 版一模一样。
- **exe 嵌入图标没有对应物。** AppImage 是只读 squashfs，除非重新打包（本项目不做）。
  Linux 的等效做法是**桌面图标**：用户级 `.desktop` + hicolor 图标，它不会被应用更新覆盖。
- **闪屏 GIF / `dsh-desktop-logo*.png` / `dsh-client-ui-primitives`** 在 Linux 发行包里不存在，
  插件遇到不存在的目标会报 `skipped` 而不是失败 —— 上游换了打包结构也不会把插件搞崩。

插件改的是**它真正在服务的那个前端**（优先从运行中的进程路径反查），而不是猜一个路径。

## 安装

两半都可以单独装，建议都装。

### 1. 徽标插件（网页 UI）

```bash
git clone https://github.com/e80985323-web/dsh-ubutu-icon.git
cd dsh-ubutu-icon
tools/install.sh              # 复制到 <DSH_HOME>/local-plugins 并注册进 profile
```

重启 DSH（或 DSH Desktop），3 秒后徽标就位。不想重启的话也可以让插件自己修一次：

```bash
# 重启后确认
tools/install.sh status
tail -n 20 ~/.dsh/ubuntu-icon-data/ubuntu-icon.log
```

`tools/install.sh` 做三件事：把包复制到 `<DSH_HOME>/local-plugins/dsh-ubutu-icon`、
在 `<DSH_HOME>/profiles/<profile>/package.json` 里登记 `dependencies` + `dsh.profile.bundles`、
再把包链到该 profile 的 `node_modules/` 下（`--copy` 可改为复制）。改 `package.json` 前会自动备份。

常用参数：`--profile <名字>`（默认 `web` 或 `$DSH_PROFILE`）、`--copy`、`--dry-run`。

### 2. 桌面启动器（菜单 / 程序坞图标）

```bash
desktop/dsh-ubuntu-icon.sh install            # 装到 ~/.local，普通用户即可
desktop/dsh-ubuntu-icon.sh install --system   # 装到 /usr/local，需要 sudo
desktop/dsh-ubuntu-icon.sh check              # 环境自检（浏览器、端口、dsh 路径……）
```

装完菜单里会出现 **DSH (GPT knot icon)**，图标就是蓝结。点它会：已经在跑就直接开窗口 →
没跑就 `dsh web` 起来再开 → 失败弹窗告诉你日志在哪。

它自己带的图标：`icons/hicolor/{16,24,32,48,64,128,256,512}` PNG + `scalable` SVG，
需要重建时 `tools/build-icons.sh`（要 ImageMagick）。

## 更新后的时间线

```
npm/npx 重装前端   →  favicon / bundle 被换回鲸鱼
DSH 启动           →  插件 apply() 注册路由，3 秒后 repairNow()
repairNow()        →  发现目标已变 → 备份一次 → 重新打上蓝结
下次刷新页面       →  蓝结
```

每次修复都写日志：`~/.dsh/ubuntu-icon-data/ubuntu-icon.log`。

## 手动控制

| 入口 | 说明 |
| --- | --- |
| `GET /ubuntu-icon/status` | 上一次修复的完整 JSON 结果（每个目标的 `ok` / `skipped` / `error`） |
| `GET /ubuntu-icon/repair` | 立刻重打一遍，返回同样的 JSON |
| `DSH_UBUNTU_ICON_ROOT=/path/to/@deepseek-ai/dsh-web-frontend` | **钉住**目标：只改这一个，关闭自动发现（测试/多 profile 用） |
| `DSH_HOME` | 数据目录位置，默认 `~/.dsh` |

自动发现顺序：`DSH_UBUNTU_ICON_ROOT` → 从运行进程的入口与 node 路径逐级向上找 →
npm/npx 缓存与全局 npm 前缀。**一旦设了 `DSH_UBUNTU_ICON_ROOT` 就只改它**，不会碰到别的安装。

## 自定义

换掉 `assets/knot.svg` 即可（`<path d="...">` 和 `fill` 会被自动读取），
然后 `tools/install.sh` 重装 + 重启。想换成别的颜色就改 `fill`。

## 卸载与还原

```bash
tools/restore.sh          # 干跑：列出会还原哪些文件
tools/restore.sh --yes    # 真还原：把原始文件按 manifest 放回去
tools/install.sh uninstall            # 注销插件（保留副本）
tools/install.sh uninstall --purge    # 连副本一起删
desktop/dsh-ubuntu-icon.sh uninstall  # 移除菜单项与图标
```

备份在 `~/.dsh/ubuntu-icon-data/backup/<前端版本>/`，附 `manifest.json`（原始路径 + 原始 sha256），
`restore.sh` 就是照它还原的；备份不会被删，所以还原本身也可逆。

## 它是怎么打补丁的

- **文件类**（favicon、徽章 PNG）：比 sha256，不同才写；写前备份一次。
- **文本类**（徽章 shields.io 链接）：按 marker 判断是否已打，`logo=deepseek` → `logo=openai&logoColor=1E6FEB`。
- **压缩过的前端 bundle**：**不硬编码压缩后的函数名**（Windows 版写死了 `function md(`）。
  这里先从导出表 `FishLogo:<别名>` 拿到别名，再用括号配对切出函数体，然后：
  1. 把 `viewBox` 归一成 `"0 0 24 24"`，并去掉原来 23.16×17.04 的宽高比修正；
  2. 把 `{d:<常量>,fill:"currentColor"}` 换成蓝结路径；
  3. 把 wordmark 里那个被 clip 的鲸鱼 `<g>` 换成蓝结，并缩放到鲸鱼原来的方框（23.16×17.04）。
  写完立刻 `node --check`，语法不过就自动回滚备份。上游重新构建、压缩名变了也照样能打。

## 测试

```bash
node tests/plugin.test.mjs    # 22 项：路由、打补丁、幂等、备份、还原、日志
tests/selfcheck.sh            # 环境与产物自检
```

`plugin.test.mjs` 用真实前端做夹具（找不到就用等价的最小 bundle），全程在临时目录里跑，
**不会碰你机器上正在跑的安装**（靠 `DSH_UBUNTU_ICON_ROOT` 钉住目标来保证）。这一点是被测过的：
测试跑完后线上 favicon 与 bundle 的 sha256 不变。

本机实测结果（打补丁前后的 sha256、浏览器实际收到的字节、真实 UI 里 `#1E6FEB` 像素数、
"还原成原版再冷启动看它自己长回来"的全过程）记在 [`docs/verification.md`](docs/verification.md)。

## 它画出来的是什么形状

同一个浏览器渲染、逐块归一化后用 IoU 比较（只看形状，不看缩放与留白）：

![形状比对](docs/assets/logo-shape-board.png)

| 方块 | 内容 | 与左下角对照的 IoU |
| --- | --- | --- |
| 左一 | `assets/knot.svg` 原样 | — |
| 左二 | 同一段 path，viewBox `0 0 24 24` | 0.971 |
| 左三 | **补丁后 bundle 里的 `FishLogo`** | **0.971**（与左二逐像素相同） |
| 左四 | 原版鲸鱼 path（对照） | 0.340 |

## 免责声明

非官方项目，与 DeepSeek 无关。会修改你 npm 缓存里 `@deepseek-ai/dsh-web-frontend` 的本地文件；
所有改动都有备份、可一键还原，但请自行评估风险。

## License

MIT，见 [LICENSE](LICENSE)。上游 Windows 版：<https://github.com/e80985323-web/dsh-gpt-icon>
