import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';

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
  @State controls: boolean = true;
  @State playing: boolean = false;
  @State waiting: boolean = true;
  @State position: number = 0;
  @State duration: number = 1;
  @State subtitle: string = '';
  @State errorText: string = '';
  @State fullscreen: boolean = false;
  @State tracks: media.MediaDescription[] = [];
  @State showTracks: boolean = false;

  async start(): Promise<void> {
    try {
      this.player = await media.createAVPlayer();
      this.player.on('stateChange', async (state: string) => {
        if (!this.player) return;
        if (state === 'initialized') {
          this.player.surfaceId = this.surface.getXComponentSurfaceId();
          await this.player.prepare();
        } else if (state === 'prepared') {
          this.duration = Math.max(1, this.player.duration);
          this.tracks = await this.player.getTrackDescription();
          await this.player.play();
        } else if (state === 'playing') {
          this.playing = true;
          this.autoHide();
        } else if (state === 'paused' || state === 'completed') {
          this.playing = false; this.waiting = false; this.controls = true;
        }
      });
      this.player.on('timeUpdate', (time: number) => {
        if (time !== this.position) { this.waiting = false; this.lastProgress = Date.now(); }
        this.position = time;
      });
      this.player.on('bufferingUpdate', (type: number) => {
        if (type === media.BufferingInfoType.BUFFERING_START && Date.now() - this.lastProgress > 1200) this.waiting = true;
        if (type === media.BufferingInfoType.BUFFERING_END) this.waiting = false;
      });
      this.player.on('subtitleUpdate', (info: media.SubtitleInfo) => {
        clearTimeout(this.subtitleTimer); this.subtitle = info.text ?? '';
        this.subtitleTimer = setTimeout(() => { this.subtitle = ''; }, info.duration ?? 4000);
      });
      this.player.on('error', (error: Error) => {
        this.errorText = '无法播放：此编码或封装可能不受系统播放器支持。' + error.message;
        this.waiting = false;
      });
      if (this.source.startsWith('http://127.0.0.1:')) this.player.url = this.source;
      else {
        this.localFile = fs.openSync(this.source, fs.OpenMode.READ_ONLY);
        this.player.fdSrc = { fd: this.localFile.fd, offset: 0, length: fs.statSync(this.localFile.fd).size };
      }
    } catch (e) { this.errorText = (e as Error).message; this.waiting = false; }
  }
  autoHide(): void {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      if (this.playing && !this.showTracks) animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.controls = false; });
    }, 2000);
  }
  async rotate(): Promise<void> {
    let w = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
    this.fullscreen = !this.fullscreen;
    await w.setPreferredOrientation(this.fullscreen ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.UNSPECIFIED);
    await w.setWindowLayoutFullScreen(this.fullscreen);
    await w.setWindowSystemBarEnable(this.fullscreen ? [] : ['status', 'navigation']);
    this.autoHide();
  }
  async close(): Promise<void> {
    clearTimeout(this.timer); clearTimeout(this.subtitleTimer);
    if (this.player) { await this.player.release(); this.player = undefined; }
    if (this.localFile) { fs.closeSync(this.localFile); this.localFile = undefined; }
    let w = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
    await w.setPreferredOrientation(window.Orientation.UNSPECIFIED);
    await w.setWindowLayoutFullScreen(false);
    await w.setWindowSystemBarEnable(['status', 'navigation']);
    this.onClose();
  }
  aboutToDisappear(): void {
    clearTimeout(this.timer); clearTimeout(this.subtitleTimer);
    this.player?.release();
    if (this.localFile) fs.closeSync(this.localFile);
  }
  clock(ms: number): string {
    let s = Math.floor(ms / 1000);
    return Math.floor(s / 60).toString() + ':' + (s % 60).toString().padStart(2, '0');
  }
  build() {
    Stack({ alignContent: Alignment.Center }) {
      XComponent({ id: 'bt-video', type: XComponentType.SURFACE, controller: this.surface })
        .width('100%').height('100%').onLoad(() => { this.start(); })
      Column() {}.width('100%').height('100%').onClick(() => {
        animateTo({ duration: 180 }, () => { this.controls = !this.controls; }); this.autoHide();
      })
      if (this.waiting && this.errorText.length === 0) {
        Row({ space: 10 }) { LoadingProgress().width(28).height(28).color(Color.White); Text('正在缓冲…').fontColor(Color.White) }
          .padding(14).borderRadius(18).backgroundColor('#AA222222').hitTestBehavior(HitTestMode.None)
      }
      if (this.errorText.length > 0) { Text(this.errorText).fontColor(Color.White).padding(32) }
      Column() {
        Blank()
        Text(this.subtitle).fontSize(22).fontColor(Color.White).textShadow({ radius: 3, color: Color.Black, offsetX: 1, offsetY: 1 }).textAlign(TextAlign.Center).margin({ bottom: this.controls ? 100 : 28 })
      }.height('100%').width('90%').hitTestBehavior(HitTestMode.None)
      if (this.controls) {
        Column() {
          Row() {
            Button('关闭').onClick(() => { this.close(); })
            Text(this.title).fontColor(Color.White).fontSize(15).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).padding(12)
          }.padding(12)
          Blank()
          Row({ space: 24 }) {
            Button('−10秒').onClick(() => { this.player?.seek(Math.max(0, this.position - 10000)); })
            Button(this.playing ? '暂停' : '播放').onClick(() => { if(this.playing) this.player?.pause(); else this.player?.play(); this.autoHide(); })
            Button('+10秒').onClick(() => { this.player?.seek(Math.min(this.duration, this.position + 10000)); })
          }.justifyContent(FlexAlign.Center).width('100%')
          Blank()
          Column() {
            Slider({ value: this.position, min: 0, max: this.duration, step: 1000 }).onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) { this.waiting = true; this.subtitle = ''; this.player?.seek(value, media.SeekMode.SEEK_CLOSEST); this.autoHide(); }
            })
            Row() {
              Text(this.clock(this.position) + ' / ' + this.clock(this.duration)).fontColor(Color.White).layoutWeight(1)
              Button('字幕 / 音轨').onClick(() => { this.showTracks = !this.showTracks; })
              Button(this.fullscreen ? '竖屏' : '全屏').margin({ left: 8 }).onClick(() => { this.rotate(); })
            }
            if (this.showTracks) {
              Scroll() {
                Column() {
                  ForEach(this.tracks, (track: media.MediaDescription) => {
                    Button('轨道 ' + String(track['track_index']) + ' · ' + String(track['track_type']) + ' · ' + String(track['language'] ?? track['codec_mime'] ?? ''))
                      .margin(4).onClick(() => { this.player?.selectTrack(Number(track['track_index'])); this.showTracks = false; this.autoHide(); })
                  })
                }
              }.constraintSize({ maxHeight: 180 })
            }
          }.padding(16).backgroundColor('#88222222').borderRadius(20).margin(12)
        }.height('100%').width('100%').transition(TransitionEffect.OPACITY)
      }
    }.width('100%').height('100%').backgroundColor(Color.Black)
  }
}
