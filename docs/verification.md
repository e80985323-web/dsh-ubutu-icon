# 验证记录 / Verification record

本文件记录 **本机上真实跑出来的结果**，不是设计意图。每条都能照着复现。
日期：2026-09-13（Asia/Shanghai），机器：Ubuntu 26.04、Wayland、DSH Desktop AppImage。

被测对象：`@deepseek-ai/dsh-web-frontend@0.1.5-rc.1`
（`/home/eid/.npm/_npx/1e7f6d9597241db0/node_modules/@deepseek-ai/dsh-web-frontend/dist`）

## 1. 打补丁前后（文件层）

| 文件 | 打补丁前 sha256 | 打补丁后 sha256 |
| --- | --- | --- |
| `dist/favicon.svg` (3721B) | `c61a62a9d47d8660f9cfe08aac6775ff0476f7d6c5053f7659c1f8493fd6d814` | `8387d0b55d58d4fda32999a574c50759b2fb19cb8769a9c728a3b8edee06de38` (1556B，与 `assets/knot.svg` 逐字节相同) |
| `dist/assets/index-DuF6ti6g.js` (516708B) | `e8719e727fee91f681ee1d885c6d204f2309c8a3bee9742825ce526ebe06ef73` | `d737db352d700b699965728f4de1819f4c975fe0da10335b5e4e8df9528d37ba` (516098B) |

打补丁后 bundle 的实测特征（`grep` 计数）：

| 特征 | 补丁前 | 补丁后 |
| --- | --- | --- |
| 结形路径 `M22.2819 9.8211` | 0 | 1 |
| `1E6FEB` 出现次数 | 0 | 2（FishLogo 与 BrandWordmark 各一处） |
| 鲸鱼 clip 组 `clipPath:"url(#dsh-wordmark-whale-clip)",children` | 1 | 0 |
| `viewBox:"0 0 24 24"` | 0 | 1 |
| `node --check` | PASS | **PASS**（语法守卫生效） |

`node --check` 通过这一点是关键的：压缩过的 51 万字节 bundle 被改过之后仍然是合法 JS。

## 2. 浏览器真正收到的东西（HTTP 层）

用一个**自己起的实例**（`dsh web --no-open --port 3099`）带自己的 token 请求，避免影响用户正在用的 3080：

| 请求 | 补丁前 | 补丁后 |
| --- | --- | --- |
| `GET /`（带 token） | 200, 31499B, `<title>DeepSeek Harness` | 200, 31499B |
| `GET /favicon.svg` | 200, **3721B** = 原版 sha | 200, **1556B** = `assets/knot.svg` 的 sha |
| `GET /assets/index-DuF6ti6g.js` | 200, 516708B = 原版 sha | 200, 516098B = 磁盘上补丁版 sha |

服务端返回的字节和磁盘上被改的文件 **sha256 完全一致**，所以"改了文件但浏览器拿到旧内容"这种情况被排除。

## 3. 渲染层：是不是真的画出了那个结

### 3.1 同一渲染器下的形状比对（`docs/assets/logo-shape-board.png`）

一页四个 300×300 方块，全部由同一个浏览器渲染，逐块裁切后各自归一化到 220×220 再用 IoU 比较
（只看形状，不看缩放/留白）：

| 方块 | 内容 | 与左下角对照的 IoU |
| --- | --- | --- |
| box0 | `assets/knot.svg` 原样（viewBox `-1 -1 26 26`） | — |
| box1 | 同一段 path，viewBox `0 0 24 24` | 与 box0 **0.971** |
| box2 | **补丁后 bundle 里的 `FishLogo`** | 与 box0 **0.971**、与 box1 **1.000** |
| box3 | 原版鲸鱼 path（对照） | 与 box0 **0.340** |

box2 与 box1 的墨迹包围盒都是 `(2, 0, 298, 300)`、覆盖像素都是 33932 —— **逐像素相同**，
说明补丁后的 `FishLogo` 画出来的就是 `assets/knot.svg` 的那段 path。

> 踩过的坑：先用 ImageMagick 渲染 `knot.svg` 做参照，得到 IoU 0.54 的"形状不符"。
> 那是 ImageMagick 自己的 SVG 渲染器与浏览器不一致造成的假阳性。改成同渲染器比对后是 0.971。
> 另一坑：两个 bundle 的 `FishLogo` 都被压缩成同一个别名 `uC`，函数声明会提升，直接拼接会让后者静默覆盖前者。

### 3.2 真实 UI 的像素证据

从补丁后的 bundle 里**抽出** `FishLogo` / `BrandWordmark` 函数原文，用 jsx shim 执行并渲染成页面截图：

| 截图 | 精确 `#1E6FEB` 像素 |
| --- | --- |
| 原版 bundle 渲染 | **0** |
| 补丁后 bundle 渲染 | **3902**（容差 ±8/通道：4061），分布范围 x 190..707, y 98..286 |

真实 UI（把 `http://127.0.0.1:3099/?token=…` 放进 iframe，用一张延时图片把 `load` 事件拖住 14 秒，
等 SPA 水合完成后再截图）：

