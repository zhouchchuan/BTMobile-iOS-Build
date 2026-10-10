import { TaskState, TorrentFile, PeerInfo, bytes } from '../model/Native';
import { IconButton } from './IconButton';

@Component
export struct TaskDetails {
  @ObjectLink task: TaskState;
  @Prop files: TorrentFile[] = [];
  @Prop peers: PeerInfo[] = [];
  @Prop trackers: string[] = [];
  @Prop peersOpen: boolean = false;
  @State filesOpen: boolean = false;
  @State trackersOpen: boolean = false;
  onClose: () => void = () => {};
  onPeers: () => void = () => {};
  onPause: () => void = () => {};
  onRefresh: () => void = () => {};
  onRemove: () => void = () => {};
  onPlay: (file: TorrentFile) => void = () => {};
  eta(): string {
    if (this.task.complete) return '已完成';
    if (this.task.download <= 0 || this.task.total <= 0) return '计算中';
    const seconds = Math.ceil((this.task.total - this.task.done) / this.task.download);
    return seconds >= 3600 ? Math.floor(seconds / 3600).toString() + ' 小时 ' + Math.floor(seconds % 3600 / 60).toString() + ' 分钟' : Math.floor(seconds / 60).toString() + ' 分 ' + (seconds % 60).toString() + ' 秒';
  }
  @Builder heading(title: string) { Text(title).fontSize(14).fontColor('#8E8E93').width('100%').padding({ left: 16, top: 10, bottom: 2 }) }
  @Builder row(title: string, value: string) {
    Row({ space: 12 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).constraintSize({ minWidth: 68 })
      Text(value).fontSize(15).fontColor('#EE9A64').textAlign(TextAlign.End).layoutWeight(1).copyOption(CopyOptions.InApp)
    }.width('100%').padding({ left: 18, right: 18, top: 14, bottom: 14 })
  }
  @Builder line() { Divider().color('#E5E5EA').margin({ left: 18, right: 18 }).width('86%') }
  build() {
    Column() {
      Row({ space: 12 }) {
        IconButton({ icon: $r('app.media.nav_back'), label: '返回任务', action: this.onClose })
        Text(this.task.name || '获取元数据…').fontSize(15).fontWeight(FontWeight.Medium).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }.width('100%').padding(16)
      Scroll() {
        Column({ space: 12 }) {
          Column() { this.row('状态', this.task.state) }.width('100%').borderRadius(22).backgroundColor(Color.White)
          this.heading('速度')
          Column() {
            this.row('下载', bytes(this.task.download) + '/s'); this.line()
            this.row('上传', bytes(this.task.upload) + '/s'); this.line()
            this.row('剩余时间', this.eta())
          }.width('100%').borderRadius(22).backgroundColor(Color.White)
          this.heading('下载进度')
          Column({ space: 12 }) {
            Text((this.task.progress * 100).toFixed(2) + '%').fontSize(16).fontColor('#EE9A64').width('100%')
            Progress({ value: this.task.progress * 100, total: 100, type: ProgressType.Linear }).color('#F39A56').width('100%')
            if (this.task.checking) { Text('校验进度 ' + (this.task.checkProgress * 100).toFixed(1) + '%').fontSize(12) }
          }.padding(18).width('100%').borderRadius(22).backgroundColor(Color.White)
          this.heading('基本信息')
          Column() {
            this.row('名称', this.task.name || '等待元数据'); this.line()
            this.row('Hash', this.task.id); this.line()
            this.row('添加时间', this.task.added > 0 ? new Date(this.task.added * 1000).toLocaleString() : '—')
          }.width('100%').borderRadius(22).backgroundColor(Color.White)
          this.heading('传输')
          Column() {
            this.row('目标大小', bytes(this.task.total)); this.line()
            this.row('已完成', bytes(this.task.done)); this.line()
            this.row('累计下载', bytes(this.task.downloaded)); this.line()
            this.row('累计上传', bytes(this.task.uploaded)); this.line()
            this.row('连接做种数', this.task.seeds.toString()); this.line()
            this.row('连接 Peer 数', this.task.peers.toString())
          }.width('100%').borderRadius(22).backgroundColor(Color.White)
          this.heading('Peer 连接')
          Column() {
            Row() {
              Text('Peers').fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
              Text(this.task.peers.toString() + ' 个 · ' + (this.peersOpen ? '收起 ﹀' : '展开 ›')).fontSize(14).fontColor('#EE9A64')
            }.width('100%').padding(18).onClick(() => { this.onPeers(); })
            if (this.peersOpen) {
              if (this.peers.length === 0) { Text('暂无活动连接').fontSize(13).fontColor('#8E8E93').padding(16) }
              ForEach(this.peers, (peer: PeerInfo) => {
                Text(peer.address + ' · ' + peer.client + '\n↓ ' + bytes(peer.download) + '/s  ↑ ' + bytes(peer.upload) + '/s  ' + (peer.progress * 100).toFixed(1) + '%')
                  .fontSize(11).width('100%').padding({ left: 16, right: 16, bottom: 10 })
              }, (peer: PeerInfo) => peer.address + ':' + peer.download.toString() + ':' + peer.upload.toString() + ':' + peer.progress.toString())
            }
          }.width('100%').borderRadius(22).backgroundColor(Color.White)
          this.heading('操作')
          Column() {
            this.row('Trackers', this.trackersOpen ? '收起 ﹀' : '展开 ›')
            if (this.trackersOpen) { ForEach(this.trackers, (url: string) => { Text(url).fontSize(12).copyOption(CopyOptions.InApp).width('100%').padding({ left: 18, right: 18, bottom: 12 }) }) }
          }.width('100%').borderRadius(22).backgroundColor(Color.White).onClick(() => { this.trackersOpen = !this.trackersOpen; })
          Column() {
            Row() { Text('文件').fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1); Text(this.filesOpen ? '收起 ﹀' : '展开 ›').fontSize(14).fontColor('#EE9A64') }.padding(18).width('100%').onClick(() => { this.filesOpen = !this.filesOpen; })
            if (this.filesOpen) {
              if (this.files.length === 0) { Text('等待获取文件列表').fontSize(13).padding(16) }
              ForEach(this.files, (file: TorrentFile) => {
                Column({ space: 5 }) {
                  Text(file.name).fontSize(13).width('100%')
                  Text(bytes(file.done) + ' / ' + bytes(file.size)).fontSize(11).fontColor('#8E8E93').width('100%')
                }.padding({ left: 18, right: 18, bottom: 16 }).width('100%').onClick(() => { this.onPlay(file); })
              }, (file: TorrentFile) => file.index.toString() + ':' + file.done.toString())
            }
          }.width('100%').borderRadius(22).backgroundColor(Color.White)
          if (this.task.error) { Text(this.task.error).fontColor('#D64545').fontSize(13).width('100%') }
        }.padding({ left: 16, right: 16, bottom: 24 }).width('100%')
      }.layoutWeight(1).width('100%')
      Row() {
        Row({ space: 4 }) {
          IconButton({ icon: this.task.paused ? $r('app.media.action_play') : $r('app.media.action_pause'), label: this.task.paused ? '继续任务' : '暂停任务', action: this.onPause })
          IconButton({ icon: $r('app.media.action_refresh'), preserveSvgStroke: true, label: '刷新任务与连接', action: this.onRefresh })
        }.padding(3).borderRadius(28).backgroundColor(Color.White)
        Blank()
        IconButton({ icon: $r('app.media.action_trash'), label: '移除任务', action: this.onRemove })
      }.padding(16).width('100%')
    }.width('100%').height('100%').backgroundColor('#F2F2F7')
  }
}
