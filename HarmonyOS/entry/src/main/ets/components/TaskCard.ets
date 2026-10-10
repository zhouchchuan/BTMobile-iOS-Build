import { TaskState, bytes } from '../model/Native';

@Component
export struct TaskCard {
  @ObjectLink task: TaskState;
  onOpen: (id: string) => void = () => {};
  onPause: (id: string, paused: boolean) => void = () => {};
  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.task.name || this.task.id).fontSize(17).fontWeight(FontWeight.Medium).maxLines(2).layoutWeight(1)
          .onClick(() => { this.onOpen(this.task.id); })
        Button(this.task.paused ? '继续' : '暂停').onClick(() => { this.onPause(this.task.id, this.task.paused); })
      }
      Progress({ value: this.task.progress * 100, total: 100, type: ProgressType.Linear }).color('#F39A56')
      Row() {
        Text(this.task.state + ' · ' + (this.task.progress * 100).toFixed(1) + '%').layoutWeight(1)
        Text('Peer ' + this.task.peers.toString())
      }
      if (this.task.checking) { Text('校验进度 ' + (this.task.checkProgress * 100).toFixed(1) + '%').fontSize(12) }
      Text(bytes(this.task.done) + ' / ' + bytes(this.task.total)).fontSize(12).fontColor('#666666').width('100%')
      Text('↓ ' + bytes(this.task.download) + '/s     ↑ ' + bytes(this.task.upload) + '/s').fontSize(13).fontColor('#666666').width('100%')
      if (this.task.error) { Text(this.task.error).fontColor(Color.Red).fontSize(12) }
    }.padding(16).borderRadius(20).backgroundColor(Color.White)
  }
}
