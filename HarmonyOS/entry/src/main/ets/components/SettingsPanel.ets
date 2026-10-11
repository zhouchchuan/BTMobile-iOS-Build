import { call, NetworkSettings } from '../model/Native';
import { SettingNumber, SettingSwitch } from './SettingField';
import { ThemeSettings } from './ThemeSettings';

@Component
export struct SettingsPanel {
  onSaved: () => void = () => {};
  onSync: () => Promise<string> = async () => '';
  onAuthorizeNotifications: () => Promise<boolean> = async () => false;
  @Prop notificationPermission: boolean = false;
  @Prop @Watch('refreshDefaults') trackerRevision: number = 0;
  @Prop runtimeMessage: string = '';
  @State loaded: boolean = false;
  @State saving: boolean = false;
  @State message: string = '';
  @State port: string = '6882';
  @State download: string = '0';
  @State upload: string = '0';
  @State queue: boolean = false;
  @State active: string = '8';
  @State downloads: string = '3';
  @State seeds: string = '5';
  @State seedEnabled: boolean = true;
  @State dht: boolean = true;
  @State lsd: boolean = true;
  @State natPmp: boolean = true;
  @State upnp: boolean = true;
  @State utp: boolean = true;
  @State allowWifi: boolean = true;
  @State allowCellular: boolean = true;
  @State completionNotifications: boolean = true;
  @State autoTrackers: boolean = true;
  @State defaults: string = '';
  @State custom: string = '';
  aboutToAppear(): void { this.load(); }
  async refreshDefaults(): Promise<void> {
    try { this.defaults = ((await call({ op: 'getNetworkSettings' })).defaultTrackers ?? []).join('\n'); } catch (_) {}
  }
  async load(): Promise<void> {
    try {
      const result = await call({ op: 'getNetworkSettings' });
      const settings = result.settings;
      if (!settings) throw new Error('未返回核心设置');
      this.port = (settings.listenPort ?? 6882).toString();
      this.download = (settings.downloadLimitKiB ?? 0).toString(); this.upload = (settings.uploadLimitKiB ?? 0).toString();
      this.queue = settings.queueEnabled ?? false;
      this.active = (settings.maxActive ?? 8).toString(); this.downloads = (settings.maxDownloads ?? 3).toString(); this.seeds = (settings.maxSeeds ?? 5).toString();
      this.seedEnabled = settings.seedEnabled ?? true;
      this.dht = settings.dht ?? true; this.lsd = settings.lsd ?? true; this.natPmp = settings.natPmp ?? true;
      this.upnp = settings.upnp ?? true; this.utp = settings.utp ?? true;
      this.allowWifi = settings.allowWifi ?? true; this.allowCellular = settings.allowCellular ?? true;
      this.completionNotifications = settings.completionNotifications ?? true;
      this.autoTrackers = settings.autoAddTrackers ?? true;
      this.defaults = (result.defaultTrackers ?? []).join('\n'); this.custom = (settings.customTrackers ?? []).join('\n');
      this.loaded = true;
    } catch(e) { this.message = '读取设置失败：' + (e as Error).message; }
  }
  number(value: string, label: string, min: number, max: number): number {
    if (!/^[0-9]+$/.test(value.trim())) throw new Error(label + '必须填写整数');
    const result = Number(value.trim());
    if (result < min || result > max) throw new Error(label + '范围为 ' + min.toString() + '～' + max.toString());
    return result;
  }
  async save(): Promise<void> {
    if (!this.loaded || this.saving) return;
    this.saving = true; this.message = '';
    try {
      const settings: NetworkSettings = {
        listenPort: this.number(this.port, 'BT 端口', 1024, 65535),
        downloadLimitKiB: this.number(this.download, '下载限速', 0, 1048576), uploadLimitKiB: this.number(this.upload, '上传限速', 0, 1048576),
        queueEnabled: this.queue, maxActive: this.number(this.active, '总活跃任务数', 0, 1000),
        maxDownloads: this.number(this.downloads, '同时下载数', 0, 1000), maxSeeds: this.number(this.seeds, '同时做种数', 0, 1000),
        seedEnabled: this.seedEnabled, dht: this.dht, lsd: this.lsd, natPmp: this.natPmp, upnp: this.upnp, utp: this.utp,
        allowWifi: this.allowWifi, allowCellular: this.allowCellular, completionNotifications: this.completionNotifications,
        autoAddTrackers: this.autoTrackers, customTrackers: this.custom.split(/\r?\n/).map((s: string) => s.trim()).filter((s: string) => s.length > 0)
      };
      await call({ op: 'setNetworkSettings', settings: settings });
      const saved = (await call({ op: 'getNetworkSettings' })).settings;
      if (!saved || saved.queueEnabled !== settings.queueEnabled || saved.maxActive !== settings.maxActive ||
        saved.maxDownloads !== settings.maxDownloads || saved.maxSeeds !== settings.maxSeeds ||
        saved.downloadLimitKiB !== settings.downloadLimitKiB || saved.uploadLimitKiB !== settings.uploadLimitKiB ||
        saved.listenPort !== settings.listenPort || saved.seedEnabled !== settings.seedEnabled ||
        saved.dht !== settings.dht || saved.lsd !== settings.lsd || saved.natPmp !== settings.natPmp ||
        saved.upnp !== settings.upnp || saved.utp !== settings.utp || saved.autoAddTrackers !== settings.autoAddTrackers ||
        saved.allowWifi !== settings.allowWifi || saved.allowCellular !== settings.allowCellular ||
        saved.completionNotifications !== settings.completionNotifications) {
        throw new Error('核心回读值不一致，请重试');
      }
      await this.load();
      let notificationStatus = '下载完成通知已关闭。';
      if (settings.completionNotifications) {
        try {
          notificationStatus = await this.onAuthorizeNotifications() ? '下载完成通知已启用。' : '通知偏好已保存，但系统尚未授权，请在系统设置中允许通知。';
        } catch (_) { notificationStatus = '通知偏好已保存，但系统尚未授权，请在系统设置中允许通知。'; }
      }
      this.message = '核心、队列与网络设置已保存，正在同步默认 Tracker…'; this.onSaved();
      try {
        const syncStatus = await this.onSync(); await this.refreshDefaults();
        this.message = '核心、队列与网络设置已保存并应用。' + notificationStatus + syncStatus;
      } catch (_) { this.message = '核心、队列与网络设置已保存；云端同步暂未完成，当前 Tracker 地址继续有效。' + notificationStatus; }
    } catch(e) { this.message = '保存失败：' + (e as Error).message; }
    finally { this.saving = false; }
  }
  build() {
    Column({ space: 14 }) {
      if (!this.loaded) { Button('重新读取核心设置').onClick(() => { this.load(); }) }
      Column({ space: 14 }) {
        Column({ space: 14 }) {
        Text('传输与做种').fontSize(16).fontWeight(FontWeight.Medium)
        SettingSwitch({ title: '下载完成后继续做种', value: $seedEnabled })
        SettingNumber({ title: '下载限速（KiB/s）', value: $download })
        SettingNumber({ title: '上传限速（KiB/s）', value: $upload })
        Text('0 表示不限速；1024 KiB/s = 1 MiB/s。限速包含局域网连接。下载任务也可以同时上传。').fontSize(12).fontColor($r('app.color.text_secondary'))
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.card_background')).borderRadius(20)
        Column({ space: 14 }) {
        Text('任务队列').fontSize(16).fontWeight(FontWeight.Medium)
        SettingSwitch({ title: '启用队列限制', value: $queue })
        Column({ space: 12 }) {
          SettingNumber({ title: '总活跃任务数', value: $active })
          SettingNumber({ title: '同时下载任务数', value: $downloads })
          SettingNumber({ title: '同时做种任务数', value: $seeds })
        }.enabled(this.queue)
        Text('总活跃数同时约束下载与做种。数量 0 表示该类任务等待；关闭队列则不限数量。手动暂停的任务不会因保存设置而自动继续。').fontSize(12).fontColor($r('app.color.text_secondary'))
        if (this.message) { Text(this.message).fontSize(12).fontColor($r('app.color.warning')) }
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.card_background')).borderRadius(20)
        Column({ space: 14 }) {
        Text('BT 网络').fontSize(16).fontWeight(FontWeight.Medium)
        SettingSwitch({ title: '允许无线网络下载 / 做种', value: $allowWifi })
        SettingSwitch({ title: '允许蜂窝数据下载 / 做种', value: $allowCellular })
        Text('默认允许无线网络和蜂窝数据。关闭蜂窝后仅使用无线网络；两项关闭将暂停 BT 传输。点击下方保存生效，切回允许的网络后自动继续，手动暂停的任务保持暂停。').fontSize(12).fontColor($r('app.color.text_secondary'))
        Text('限制网络时，如 VPN 或系统未能确认连接类型，将等待允许的网络；不会绕过 VPN。此开关不限制订阅与配置同步。').fontSize(12).fontColor($r('app.color.text_secondary'))
        SettingNumber({ title: '首选监听端口', value: $port })
        Text('默认 6882。保留 IPv4 / IPv6 自动发现与可用端口回退；实际端口显示在网络状态中。').fontSize(12).fontColor($r('app.color.text_secondary'))
        SettingSwitch({ title: 'DHT 节点发现', value: $dht })
        SettingSwitch({ title: 'LSD 本地发现', value: $lsd })
        SettingSwitch({ title: 'NAT-PMP 映射', value: $natPmp })
        SettingSwitch({ title: 'UPnP 映射', value: $upnp })
        SettingSwitch({ title: 'μTP 连接', value: $utp })
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.card_background')).borderRadius(20)
        Column({ space: 14 }) {
        Text('Tracker').fontSize(16).fontWeight(FontWeight.Medium)
        SettingSwitch({ title: '新任务自动添加 Tracker', value: $autoTrackers })
        Text('默认 Tracker · 配置 ' + this.trackerRevision.toString()).fontSize(15).fontWeight(FontWeight.Medium)
        Text('默认地址已隐藏，仍按当前设置参与连接与同步。').fontSize(12).fontColor($r('app.color.text_secondary'))
        Text(this.runtimeMessage).fontSize(12).fontColor($r('app.color.text_secondary'))
        Text('服务端统一管理默认地址，联网约每分钟同步；断网保留缓存，自定义地址不被覆盖。不重启核心，不改变已有任务的 Tracker。').fontSize(12).fontColor($r('app.color.text_secondary'))
        Text('自定义地址（每行一个）').fontSize(15).fontWeight(FontWeight.Medium)
        TextArea({ text: this.custom, placeholder: 'http://、https:// 或 udp:// 地址' }).fontSize(13).height(160).onChange((v: string) => { this.custom = v; })
        Text('自动去重，保留磁力和种子自带地址。已识别为私有的种子不补充公共 Tracker。').fontSize(12).fontColor($r('app.color.text_secondary'))
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.card_background')).borderRadius(20)
        ThemeSettings()
        Column({ space: 14 }) {
          Text('下载完成通知').fontSize(16).fontWeight(FontWeight.Medium)
          SettingSwitch({ title: '下载完成时通知', value: $completionNotifications })
          Text(this.notificationPermission ? '系统通知已授权' : '尚未获得系统通知权限；开启后点击保存，将申请授权。').fontSize(13).fontColor($r('app.color.text_secondary'))
          Text('与核心设置一起保存。关闭仅停止下载完成提醒，不影响系统要求的后台传输通知。').fontSize(12).fontColor($r('app.color.text_secondary'))
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.card_background')).borderRadius(20)
        Button(this.saving ? '正在保存与同步…' : '保存核心设置').width('100%').backgroundColor('#F39A56').onClick(() => { this.save(); })
      }.enabled(this.loaded && !this.saving).alignItems(HorizontalAlign.Start).width('100%')
      if (this.message) { Text(this.message).fontSize(13).fontColor($r('app.color.warning')) }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
