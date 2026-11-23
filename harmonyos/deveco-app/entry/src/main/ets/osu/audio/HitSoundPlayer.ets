import { HitResult } from '../scoring/HitResult';
import { OsuHitObject, SliderNested, SliderNestedKind } from '../ruleset/OsuObjects';

/** 打击音种类，与 native 侧 HitSoundKind 的序号一一对应 */
export class SfxKind {
  static readonly NORMAL: number = 0;
  static readonly WHISTLE: number = 1;
  static readonly FINISH: number = 2;
  static readonly CLAP: number = 3;
}

/** 谱面 hitSound 位掩码 */
export class HitSoundFlags {
  static readonly NORMAL: number = 1;
  static readonly WHISTLE: number = 2;
  static readonly FINISH: number = 4;
  static readonly CLAP: number = 8;
}

export type SampleTrigger = (kind: number, volume: number) => void;

/**
 * 打击音调度：判定结果 → 该响几个音、响多大声。
 *
 * 和 osu! 的规则一致（LegacyBeatmapDecoder.convertHitSamples）：
 *   - hitSound == 0 → 视为 normal
 *   - 否则按位展开，只响被置位的那些（不会额外补 normal）
 * 音量 = 物件所在 sample 控制点的音量 × 全局音量。
 *
 * 实际发声通过注入的 trigger 回调，这样内核逻辑在 Node 上也能断言。
 */
export class HitSoundPlayer {
  private trigger: SampleTrigger;
  private globalVolume: number = 0.8;
  private enabled: boolean = true;

  /** 统计，便于确认"判定发生但没出声"这类问题 */
  playCount: number = 0;

  constructor(trigger: SampleTrigger) {
    this.trigger = trigger;
  }

  setVolume(v: number): void {
    this.globalVolume = Math.min(1, Math.max(0, v));
  }

  setEnabled(on: boolean): void {
    this.enabled = on;
  }

  /** 一个物件的击打音（circle 命中 / slider 头 / spinner 完成） */
  playForObject(object: OsuHitObject | null): void {
    if (object === null || !this.enabled) {
      return;
    }
    this.playMask(object.hitSound, object.sampleVolume);
  }

  /** 滑条内部判定点：tick 用 normal，repeat 用 normal，尾判不放音（和 stable 一致） */
  playForNested(nested: SliderNested | null, object: OsuHitObject | null): void {
    if (nested === null || object === null || !this.enabled) {
      return;
    }
    if (nested.kind === SliderNestedKind.TAIL || nested.kind === SliderNestedKind.LEGACY_LAST_TICK) {
      return;
    }
    // tick / repeat 只响 normal，音量跟物件走
    this.play(SfxKind.NORMAL, object.sampleVolume);
  }

  /** 按位掩码展开 */
  playMask(hitSound: number, sampleVolume: number): void {
    if (!this.enabled) {
      return;
    }
    const mask = hitSound === 0 ? HitSoundFlags.NORMAL : hitSound;
    if ((mask & HitSoundFlags.NORMAL) !== 0) {
      this.play(SfxKind.NORMAL, sampleVolume);
    }
    if ((mask & HitSoundFlags.WHISTLE) !== 0) {
      this.play(SfxKind.WHISTLE, sampleVolume);
    }
    if ((mask & HitSoundFlags.FINISH) !== 0) {
      this.play(SfxKind.FINISH, sampleVolume);
    }
    if ((mask & HitSoundFlags.CLAP) !== 0) {
      this.play(SfxKind.CLAP, sampleVolume);
    }
  }

  /** 未命中不发声，和 osu! 一致（miss 只有音效轨，不放 samples） */
  playForResult(result: string, object: OsuHitObject | null): void {
    if (result === HitResult.MISS || result === HitResult.NONE) {
      return;
    }
    this.playForObject(object);
  }

  play(kind: number, sampleVolume: number): void {
    if (!this.enabled) {
      return;
    }
    const vol = (sampleVolume <= 0 ? 100 : sampleVolume) / 100 * this.globalVolume;
    if (vol <= 0.001) {
      return;
    }
    this.playCount++;
    this.trigger(kind, vol);
  }
}
