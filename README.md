# 喜马抢兑 · iOS（TrollStore）

## 为什么是"点按钮"而不是"发请求"

实测结论（2026-11-15，真机 HAR 重放）：

| 实验 | 结果 |
|---|---|
| HAR 原件原样重放 `reserveQuota` | `ret=0` ✅ 锁额成功 |
| 只换 Cookie（安卓登录态） | `ret=-1 系统错误` ❌ |
| 只换 x-timestamp / x-nonce（新值） | `ret=-1 系统错误` ❌ |
| 只换 body（自己加密）+ 原盾 | `ret=-1 系统错误` ❌ |
| 换 iOS UA 但不带盾 | `ret=-1 系统错误` ❌ |

结论：`x-shield-token` 的算法签名是

```
getShield:timeStamp:nonce:qimei36:model:appVersion:params:
```

它把 **时间戳 + nonce + 设备指纹 + 机型 + 版本 + 请求参数** 全绑在一起，每个请求都必须重算。
20 小时前抓的 token 能重放成功，只是因为 ts/nonce/params 完全没变 —— 一旦改任何一个就失效。

所以"独立 App 直接发 HTTP"这条路是死的：纯 HTTP 复现不出 `qimei36` 和盾算法。
唯一干净的做法是**让官方 App 自己发请求**，本 App 只负责在准确时刻把按钮点下去。

## 它怎么绕过检测

- 不用无障碍（Auto.js 那套会被 `rewardShieldAccessibilityClick` 识别）
- 不 hook 进程（`tme::detect::Frida` / `Xposed` 会抓到）
- 走 `IOHIDEventSystemClientDispatchEvent`，在 HID 层合成触摸，App 侧和真人点击无差别

需要 entitlement `com.apple.private.hid.client.event-dispatch`，TrollStore 签名时保留。

## 编译

```
git init && git add . && git commit -m init
gh repo create xmlygrab --private --source=. --push
```

Actions 自动出 `XmlyGrab.ipa`，iPhone 上用 TrollStore 打开安装。

## 首次使用

1. 打开 App，**先点「录制全部」**，按提示依次点：我的 → 金币 → 提现 → 档位 → 普通到账 → 关广告 → 确认提现
   （坐标必须自己录，机型不同布局不同，硬编码一定点歪）
2. 点第二段「定时点」可改刷新时刻，默认 `00:00,08:00,12:00,16:00,20:00`
3. 点「开始定时」，把 App 留在后台别杀
4. 到点它会自动拉起喜马、按顺序点

## 注意

- 手机要一直亮屏充电，App 不能被杀
- 广告那一步是**真等 35 秒**，服务端按播放时长判定，跳了会记 `10003 广告未计入`
- 档位选 1 元最稳；10 元要连签 7 天，30 元要 14 天
- 每天只能提 1 次（`max_apply_count=1`）