| 截图 | 精确 `#1E6FEB` 像素 | 位置 |
| --- | --- | --- |
| 原版 UI | **0** | — |
| 补丁后 UI | **23** | x 13..34, y 22..37（左上角徽标处，22×16 px，和字形大小吻合） |

同一个页面、同一台服务器、只换 bundle，蓝色像素从 0 变成 23 —— 这一点不受"截图太早/太晚"影响。

## 4. 更新之后会不会自己长回来（核心承诺）

模拟一次 npm/npx 更新，然后冷启动一个新的 `dsh web`，看插件是否自己把品牌打回来：

```
1) tools/restore.sh --yes        -> favicon c61a62a9…, bundle e8719e72…, 结形路径 0 处   （= 更新后被打回原样）
2) dsh web --no-open --port 3097 -> 冷启动，profile 里已注册 dsh-ubutu-icon
3) 等 25 秒
   favicon 8387d0b5…, bundle d737db35…, 结形路径 1 处, #1E6FEB 2 处, 鲸鱼组 0 处
   ~/.dsh/ubuntu-icon-data/ubuntu-icon.log 新增 4 行:
     OK … :: web favicon (blue hollow knot): replaced
     OK … :: FishLogo + BrandWordmark (web bundle): index-DuF6ti6g.js: patched FishLogo + wordmark whale
     OK … :: skill badge image: already applied
     OK … :: skill badge shields.io logo: already applied
4) 该实例 GET /favicon.svg -> 200 1556B（= knot sha）、GET /assets/index-*.js -> 与磁盘补丁版 sha 相同、node --check PASS
```

结论：**不需要重启桌面应用、不需要手动重打**，插件在启动后 3 秒内自己完成。

## 5. 测试与自检

```
node tests/plugin.test.mjs   ->  22 passed, 0 failed
tests/selfcheck.sh           ->  50 passed, 0 failed, 2 skipped
```

自检里的 2 个 skip 是"本机尚未打补丁"时才出现的状态检查（安装前跑的那次）；现在这两项都已是
PASS 状态。`selfcheck.sh` 会在一次性 `$HOME` 里真的装一遍启动器（菜单项、8 个尺寸图标、
`desktop-file-validate`、卸载清理），跑完即删；对真实 DSH 安装只读，唯一的例外是显式检查
favicon 是否已变成结形。

## 6. 桌面启动器（另一半）

| 检查 | 结果 |
| --- | --- |
| `~/.local/bin/dsh-ubuntu-icon` 与仓库内文件 | sha256 相同（`c33b9598…`） |
| `desktop-file-validate` | 无输出（通过） |
| 菜单项 | `Name=DSH (GPT knot icon)`、`Name[zh_CN]=DSH（GPT 蓝结图标）`、`Icon=dsh-ubuntu-icon` |
| 图标 | scalable SVG + hicolor 16/24/32/48/64/128/256/512 PNG |
| GTK `IconTheme.lookup_icon` | 16px/48px/256px 全部解析到刚装的 PNG |
| `dsh-ubuntu-icon check` | 认出 Ubuntu 26.04 / Wayland / 运行中的 GUI 在 3080 / 无 Chromium 系浏览器（仅 xdg-open） |
| `run`（`DSH_NO_START=1 DSH_BROWSER=/bin/echo` 冒烟） | 检测到已运行实例，构造出 `--app=http://127.0.0.1:3080/ --ozone-platform-hint=auto --user-data-dir=… --no-first-run --no-default-browser-check`，桩浏览器退出时如实报警而不是谎报"已打开" |
| 旧启动器 | `dsh-gpt.desktop` / `dsh-gpt-launcher` / `dsh-gpt.svg` 已移入 `~/.local/share/dsh-retired-gpt-launcher-<时间戳>/`，菜单里只剩一个新条目 |

## 7. 还原能力

`tools/restore.sh --yes` 在第 4 节里被真实用过：它按 `manifest.json` 里的原始路径与原始 sha256
把两个文件都还原成了原版，`already stock` 判定在第二次运行时正确识别"已经还原过"（幂等）。
备份目录 `~/.dsh/ubuntu-icon-data/backup/0.1.5-rc.1/` 不会被删除，所以还原本身也可逆。

> 踩过的坑：`restore.sh` 最初把 `--yes` 标志以字符串 `"0"` 传给 JS，而 JS 里非空字符串恒为真，
> 于是"干跑"实际上会真还原。被自检抓出来后改成传空串。

## 8. 复现方式

```bash
# 文件层
node tests/plugin.test.mjs && tests/selfcheck.sh

# 服务层：自己起一个实例，用日志里带 token 的地址请求 /favicon.svg 与 /assets/index-*.js
dsh web --no-open --port 3099 &
curl -L -c cj -b cj "http://127.0.0.1:3099/?token=$(...)"

# 更新生存：先还原再冷启动，然后对比 sha256
tools/restore.sh --yes && dsh web --no-open --port 3097 &
```

注意：DSH 的 Web 服务与 harness 同进程，而工具调用会阻塞该进程的事件循环，
所以对 **3080（正在用的那个实例）** 的 HTTP 请求要在工具调用之外（后台任务）发，
否则会看到"连接建立但永不响应"。这一点也解释了为什么第 2 节用的是独立实例。
