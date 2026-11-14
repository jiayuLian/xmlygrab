# 喜马抢兑 · iOS（TrollStore）

**下载**：https://github.com/jiayuLian/xmlygrab/releases/download/v1.0.0/XmlyGrab.ipa

## 为什么不直接发 HTTP

用你 11-14 的真机 HAR 逐项重放，结论很硬：

| 实验 | 结果 |
|---|---|
| HAR 原件原样重放 `reserveQuota` | `ret=0`，锁额成功 |
| 只换 Cookie | `ret=-1 系统错误` |
| 只换 timestamp / nonce | `ret=-1 系统错误` |
| 只换 body（自己加密） | `ret=-1 系统错误` |
| 换 iOS UA 但不带盾 | `ret=-1 系统错误` |

iOS 二进制里盾的函数名是明文导出的：

```
getShield:timeStamp:nonce:qimei36:model:appVersion:params:
```

`params` 是入参 —— **时间戳、nonce、设备指纹、机型、版本、请求参数全部参与签名，每个请求必须重算**。
20 小时前那个 token 能重放成功，只是因为这六项一个没变。

独立 App 拿不到 `qimei36`，也调不到 native 层的盾算法，所以「自己发请求」这条路是死的。

## 它怎么干

不去伪造请求，改为**在准确时刻替你把官方 App 的按钮点下去**。所有网络动作由官方 App 自己完成，
盾、票、设备指纹全部原生，服务端看不到任何差异。

- 不用无障碍 —— 喜马带 `rewardShieldAccessibilityClick` 专门识别 Auto.js
- 不 hook 进程 —— 喜马带 `tme::detect::Frida / Xposed / Magisk` 检测
- 走 `IOHIDEventSystemClientDispatchEvent`，在 HID 层合成触摸，和真人手指完全一样

## 安装（TrollStore）

1. iPhone 用 **Safari** 打开上面的下载链接
2. 下载完点开 → 分享 → **用 TrollStore 打开**
3. TrollStore 里点 Install

装完先别急着开，确认这一条：App 里第一行日志应该是

```
HID 注入 就绪
```

显示「不可用」说明 entitlements 没保留（TrollStore 签名时丢了），重装一次。

## 首次使用：录坐标

**坐标必须自己录。** 不同机型布局不同，硬编码一定点歪。

1. 先打开喜马 App，把要经过的页面各截一张图存相册
   （我的页、金币页、提现页、档位弹窗、到账方式弹窗）
2. 打开喜马抢兑 → 点「全录坐标」
3. 每一步会弹出「看截图点」→ 选对应那张截图 → 在图上点按钮的真实位置
4. 坐标会按比例换算，跨机型也准（录一次就行，以后不用再录）

默认流程 10 步：

```
1. 拉起喜马                 等 6s
2. 我的                     等 2.5s
3. 金币                     等 3s
4. 提现                     等 3.5s
5. 选档位（3/5/10 元）      等 1.8s
6. 等到「触发时刻 +1 秒」   ← 卡在整点
7. 普通到账（看 1 个广告）  ← 这一步服务端才会 reserveQuota 锁额
8. 等广告播完               35s
9. 关广告                   等 2.5s
10. 确认提现                等 2s
```

**第 6 步是整个设计的核心。** 前 5 步在整点前 20 秒就走完（App 会自动提前 20 秒启动），
停在「选到账方式」的弹窗前；整点一到第 7 步立刻按下，那一枪才是真正去抢名额的。

## 定时

- 点第二段「刷新时刻」那行可以改，默认 `00:00,08:00,12:00,16:00,20:00`
- 点「定时开关」打开
- App 要留在后台别杀，屏幕保持亮着、插电

脚本内置静音音频保活，切到后台也能继续走流程。

## 注意

- 1 元档随时能提，不用抢；真要抢的是 3 / 5 / 10 元档
- 10 元要连签 7 天、30 元要 14 天，没到门槛会被服务端挡
- 广告那 35 秒是**真等**，服务端按播放时长判定，跳了会记 `10003 广告未计入`
- 每天只能提 1 次（`max_apply_count=1`）
- 第一次跑建议先点「执行一次」手动走一遍，看日志每一步的坐标对不对

## 自己编译

推送到 `main` 会自动构建：

```
gh repo clone jiayuLian/xmlygrab
cd xmlygrab
git commit --allow-empty -m "rebuild" && git push
```

Actions 跑完在 Releases 里出新的 IPA。
