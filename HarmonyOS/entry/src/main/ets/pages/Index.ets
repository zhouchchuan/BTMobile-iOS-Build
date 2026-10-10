import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import promptAction from '@ohos.promptAction';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import preferences from '@ohos.data.preferences';
import { call, files, peers, bytes, TaskInfo, TaskState, TorrentFile, PeerInfo } from '../model/Native';
import { Player } from '../components/Player';
import { ImageViewer } from '../components/ImageViewer';
import { TaskCard } from '../components/TaskCard';
import { SettingsPanel } from '../components/SettingsPanel';
import { IconButton } from '../components/IconButton';
import { TaskDetails } from '../components/TaskDetails';
import { matchesTask } from '../model/TaskFilter';
import { CompletionNotifications } from '../model/CompletionNotifications';
import { networkDisplay, deletionBanner } from '../model/NetworkDisplay';
import { SubscriptionService, SubscriptionState } from '../model/SubscriptionService';
import { SubscriptionPanel, subscriptionDate } from '../components/SubscriptionPanel';
import { APP_VERSION } from '../model/SubscriptionPolicy';

interface FileItem { name: string; path: string; directory: boolean; size: number; modified?: number }
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
  private notifications: CompletionNotifications = new CompletionNotifications();
  @StorageLink('incomingMagnet') @Watch('receiveMagnet') incomingMagnet: string = '';
  @StorageLink('notificationTask') @Watch('receiveNotificationTask') notificationTask: string = '';
  @State showAdd: boolean = false;
  @State adding: boolean = false;
  @State keyword: string = '';
  @State taskFilter: number = 0;
  @State trackerRows: string[] = [];
  @State notificationsEnabled: boolean = false;
  private readonly filters: string[] = ['全部', '完成', '下载中', '做种中', '已暂停', '校验文件', '获取元数据'];
  @State allowBackground: boolean = false;
  @State backgroundMessage: string = '后台传输未启用';
  @State networkPort: string = '—';
  @State networkDht: string = '—';
  @State networkTrackers: string = '—';
  @State actionPath: string = '';
  @State newName: string = '';
  @State imagePath: string = '';
  @State ready: boolean = false;
  @State tab: number = 0;
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
  @State playerCloseRequest: number = 0;
  @State subscriptionState: SubscriptionState = new SubscriptionState();
  private subscriptions: SubscriptionService = new SubscriptionService(this.subscriptionState);
  @State showSubscription: boolean = false;
  @State subscriptionBackRequest: number = 0;

  onBackPress(): boolean {
    if (this.playerSource) { this.playerCloseRequest++; return true; }
    if (this.showSubscription) { this.subscriptionBackRequest++; return true; }
    return false;
  }

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
      this.ready = true; this.status = '';
      await this.refresh();
      this.receiveMagnet(); this.receiveNotificationTask();
      if (this.pageVisible) { clearInterval(this.poll); this.poll = setInterval(() => { this.refresh(); }, 1000); }
      // Notification-service availability must never disable live BT progress.
      this.notifications.enabled().then((enabled: boolean) => { this.notificationsEnabled = enabled; }).catch(() => {});
      // Subscription networking is independent from BT initialization and progress polling.
      this.subscriptions.start(context);
    } catch (e) { this.status = '核心启动失败：' + (e as Error).message; }
    this.list();
  }
  aboutToDisappear(): void { this.pageVisible = false; clearInterval(this.poll); this.poll = -1; this.subscriptions.stop(); }
  foregroundChanged(): void { this.subscriptions.setForeground(this.foreground); if (this.foreground && this.ready && this.pageVisible) this.refresh(); }
  receiveMagnet(): void {
    if (!this.ready || !this.incomingMagnet) return;
    this.magnet = this.incomingMagnet; this.incomingMagnet = ''; this.tab = 0; this.selectedTask = ''; this.showAdd = true;
  }
  receiveNotificationTask(): void {
    if (!this.ready || !this.notificationTask) return;
    const id = this.notificationTask; this.notificationTask = ''; this.tab = 0;
    if (this.tasks.some((task: TaskState) => task.id === id)) { this.selectedTask = id; this.refreshDetails(); }
    else promptAction.showToast({ message: '此任务已被移除，可在文件管理中查看保留的文件' });
  }
  visibleTasks(): TaskState[] { return this.tasks.filter((task: TaskState) => matchesTask(task, this.keyword, this.taskFilter)); }
  async enableNotifications(): Promise<boolean> {
    try { await this.notifications.authorize(getContext(this) as common.UIAbilityContext); this.notificationsEnabled = await this.notifications.enabled(); }
    catch (_) { this.notificationsEnabled = false; }
    return this.notificationsEnabled;
  }
  async refresh(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      const result = await call({ op: 'tasks' });
      if (!this.pageVisible) return;
      const old = this.tasks;
      if ((result.deletionRevision ?? 0) > this.deletionRevision) {
        this.deletionRevision = result.deletionRevision ?? 0;
        this.status = deletionBanner(result.deletionMessage ?? ''); this.list();
      }
      this.tasks = (result.items ?? []).map((value: TaskInfo): TaskState => {
        const row = old.find((item: TaskState) => item.id === value.id) ?? new TaskState();
        row.update(value); return row;
      });
      if (result.network) {
        const display = networkDisplay(result.network);
        this.networkPort = display.port; this.networkDht = display.dht; this.networkTrackers = display.trackers;
      }
      // OS authorization and file/Peer detail calls must not block task refresh.
      // Deliver the persisted completion event before releasing background runtime.
      this.notifications.deliver(getContext(this) as common.UIAbilityContext).finally(() => { this.syncBackground(); });
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
        const trackers = (await call({ op: 'trackers', id: selected })).trackers ?? [];
        if (this.selectedTask === selected) this.trackerRows = trackers;
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
    if (!this.magnet.trim() || !this.ready || this.adding) return;
    if (!/^magnet:\?/i.test(this.magnet.trim())) { this.fail(new Error('请输入有效的 magnet: 磁力链接')); return; }
    this.adding = true;
    try {
      const admitted = await this.subscriptions.addTask(this.magnet.trim().replace(/^magnet:/i, 'magnet:'));
      if (!admitted) { this.showAdd = false; this.showSubscription = true; return; }
      this.magnet = ''; this.status = ''; this.showAdd = false; this.tab = 0; this.keyword = ''; this.taskFilter = 0; await this.refresh();
    }
    catch(e) { this.fail(e as Error); }
    finally { this.adding = false; }
  }
  list(): void {
    try {
      this.entries = fs.listFileSync(this.root + '/' + this.current).filter((name: string) => name !== '.state').map((name: string): FileItem => {
        const path = this.current ? this.current + '/' + name : name;
        const stat = fs.statSync(this.root + '/' + path);
        return { name: name, path: path, directory: stat.isDirectory(), size: stat.size, modified: stat.mtime };
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
      if (extension === 'torrent') {
        const choice = await promptAction.showDialog({ title: '确认添加下载任务', message: item.name, buttons: [{ text: '取消', color: '#8E8E93' }, { text: '添加', color: '#F39A56' }] });
        if (choice.index !== 1) return;
        if (!await this.subscriptions.addTask(item.path)) { this.showSubscription = true; return; }
        this.tab = 0; await this.refresh();
      }
      else if (['txt','log','md','srt','ass','json','csv'].includes(extension)) {
        if (item.size > 4 * 1024 * 1024) throw new Error('此文本超过 4 MiB，请使用外部编辑器');
        this.textPath = item.path; this.text = fs.readTextSync(this.root + '/' + item.path); this.editing = false; this.splitText();
      } else if (['png','jpg','jpeg','webp','gif'].includes(extension)) {
        this.imagePath = this.root + '/' + item.path;
      } else if (['zip','7z','rar','tar','gz','xz','bz2','zst','tgz','txz','tbz','tbz2'].includes(extension) || /^(\d{3,}|z\d{2,}|r\d{2,})$/.test(extension)) {
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
      const base = this.archivePath.replace(/(?:\.part\d+\.rar|\.(?:7z|zip)\.\d+|\.tar\.(?:gz|xz|bz2|zst)|\.(?:7z|zip|rar|tar|gz|xz|bz2|zst|tgz|txz|tbz2?)|\.[zr]\d+)$/i, '');
      let output = base + '-解压';
      let suffix = 2;
      while (fs.accessSync(this.root + '/' + output)) { output = base + '-解压 (' + suffix.toString() + ')'; suffix++; }
      await call({ op: 'extract', path: this.archivePath, output: output, password: this.password });
      this.archivePath = ''; this.password = ''; this.current = output; this.tab = 1; this.list(); promptAction.showToast({ message: '解压完成，已打开独立文件夹' });
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
  confirmDeleteFile(path: string = this.actionPath): void {
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
  @Builder
  swipeFile(path: string, name: string) {
    Row({ space: 6 }) {
      Button('重命名').backgroundColor('#DB863F').onClick(() => { this.actionPath = path; this.newName = name; })
      Button('删除').backgroundColor('#D83B35').onClick(() => { this.confirmDeleteFile(path); })
    }.padding(8)
  }
  icon(item: FileItem): Resource {
    if (item.directory) return $r('app.media.file_folder');
    const e = item.name.split('.').pop()?.toLowerCase() ?? '';
    if (['zip','7z','rar','tar','gz','xz','bz2','zst','tgz','txz','tbz','tbz2'].includes(e) || /^(\d{3,}|z\d{2,}|r\d{2,})$/.test(e)) return $r('app.media.file_archive');
    if (['mp4','mkv','mov','avi','webm','mp3','m4a','flac','aac'].includes(e)) return $r('app.media.file_video');
    if (['png','jpg','jpeg','webp','gif'].includes(e)) return $r('app.media.file_image');
    return $r('app.media.file_text');
  }
  fileSummary(item: FileItem): string {
    const type = item.directory ? '文件夹' : (item.name.split('.').pop() ?? '文件').toUpperCase();
    if (!item.modified) return type;
    const date = new Date(item.modified * 1000);
    return type + ' · ' + (date.getMonth() + 1).toString().padStart(2, '0') + '-' + date.getDate().toString().padStart(2, '0') + ' ' + date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
  }
  backFiles(): void {
    if (this.current) { this.current = this.current.split('/').slice(0, -1).join('/'); this.list(); }
    else this.tab = 0;
  }
  build() {
    Stack() {
      Column() {
        Row({ space: 12 }) {
          if (this.tab !== 0) { IconButton({ icon: $r('app.media.nav_back'), label: this.tab === 1 ? '返回上一级' : '返回任务', action: () => { if (this.tab === 1) this.backFiles(); else this.tab = 0; } }) }
          Text(this.tab === 0 ? 'BTmobie' : this.tab === 1 ? (this.current.split('/').pop() || '文件管理') : '设置').fontSize(this.tab === 0 ? 32 : 18).fontWeight(FontWeight.Bold).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (this.tab === 1) {
            Button('⋯', { type: ButtonType.Circle }).width(48).height(48).fontSize(28).fontColor('#202022').backgroundColor(Color.White).accessibilityText('文件操作').bindMenu([{ value: '导入文件', action: () => { this.importFile(); } }, { value: '刷新文件列表', action: () => { this.list(); } }])
          } else { Text(APP_VERSION).fontSize(12).fontColor('#8E8E93') }
        }.width('100%').padding({ left: 20, right: 20, top: 16, bottom: 12 })
        if (this.status) { Text(this.status).fontColor('#BB4B18').fontSize(13).padding(10) }
        if (this.extracting && !this.archivePath) { Text('压缩处理中 ' + Math.max(0,this.percent).toString() + '%').fontSize(14).padding(8) }
        if (this.tab === 0) {
          Search({ value: this.keyword, placeholder: '搜索任务名称或 Hash' }).textFont({ size: 15 }).height(44).backgroundColor('#EFEFF0').borderRadius(24).margin({ left: 18, right: 18, bottom: 12 }).onChange((v: string) => { this.keyword = v; })
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.filters, (label: string, index: number) => {
                Button(label).fontSize(13).fontWeight(FontWeight.Medium).height(32).padding({ left: 13, right: 13 }).fontColor(this.taskFilter === index ? Color.White : '#202022').backgroundColor(this.taskFilter === index ? '#F39A56' : Color.Transparent).onClick(() => { this.taskFilter = index; })
              })
            }.padding({ left: 18, right: 18 })
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').margin({ bottom: 12 })
          if (this.visibleTasks().length === 0) {
            Column({ space: 12 }) {
              Image($r('app.media.welcome')).width(64).height(64).margin({ bottom: 8 })
              Text(this.tasks.length === 0 ? '欢迎使用 BTmobie' : '没有匹配的任务').fontSize(22).fontWeight(FontWeight.Bold)
              Text(this.tasks.length === 0 ? '点击左下角的“＋”添加磁力链接，也可以从文件管理打开 Torrent 文件。' : '试试其他关键词，或选择“全部”查看任务。').fontSize(14).fontColor('#8E8E93').textAlign(TextAlign.Center).lineHeight(21).padding({ left: 26, right: 26 })
            }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
          } else {
          List({ space: 12 }) {
            ForEach(this.visibleTasks(), (task: TaskState) => {
              ListItem() {
                TaskCard({ task: task, onOpen: (id: string) => { this.selectedTask = id; this.refreshDetails(); },
                  onPause: async (id: string, paused: boolean) => { try { await call({ op: paused ? 'resume' : 'pause', id: id }); await this.refresh(); } catch(e) { this.fail(e as Error); } } })
              }.swipeAction({ end: this.swipeRemove.bind(this, task.id) })
            }, (t: TaskState) => t.id)
          }.layoutWeight(1).padding({ left: 16, right: 16 })
          }
        } else if (this.tab === 1) {
          Text('当前下载目录：BTmobie').fontSize(13).fontColor('#8E8E93').padding({ top: 14, bottom: 20 })
          List({ space: 0 }) {
            ForEach(this.entries, (item: FileItem) => {
              ListItem() {
                Row({ space: 12 }) {
                  Image(this.icon(item)).width(25).height(29).objectFit(ImageFit.Contain).onClick(() => { this.open(item); })
                  Column({ space: 5 }) {
                    Text(item.name).fontSize(15).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.fileSummary(item)).fontSize(11).fontColor('#AAAAAF').width('100%')
                  }.layoutWeight(1).onClick(() => { this.open(item); })
                  Text(item.directory ? '›' : bytes(item.size)).fontSize(12).fontColor('#8E8E93').constraintSize({ maxWidth: 62 }).textAlign(TextAlign.End)
                }.padding({ left: 18, right: 18, top: 18, bottom: 18 }).width('100%').backgroundColor(Color.White)
                .gesture(LongPressGesture().onAction(() => { this.actionPath = item.path; this.newName = item.name; }))
              }.swipeAction({ end: this.swipeFile.bind(this, item.path, item.name) })
            }, (item: FileItem) => item.path + ':' + item.size.toString() + ':' + (item.modified ?? 0).toString())
          }.layoutWeight(1).backgroundColor(Color.White).borderRadius(24).clip(true).divider({ strokeWidth: 0.5, color: '#E5E5EA', startMargin: 18, endMargin: 18 }).margin({ left: 16, right: 16 })
        } else {
          Scroll() {
            Column({ space: 16 }) {
              Column({ space: 12 }) {
              Text('下载核心网络状态').fontSize(16).fontWeight(FontWeight.Medium)
              Row({ space: 8 }) {
                Text('端口 ' + this.networkPort).fontSize(12).minFontSize(9).maxFontSize(12).maxLines(1).layoutWeight(1)
                Text('DHT 节点 ' + this.networkDht).fontSize(12).minFontSize(9).maxFontSize(12).maxLines(1).layoutWeight(1).textAlign(TextAlign.Center)
                Text('Tracker 响应 ' + this.networkTrackers).fontSize(12).minFontSize(9).maxFontSize(12).maxLines(1).layoutWeight(1).textAlign(TextAlign.End)
              }.width('100%')
              }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(20)
              Column({ space: 12 }) {
              Text('后台传输').fontSize(16).fontWeight(FontWeight.Medium)
              Row() { Text('允许后台下载 / 做种').fontSize(15).layoutWeight(1); Toggle({ type: ToggleType.Switch, isOn: this.allowBackground }).selectedColor('#34C759').onChange((value: boolean) => { this.setAllowBackground(value); }) }
              Text(this.backgroundMessage).fontSize(13).fontColor('#666666')
              Text('后台传输使用系统持续任务通知，无活动任务时自动停止。需要真机验证系统授权与锁屏表现。').fontSize(13).fontColor('#666666')
              }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(20)
              SettingsPanel({ trackerRevision: this.subscriptionState.trackerRevision, runtimeMessage: this.subscriptionState.runtimeMessage,
                notificationPermission: this.notificationsEnabled, onAuthorizeNotifications: async () => this.enableNotifications(),
                onSync: async () => { await this.subscriptions.synchronize(true); return this.subscriptionState.runtimeMessage; }, onSaved: () => { this.refresh(); } })
              Column({ space: 12 }) {
              Text('订阅信息').fontSize(16).fontWeight(FontWeight.Medium)
              Row() { Text('当前版本').fontSize(15).layoutWeight(1); Text('V' + APP_VERSION).fontSize(15).fontColor('#EE9A64') }.width('100%')
              Divider().color('#E5E5EA')
              Row() { Text('订阅到期时间').fontSize(15).layoutWeight(1); Text(subscriptionDate(this.subscriptionState.expiresAt)).fontSize(13).fontColor('#EE9A64') }.width('100%')
              Divider().color('#E5E5EA')
              Row() { Text('订阅与设备身份').fontSize(15).layoutWeight(1); Text(this.subscriptionState.status + ' ›').fontSize(14).fontColor('#EE9A64') }.width('100%').height(40).onClick(() => { this.showSubscription = true; this.subscriptions.synchronize(); })
              Text('UUID：' + (this.subscriptionState.deviceID || this.subscriptionState.identityMessage)).fontSize(12).fontColor('#8E8E93').copyOption(CopyOptions.InApp)
              Text(this.subscriptionState.unlimited ? '无限添加下载任务' : '今日免费剩余 ' + this.subscriptionState.freeRemaining.toString() + ' / 3 次').fontSize(12).fontColor('#8E8E93')
              Text('订阅 8 元 / 30 天，以最近一次有效同步的服务端策略为准。').fontSize(12).fontColor('#8E8E93')
              }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(20)
            }.padding(16).width('100%').alignItems(HorizontalAlign.Start)
          }.layoutWeight(1)
        }
        Row() {
          IconButton({ icon: $r('app.media.nav_add'), label: '添加磁力任务', selected: this.tab === 0, action: () => { this.tab = 0; this.showAdd = true; } })
          Blank()
          IconButton({ icon: $r('app.media.nav_folder'), label: '文件管理', selected: this.tab === 1, action: () => { this.tab = this.tab === 1 ? 0 : 1; this.list(); } })
          Blank()
          IconButton({ icon: $r('app.media.nav_gear'), label: '设置', selected: this.tab === 2, action: () => { this.tab = this.tab === 2 ? 0 : 2; } })
        }.padding({ left: 24, right: 24, top: 14, bottom: 16 }).width('100%')
      }.height('100%').width('100%').backgroundColor(this.tab === 0 ? '#FFFFFF' : '#F2F2F7')
      if (this.selectedTask) {
        ForEach(this.tasks.filter((task: TaskState) => task.id === this.selectedTask), (task: TaskState) => {
          TaskDetails({ task: task, files: this.taskFiles, peers: this.peerRows, trackers: this.trackerRows, peersOpen: this.showPeers,
            onClose: () => { this.selectedTask = ''; this.showPeers = false; },
            onPeers: () => { this.showPeers = !this.showPeers; this.refreshDetails(); },
            onPause: async () => { try { await call({ op: task.paused ? 'resume' : 'pause', id: task.id }); await this.refresh(); } catch(e) { this.fail(e as Error); } },
            onRefresh: async () => { try { await call({ op: 'refreshTask', id: task.id }); await this.refresh(); promptAction.showToast({ message: task.paused ? '任务状态已刷新，保持暂停' : '任务状态已刷新，已请求重新发现连接' }); } catch(e) { this.fail(e as Error); } },
            onRemove: () => { this.removeTaskId = task.id; }, onPlay: (file: TorrentFile) => { this.playTask(file); } })
        }, (task: TaskState) => task.id)
      }
      if (this.showAdd) {
        Column().width('100%').height('100%').backgroundColor('#55000000').onClick(() => { if (!this.adding) this.showAdd = false; })
        Column({ space: 16 }) {
          Text('确认添加下载任务').fontSize(20).fontWeight(FontWeight.Bold)
          Text('检查磁力链接后点击添加，下载将保存到文件管理。').fontSize(13).fontColor('#8E8E93')
          TextArea({ text: this.magnet, placeholder: '粘贴 magnet: 磁力链接' }).fontSize(13).height(136).onChange((v: string) => { this.magnet = v; })
          Row({ space: 14 }) {
            Button('取消').fontColor('#202022').backgroundColor('#EFEFF0').layoutWeight(1).enabled(!this.adding).onClick(() => { this.showAdd = false; this.magnet = ''; })
            Button(this.adding ? '正在添加…' : '添加任务').backgroundColor('#F39A56').layoutWeight(1).enabled(this.ready && !this.adding).onClick(() => { this.add(); })
          }
        }.width('90%').padding(24).borderRadius(26).backgroundColor(Color.White)
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
        Column().width('100%').height('100%').backgroundColor('#55000000')
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
        ImageViewer({ source: this.imagePath, onClose: () => { this.imagePath = ''; } })
      }
      if (this.playerSource) {
        Player({ source: this.playerSource, title: this.playerTitle, closeRequest: this.playerCloseRequest, onClose: () => { this.playerSource = ''; call({ op: 'stopStream' }).catch(() => {}); } })
      }
      if (this.showSubscription) {
        SubscriptionPanel({ state: this.subscriptionState, service: this.subscriptions, backRequest: this.subscriptionBackRequest, onClose: () => { this.showSubscription = false; } })
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
