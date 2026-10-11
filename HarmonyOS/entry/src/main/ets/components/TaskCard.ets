import { TaskState, bytes } from '../model/Native';

@Component
export struct TaskCard {
  @ObjectLink task: TaskState;
  onOpen: (id: string) => void = () => {};
  onPause: (id: string, paused: boolean) => void = () => {};
  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.task.name || this.task.id).fontSize(14).minFontSize(12).maxFontSize(14).heightAdaptivePolicy(TextHeightAdaptivePolicy.MIN_FONT_SIZE_FIRST).fontWeight(FontWeight.Medium).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          .onClick(() => { this.onOpen(this.task.id); })
        Text('›').fontSize(25).fontColor($r('app.color.text_tertiary')).margin({ left: 10 })
      }
      Text(bytes(this.task.done) + ' / ' + bytes(this.task.total) + ' (' + (this.task.progress * 100).toFixed(2) + '%)').fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      Text(this.task.state + ' · ↓ ' + bytes(this.task.download) + '/s · ↑ ' + bytes(this.task.upload) + '/s · Peer ' + this.task.peers.toString()).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
      if (this.task.checking) { Text('校验进度 ' + (this.task.checkProgress * 100).toFixed(1) + '%').fontSize(12) }
      Progress({ value: this.task.progress * 100, total: 100, type: ProgressType.Linear }).color('#F39A56').style({ strokeWidth: 3 }).width('100%')
      if (this.task.error) { Text(this.task.error).fontColor(Color.Red).fontSize(12) }
    }.padding(16).borderRadius(20).backgroundColor($r('app.color.card_background')).border({ width: 0.5, color: $r('app.color.separator') }).onClick(() => { this.onOpen(this.task.id); })
  }
}
