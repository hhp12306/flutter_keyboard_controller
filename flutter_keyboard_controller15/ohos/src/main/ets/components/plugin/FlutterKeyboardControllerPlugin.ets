/**
 * flutter_keyboard_controller15 — HarmonyOS 5.0.3（API 15）专用。
 *
 * 仅 keyboardHeightChange（API 7+），无 keyboardDidShow（18+）/ keyboardWillShow（20+）。
 * 收到终值后本地合成 keyboardMove 帧。与高版本 flutter_keyboard_controller 完全隔离。
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

const TAG: string = 'FlutterKeyboardControllerPlugin15';

const FRAME_INTERVAL_MS: number = 16;
const DEFAULT_DURATION_MS: number = 250;
const EPSILON: number = 0.5;

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

  private isAnimating: boolean = false;
  private frameTimer: number = -1;
  private animStartTime: number = 0;
  private animFromHeight: number = 0;
  private animToHeight: number = 0;
  private animDuration: number = DEFAULT_DURATION_MS;

  private isListenersAttached: boolean = false;
  private setupRetryCount: number = 0;

  getUniqueClassName(): string {
    return TAG;
  }

  setEventSink(sink: EventSink | null): void {
    this.eventSink = sink;
  }

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

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.ability = binding.getAbility();
    this.setupKeyboardTracking();
  }

  onDetachedFromAbility(): void {
    this.teardownKeyboardTracking();
    this.ability = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'dismiss':
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

    try {
      win.on('keyboardHeightChange', this.onKeyboardHeightChange);
      Log.i(TAG, 'keyboard listeners attached, HarmonyOS 5.0.3 (API 15) — keyboardHeightChange only');
    } catch (err) {
      Log.e(TAG, 'keyboardHeightChange unavailable: ' + JSON.stringify(err as BusinessError));
    }
  }

  private teardownKeyboardTracking(): void {
    this.stopFrameSynthesis();
    const win: window.Window | null = this.mainWindow;
    if (win !== null) {
      try {
        win.off('keyboardHeightChange', this.onKeyboardHeightChange);
      } catch (err) {
      }
    }
    this.mainWindow = null;
    this.isListenersAttached = false;
    this.isAnimating = false;
  }

  /** API 15 唯一高度来源：终值到达后才开始合成动画。 */
  private onKeyboardHeightChange = (heightPx: number): void => {
    if (this.isAnimating) {
      return;
    }
    const heightVp: number = this.pxToVp(heightPx);
    if (Math.abs(this.currentHeight - heightVp) < EPSILON) {
      return;
    }
    this.beginAnimation(heightVp, heightVp > 0 ? 'keyboardWillShow' : 'keyboardWillHide');
  };

  private beginAnimation(target: number, willType: string): void {
    this.stopFrameSynthesis();

    this.animFromHeight = this.currentHeight;
    this.animToHeight = target;
    this.animDuration = DEFAULT_DURATION_MS;

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
    const progress: number = Math.min(1, elapsed / this.animDuration);
    const t: number = this.easeOutCubic(progress);
    const finished: boolean = progress >= 1;

    const height: number = this.animFromHeight + (this.animToHeight - this.animFromHeight) * t;
    this.currentHeight = height;

    const maxHeight: number = Math.max(this.animFromHeight, this.animToHeight);
    const progressRatio: number = maxHeight > 0 ? Math.min(1, Math.max(0, height / maxHeight)) : 0;
    this.emitEvent('keyboardMove', height, progressRatio, this.animDuration);

    if (finished) {
      this.finishAnimation(this.animToHeight);
    }
  }

  private easeOutCubic(progress: number): number {
    const inv: number = 1 - progress;
    return 1 - inv * inv * inv;
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
