/**
 * OpenHarmony implementation of flutter_keyboard_controller.
 *
 * 对齐 Android 端（FlutterKeyboardControllerPlugin.kt）的通道与事件契约：
 *   MethodChannel  flutter_keyboard_controller
 *   EventChannel   flutter_keyboard_controller/keyboard_events
 *   事件字段        { type, height(vp), progress, duration(ms), timestamp }
 *
 * 与 Android 的本质差异：
 *   Android 有 WindowInsetsAnimation.onProgress，系统逐帧回调真实高度。
 *   鸿蒙没有等价 API —— keyboardHeightChange 只给「0 和最终高度」两个值。
 *   但 API 20 起提供 keyboardWillShow / keyboardWillHide，回调的 KeyboardInfo 里带
 *   endRect（目标高度）与 config（动画曲线和时长）。本实现据此在本地按同一条曲线
 *   插值合成 keyboardMove 帧，使 Dart 侧拿到与 Android 一致形态的逐帧数据。
 *   合成帧的时长与曲线参数来自系统，不是拍脑袋定的，但终究是插值而非系统真实帧。
 *
 * 编译期约束：
 *   keyboardWillShow / KeyboardInfo.config / KeyboardInfo.animated 均为 API 20+。
 *   为了能在 compatibleSdkVersion 低于 20 的工程里编译，所有 API 20 特性一律通过
 *   ESObject 动态访问 + try/catch 运行时探测，不直接引用其类型。
 */

import {
  AbilityAware,
  AbilityPluginBinding,
  Any,
  BinaryMessenger,
  EventChannel,
  EventSink,
  FlutterManager,
  FlutterPlugin,
  FlutterPluginBinding,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
  StreamHandler,
} from '@ohos/flutter_ohos';
import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import inputMethod from '@ohos.inputMethod';
import { BusinessError } from '@ohos.base';

const TAG: string = 'FlutterKeyboardControllerPlugin';

/** 合成帧间隔。16ms ≈ 60fps，与 Android onProgress 的回调密度相当 */
const FRAME_INTERVAL_MS: number = 16;

/** 系统未提供动画时长时的兜底值，取鸿蒙键盘动画的经验值 */
const DEFAULT_DURATION_MS: number = 250;

/** 高度变化小于该值（vp）视为无变化，避免浮点抖动产生无效事件 */
const EPSILON: number = 0.5;

/** window.WindowAnimationCurve.INTERPOLATION_SPRING，API 20 才有该枚举，此处用字面值避免编译期依赖 */
const CURVE_INTERPOLATION_SPRING: number = 1;

/** 弹簧曲线没有固定时长，用它作为硬上限兜底，防止定时器泄漏 */
const SPRING_MAX_DURATION_MS: number = DEFAULT_DURATION_MS * 3;

/** 取主窗口失败后的重试间隔与次数：插件 attach 可能早于 windowStage.loadContent */
const SETUP_RETRY_INTERVAL_MS: number = 200;
const MAX_SETUP_RETRY: number = 15;

class KeyboardStreamHandler implements StreamHandler {
  private owner: FlutterKeyboardControllerPlugin;

  constructor(owner: FlutterKeyboardControllerPlugin) {
    this.owner = owner;
  }

  onListen(args: Any, events: EventSink): void {
    this.owner.setEventSink(events);
  }

  onCancel(args: Any): void {
    this.owner.setEventSink(null);
  }
}

