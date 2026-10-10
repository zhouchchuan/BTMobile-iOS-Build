import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';
import { compatibility } from '../model/CompatPlayer';
import { isAv1DecoderFailure, canControlPlayback } from '../model/PlaybackPolicy';

@Component
export struct Player {
  @Prop source: string = '';
  @Prop title: string = '';
  onClose: () => void = () => {};
  private surface: XComponentController = new XComponentController();
  private player?: media.AVPlayer;
  private localFile?: fs.File;
  private timer: number = -1;
  private subtitleTimer: number = -1;
  private lastProgress: number = 0;
  private disposed: boolean = false;
  private compatToken: number = -1;
  private compatTimer: number = -1;
  private compatPolling: boolean = false;
  private fallbackAttempted: boolean = false;
  private compatStart: Promise<void> | undefined = undefined;
  private compatComplete: boolean = false;
  private nativeState: string = 'idle';
  private orientationChosen: boolean = false;
  private windowChange: Promise<void> = Promise.resolve();
  @StorageLink('btmobileForeground') @Watch('foregroundChanged') foreground: boolean = true;
  @State compatibilityMode: boolean = false;
  @State playbackReady: boolean = false;
  @State warningText: string = '';
  @State controls: boolean = true;
  @State playing: boolean = false;
  @State waiting: boolean = true;
  @State playbackPosition: number = 0;
  @State duration: number = 1;
  @State subtitle: string = '';
  @State errorText: string = '';
  @State fullscreen: boolean = false;
  @State tracks: media.MediaDescription[] = [];
  @State trackPanel: number = -1;
  @State selectedTracks: number[] = [];
  @State fitCrop: boolean = false;
  @State videoRatio: number = 16 / 9;
  @State areaWidth: number = 1;
  @State areaHeight: number = 1;

