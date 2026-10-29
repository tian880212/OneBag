# OneBag — 个人修改版（Turtle WoW 1.12）

> **非官方修改版。** OneBag 原作 **Kaelten**，1.12 移植由 **凡人** 完成，中文界面 **阿拉正经人**，
> 整理逻辑（SortBags）来自 **shirsig**。
> 本仓库在其基础上继续修改，面向 **Turtle WoW / WoW 1.12（Interface 11200）**。
> 版权归原作者与全部贡献者所有；本仓库只做修改与分发，不主张任何新版权。

本仓库地址：<https://github.com/tian880212/OneBag>

单窗口整合全部背包 + 银行 / 小号银行视图，带回分类标签、筛选搜索、一键整理、物品锁定。

---

## 安装

1. 解压后目录名必须是 **`OneBag`**（与 `OneBag.toc` 同级）
2. 整个目录放进 `Interface\AddOns\`
3. **需要公共库 `!Libs`**（`OneBag.toc` 里 `Dependencies: !Libs`）。本仓库**不含**该库。
   配套打包好的版本：[tian880212/Libs](https://github.com/tian880212/Libs)
   （解压后目录名必须带感叹号：`!Libs`）
4. 进游戏按背包键（`B`）或点击小地图按钮打开

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `/obhelp`、`/onebaghelp` | 打印全部命令与用法 |
| `/obitem <物品>`、`/onebagitem <物品>` | 按名字查找背包里的物品 |
| `/obitemdel <物品>` | 查找并删除（会先确认） |
| `/obtf`、`/obtogglefilters` | 显示 / 隐藏筛选模块栏 |
| `/itemlock` | 物品锁定（防止误卖 / 误分解），子命令 `add`、`remove`、`list`、`unlockall` |

存档：`OneBagDB`、`OneBankDB`、`OneRingDB`、`OneViewDB`、`ItemLockDB`、`OneBagSortLockDB`。
其中 `OneBankDB` / `OneViewDB` / `OneRingDB` 与 **OneBank / OneView / OneRing** 系列插件共用，
配合使用即可在同一窗口里看银行、看小号仓库。

---

## 与原版的主要差异

### 打开背包的卡顿（重点）

实测结论：Lua 侧已经榨干——`OnShow` 打开面板平均只有 **2.5ms**，`UpdateBag` 0.2~0.3ms；
真正的 40~80ms 尖峰全在**引擎侧**（80+ 按钮首次绘制、图标贴图首次上传、边框背景首次构建）。
这类开销无法用 Lua 优化掉，只能**挪到玩家按背包键之前**。

- **登录后后台「预热真画」**：6.5 秒后把整个背包框 **挪到屏幕外**（临时关掉 `SetClampedToScreen`，
  斜向 `-4000, -4000`）、`SetAlpha(0)` 真实绘制 **1 帧**，下一帧立刻 `Hide()` 并还原锚点、alpha、鼠标响应
  - 光调 `SetClampedToScreen(false)` 不够：`OnBaseShow` 里有 `_baseClamped` 缓存判断，
    不同步缓存会被它按 `profile.clamped` 改回去，框被钳回屏幕内 → 表现就是
    「明明挪到屏外，却闪在屏幕左下角」
  - 窗口内把 `OBBagFram` / `OneBankFrame` / `OneRingFrame` / `OneViewFrame` / `OBBBagFra`
    的 alpha 也临时压 0 并记录还原值：这些是 `parent=UIParent` 的独立顶层框，
    其中银行/戒指框在 XML 里**没有锚点**，默认就停在左下角，任何一次误 Show 都会露馅
  - 为什么必须挪到屏外：只压 alpha 压不住，0.02 在 1.12 上肉眼仍能看见，会表现为
    「进游戏几秒后背包自己弹出来又消失」的鬼影（`S_ItemTip` 装等面板的预热就是这么做的）
  - 为什么必须只画 1 帧：预热真正需要的只是「第一次被绘制的那一帧」，可见窗口一旦拉长到
    0.35 秒（约 21 帧），窗口内的异步 `BAG_UPDATE → Refresh` 就能把标签条、侧边栏这些
    **独立顶层框**（`parent=UIParent`，不吃主框 alpha）整块点亮，表现为「/reload 不闪、
    小退进游戏却闪」。帧数制比固定秒数可靠，不要再改回 `elapsed < 0.35`
  - `_warming` 守卫覆盖整个可见窗口：同步路径（`OnShow → Refresh → UpdateButtons`）靠它拦住
  - 只在物品数据都解析完成后才画（否则画的是空图标，白跑），失败最多重试 6 次
  - 可见窗口内玩家自己按开背包时只恢复外观、不隐藏（`_warmupAborted`）
  - 玩家手动开过一次就不再预热（`_warmupDrawn`）
  - 开关：`/obwarmup` 切换（存 `profile.warmupDraw`，下次进入游戏生效）；
    `/obwarm` 立即手动跑一次（不用反复小退，便于验证）
- 后台 `GetItemInfo` 缓存预热（参考 Guda 的 `CacheWarmer`），与工作队列共享每帧预算，
  拖拽时暂停队列以保住帧率

### 整理逻辑（SortBags / Clean_Up）

- 与 SUCC-bag 同源的整理代码做了同一批修复：整理后**格子变灰**、**图标丢失**、
  分类标签与整理结果不同步
- 保留排序锁（`OneBagSortLockDB`），整理时不会移动被锁定的物品

### 其它

- 中文界面与提示
- 分类标签页、筛选与搜索框的一批边界修正

---

## 说明

- 个人维护版本，不保证与上游同步
- 报错请带 `Interface\AddOns\OneBag` 下的完整路径与行号
- 单文件较大（`OneBag.lua` 约 6800 行），改动前建议先备份
