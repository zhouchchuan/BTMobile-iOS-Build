import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import hilog from '@ohos.hilog';
import { compatibility } from '../model/CompatPlayer';
import { isAv1DecoderFailure, canControlPlayback, clampSeekTarget, relativeSeekTarget } from '../model/PlaybackPolicy';
import { trackLabel, enrichTracks } from '../model/TrackLabels';

@Component
export struct Player {
  @Prop source: string = '';
  @Prop title: string = '';
  onClose: () => void = () => {};
  @Prop @Watch('backRequested') closeRequest: number = 0;
  private opening: Promise<void> | undefined = undefined;
  private releasing: Promise<void> | undefined = undefined;
  private probeTracks: media.MediaDescription[] = [];
  private firstNativeFrame: boolean = false;
  private surface: XComponentController = new XComponentController();
  private player?: media.AVPlayer;
  private localFile?: fs.File;
  private timer: number = -1;
  private subtitleTimer: number = -1;
  private lastProgress: number = 0;
  private seekTarget: number = -1;
  private seekRequestedAt: number = 0;
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

  start(): void { if (!this.opening) this.opening = this.open(); }
  async open(): Promise<void> {
    try {
      this.setOrientation(false);
      if (!this.source.startsWith('http://127.0.0.1:')) this.localFile = fs.openSync(this.source, fs.OpenMode.READ_ONLY);
      try {
        const metadata = await compatibility({ op: 'probe', fd: this.localFile?.fd ?? -1, url: this.localFile ? '' : this.source });
        if (this.disposed) return;
        this.probeTracks = metadata.tracks ?? [];
        if ((metadata.width ?? 0) > 0) this.videoSize(metadata.width ?? 0, metadata.height ?? 0);
        if (metadata.videoCodec === 'av1') {
          this.fallbackAttempted = true; this.compatStart = this.startCompatibility(); await this.compatStart; return;
        }
      } catch (_) { /* An incomplete streaming header must not prevent native playback. */ }
      if (this.disposed) return;
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
          this.tracks = enrichTracks((await this.player.getTrackDescription()).filter((track: media.MediaDescription) => Number(track['track_type']) !== media.MediaType.MEDIA_TYPE_VID), this.probeTracks);
          try { this.selectedTracks = await created.getSelectedTracks(); } catch (_) { this.selectedTracks = []; }
          await this.player.play();
        } else if (state === 'playing') {
          this.playing = true;
          this.autoHide();
        } else if (state === 'paused' || state === 'completed') {
          this.playing = false; this.waiting = false; this.controls = true;
        }
        } catch(e) { if (!this.disposed && !this.fallbackAttempted) this.handleError(e as BusinessError); }
      });
      created.on('startRenderFrame', () => { this.firstNativeFrame = true; this.waiting = false; hilog.info(0x1202, 'BTMobilePlayer', 'Native first frame rendered'); });
      created.on('seekDone', (requested: number) => {
        if (this.player !== created || this.disposed || this.fallbackAttempted) return;
        const actual = created.currentTime;
        if (actual >= 0) this.playbackPosition = actual;
        if (Math.abs(requested - this.seekTarget) <= 1) this.seekTarget = -1;
        this.waiting = false;
        hilog.info(0x1202, 'BTMobilePlayer', 'seek completed requested=%{public}d actual=%{public}d', requested, actual);
      });
      created.on('trackChange', (index: number, selected: boolean) => {
        if (this.disposed || this.player !== created) return;
        this.selectedTracks = this.selectedTracks.filter((id: number) => id !== index);
        if (selected) this.selectedTracks = this.selectedTracks.concat([index]);
        this.subtitle = '';
      });
      created.on('trackInfoUpdate', (tracks: media.MediaDescription[]) => {
        if (!this.disposed && this.player === created) this.tracks = enrichTracks(tracks.filter((t: media.MediaDescription) => Number(t['track_type']) !== 1), this.probeTracks);
      });
      created.on('videoSizeChange', (width: number, height: number) => {
        if (this.player === created && !this.disposed && !this.fallbackAttempted) this.videoSize(width, height);
      });
      this.player.on('timeUpdate', (time: number) => {
        if (this.player !== created || this.disposed || this.fallbackAttempted) return;
        if (time !== this.playbackPosition) { if (this.firstNativeFrame) this.waiting = false; this.lastProgress = Date.now(); }
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
      else if (this.localFile) this.player.fdSrc = { fd: this.localFile.fd, offset: 0, length: fs.statSync(this.localFile.fd).size };
    } catch (e) { if (!this.disposed) { this.errorText = (e as Error).message; this.waiting = false; } }
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
      if (this.seekTarget >= 0 && Math.abs(this.playbackPosition - this.seekTarget) < 750) this.seekTarget = -1;
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
  async skipBy(delta: number): Promise<void> {
    if (this.disposed || !this.playbackReady || this.errorText) return;
    // Read live state at click time; Builder value arguments capture old times.
    const nativeTime = this.player?.currentTime ?? -1;
    const current = !this.compatibilityMode && nativeTime >= 0 ? nativeTime : this.playbackPosition;
    const pending = Date.now() - this.seekRequestedAt < 1500 ? this.seekTarget : -1;
    await this.control('seek', relativeSeekTarget(current, delta, this.duration, pending));
  }
  async control(op: string, value: number = 0): Promise<void> {
    if (this.disposed || !this.playbackReady || this.errorText) return;
    if (!this.compatibilityMode && (!this.player || !canControlPlayback(this.nativeState))) return;
    try {
      if (op === 'seek') {
        value = clampSeekTarget(value, this.duration);
        this.seekTarget = value; this.seekRequestedAt = Date.now();
        this.waiting = true; this.subtitle = ''; clearTimeout(this.subtitleTimer);
        hilog.info(0x1202, 'BTMobilePlayer', 'seek requested from=%{public}d to=%{public}d', this.playbackPosition, value);
      }
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
      this.autoHide();
    } catch(e) {
      if (op === 'seek') { this.seekTarget = -1; this.waiting = false; }
      this.warningText = '操作未完成：' + (e as Error).message; this.controls = true;
    }
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
    // Portrait playback keeps the original aspect ratio with letterboxing.
    // Only the explicit fullscreen control changes the orientation.
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
  trackName(track: media.MediaDescription, index: number): string { return trackLabel(track, index); }
  subtitleDisabled(): boolean {
    return !this.tracks.some((t: media.MediaDescription) => Number(t['track_type']) === media.MediaType.MEDIA_TYPE_SUBTITLE && this.selectedTracks.includes(Number(t['track_index'])));
  }
  async restoreWindow(): Promise<void> {
    await this.windowChange;
    const w = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
    await w.setPreferredOrientation(window.Orientation.UNSPECIFIED);
    await w.setWindowLayoutFullScreen(false); await w.setWindowSystemBarEnable(['status', 'navigation']);
  }
  backRequested(): void {
    if (this.trackPanel >= 0) { this.trackPanel = -1; this.controls = true; this.autoHide(); }
    else this.close();
  }
  close(): void {
    if (this.disposed) return;
    this.disposed = true;
    clearTimeout(this.timer); clearTimeout(this.subtitleTimer); clearInterval(this.compatTimer);
    // Exit the UI immediately. Decoder cleanup must never trap the user on a
    // broken screen; its retained native window remains valid until release.
    this.onClose();
    this.releasePlayer().catch(() => {});
    this.restoreWindow().catch(() => {});
  }
  releasePlayer(): Promise<void> {
    if (!this.releasing) this.releasing = this.cleanupPlayer();
    return this.releasing;
  }
  async cleanupPlayer(): Promise<void> {
    if (this.opening) await this.opening;
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
    clearTimeout(this.timer); clearTimeout(this.subtitleTimer); clearInterval(this.compatTimer);
    this.releasePlayer().catch(() => {});
    if (restore) this.restoreWindow().catch(() => {});
  }
  clock(ms: number): string {
    let s = Math.floor(ms / 1000);
    return Math.floor(s / 60).toString() + ':' + (s % 60).toString().padStart(2, '0');
  }
  panelWidth(): number { return Math.min(340, Math.max(220, this.areaWidth - 32)); }
  panelHeight(): number { return Math.max(100, Math.min(390, this.areaHeight - 160)); }
  @Builder
  menuButton(label: string, selected: boolean, action: () => void) {
    Button(label).height(44).fontSize(14).fontColor(selected ? '#F6AE7A' : Color.White)
      .backgroundColor(selected ? '#CC544034' : '#99333333').padding({ left: 16, right: 16 }).onClick(action)
  }
  build() {
    // Stack.align aligns a component's own content, not its position in the
    // parent. Explicit positions keep every hit region in screen coordinates.
    Stack({ alignContent: Alignment.TopStart }) {
      XComponent({ id: 'bt-video', type: XComponentType.SURFACE, controller: this.surface })
        .width(this.surfaceWidth()).height(this.surfaceHeight())
        .position({ x: (this.areaWidth - this.surfaceWidth()) / 2, y: (this.areaHeight - this.surfaceHeight()) / 2 })
        .zIndex(0).hitTestBehavior(HitTestMode.None).onLoad(() => { this.start(); })
      // This plane covers black bars as well as the picture, in both orientations.
      Column() {}.width('100%').height('100%').position({ x: 0, y: 0 }).zIndex(1)
        .backgroundColor(Color.Transparent).hitTestBehavior(HitTestMode.Block)
        .onClick(() => { this.toggleControls(); }).accessibilityText('显示或隐藏播放控制')
      if (this.waiting && !this.errorText) {
        Row({ space: 10 }) { LoadingProgress().width(24).height(24).color(Color.White); Text('正在缓冲…').fontSize(14).fontColor(Color.White) }
          .padding(12).borderRadius(20).backgroundColor('#CC222222')
          .position({ x: Math.max(16, this.areaWidth / 2 - 68), y: Math.max(80, this.areaHeight / 2 + 52) }).zIndex(2).hitTestBehavior(HitTestMode.None)
      }
      if (this.errorText) {
        Column({ space: 8 }) {
          Text('播放未能启动').fontColor(Color.White).fontSize(17)
          Text(this.errorText).fontColor('#DDDDDD').fontSize(13).maxLines(5)
          Text('点右上角 × 返回文件列表').fontColor('#F6AE7A').fontSize(13)
        }.padding(20).width('90%').backgroundColor('#CC222222').borderRadius(20)
          .position({ x: '5%', y: 92 }).zIndex(7).hitTestBehavior(HitTestMode.None)
      }
      if (this.subtitle) {
        Text(this.subtitle).fontSize(20).fontColor(Color.White)
          .textShadow({ radius: 3, color: Color.Black, offsetX: 1, offsetY: 1 }).textAlign(TextAlign.Center)
          .width('90%').maxLines(4)
          .position({ x: '5%', y: Math.max(80, Math.min((this.areaHeight + this.surfaceHeight()) / 2 - 90, this.areaHeight - (this.controls ? 180 : 90))) })
          .zIndex(3).hitTestBehavior(HitTestMode.None)
      }
      if (this.controls) {
        Text(this.title).fontColor(Color.White).fontSize(14).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(Math.max(80, this.areaWidth - 112)).position({ x: 24, y: 34 }).zIndex(5).hitTestBehavior(HitTestMode.None)
        if (this.warningText && !this.errorText) {
          Text(this.warningText).fontColor('#CCCCCC').fontSize(11).maxLines(2).width('75%')
            .position({ x: 24, y: 66 }).zIndex(5).hitTestBehavior(HitTestMode.None)
        }
        if (!this.errorText && this.trackPanel < 0) {
          Row({ space: 26 }) {
            Button({ type: ButtonType.Circle }) {
              Image($r('app.media.player_back10')).width(32).height(32)
            }.width(56).height(56).backgroundColor('#88333333').border({ width: 1, color: '#66FFFFFF' })
              .enabled(this.playbackReady).accessibilityText('倒退 10 秒').onClick(() => { this.skipBy(-10000); })
            Button({ type: ButtonType.Circle }) {
              Image(this.playing ? $r('app.media.action_pause') : $r('app.media.action_play')).width(32).height(32).fillColor(Color.White)
            }.width(76).height(76).backgroundColor('#88333333').border({ width: 1, color: '#66FFFFFF' })
              .enabled(this.playbackReady).accessibilityText(this.playing ? '暂停' : '播放')
              .onClick(() => { this.control(this.playing ? 'pause' : 'play'); })
            Button({ type: ButtonType.Circle }) {
              Image($r('app.media.player_forward10')).width(32).height(32)
            }.width(56).height(56).backgroundColor('#88333333').border({ width: 1, color: '#66FFFFFF' })
              .enabled(this.playbackReady).accessibilityText('前进 10 秒').onClick(() => { this.skipBy(10000); })
          }.width(240).height(76).justifyContent(FlexAlign.Center)
            .position({ x: Math.max(0, this.areaWidth / 2 - 120), y: Math.max(90, this.areaHeight / 2 - 38) }).zIndex(5)
        }
        Column({ space: 10 }) {
          Row({ space: 6 }) {
            this.menuButton('音轨', this.trackPanel === 0, () => { this.trackPanel = this.trackPanel === 0 ? -1 : 0; clearTimeout(this.timer); })
            this.menuButton('字幕', this.trackPanel === 2, () => { this.trackPanel = this.trackPanel === 2 ? -1 : 2; clearTimeout(this.timer); })
            this.menuButton(this.fitCrop ? '铺满' : '适应', this.fitCrop, () => { this.fitCrop = !this.fitCrop; this.autoHide(); })
            this.menuButton(this.fullscreen ? '竖屏' : '横屏', this.fullscreen, () => { this.toggleFullscreen(); })
          }.width('100%').justifyContent(FlexAlign.End)
          Row({ space: 8 }) {
            Text(this.clock(this.playbackPosition)).fontSize(12).fontColor('#EEEEEE')
            Slider({ value: this.playbackPosition, min: 0, max: this.duration, step: 1000 })
              .layoutWeight(1).height(44).selectedColor('#F39A56').enabled(this.playbackReady)
              .onChange((value: number, mode: SliderChangeMode) => {
                clearTimeout(this.timer);
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) this.control('seek', value);
              })
            Text('−' + this.clock(Math.max(0, this.duration - this.playbackPosition))).fontSize(12).fontColor('#EEEEEE')
          }.width('100%').padding({ left: 14, right: 14 }).height(50).backgroundColor('#AA222222').borderRadius(28)
        }.width(Math.max(0, this.areaWidth - 40)).height(104)
          .position({ x: 20, y: Math.max(150, this.areaHeight - 132) }).zIndex(5)
      }
      if (this.trackPanel >= 0) {
        Column() {
          Row() {
            Text(this.trackPanel === 0 ? '音轨' : '字幕').fontSize(16).fontColor('#DDDDDD').layoutWeight(1)
            Button('完成').height(40).fontSize(14).fontColor(Color.White).backgroundColor(Color.Transparent)
              .accessibilityText('关闭选择菜单').onClick(() => { this.trackPanel = -1; this.controls = true; this.autoHide(); })
          }.width('100%').padding({ left: 16, right: 8 })
          Scroll() {
            Column() {
              if (this.trackPanel === 2) {
                Button() {
                  Row() { Text(this.subtitleDisabled() ? '✓' : '').width(26).fontColor('#F6AE7A'); Text('关闭字幕').fontColor(Color.White).layoutWeight(1) }
                }.width('100%').height(48).backgroundColor(Color.Transparent).borderRadius(0)
                  .onClick(async () => { await this.control('subtitleOff'); this.trackPanel = -1; this.autoHide(); })
              }
              ForEach(this.panelTracks(), (track: media.MediaDescription, index: number) => {
                Button() {
                  Row() {
                    Text(this.selectedTracks.includes(Number(track['track_index'])) ? '✓' : '').width(26).fontColor('#F6AE7A')
                    Text(this.trackName(track, index)).fontSize(15).fontColor(Color.White).maxLines(2).layoutWeight(1)
                  }.width('100%').padding({ left: 12, right: 12 })
                }.width('100%').constraintSize({ minHeight: 52 }).backgroundColor(Color.Transparent).borderRadius(0)
                  .onClick(async () => { await this.control('track', Number(track['track_index'])); this.trackPanel = -1; this.autoHide(); })
                Divider().color('#22FFFFFF').margin({ left: 38, right: 12 })
              }, (track: media.MediaDescription) => String(track['track_index']))
              if (!this.panelTracks().length) { Text(this.trackPanel === 0 ? '没有可选择的音轨' : '没有内嵌字幕').fontColor('#CCCCCC').fontSize(14).padding(18) }
            }.width('100%')
          }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
        }.width(this.panelWidth()).height(this.panelHeight()).padding({ bottom: 8 })
          .backgroundColor('#F02C2C30').borderRadius(24).border({ width: 1, color: '#44FFFFFF' })
          .position({ x: Math.max(16, this.areaWidth - this.panelWidth() - 20), y: Math.max(84, this.areaHeight - this.panelHeight() - 144) }).zIndex(20)
      }
      // Hide with the controls during playback; errors and menus retain an exit.
      if (this.controls || this.trackPanel >= 0 || this.errorText.length > 0) {
        Button('×', { type: ButtonType.Circle }).width(48).height(48).fontSize(34).fontColor(Color.White)
          .backgroundColor('#BB222222').border({ width: 1, color: '#66FFFFFF' })
          .position({ x: Math.max(12, this.areaWidth - 72), y: 20 }).zIndex(40)
          .accessibilityText('关闭播放器').onClick(() => { this.close(); })
      }
    }.width('100%').height('100%').backgroundColor(Color.Black).clip(true)
      .onAreaChange((_old: Area, area: Area) => {
        this.areaWidth = Math.max(1, Number(area.width)); this.areaHeight = Math.max(1, Number(area.height));
      })
  }
}
