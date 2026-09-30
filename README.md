# 流量计抄表 · iOS 版（VM6 蓝牙抄表）

从 `流量计抄表-1.0.1.apk` 反编译还原、用 **原生 Swift + SwiftUI** 重写的 iOS 应用。
零第三方依赖（只用系统框架），可在越狱 iPhone 上安装。

---

## 一、先说清楚：这不是"格式转换"

APK 与 IPA 是两套完全不同的运行时，**不存在把 APK 直接转成 IPA 的工具**：

| | Android APK | iOS IPA |
|---|---|---|
| 代码 | Dalvik bytecode（Java/Kotlin） | Mach-O ARM64（Swift/ObjC） |
| 蓝牙 | `android.bluetooth.*` | CoreBluetooth |
| 界面 | Android View / Flutter | SwiftUI |

`流量计抄表-1.0.1.apk` 是一个 **Flutter release 构建**（`lib/*/libapp.so` + `libflutter.so`），
Dart 代码已被 AOT 编译成 Android ARM 机器码，**无法移植到 iOS**，也取不回 Dart 源码。

所以做法是：**把这个 App 的逻辑完整逆向出来，再用 iOS 原生技术重写一遍**，
功能、界面、协议、数据完全一致。

## 二、逆向依据（都是实打实拿到的）

| 来源 | 拿到了什么 |
|---|---|
| `流量计抄表-1.0.1.apk` | 完整 Dart 源码文件树与类名（`package:meter_reader_app/...`）、全部依赖插件清单、`bledata.proto` |
| `MeterReaderOffline-v1.3.0.apk` | **完整 Java 源码**（jadx 反编译）：`A5Protocol`、`BleService`、`AppDb`、`MainActivity`、全部布局 XML 与配色 |
| `BLE调试宝_realtime_log_*.txt` | **真实蓝牙报文**，用于验证协议实现 |
| `assets/*.json` | 你原有的 4 个表具、11 条读数、121 条指标快照 |

### 协议已被真实抓包验证

重写的 `A5Protocol` 生成的报文与抓包日志**逐字节一致**：

```
readRealtime()    -> A5 47 3A D2     ← 日志 "A5 47 3A D2"  ✓
readParamTable()  -> A5 4D BA D5     ← 日志 "A5 4D BA D5"  ✓
```

详见 [`PROTOCOL.md`](PROTOCOL.md)。

## 三、已还原的功能

- **扫描 / 连接**：BLE 扫描、按 RSSI 排序、⭐目标设备标记、点击连接
- **实时抄表**：每 3 秒轮询 —— `0x47` 实时值 + `0x03` 读寄存器 16（流量系数）
- **五项实时数据**：瞬时流量 m³/h、压力 kPa、温度 ℃、累计流量 m³、流量系数
- **流量系数写入 + 回读校验**：写寄存器 16，再回读比对，容差 `max(1e-4, |值|×0.001)`
- **抄表存档**：记录时间、GPS 坐标、备注，写入 SQLite 并进入同步队列
- **指标快照**：每条读数自动生成 5 条 metric_snapshot
- **历史**：表具列表（在线状态点 / 型号 / MAC / 连接状态 / RSSI / 读数条数）、全部抄表记录、读数明细、快照明细
- **离线手工抄表**：无设备时手工录入读数
- **设置**：目标设备名与标识、权限状态、数据导出、BLE 通讯日志
- **数据导出**：导出 JSON 到「文件」App，可与安卓版数据互通

## 四、目录结构

```
MeterReader-iOS/
├── project.yml                     # XcodeGen 工程定义
├── build-ipa.sh                    # macOS 本地一键打包
├── .github/workflows/build-ipa.yml # 云端自动构建（推荐）
└── MeterReader/
    ├── Info.plist                  # 显示名「流量计抄表」+ 蓝牙/定位权限说明
    ├── Assets.xcassets/            # App 图标（按安卓 ic_launcher 重绘）
    ├── Protocol/A5Protocol.swift   # A5/Modbus 协议（CRC16、封包、解包）
    ├── Models/Models.swift         # 数据模型 + 时间戳处理
    ├── Services/
    │   ├── BleService.swift        # CoreBluetooth 状态机
    │   ├── AppDatabase.swift       # SQLite（与安卓表结构完全兼容）
    │   ├── LocationService.swift   # 定位打点
    │   └── AppSettings.swift       # 偏好设置
    ├── App/                        # 入口、主题配色、全局状态
    ├── Views/                      # 5 个页面 + 3 个详情页
    └── Resources/                  # 首启种子数据（你原有的历史记录）
```

