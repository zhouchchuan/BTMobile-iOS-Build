import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import promptAction from '@ohos.promptAction';
import { call, files, bytes, TaskInfo, TorrentFile } from '../model/Native';
import { Player } from '../components/Player';

interface FileItem { name: string; path: string; directory: boolean; size: number }
interface TextPart { value: string; link: boolean }

@Entry
@Component
struct Index {
  private root: string = '';
  private poll: number = -1;
  private polling: boolean = false;
  @State ready: boolean = false;
  @State tab: number = 0;
  @State version: string = '';
  @State tasks: TaskInfo[] = [];
  @State magnet: string = '';
  @State status: string = '正在启动原生下载核心…';
  @State current: string = '';
  @State entries: FileItem[] = [];
  @State taskFiles: TorrentFile[] = [];
  @State selectedTask: string = '';
  @State playerSource: string = '';
  @State playerTitle: string = '';
  @State textPath: string = '';
  @State text: string = '';
  @State parts: TextPart[] = [];
  @State editing: boolean = false;
  @State archivePath: string = '';
  @State password: string = '';
  @State extracting: boolean = false;
  @State percent: number = 0;

  async aboutToAppear(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    this.root = context.filesDir + '/Download';
    if (!fs.accessSync(this.root)) fs.mkdirSync(this.root, true);
    try {
      const result = await call({ op: 'init', root: this.root });
      this.version = result.version ?? ''; this.ready = true; this.status = '';
      await this.refresh();
      this.poll = setInterval(() => { this.refresh(); }, 1000);
    } catch (e) { this.status = '核心启动失败：' + (e as Error).message; }
    this.list();
  }
  aboutToDisappear(): void { clearInterval(this.poll); }
  async refresh(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      this.tasks = (await call({ op: 'tasks' })).items ?? [];
      if (this.selectedTask) this.taskFiles = await files(this.selectedTask);
      if (this.extracting) this.percent = (await call({ op: 'archiveProgress' })).percent ?? 0;
    } catch (e) { this.status = (e as Error).message; }
    finally { this.polling = false; }
  }
  fail(e: Error): void { this.status = e.message; promptAction.showToast({ message: e.message, duration: 3000 }); }
  async add(): Promise<void> {
    if (!this.magnet.trim() || !this.ready) return;
    try { await call({ op: 'add', uri: this.magnet.trim() }); this.magnet = ''; this.status = ''; await this.refresh(); }
    catch(e) { this.fail(e as Error); }
  }
  list(): void {
    try {
      this.entries = fs.listFileSync(this.root + '/' + this.current).filter((name: string) => name !== '.state').map((name: string): FileItem => {
        const path = this.current ? this.current + '/' + name : name;
        const stat = fs.statSync(this.root + '/' + path);
        return { name: name, path: path, directory: stat.isDirectory(), size: stat.size };
      }).sort((a: FileItem, b: FileItem) => a.directory !== b.directory ? a.directory ? -1 : 1 : a.name.localeCompare(b.name));
    } catch(e) { this.fail(e as Error); }
  }
  async importFile(): Promise<void> {
    try {
      let result = await new picker.DocumentViewPicker().select({ maxSelectNumber: 1 });
      if (result.length === 0) return;
      let name = decodeURIComponent(result[0].split('/').pop() ?? 'imported-file');
      if (!name || name.includes('/') || name.includes('\\') || name === '..') throw new Error('文件名无效');
      const path = this.root + '/' + this.current + '/' + name;
      if (fs.accessSync(path)) throw new Error('同名文件已存在，请先重命名');
      const input = fs.openSync(result[0], fs.OpenMode.READ_ONLY);
      try { fs.copyFileSync(input.fd, path); } finally { fs.closeSync(input); }
      this.list();
    } catch(e) { this.fail(e as Error); }
  }
  splitText(): void {
    const pattern = /https?:\/\/[^\s<>"，。；）】]+/g;
    let result: TextPart[] = [];
    let last = 0;
    let match = pattern.exec(this.text);
    while(match !== null) {
      if (match.index > last) result.push({ value: this.text.slice(last, match.index), link: false });
      result.push({ value: match[0], link: true }); last = match.index + match[0].length;
      match = pattern.exec(this.text);
    }
    if (last < this.text.length) result.push({ value: this.text.slice(last), link: false });
    this.parts = result;
  }
  async open(item: FileItem): Promise<void> {
    if(item.directory) { this.current = item.path; this.list(); return; }
    const extension = item.name.split('.').pop()?.toLowerCase() ?? '';
    try {
      if (extension === 'torrent') { await call({ op: 'add', uri: item.path }); this.tab = 0; await this.refresh(); }
      else if (['txt','log','md','srt','ass','json','csv'].includes(extension)) {
        if (item.size > 4 * 1024 * 1024) throw new Error('此文本超过 4 MiB，请使用外部编辑器');
        this.textPath = item.path; this.text = fs.readTextSync(this.root + '/' + item.path); this.editing = false; this.splitText();
      } else if (['zip','7z','rar','tar','gz','xz','bz2','001'].includes(extension)) {
        this.archivePath = item.path; this.password = '';
      } else if (['mp4','mkv','avi','mov','webm','m4v','mp3','flac','m4a','aac','ogg'].includes(extension)) {
        const match = await call({ op: 'resolve', path: item.path });
        if (match.id && !match.complete) {
          const stream = await call({ op: 'stream', id: match.id, index: match.index }); this.playerSource = stream.url ?? '';
        } else this.playerSource = this.root + '/' + item.path;
        this.playerTitle = item.name;
      } else throw new Error('当前版本暂不预览此类文件');
    } catch(e) { this.fail(e as Error); }
  }
  async playTask(file: TorrentFile): Promise<void> {
    try {
      if (file.done >= file.size) { await this.open({ name: file.name, path: file.name, size: file.size, directory: false }); return; }
      const result = await call({ op: 'stream', id: this.selectedTask, index: file.index });
      this.playerTitle = file.name; this.playerSource = result.url ?? '';
    } catch(e) { this.fail(e as Error); }
  }
  async extract(): Promise<void> {
    this.extracting = true; this.percent = 0;
    try {
      await call({ op: 'extract', path: this.archivePath, output: this.archivePath + '-解压-' + Date.now().toString(), password: this.password });
      this.archivePath = ''; this.password = ''; this.list(); promptAction.showToast({ message: '解压完成' });
    } catch(e) { this.fail(e as Error); }
    finally { this.extracting = false; }
  }
  icon(item: FileItem): string {
    if (item.directory) return '📁';
    const e = item.name.split('.').pop()?.toLowerCase() ?? '';
    if (['zip','7z','rar','tar','gz','xz','001'].includes(e)) return '📦';
    if (['mp4','mkv','mov','avi','webm'].includes(e)) return '🎬';
    if (['mp3','m4a','flac','aac'].includes(e)) return '🎵';
    if (['png','jpg','jpeg','webp'].includes(e)) return '🖼';
    return '📄';
  }
  build() {
    Stack() {
      Column() {
        Row() { Text('BTMobile').fontSize(30).fontWeight(FontWeight.Bold).layoutWeight(1); Text('鸿蒙 · 0.1.0').fontSize(13).fontColor('#888888') }.padding(20)
        if (this.status) { Text(this.status).fontColor('#BB4B18').fontSize(13).padding(10) }
        if (this.tab === 0) {
          Row({ space: 8 }) { TextInput({ placeholder: '粘贴磁力链接', text: this.magnet }).onChange((v: string) => { this.magnet = v; }).layoutWeight(1); Button('添加').enabled(this.ready).backgroundColor('#F39A56').onClick(() => { this.add(); }) }.padding(16)
          List({ space: 12 }) {
            ForEach(this.tasks, (task: TaskInfo) => {
              ListItem() {
                Column({ space: 8 }) {
                  Row() {
                    Text(task.name || task.id).fontSize(17).fontWeight(FontWeight.Medium).maxLines(2).layoutWeight(1).onClick(async () => { this.selectedTask = task.id; this.taskFiles = await files(task.id); })
                    Button(task.paused ? '继续' : '暂停').onClick(async () => { try { await call({ op: task.paused ? 'resume' : 'pause', id: task.id }); await this.refresh(); } catch(e) { this.fail(e as Error); } })
                  }
                  Progress({ value: task.progress * 100, total: 100, type: ProgressType.Linear }).color('#F39A56')
                  Row() { Text(task.state + ' · ' + (task.progress * 100).toFixed(1) + '%').layoutWeight(1); Text('Peer ' + task.peers.toString()) }
                  Text('↓ ' + bytes(task.download) + '/s     ↑ ' + bytes(task.upload) + '/s').fontSize(13).fontColor('#666666').width('100%')
                  if (task.error) { Text(task.error).fontColor(Color.Red).fontSize(12) }
                }.padding(16).borderRadius(20).backgroundColor(Color.White)
              }
            }, (t: TaskInfo) => t.id)
          }.layoutWeight(1).padding({ left: 16, right: 16 })
        } else if (this.tab === 1) {
          Row() { Button('上一级').enabled(this.current.length > 0).onClick(() => { this.current = this.current.split('/').slice(0,-1).join('/'); this.list(); }); Text(this.current || '下载目录').fontSize(14).layoutWeight(1).padding(10); Button('导入').onClick(() => { this.importFile(); }); Button('刷新').onClick(() => { this.list(); }) }.padding(12)
          List() {
            ForEach(this.entries, (item: FileItem) => {
              ListItem() { Row({ space: 12 }) { Text(this.icon(item)).fontSize(28); Column({ space: 5 }) { Text(item.name).fontSize(16).width('100%'); Text(item.directory ? '文件夹' : bytes(item.size)).fontSize(12).fontColor('#888888').width('100%') }.layoutWeight(1) }.padding(16).onClick(() => { this.open(item); }) }
            }, (item: FileItem) => item.path)
          }.layoutWeight(1)
        } else {
          Scroll() {
            Column({ space: 16 }) {
              Text('原生下载核心').fontSize(20).fontWeight(FontWeight.Bold)
              Text('libtorrent ' + this.version + '\nTCP / μTP · DHT · Tracker · 断点续传').fontSize(15)
              Text('V0.1.0 开发验证版\n当前包未签名，需调试 Profile 与真机 UDID 后安装。后台连续任务、系统编解码兼容性及性能需要真机验证。').fontSize(14).fontColor('#666666')
              Text('下载目录\n' + this.root).fontSize(12)
              Text('基线：iOS V1.2.5\n订阅、WebDAV、完整 VLC 编码与压缩格式支持仍在移植，不代表与 iOS 功能完全等同。').fontSize(14).fontColor('#666666')
            }.padding(24).width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1)
        }
        Row() {
          Button('任务').layoutWeight(1).onClick(() => { this.tab = 0; })
          Button('文件').layoutWeight(1).onClick(() => { this.tab = 1; this.list(); })
          Button('设置').layoutWeight(1).onClick(() => { this.tab = 2; })
        }.padding(16).width('100%')
      }.height('100%').width('100%').backgroundColor('#F5F5F7')
      if (this.selectedTask) {
        Column() {
          Row() { Text('任务文件 · 点击视频边下边播').layoutWeight(1); Button('关闭').onClick(() => { this.selectedTask = ''; }) }.padding(16)
          List() { ForEach(this.taskFiles, (file: TorrentFile) => { ListItem() { Column({ space: 8 }) { Text(file.name).width('100%'); Text(bytes(file.done) + ' / ' + bytes(file.size)).fontSize(12).fontColor('#777777').width('100%') }.padding(16).onClick(() => { this.playTask(file); }) } }) }.layoutWeight(1)
        }.width('100%').height('100%').backgroundColor(Color.White)
      }
      if (this.textPath) {
        Column() {
          Row() { Button('返回').onClick(() => { this.textPath = ''; }); Text(this.textPath.split('/').pop() ?? '文本').fontSize(16).maxLines(1).layoutWeight(1).padding(12); Button(this.editing ? '保存' : '编辑').onClick(() => {
            if(this.editing) {
              try { const f = fs.openSync(this.root + '/' + this.textPath, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC); try { fs.writeSync(f.fd, this.text); } finally { fs.closeSync(f); } this.splitText(); this.editing = false; } catch(e) { this.fail(e as Error); }
            } else this.editing = true;
          }) }.padding(12)
          if (this.editing) { TextArea({ text: this.text }).onChange((v: string) => { this.text = v; }).fontSize(14).layoutWeight(1).width('100%') }
          else {
            Scroll() {
              Text() {
                ForEach(this.parts, (part: TextPart) => {
                  Span(part.value).fontColor(part.link ? '#007AFF' : '#202020').decoration({ type: part.link ? TextDecorationType.Underline : TextDecorationType.None }).onClick(() => {
                    if (part.link) (getContext(this) as common.UIAbilityContext).startAbility({ action: 'ohos.want.action.viewData', uri: part.value }).catch((e: Error) => { this.fail(e); });
                  })
                })
              }.fontSize(14).lineHeight(22).width('100%').padding(16)
            }.layoutWeight(1).width('100%')
          }
        }.width('100%').height('100%').backgroundColor(Color.White)
      }
      if (this.archivePath) {
        Column({ space: 16 }) {
          Text('解压压缩包').fontSize(20).fontWeight(FontWeight.Bold)
          Text('如已加密，请输入密码；未加密可留空。').fontSize(14)
          TextInput({ placeholder: '解压密码（可选）', text: this.password }).type(InputType.Password).enabled(!this.extracting).onChange((v: string) => { this.password = v; })
          if (this.extracting) { Progress({ value: Math.max(0,this.percent), total: 100 }); Text('解压中 ' + Math.max(0,this.percent).toString() + '%') }
          Row({ space: 16 }) { Button('取消').onClick(() => { if(this.extracting) call({ op: 'cancelArchive' }); else this.archivePath = ''; }); Button('解压').enabled(!this.extracting).onClick(() => { this.extract(); }) }
        }.padding(24).width('90%').backgroundColor(Color.White).borderRadius(24).shadow({ radius: 30, color: '#666666' })
      }
      if (this.playerSource) {
        Player({ source: this.playerSource, title: this.playerTitle, onClose: () => { this.playerSource = ''; call({ op: 'stopStream' }); } })
      }
    }.width('100%').height('100%')
  }
}