export default class FlutterKeyboardControllerPlugin implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private static METHOD_CHANNEL: string = 'flutter_keyboard_controller';
  private static EVENT_CHANNEL: string = 'flutter_keyboard_controller/keyboard_events';

  private methodChannel: MethodChannel | null = null;
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null;

  private ability: UIAbility | null = null;
  private mainWindow: window.Window | null = null;

  private currentHeight: number = 0;
  private isKeyboardVisible: boolean = false;

  /** 合成动画进行中，用于抑制 keyboardHeightChange 的重复上报（对应 Android 的 isAnimating） */
  private isAnimating: boolean = false;
  private frameTimer: number = -1;
  private animStartTime: number = 0;
  private animFromHeight: number = 0;
  private animToHeight: number = 0;
  private animDuration: number = DEFAULT_DURATION_MS;
  private animSpringParam: Array<number> | null = null;

  private isListenersAttached: boolean = false;
  private setupRetryCount: number = 0;

  /** keyboardWillShow/Hide 是否注册成功。失败说明系统低于 API 20，退化为只有终值的两段式 */
  private hasWillEvents: boolean = false;

  getUniqueClassName(): string {
    return TAG;
  }

  setEventSink(sink: EventSink | null): void {
    this.eventSink = sink;
  }

  // ── FlutterPlugin ─────────────────────────────────────────────────────────

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    const messenger: BinaryMessenger = binding.getBinaryMessenger();

    this.methodChannel = new MethodChannel(messenger, FlutterKeyboardControllerPlugin.METHOD_CHANNEL);
    this.methodChannel.setMethodCallHandler(this);

    this.eventChannel = new EventChannel(messenger, FlutterKeyboardControllerPlugin.EVENT_CHANNEL);
    this.eventChannel.setStreamHandler(new KeyboardStreamHandler(this));
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.methodChannel?.setMethodCallHandler(null);
    this.methodChannel = null;
    this.eventChannel?.setStreamHandler(null);
    this.eventChannel = null;
    this.eventSink = null;
  }

  // ── AbilityAware ──────────────────────────────────────────────────────────

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.ability = binding.getAbility();
    this.setupKeyboardTracking();
  }

  onDetachedFromAbility(): void {
    this.teardownKeyboardTracking();
    this.ability = null;
  }

  // ── MethodCallHandler ─────────────────────────────────────────────────────

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'dismiss':
        // 鸿蒙没有 keepFocus 语义：stopInputSession 只收键盘，焦点由 ArkUI 侧保留，
        // 因此该参数在本平台被忽略，行为等同 keepFocus: true。
        try {
          inputMethod.getController().stopInputSession();
        } catch (err) {
          Log.e(TAG, 'stopInputSession failed: ' + JSON.stringify(err as BusinessError));
        }
        result.success(null);
        break;

      case 'isVisible':
        result.success(this.isKeyboardVisible);
        break;

      case 'state': {
        const state: Map<string, Any> = new Map<string, Any>();
        state.set('height', this.currentHeight);
        state.set('isVisible', this.isKeyboardVisible);
        state.set('progress', this.isKeyboardVisible ? 1.0 : 0.0);
        result.success(state);
        break;
      }

      // Android/iOS 专有能力，鸿蒙无对应实现。返回 success 而非 notImplemented，
      // 与 Android 端处理 iOS 专有方法的方式保持一致，避免 Dart 侧抛异常。
      case 'setInputMode':
      case 'setDefaultMode':
      case 'setupEdgeToEdge':
      case 'preload':
      case 'focusNext':
      case 'focusPrev':
        result.success(null);
        break;

      default:
        result.notImplemented();
    }
  }

  // ── Keyboard tracking ─────────────────────────────────────────────────────

  /**
   * onAttachedToAbility 时 windowStage 可能尚未 loadContent，此时 getLastWindow 会抛
   * 1300002（window state abnormal）。这里优先走引擎同款的 FlutterManager 取主窗口，
   * 失败再退回 getLastWindow，仍失败则延时重试，避免因时序错过监听注册。
   */
  private setupKeyboardTracking(): void {
    const ability: UIAbility | null = this.ability;
    if (this.isListenersAttached || ability === null) {
      return;
    }

    const fromStage: window.Window | null = this.tryGetWindowFromStage(ability);
    if (fromStage !== null) {
      this.attachWindowListeners(fromStage);
      return;
    }

    window.getLastWindow(ability.context).then((win: window.Window) => {
      this.attachWindowListeners(win);
    }).catch((err: BusinessError) => {
      Log.w(TAG, 'getLastWindow failed, will retry: ' + JSON.stringify(err));
      this.scheduleSetupRetry();
    });
  }

  private tryGetWindowFromStage(ability: UIAbility): window.Window | null {
    try {
      return FlutterManager.getInstance().getWindowStage(ability).getMainWindowSync();
    } catch (err) {
      return null;
    }
  }

  private scheduleSetupRetry(): void {
    if (this.setupRetryCount >= MAX_SETUP_RETRY) {
      Log.e(TAG, 'give up attaching keyboard listeners after ' + MAX_SETUP_RETRY + ' retries');
      return;
    }
    this.setupRetryCount++;
    setTimeout(() => {
      this.setupKeyboardTracking();
    }, SETUP_RETRY_INTERVAL_MS);
  }

  private attachWindowListeners(win: window.Window): void {
    if (this.isListenersAttached) {
      return;
    }
    this.mainWindow = win;
    this.isListenersAttached = true;

    {
      // API 20+：带目标高度与系统动画参数，是合成逐帧数据的依据。
      // 用 ESObject 动态调用，避免低版本 SDK 上因类型不存在而编译失败。
      const dynamicWin: ESObject = win as ESObject;
      try {
        dynamicWin.on('keyboardWillShow', this.onKeyboardWillShow);
        dynamicWin.on('keyboardWillHide', this.onKeyboardWillHide);
        this.hasWillEvents = true;
      } catch (err) {
        // 801 = Capability not supported（设备或系统版本不支持）
        this.hasWillEvents = false;
        Log.w(TAG, 'keyboardWillShow/Hide unavailable, fallback to keyboardHeightChange: '
          + JSON.stringify(err as BusinessError));
      }

      // API 18+：动画结束的确认信号，用于把合成值校正回系统终值
      try {
        dynamicWin.on('keyboardDidShow', this.onKeyboardDidShow);
        dynamicWin.on('keyboardDidHide', this.onKeyboardDidHide);
      } catch (err) {
        Log.w(TAG, 'keyboardDidShow/Hide unavailable: ' + JSON.stringify(err as BusinessError));
      }

      // API 7+：全版本可用。低版本上是主路径，高版本上是安全网，
      // 对应 Android 端 setOnApplyWindowInsetsListener 那层 static insets safety net。
      try {
        win.on('keyboardHeightChange', this.onKeyboardHeightChange);
      } catch (err) {
        Log.e(TAG, 'keyboardHeightChange unavailable: ' + JSON.stringify(err as BusinessError));
      }

      Log.i(TAG, 'keyboard listeners attached, frame-accurate mode: ' + this.hasWillEvents);
    }
  }

  private teardownKeyboardTracking(): void {
    this.stopFrameSynthesis();
    const win: window.Window | null = this.mainWindow;
    if (win !== null) {
      const dynamicWin: ESObject = win as ESObject;
      try {
        dynamicWin.off('keyboardWillShow', this.onKeyboardWillShow);
        dynamicWin.off('keyboardWillHide', this.onKeyboardWillHide);
      } catch (err) {
        // 未注册成功过，忽略
      }
      try {
        dynamicWin.off('keyboardDidShow', this.onKeyboardDidShow);
        dynamicWin.off('keyboardDidHide', this.onKeyboardDidHide);
      } catch (err) {
      }
      try {
        win.off('keyboardHeightChange', this.onKeyboardHeightChange);
      } catch (err) {
      }
    }
    this.mainWindow = null;
    this.isListenersAttached = false;
    this.isAnimating = false;
  }

  // ── Window callbacks ──────────────────────────────────────────────────────

  private onKeyboardWillShow = (info: ESObject): void => {
    this.beginAnimation(this.readEndHeightVp(info), info, 'keyboardWillShow');
  };

  private onKeyboardWillHide = (info: ESObject): void => {
    this.beginAnimation(0, info, 'keyboardWillHide');
  };

  /**
   * did 事件在 API 18 起可用，但含义随是否有 will 事件而不同：
   *
   * - 有 will（API 20+）：动画已由 will 启动并合成中，did 只负责把高度校正到系统终值。
   * - 无 will（API 18/19）：did 是我们能拿到的最早信号，此时才开始合成动画。若在这里
   *   直接 finish，输入框会一步跳到位——API 19 真机上就是这个表现。
   */
  private onKeyboardDidShow = (info: ESObject): void => {
    const height: number = this.readEndHeightVp(info);
    if (this.hasWillEvents) {
      this.finishAnimation(height);
    } else {
      this.beginAnimation(height, null, 'keyboardWillShow');
    }
  };

  private onKeyboardDidHide = (info: ESObject): void => {
    if (this.hasWillEvents) {
      this.finishAnimation(0);
    } else {
      this.beginAnimation(0, null, 'keyboardWillHide');
    }
  };

  /**
   * 全版本可用的高度回调，单位 px，只在键盘显示/隐藏完成时给一次终值。
   *
   * 高版本上 will/did 已覆盖整个过程，这里只作安全网：合成动画期间直接跳过，
   * 避免与合成帧打架（对应 Android 端 isAnimating 的判断）。
   */
  private onKeyboardHeightChange = (heightPx: number): void => {
    if (this.isAnimating) {
      return;
    }
    const heightVp: number = this.pxToVp(heightPx);
    if (Math.abs(this.currentHeight - heightVp) < EPSILON) {
      return;
    }

    if (this.hasWillEvents) {
      // will 事件可用却走到这里，说明是一次没有动画的高度突变
      // （切换输入法、键盘尺寸调整等），直接同步终值。
      this.finishAnimation(heightVp);
      return;
    }

    // 低版本主路径：系统只给终值，按默认时长自行合成一段动画，
    // 否则 Dart 侧会看到输入框一步跳到位。
    this.beginAnimation(heightVp, null, heightVp > 0 ? 'keyboardWillShow' : 'keyboardWillHide');
  };

  // ── Frame synthesis ───────────────────────────────────────────────────────

  private beginAnimation(target: number, info: ESObject | null, willType: string): void {
    this.stopFrameSynthesis();

    this.animFromHeight = this.currentHeight;
    this.animToHeight = target;
    this.animDuration = DEFAULT_DURATION_MS;
    this.animSpringParam = null;

    if (info !== null) {
      // 系统明确告知本次无动画时，不合成中间帧，直接落到终值
      if (info.animated === false) {
        this.finishAnimation(target);
        return;
      }

      // API 20 起 KeyboardInfo 带 config：curve 为 INTERPOLATION_SPRING 时时长由曲线
      // 参数决定（duration 字段不生效），为 LINEAR 时 duration 必填。
      const config: ESObject = info.config;
      if (config !== undefined && config !== null) {
        const param: ESObject = config.param;
        if (config.curve === CURVE_INTERPOLATION_SPRING && param !== undefined && param !== null) {
          this.animSpringParam = param as Array<number>;
        } else if (typeof config.duration === 'number' && config.duration > 0) {
          this.animDuration = config.duration as number;
        }
      }
    }

    if (Math.abs(this.animToHeight - this.animFromHeight) < EPSILON) {
      return;
    }

    this.isAnimating = true;
    this.animStartTime = Date.now();

    const isShowing: boolean = target > 0;
    this.emitEvent(willType, target, isShowing ? 0.0 : 1.0, this.animDuration);

    this.frameTimer = setInterval(() => {
      this.onSynthesizedFrame();
    }, FRAME_INTERVAL_MS);
  }

  private onSynthesizedFrame(): void {
    const elapsed: number = Date.now() - this.animStartTime;
    const springParam: Array<number> | null = this.animSpringParam;

    let t: number;
    let finished: boolean;
    if (springParam !== null) {
      t = this.springValue(elapsed / 1000, springParam);
      finished = elapsed >= SPRING_MAX_DURATION_MS || Math.abs(1 - t) < 0.001;
    } else {
      const progress: number = Math.min(1, elapsed / this.animDuration);
      t = this.easeOutCubic(progress);
      finished = progress >= 1;
    }

    const height: number = this.animFromHeight + (this.animToHeight - this.animFromHeight) * t;
    this.currentHeight = height;

    const maxHeight: number = Math.max(this.animFromHeight, this.animToHeight);
    const progressRatio: number = maxHeight > 0 ? Math.min(1, Math.max(0, height / maxHeight)) : 0;
    this.emitEvent('keyboardMove', height, progressRatio, this.animDuration);

    if (finished) {
      this.finishAnimation(this.animToHeight);
    }
  }

  /**
   * 系统没给曲线参数时的近似：easeOutCubic。
   *
   * 与鸿蒙键盘实际使用的弹簧曲线在「先快后慢、无回弹」的整体形态上接近，
   * 误差集中在尾段几个像素，且会被 didShow 的终值校正，不会累积。
   */
  private easeOutCubic(progress: number): number {
    const inv: number = 1 - progress;
    return 1 - inv * inv * inv;
  }

  /**
   * 按系统给的 [velocity, mass, stiffness, damping] 求阻尼弹簧在 t 秒时的归一化位移，
   * 与 ArkUI interpolatingSpring 的语义一致。区分欠阻尼与临界/过阻尼两种情形。
   */
  private springValue(t: number, param: Array<number>): number {
    const velocity: number = param[0];
    const mass: number = param[1] > 0 ? param[1] : 1;
    const stiffness: number = param[2] > 0 ? param[2] : 1;
    const damping: number = param[3] > 0 ? param[3] : 1;

    const omega0: number = Math.sqrt(stiffness / mass);
    const zeta: number = damping / (2 * Math.sqrt(stiffness * mass));

    if (zeta < 1) {
      const omegaD: number = omega0 * Math.sqrt(1 - zeta * zeta);
      const envelope: number = Math.exp(-zeta * omega0 * t);
      return 1 - envelope * (Math.cos(omegaD * t) + ((zeta * omega0 + velocity) / omegaD) * Math.sin(omegaD * t));
    }
    const envelope: number = Math.exp(-omega0 * t);
    return 1 - envelope * (1 + (omega0 + velocity) * t);
  }

  private finishAnimation(height: number): void {
    this.stopFrameSynthesis();
    this.currentHeight = height;
    this.isKeyboardVisible = height > EPSILON;
    this.emitEvent(
      this.isKeyboardVisible ? 'keyboardDidShow' : 'keyboardDidHide',
      height,
      this.isKeyboardVisible ? 1.0 : 0.0,
      this.animDuration,
    );
  }

  private stopFrameSynthesis(): void {
    if (this.frameTimer !== -1) {
      clearInterval(this.frameTimer);
      this.frameTimer = -1;
    }
    this.isAnimating = false;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /** KeyboardInfo.endRect 的单位是 px，Dart 侧约定收 vp（等价于 Android 的 dp） */
  private readEndHeightVp(info: ESObject): number {
    if (info === undefined || info === null) {
      return 0;
    }
    const endRect: ESObject = info.endRect;
    if (endRect === undefined || endRect === null) {
      return 0;
    }
    return this.pxToVp(endRect.height as number);
  }

  private pxToVp(px: number): number {
    const ctx: ESObject = this.mainWindow?.getUIContext();
    if (ctx === undefined || ctx === null) {
      return px;
    }
    return ctx.px2vp(px) as number;
  }

  private emitEvent(type: string, height: number, progress: number, duration: number): void {
    const sink: EventSink | null = this.eventSink;
    if (sink === null) {
      return;
    }
    const event: Map<string, Any> = new Map<string, Any>();
    event.set('type', type);
    event.set('height', height);
    event.set('progress', progress);
    event.set('duration', duration);
    event.set('timestamp', Date.now());
    sink.success(event);
  }
}