## 五、怎么拿到 IPA（不需要 Mac）

1. 在 GitHub 上新建一个仓库（可以是 **Private**，免费账号也够用）。
2. 把 `MeterReader-iOS` 里的**全部内容**上传到仓库根目录。
   - 网页端：仓库页 → `Add file` → `Upload files` → 把 `MeterReader-iOS` 里的所有文件和文件夹拖进去 → Commit。
   - 注意 `.github` 目录要一起传（它决定自动构建）。
3. 上传后 **Actions** 标签页会自动开始 `Build unsigned IPA`。
   若没自动跑：Actions → 左侧 `Build unsigned IPA` → 右侧 `Run workflow`。
4. 等约 3–6 分钟，构建成功后在这次运行页面底部 **Artifacts** 下载：
   - `MeterReader-adhoc.ipa` —— 给 **TrollStore**
   - `MeterReader-unsigned.ipa` —— 给 **AppSync Unified** / AltStore / Sideloadly

> Actions 对私有仓库有免费分钟数（每月 2000 分钟），一次构建约 5 分钟，足够用。

## 六、装到越狱 iPhone

| 你的环境 | 用哪个包 | 怎么装 |
|---|---|---|
| 有 **TrollStore**（iOS 14–17，支持 CoreTrust 漏洞） | `MeterReader-adhoc.ipa` | 直接分享/打开该 IPA → TrollStore 自动接管安装 |
| 装了 **AppSync Unified** | `MeterReader-unsigned.ipa` | 用 Filza 复制到设备 → 用 `ipainstaller` 或 Sileo 的"本地安装" |
| 都没装 | `MeterReader-unsigned.ipa` | 用 AltStore / Sideloadly 用自己的 Apple ID 重签（免费账号 7 天有效期） |

安装后首次打开会申请**蓝牙**和**定位**权限，都要允许，否则无法扫描表具。

## 七、在 Mac 上本地构建

```bash
brew install xcodegen
cd MeterReader-iOS
chmod +x build-ipa.sh
./build-ipa.sh
```

或者直接用 Xcode：`xcodegen generate` 后打开 `MeterReader.xcodeproj`，
选真机 → Run。已预置 `CODE_SIGNING_ALLOWED=NO`，越狱机可直接跑。

## 八、关于你的历史数据

App 首次启动会把 `MeterReader/Resources/` 里的
`meters.json` / `readings.json` / `metric_snapshots.json`
导入 SQLite —— 也就是你原有的 **4 个表具（含 `VM6-2120147-KMJ` 等）、11 条读数、121 条快照**，
打开就能看到，不用重新录。

数据库表结构与安卓版**完全一致**，两边的导出 JSON 可以互相导入。

## 九、常见问题

**Q: 为什么设置里是"标识"不是 "MAC"？**
iOS 出于隐私**不允许** App 读取蓝牙 MAC 地址，只能拿到系统分配的 CoreBluetooth 标识（每台手机不同）。
若要新抄的表继续落进原来那条表具记录，把原 MAC（如 `B4:52:A9:D0:10:FB`）填进「目标表具标识」即可。

**Q: 扫描不到设备？**
1. 确认系统 设置 → 隐私与安全性 → 蓝牙 里本 App 已允许；
2. 表具要在附近且已上电；
3. 设置页 →「查看 BLE 通讯日志」能看到扫描与收发报文的详细记录，便于排查。

**Q: 收不到实时值？**
抄表页会显示 `TX A5 47 3A D2` 和 `RX ...`。若只 TX 不 RX，说明设备没响应或写特征不对，
把日志发我即可定位。

**Q: 能改 Bundle ID / 显示名吗？**
改 `project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER`，以及 `Info.plist` 的 `CFBundleDisplayName`。

---

最低支持 **iOS 15.0**，已构建为 `arm64`。
