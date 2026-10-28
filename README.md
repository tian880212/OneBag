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

- **登录后后台「预热真画」**：6.5 秒后把整个背包框 `Show()` 真实绘制一次，立刻 `SetAlpha(0.02)`，
  0.35 秒后 `Hide()` 并恢复 alpha 与鼠标响应
  - 只在物品数据都解析完成后才画（否则画的是空图标，白跑），失败最多重试 6 次
  - 预热期间抑制开关背包音效与分类页刷新（`_warming` 守卫）
  - 预热窗口内玩家自己按开背包时只恢复外观、不隐藏（`_warmupAborted`）
  - 玩家手动开过一次就不再预热（`_warmupDrawn`）
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
