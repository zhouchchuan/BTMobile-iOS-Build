import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import promptAction from '@ohos.promptAction';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import preferences from '@ohos.data.preferences';
import { call, files, peers, bytes, TaskInfo, TaskState, TorrentFile, PeerInfo } from '../model/Native';
import { Player } from '../components/Player';
import { TaskCard } from '../components/TaskCard';
import { SettingsPanel } from '../components/SettingsPanel';

interface FileItem { name: string; path: string; directory: boolean; size: number }
interface TextPart { value: string; link: boolean }

@Entry
@Component
struct Index {
  private root: string = '';
  private poll: number = -1;
  private polling: boolean = false;
  private detailPolling: boolean = false;
  private deletionRevision: number = 0;
  private pageVisible: boolean = false;
  @StorageLink('btmobileForeground') @Watch('foregroundChanged') foreground: boolean = true;
  private backgroundActive: boolean = false;
  private backgroundBusy: boolean = false;
  private backgroundRetryAfter: number = 0;
  private preferencesStore: preferences.Preferences | undefined = undefined;
  private preferenceWrite: Promise<void> = Promise.resolve();
  @State allowBackground: boolean = false;
  @State backgroundMessage: string = '后台传输未启用';
  @State networkSummary: string = '正在读取网络状态…';
  @State networkDetail: string = '';
  @State actionPath: string = '';
  @State newName: string = '';
  @State imagePath: string = '';
  @State ready: boolean = false;
  @State tab: number = 0;
  @State version: string = '';
  @State tasks: TaskState[] = [];
  @State magnet: string = '';
  @State status: string = '正在启动原生下载核心…';
  @State current: string = '';
  @State entries: FileItem[] = [];
  @State taskFiles: TorrentFile[] = [];
  @State peerRows: PeerInfo[] = [];
  @State showPeers: boolean = false;
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
  @State archiveError: string = '';
  @State removeTaskId: string = '';

