# flutter_keyboard_controller15

公司统一键盘插件：**一个依赖覆盖 Android / iOS / 鸿蒙**。

| 平台 | 原生实现 | 说明 |
|---|---|---|
| **Android** | `android/` 完整 FKC（WindowInsetsAnimation 逐帧） | 与上游一致 |
| **iOS** | `ios/` 完整 FKC | 与上游一致 |
| **鸿蒙** | `ohos/` API 15 专用 | 仅 `keyboardHeightChange` + 本地合成帧，适配 `compatibleSdkVersion: 5.0.3(15)` |

Dart API、MethodChannel 名与上游 `flutter_keyboard_controller` **完全一致**，业务代码无感切换。

## 接入

1. 拷贝整个 `flutter_keyboard_controller15/` 到工程 `third_party/`

2. `pubspec.yaml`：

```yaml
dependencies:
  flutter_keyboard_controller15:
    path: third_party/flutter_keyboard_controller15
```

3. Dart（全平台统一 import）：

```dart
import 'package:flutter_keyboard_controller15/flutter_keyboard_controller.dart';
```

4. App 根节点挂 `KeyboardProvider`，详情页按落地 MD 接 `SoftKeyboardLift` + FKC。

**不要**再同时依赖 `flutter_keyboard_controller`（MethodChannel 同名，会冲突）。

## 目录结构

```
flutter_keyboard_controller15/
├── lib/                    # Dart（KeyboardProvider、heightNotifier 等）
├── android/                # 安卓完整原生
├── ios/                    # iOS 完整原生
└── ohos/
    ├── Index.ets
    └── src/main/ets/components/plugin/
        └── FlutterKeyboardControllerPlugin.ets   # API 15 鸿蒙实现
```

## 鸿蒙日志

启动后弹键盘，确认走的是 API 15 路径：

```bash
hdc shell "hilog -z 500" | grep Plugin15
```

```
FlutterKeyboardControllerPlugin15 --> keyboard listeners attached, HarmonyOS 5.0.3 (API 15) — keyboardHeightChange only
```

## 与上游的关系

- 基于 `flutter_keyboard_controller` 1.0.4 fork
- Android/iOS 源码与上游相同
- 鸿蒙为自行实现的 API 15 版本（上游无 ohos）
- 包名刻意用 `flutter_keyboard_controller15` 以便与公司旧依赖区分