  async start(): Promise<void> {
    try {
      const created = await media.createAVPlayer();
      if (this.disposed) { await created.release(); return; }
      this.player = created;
      created.on('stateChange', async (state: string) => {
        if (this.player !== created || this.disposed || this.fallbackAttempted) return;
        this.nativeState = state;
        try {
        if (state === 'initialized') {
          this.player.surfaceId = this.surface.getXComponentSurfaceId();
          await this.player.prepare();
        } else if (state === 'prepared') {
          created.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
          this.videoSize(created.width, created.height);
          this.playbackReady = true;
          this.duration = Math.max(1, this.player.duration);
          this.tracks = (await this.player.getTrackDescription()).filter((track: media.MediaDescription) => Number(track['track_type']) !== media.MediaType.MEDIA_TYPE_VID);
          this.selectedTracks = await created.getSelectedTracks();
          await this.player.play();
        } else if (state === 'playing') {
          this.playing = true;
          this.autoHide();
        } else if (state === 'paused' || state === 'completed') {
          this.playing = false; this.waiting = false; this.controls = true;
        }
        } catch(e) { if (!this.disposed && !this.fallbackAttempted) this.handleError(e as BusinessError); }
      });
      created.on('videoSizeChange', (width: number, height: number) => {
        if (this.player === created && !this.disposed && !this.fallbackAttempted) this.videoSize(width, height);
      });
      this.player.on('timeUpdate', (time: number) => {
        if (this.player !== created || this.disposed || this.fallbackAttempted) return;
        if (time !== this.playbackPosition) { this.waiting = false; this.lastProgress = Date.now(); }
        this.playbackPosition = time;
      });
      this.player.on('bufferingUpdate', (type: number) => {
        if (this.player !== created || this.disposed || this.fallbackAttempted) return;
        if (type === media.BufferingInfoType.BUFFERING_START && Date.now() - this.lastProgress > 1200) this.waiting = true;
        if (type === media.BufferingInfoType.BUFFERING_END) this.waiting = false;
      });
      this.player.on('subtitleUpdate', (info: media.SubtitleInfo) => {
        if (this.player !== created || this.disposed || this.fallbackAttempted) return;
        clearTimeout(this.subtitleTimer); this.subtitle = info.text ?? '';
        this.subtitleTimer = setTimeout(() => { this.subtitle = ''; }, info.duration ?? 4000);
      });
      this.player.on('error', (error: BusinessError) => {
        if (this.player === created && !this.disposed) this.handleError(error);
      });
      if (this.source.startsWith('http://127.0.0.1:')) this.player.url = this.source;
      else {
        this.localFile = fs.openSync(this.source, fs.OpenMode.READ_ONLY);
        this.player.fdSrc = { fd: this.localFile.fd, offset: 0, length: fs.statSync(this.localFile.fd).size };
      }
    } catch (e) { this.errorText = (e as Error).message; this.waiting = false; }
  }
  handleError(error: BusinessError): void {
    hilog.error(0x1202, 'BTMobilePlayer', 'system playback failed, code=%{public}d, av1=%{public}s', error.code ?? 0, isAv1DecoderFailure(error.message, error.code) ? 'true' : 'false');
    if (this.fallbackAttempted) return;
    this.nativeState = 'error'; this.playbackReady = false; this.playing = false;
    if (isAv1DecoderFailure(error.message, error.code)) {
      this.fallbackAttempted = true; this.compatStart = this.startCompatibility();
    } else { this.errorText = '无法播放：' + error.message; this.waiting = false; }
  }
  async startCompatibility(): Promise<void> {
    this.waiting = true; this.errorText = ''; this.warningText = '正在启用 AV1 兼容解码…';
    try {
      const original = this.player; this.player = undefined;
      if (original) await original.release();
      if (this.disposed) return;
      // Keep the original descriptor open until the decoder has duplicated it.
      const result = await compatibility({ op: 'start', surface: this.surface.getXComponentSurfaceId(),
        fd: this.localFile?.fd ?? -1, url: this.localFile ? '' : this.source });
      const token = result.token ?? -1;
      if (this.disposed) { if (token >= 0) await compatibility({ op: 'close', token: token }); return; }
      this.compatToken = token; this.compatibilityMode = true;
      if (!this.foreground) await compatibility({ op: 'pause', token: token });
      this.compatTimer = setInterval(() => { this.refreshCompatibility(); }, 200);
      await this.refreshCompatibility();
    } catch(e) { if (!this.disposed) { this.errorText = 'AV1 兼容播放失败：' + (e as Error).message; this.waiting = false; this.warningText = ''; } }
  }
  async refreshCompatibility(): Promise<void> {
    if (this.compatPolling || this.compatToken < 0 || this.disposed) return;
    this.compatPolling = true; const token = this.compatToken;
    try {
      const state = await compatibility({ op: 'status', token: token });
      if (this.disposed || token !== this.compatToken || state.stale) return;
      const wasPlaying = this.playing; const wasReady = this.playbackReady;
      this.playbackReady = state.ready ?? false; this.playing = state.playing ?? false;
      this.waiting = state.waiting ?? false; this.playbackPosition = Math.max(0, state.position ?? 0);
      this.duration = Math.max(1, state.duration ?? 1); this.tracks = state.tracks ?? [];
      this.selectedTracks = [state.audioTrack ?? -1, state.subtitleTrack ?? -1].filter((i: number) => i >= 0);
      if ((state.width ?? 0) > 0 && (state.height ?? 0) > 0) this.videoSize(state.width ?? 0, state.height ?? 0);
      this.subtitle = state.subtitle ?? ''; this.errorText = state.error ?? '';
      this.warningText = state.warning || (this.playbackReady ? 'AV1 · 兼容解码' : '正在启用 AV1 兼容解码…');
      if (this.errorText) { this.waiting = false; this.playbackReady = false; this.controls = true; }
      this.compatComplete = state.complete ?? false;
      if (this.compatComplete) { this.playing = false; this.controls = true; }
      if ((!wasPlaying || !wasReady) && this.playing && this.playbackReady) this.autoHide();
    } catch(e) { this.errorText = (e as Error).message; this.waiting = false; this.playbackReady = false; }
    finally { this.compatPolling = false; }
  }
  foregroundChanged(): void {
    if (!this.foreground && this.compatToken >= 0) this.control('pause');
  }
  async control(op: string, value: number = 0): Promise<void> {
    if (this.disposed || !this.playbackReady || this.errorText) return;
    try {
      if (this.compatibilityMode) {
        if (op === 'play' && this.compatComplete) await compatibility({ op: 'seek', token: this.compatToken, position: 0 });
        await compatibility({ op: op, token: this.compatToken, position: Math.floor(value), track: Math.floor(value) });
        await this.refreshCompatibility();
      } else {
        const player = this.player; if (!player || !canControlPlayback(this.nativeState)) return;
        if (op === 'pause') await player.pause();
        else if (op === 'play') await player.play();
        else if (op === 'seek') player.seek(value, media.SeekMode.SEEK_CLOSEST);
        else if (op === 'track') { await player.selectTrack(Math.floor(value)); this.selectedTracks = await player.getSelectedTracks(); }
        else if (op === 'subtitleOff') {
          for (const track of this.tracks) if (Number(track['track_type']) === media.MediaType.MEDIA_TYPE_SUBTITLE && this.selectedTracks.includes(Number(track['track_index']))) await player.deselectTrack(Number(track['track_index']));
          this.selectedTracks = await player.getSelectedTracks(); this.subtitle = '';
        }
      }
      if (op === 'seek') { this.waiting = true; this.subtitle = ''; }
      this.autoHide();
    } catch(e) { this.warningText = '操作未完成：' + (e as Error).message; }
  }
  autoHide(): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      if (this.playing && this.trackPanel < 0) animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.controls = false; });
    }, 3500);
  }
  videoSize(width: number, height: number): void {
    if (width <= 0 || height <= 0) return;
    this.videoRatio = width / height;
    if (!this.orientationChosen) { this.orientationChosen = true; this.setOrientation(width > height); }
  }
  setOrientation(landscape: boolean): void {
    this.fullscreen = landscape;
    this.windowChange = this.windowChange.then(async () => {
      if (this.disposed) return;
      const w = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      if (this.disposed) return;
      await w.setPreferredOrientation(landscape ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.PORTRAIT);
      await w.setWindowLayoutFullScreen(true);
      await w.setWindowSystemBarEnable([]);
    }).catch(() => { this.warningText = '自动旋转未完成，可点击横屏 / 竖屏重试'; });
  }
  toggleFullscreen(): void { this.orientationChosen = true; this.setOrientation(!this.fullscreen); this.autoHide(); }
  surfaceWidth(): number {
    const width = this.areaHeight * this.videoRatio;
    return this.fitCrop ? Math.max(this.areaWidth, width) : Math.min(this.areaWidth, width);
  }
  surfaceHeight(): number { return this.surfaceWidth() / this.videoRatio; }
  toggleControls(): void {
    if (this.trackPanel >= 0) { this.trackPanel = -1; this.controls = true; }
    else animateTo({ duration: 180 }, () => { this.controls = !this.controls; });
    this.autoHide();
  }
  panelTracks(): media.MediaDescription[] { return this.tracks.filter((t: media.MediaDescription) => Number(t['track_type']) === this.trackPanel); }
  trackName(track: media.MediaDescription, index: number): string {
    const language = String(track['language'] ?? '').toLowerCase();
    let name = language;
    if (['zh','zho','chi','zh-cn','zh-hans'].includes(language)) name = '中文';
    else if (['en','eng'].includes(language)) name = '英语';
    else if (['ja','jpn'].includes(language)) name = '日语';
    else if (['ko','kor'].includes(language)) name = '韩语';
    if (!name || name === 'und') name = '未标注语言';
    const kind = Number(track['track_type']) === media.MediaType.MEDIA_TYPE_AUD ? '音轨' : '字幕';
    return kind + ' ' + (index + 1).toString() + ' · ' + name + (track['codec_mime'] ? ' · ' + String(track['codec_mime']) : '');
  }
  subtitleDisabled(): boolean {
    return !this.tracks.some((t: media.MediaDescription) => Number(t['track_type']) === media.MediaType.MEDIA_TYPE_SUBTITLE && this.selectedTracks.includes(Number(t['track_index'])));
  }
  async restoreWindow(): Promise<void> {
    await this.windowChange;
    const w = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
    await w.setPreferredOrientation(window.Orientation.UNSPECIFIED);
    await w.setWindowLayoutFullScreen(false); await w.setWindowSystemBarEnable(['status', 'navigation']);
  }
  async close(): Promise<void> {
    this.disposed = true;
    clearTimeout(this.timer); clearTimeout(this.subtitleTimer);
    try {
      await this.releasePlayer();
      await this.restoreWindow();
    } finally { this.onClose(); }
  }
  async releasePlayer(): Promise<void> {
    // A native start duplicates the file descriptor asynchronously. Do not close
    // the ArkTS descriptor while that operation still owns a pending reference.
    if (this.compatStart) await this.compatStart;
    clearInterval(this.compatTimer); this.compatTimer = -1;
    const token = this.compatToken; this.compatToken = -1;
    const player = this.player; this.player = undefined;
    const file = this.localFile; this.localFile = undefined;
    try { if (token >= 0) await compatibility({ op: 'close', token: token }); if (player) await player.release(); }
    finally { if (file) fs.closeSync(file); }
  }
  aboutToDisappear(): void {
    const restore = !this.disposed;
    this.disposed = true;
    clearTimeout(this.timer); clearTimeout(this.subtitleTimer);
    this.releasePlayer().catch(() => {});
    if (restore) this.restoreWindow().catch(() => {});
  }
  clock(ms: number): string {
    let s = Math.floor(ms / 1000);
    return Math.floor(s / 60).toString() + ':' + (s % 60).toString().padStart(2, '0');
  }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: 'bt-video', type: XComponentType.SURFACE, controller: this.surface })
        .width(this.surfaceWidth()).height(this.surfaceHeight()).hitTestBehavior(HitTestMode.None).onLoad(() => { this.start(); })
      // An actual full-size hit plane; no full-height control Column intercepts
      // taps on empty space. Only visible buttons/slider sit above this plane.
      Column() {}.width('100%').height('100%').backgroundColor(Color.Transparent)
        .onClick(() => { this.toggleControls(); }).accessibilityText('点击显示或隐藏播放控制')
      if (this.waiting && this.errorText.length === 0) {
        Row({ space: 10 }) { LoadingProgress().width(28).height(28).color(Color.White); Text('正在缓冲…').fontColor(Color.White) }
          .padding(14).borderRadius(18).backgroundColor('#AA222222').hitTestBehavior(HitTestMode.None)
      }
      if (this.errorText.length > 0) { Text(this.errorText).fontColor(Color.White).padding(32).hitTestBehavior(HitTestMode.None) }
      Column() {
        Blank()
        Text(this.subtitle).fontSize(20).fontColor(Color.White).textShadow({ radius: 3, color: Color.Black, offsetX: 1, offsetY: 1 }).textAlign(TextAlign.Center).margin({ bottom: this.controls ? 138 : 32 })
      }.height('100%').width('90%').hitTestBehavior(HitTestMode.None)
      if (this.controls) {
        Column({ space: 4 }) {
          Row() {
            Button('×', { type: ButtonType.Circle }).width(48).height(48).fontSize(30).fontColor(Color.White).backgroundColor('#99333333').accessibilityText('关闭播放器').onClick(() => { this.close(); })
            Text(this.title).fontColor(Color.White).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).padding(12)
          }.width('100%')
          if (this.warningText && !this.errorText) { Text(this.warningText).fontColor('#CCCCCC').fontSize(12).maxLines(2).padding(8) }
        }.padding({ left: 24, right: 24, top: 12 }).width('100%').align(Alignment.TopStart)
        Row({ space: 24 }) {
          Button('−10秒').width(72).height(52).fontSize(14).fontColor(Color.White).backgroundColor('#99333333').enabled(this.playbackReady).onClick(() => { this.control('seek', Math.max(0, this.playbackPosition - 10000)); })
          Button(this.playing ? '暂停' : '播放').width(72).height(60).fontSize(18).fontColor(Color.White).backgroundColor('#AA333333').enabled(this.playbackReady).onClick(() => { this.control(this.playing ? 'pause' : 'play'); })
          Button('+10秒').width(72).height(52).fontSize(14).fontColor(Color.White).backgroundColor('#99333333').enabled(this.playbackReady).onClick(() => { this.control('seek', Math.min(this.duration - 1, this.playbackPosition + 10000)); })
        }.justifyContent(FlexAlign.Center)
        Column({ space: 2 }) {
            Slider({ value: this.playbackPosition, min: 0, max: this.duration, step: 1000 }).height(36).selectedColor('#F39A56').enabled(this.playbackReady).onChange((value: number, mode: SliderChangeMode) => {
              clearTimeout(this.timer);
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.control('seek', value);
            })
            Text(this.clock(this.playbackPosition) + ' / ' + this.clock(this.duration)).fontSize(12).fontColor('#DDDDDD').width('100%')
            Row({ space: 6 }) {
              Button('字幕').layoutWeight(1).height(44).fontSize(14).fontColor(Color.White).backgroundColor('#555555').onClick(() => { this.trackPanel = media.MediaType.MEDIA_TYPE_SUBTITLE; clearTimeout(this.timer); })
              Button('音轨').layoutWeight(1).height(44).fontSize(14).fontColor(Color.White).backgroundColor('#555555').onClick(() => { this.trackPanel = media.MediaType.MEDIA_TYPE_AUD; clearTimeout(this.timer); })
              Button(this.fitCrop ? '裁剪铺满' : '原始比例').layoutWeight(1).height(44).fontSize(12).fontColor(Color.White).backgroundColor('#555555').onClick(() => { this.fitCrop = !this.fitCrop; this.autoHide(); })
              Button(this.fullscreen ? '竖屏' : '横屏').layoutWeight(1).height(44).fontSize(14).fontColor(Color.White).backgroundColor('#555555').onClick(() => { this.toggleFullscreen(); })
            }.width('100%')
        }.padding({ left: 20, right: 20, top: 4, bottom: 16 }).backgroundColor('#CC222222').width('100%').align(Alignment.BottomStart)
      }
      if (this.trackPanel >= 0) {
        Column({ space: 12 }) {
          Row() {
            Text(this.trackPanel === media.MediaType.MEDIA_TYPE_AUD ? '选择音轨' : '选择字幕').fontSize(18).fontColor(Color.White).layoutWeight(1)
            Button('×', { type: ButtonType.Circle }).width(44).height(44).fontSize(26).fontColor(Color.White).backgroundColor('#555555').onClick(() => { this.trackPanel = -1; this.autoHide(); })
          }.width('100%')
          Scroll() {
            Column({ space: 8 }) {
              if (this.trackPanel === media.MediaType.MEDIA_TYPE_SUBTITLE) {
                Button((this.subtitleDisabled() ? '✓  ' : '') + '关闭字幕').width('100%').height(48).fontColor(Color.White).backgroundColor(this.subtitleDisabled() ? '#995A30' : '#444444').onClick(async () => { await this.control('subtitleOff'); this.trackPanel = -1; this.autoHide(); })
              }
              ForEach(this.panelTracks(), (track: media.MediaDescription, index: number) => {
                Button((this.selectedTracks.includes(Number(track['track_index'])) ? '✓  ' : '') + this.trackName(track, index))
                  .width('100%').constraintSize({ minHeight: 48 }).fontSize(14).fontColor(Color.White)
                  .backgroundColor(this.selectedTracks.includes(Number(track['track_index'])) ? '#995A30' : '#444444')
                  .onClick(async () => { await this.control('track', Number(track['track_index'])); this.trackPanel = -1; this.autoHide(); })
              }, (track: media.MediaDescription) => String(track['track_index']))
              if (this.panelTracks().length === 0) { Text(this.trackPanel === 0 ? '此视频没有可选择的音轨' : '此视频没有内嵌字幕').fontColor('#CCCCCC').fontSize(14).padding(12) }
            }.width('100%')
          }.constraintSize({ maxHeight: Math.max(100, this.areaHeight - 130) }).width('100%')
        }.padding(16).width('88%').constraintSize({ maxWidth: 460 }).backgroundColor('#F2222222').borderRadius(22)
      }
    }.width('100%').height('100%').backgroundColor(Color.Black).clip(true)
    .onAreaChange((_old: Area, area: Area) => { this.areaWidth = Math.max(1, Number(area.width)); this.areaHeight = Math.max(1, Number(area.height)); })
  }
}