  async aboutToAppear(): Promise<void> {
    this.pageVisible = true;
    const context = getContext(this) as common.UIAbilityContext;
    this.root = context.filesDir + '/Download';
    if (!fs.accessSync(this.root)) fs.mkdirSync(this.root, true);
    try {
      this.preferencesStore = await preferences.getPreferences(context, { name: 'btmobile-settings' });
      this.allowBackground = (await this.preferencesStore.get('allowBackground', false)) as boolean;
    } catch (e) { this.backgroundMessage = '无法读取后台设置：' + (e as Error).message; }
    try {
      const result = await call({ op: 'init', root: this.root });
      this.version = result.version ?? ''; this.ready = true; this.status = '';
      await this.refresh();
      if (this.pageVisible) { clearInterval(this.poll); this.poll = setInterval(() => { this.refresh(); }, 1000); }
    } catch (e) { this.status = '核心启动失败：' + (e as Error).message; }
    this.list();
  }
  aboutToDisappear(): void { this.pageVisible = false; clearInterval(this.poll); this.poll = -1; }
  foregroundChanged(): void { if (this.foreground && this.ready && this.pageVisible) this.refresh(); }
  async refresh(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      const result = await call({ op: 'tasks' });
      if (!this.pageVisible) return;
      const old = this.tasks;
      if ((result.deletionRevision ?? 0) > this.deletionRevision) {
        this.deletionRevision = result.deletionRevision ?? 0;
        this.status = result.deletionMessage ?? ''; this.list();
      }
      this.tasks = (result.items ?? []).map((value: TaskInfo): TaskState => {
        const row = old.find((item: TaskState) => item.id === value.id) ?? new TaskState();
        row.update(value); return row;
      });
      if (result.network) {
        const net = result.network;
        const connection = net.networkCode !== 0 ? '网络不可用 (' + net.networkCode.toString() + ')' : net.listening ? 'BT 已监听 ' + net.listenPort.toString() : 'BT 等待监听 ' + net.configuredPort.toString();
        this.networkSummary = connection + ' · DHT ' + net.dhtNodes.toString() + ' 节点 · Tracker 响应 ' + net.trackerReplies.toString();
        this.networkDetail = '网络接口 ' + net.interfaces.toString() + ' · 路由 ' + net.routes.toString() + ' · Tracker 返回 Peer ' + net.trackerPeers.toString() + '\n已获取磁力元数据 ' + net.metadataReceived.toString() + ' · 网络恢复 ' + net.recoveries.toString();
        if (net.listenError) this.networkDetail += '\n' + net.listenError;
        if (net.trackerError) this.networkDetail += '\n' + net.trackerError;
      }
      // OS authorization and file/Peer detail calls must not block task refresh.
      this.syncBackground();
      this.refreshDetails();
    } catch (e) { this.status = (e as Error).message; }
    finally { this.polling = false; }
  }
  fail(e: Error): void { this.status = e.message; promptAction.showToast({ message: e.message, duration: 3000 }); }
  async refreshDetails(): Promise<void> {
    if (this.detailPolling) return;
    this.detailPolling = true;
    try {
      if (this.extracting) this.percent = Math.max(0, (await call({ op: 'archiveProgress' })).percent ?? 0);
      const selected = this.selectedTask;
      if (selected) {
        const items = await files(selected);
        if (this.selectedTask === selected) this.taskFiles = items;
        if (this.showPeers && this.selectedTask === selected) {
          const rows = await peers(selected);
          if (this.selectedTask === selected && this.showPeers) this.peerRows = rows;
        }
      }
    } catch(e) { this.status = (e as Error).message; }
    finally { this.detailPolling = false; }
  }
  setAllowBackground(value: boolean): void {
    this.allowBackground = value;
    this.backgroundRetryAfter = 0;
    this.preferenceWrite = this.preferenceWrite.then(async () => {
      const store = this.preferencesStore;
      if (!store) throw new Error('设置存储尚未就绪');
      await store.put('allowBackground', value); await store.flush();
    }).catch((e: Error) => { this.fail(new Error('后台设置保存失败：' + e.message)); });
    this.syncBackground();
  }
  async syncBackground(): Promise<void> {
    if (this.backgroundBusy || Date.now() < this.backgroundRetryAfter) return;
    const active = this.allowBackground && this.tasks.some((task: TaskState) => task.active);
    if (active === this.backgroundActive) {
      this.backgroundMessage = active ? '后台持续传输已获系统批准' : this.allowBackground ? '设置已保存；有活动任务时申请后台传输' : '后台传输未启用';
      return;
    }
    this.backgroundBusy = true;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      if (active) {
        const agent = await wantAgent.getWantAgent({ wants: [{ bundleName: 'com.mxmall123.btmobile.hm', abilityName: 'EntryAbility' }], operationType: wantAgent.OperationType.START_ABILITY, requestCode: 1, wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
        await backgroundTaskManager.startBackgroundRunning(context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      } else await backgroundTaskManager.stopBackgroundRunning(context);
      this.backgroundActive = active;
      this.backgroundMessage = active ? '后台持续传输已获系统批准' : '后台持续传输已停止';
    } catch(e) {
      // Keep the user's saved preference; a system denial is a separate state.
      this.backgroundRetryAfter = Date.now() + 60000;
      this.backgroundMessage = '设置已保存，但系统后台传输操作失败：' + (e as Error).message;
    } finally { this.backgroundBusy = false; }
  }
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
      } else if (['png','jpg','jpeg','webp','gif'].includes(extension)) {
        this.imagePath = this.root + '/' + item.path;
      } else if (['zip','7z','rar','tar','gz','xz','bz2','001'].includes(extension)) {
        this.archivePath = item.path; this.password = ''; this.archiveError = ''; this.percent = 0;
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
    if (this.extracting || !this.archivePath) return;
    this.extracting = true; this.percent = 0; this.archiveError = '';
    try {
      await call({ op: 'extract', path: this.archivePath, output: this.archivePath + '-解压-' + Date.now().toString(), password: this.password });
      this.archivePath = ''; this.password = ''; this.list(); promptAction.showToast({ message: '解压完成' });
    } catch(e) { this.archiveError = (e as Error).message; this.list(); }
    finally { this.extracting = false; }
  }
  async removeTask(deleteData: boolean): Promise<void> {
    const id = this.removeTaskId;
    if (!id) return;
    try {
      await call({ op: 'remove', id: id, deleteData: deleteData });
      if (this.selectedTask === id) this.selectedTask = '';
      this.removeTaskId = ''; await this.refresh(); this.list();
      promptAction.showToast({ message: deleteData ? '任务已移除，正在清理该任务下载的数据' : '任务已移除，下载文件已保留' });
    } catch(e) { this.fail(e as Error); }
  }
  confirmDeleteTask(): void {
    AlertDialog.show({ title: '删除任务及下载数据？', message: '将停止此任务并删除它下载的文件。此操作无法撤销；该目录中其他文件和已解压的文件不在清理范围内。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除任务和数据', action: () => { this.removeTask(true); } } });
  }
  confirmDeleteFile(): void {
    const path = this.actionPath;
    AlertDialog.show({ title: '删除文件或文件夹？', message: path + '\n文件夹中的内容也会删除，且无法撤销。仍属于下载任务的文件，请从任务管理中删除。',
      primaryButton: { value: '取消', action: () => {} }, secondaryButton: { value: '删除', action: async () => {
        try { await call({ op: 'deleteFile', path: path }); this.actionPath = ''; this.list(); promptAction.showToast({ message: '已删除' }); }
        catch(e) { this.fail(e as Error); }
      } } });
  }
  @Builder
  swipeRemove(id: string) {
    Button('移除').backgroundColor('#D83B35').margin(8).onClick(() => { this.removeTaskId = id; })
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
        Row() { Text('BTMobile').fontSize(30).fontWeight(FontWeight.Bold).layoutWeight(1); Text('鸿蒙 · 0.1.2').fontSize(13).fontColor('#888888') }.padding(20)
        if (this.status) { Text(this.status).fontColor('#BB4B18').fontSize(13).padding(10) }
        if (this.extracting && !this.archivePath) { Text('压缩处理中 ' + Math.max(0,this.percent).toString() + '%').fontSize(14).padding(8) }
        if (this.tab === 0) {
          Text(this.networkSummary).fontSize(12).fontColor('#666666').padding({ left: 16, right: 16 })
          Row({ space: 8 }) { TextInput({ placeholder: '粘贴磁力链接', text: this.magnet }).onChange((v: string) => { this.magnet = v; }).layoutWeight(1); Button('添加').enabled(this.ready).backgroundColor('#F39A56').onClick(() => { this.add(); }) }.padding(16)
          List({ space: 12 }) {
            ForEach(this.tasks, (task: TaskState) => {
              ListItem() {
                TaskCard({ task: task, onOpen: (id: string) => { this.selectedTask = id; this.refreshDetails(); },
                  onPause: async (id: string, paused: boolean) => { try { await call({ op: paused ? 'resume' : 'pause', id: id }); await this.refresh(); } catch(e) { this.fail(e as Error); } } })
              }.swipeAction({ end: this.swipeRemove.bind(this, task.id) })
            }, (t: TaskState) => t.id)
          }.layoutWeight(1).padding({ left: 16, right: 16 })
        } else if (this.tab === 1) {
          Row() { Button('上一级').enabled(this.current.length > 0).onClick(() => { this.current = this.current.split('/').slice(0,-1).join('/'); this.list(); }); Text(this.current || '下载目录').fontSize(14).layoutWeight(1).padding(10); Button('导入').onClick(() => { this.importFile(); }); Button('刷新').onClick(() => { this.list(); }) }.padding(12)
          List() {
            ForEach(this.entries, (item: FileItem) => {
              ListItem() { Row({ space: 12 }) { Text(this.icon(item)).fontSize(28); Column({ space: 5 }) { Text(item.name).fontSize(16).width('100%'); Text(item.directory ? '文件夹' : bytes(item.size)).fontSize(12).fontColor('#888888').width('100%') }.layoutWeight(1).onClick(() => { this.open(item); }); Button('⋯').onClick(() => { this.actionPath = item.path; this.newName = item.name; }) }.padding(16) }
            }, (item: FileItem) => item.path)
          }.layoutWeight(1)
        } else {
          Scroll() {
            Column({ space: 16 }) {
              Text('原生下载核心').fontSize(20).fontWeight(FontWeight.Bold)
              Text('libtorrent ' + this.version + '\nTCP / μTP · DHT · Tracker · 断点续传').fontSize(15)
              Text('Peer 客户端标志：Htorrent 0.1.2').fontSize(14)
              Text(this.networkSummary).fontSize(14)
              Text(this.networkDetail).fontSize(12).fontColor('#666666')
              Row() { Text('允许后台下载 / 做种').layoutWeight(1); Toggle({ type: ToggleType.Switch, isOn: this.allowBackground }).onChange((value: boolean) => { this.setAllowBackground(value); }) }
              Text(this.backgroundMessage).fontSize(13).fontColor('#666666')
              Text('后台传输使用系统持续任务通知，无活动任务时自动停止。需要真机验证系统授权与锁屏表现。').fontSize(13).fontColor('#666666')
              SettingsPanel({ onSaved: () => { this.refresh(); } })
              Text('V0.1.2 调试版\n调试安装需要匹配设备的签名与 Profile。系统编解码兼容性及性能需要真机验证。').fontSize(14).fontColor('#666666')
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
          Row({ space: 12 }) {
            Button(this.showPeers ? '收起 Peer' : '查看 Peer').onClick(async () => { this.showPeers = !this.showPeers; if(this.showPeers) this.peerRows = await peers(this.selectedTask); })
            Button('移除任务').onClick(() => {
              this.removeTaskId = this.selectedTask;
            })
          }
          if (this.showPeers) {
            Scroll() { Column({ space: 6 }) { ForEach(this.peerRows, (p: PeerInfo) => { Text(p.address + ' · ' + p.client + ' · ↓' + bytes(p.download) + ' ↑' + bytes(p.upload)).fontSize(11).width('100%') }) }.padding(12) }.constraintSize({ maxHeight: 180 }).width('100%')
          }
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
        Scroll() {
        Column({ space: 16 }) {
          Text('解压压缩包').fontSize(20).fontWeight(FontWeight.Bold)
          Text('如已加密，请输入密码；未加密可留空。').fontSize(14)
          TextInput({ placeholder: '解压密码（可选）', text: this.password }).type(InputType.Password).enabled(!this.extracting).onChange((v: string) => { this.password = v; })
          if (this.archiveError) { Text(this.archiveError).fontColor('#B54020').fontSize(14).width('100%'); Text('失败后可修改密码重试；已写出的部分文件会保留在对应解压目录。').fontSize(12) }
          if (this.extracting) { Progress({ value: Math.max(0,this.percent), total: 100 }); Text('解压中 ' + Math.max(0,this.percent).toString() + '%') }
          Row({ space: 16 }) { Button('取消').onClick(() => { if(this.extracting) call({ op: 'cancelArchive' }); else this.archivePath = ''; }); Button('解压').enabled(!this.extracting).onClick(() => { this.extract(); }) }
        }.padding(24).width('100%')
        }.width('90%').constraintSize({ maxHeight: '80%' }).backgroundColor(Color.White).borderRadius(24).shadow({ radius: 30, color: '#666666' })
      }
      if (this.actionPath) {
        Column({ space: 16 }) {
          Text('文件操作').fontSize(20)
          TextInput({ text: this.newName }).onChange((v: string) => { this.newName = v; })
          Button('重命名').onClick(() => {
            try {
              if (!this.newName.trim() || this.newName.includes('/') || this.newName.includes('\\') || this.newName === '.' || this.newName === '..') throw new Error('文件名无效');
              const dir = this.actionPath.split('/').slice(0,-1).join('/');
              const output = this.root + '/' + dir + '/' + this.newName;
              if(fs.accessSync(output)) throw new Error('目标文件已存在');
              fs.renameSync(this.root + '/' + this.actionPath, output); this.actionPath = ''; this.list();
            } catch(e) { this.fail(e as Error); }
          })
          Button('压缩为 ZIP').onClick(async () => {
            const input = this.actionPath; this.actionPath = ''; this.extracting = true;
            try { await call({ op: 'compress', path: input, output: input + '-' + Date.now().toString() + '.zip' }); this.list(); promptAction.showToast({ message: '压缩完成' }); }
            catch(e) { this.fail(e as Error); } finally { this.extracting = false; }
          })
          Text('正在下载或做种的文件请勿重命名，以免任务找不到文件。').fontSize(12).fontColor('#BB4B18')
          Button('删除文件 / 文件夹').backgroundColor('#D83B35').onClick(() => { this.confirmDeleteFile(); })
          Button('取消').onClick(() => { this.actionPath = ''; })
        }.padding(24).width('90%').backgroundColor(Color.White).borderRadius(24)
      }
      if (this.imagePath) {
        Column() { Button('关闭图片').onClick(() => { this.imagePath = ''; }); Image('file://' + this.imagePath).objectFit(ImageFit.Contain).layoutWeight(1).width('100%') }.width('100%').height('100%').backgroundColor(Color.Black)
      }
      if (this.playerSource) {
        Player({ source: this.playerSource, title: this.playerTitle, onClose: () => { this.playerSource = ''; call({ op: 'stopStream' }); } })
      }
      if (this.removeTaskId) {
        Column({ space: 18 }) {
          Text('移除任务').fontSize(20).fontWeight(FontWeight.Bold)
          Text(this.tasks.find((task: TaskState) => task.id === this.removeTaskId)?.name ?? '当前任务').maxLines(3).fontSize(14)
          Button('仅移除任务，保留文件').onClick(() => { this.removeTask(false); })
          Button('移除任务并删除下载数据').backgroundColor('#D83B35').onClick(() => { this.confirmDeleteTask(); })
          Button('取消').onClick(() => { this.removeTaskId = ''; })
        }.padding(24).width('90%').backgroundColor(Color.White).borderRadius(24).shadow({ radius: 30, color: '#666666' })
      }
    }.width('100%').height('100%')
  }
}
