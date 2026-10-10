import { call, NetworkSettings } from '../model/Native';
import { SettingNumber, SettingSwitch } from './SettingField';

@Component
export struct SettingsPanel {
  onSaved: () => void = () => {};
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
  @State autoTrackers: boolean = true;
  @State defaults: string = '';
  @State custom: string = '';
  aboutToAppear(): void { this.load(); }
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
        autoAddTrackers: this.autoTrackers, customTrackers: this.custom.split(/\r?\n/).map((s: string) => s.trim()).filter((s: string) => s.length > 0)
      };
      await call({ op: 'setNetworkSettings', settings: settings });
      await this.load();
      this.message = '设置已保存并应用；不需要重启下载核心。Tracker 自动补充规则用于新添加的任务。'; this.onSaved();
    } catch(e) { this.message = '保存失败：' + (e as Error).message; }
    finally { this.saving = false; }
  }
  async saveQueue(): Promise<void> {
    if (!this.loaded || this.saving) return;
    this.saving = true; this.message = '';
    try {
      const update: NetworkSettings = { queueEnabled: this.queue,
        maxActive: this.number(this.active, '总活跃任务数', 0, 1000),
        maxDownloads: this.number(this.downloads, '同时下载数', 0, 1000),
        maxSeeds: this.number(this.seeds, '同时做种数', 0, 1000) };
      await call({ op: 'setNetworkSettings', settings: update });
      const saved = (await call({ op: 'getNetworkSettings' })).settings;
      if (!saved || saved.queueEnabled !== update.queueEnabled || saved.maxActive !== update.maxActive ||
        saved.maxDownloads !== update.maxDownloads || saved.maxSeeds !== update.maxSeeds) throw new Error('核心回读值不一致，请重试');
      this.message = '队列设置已保存并回读确认'; this.onSaved();
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
        Text('0 表示不限速；1024 KiB/s = 1 MiB/s。限速包含局域网连接。下载任务也可以同时上传。').fontSize(12).fontColor('#666666')
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(20)
        Column({ space: 14 }) {
        Text('任务队列').fontSize(16).fontWeight(FontWeight.Medium)
        SettingSwitch({ title: '启用队列限制', value: $queue })
        Column({ space: 12 }) {
          SettingNumber({ title: '总活跃任务数', value: $active })
          SettingNumber({ title: '同时下载任务数', value: $downloads })
          SettingNumber({ title: '同时做种任务数', value: $seeds })
        }.enabled(this.queue)
        Text('总活跃数同时约束下载与做种。数量 0 表示该类任务等待；关闭队列则不限数量。手动暂停的任务不会因保存设置而自动继续。').fontSize(12).fontColor('#666666')
        Button(this.saving ? '正在保存…' : '保存队列设置').fontColor('#EE9A64').backgroundColor('#FFF0E5').onClick(() => { this.saveQueue(); })
        if (this.message) { Text(this.message).fontSize(12).fontColor('#995522') }
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(20)
        Column({ space: 14 }) {
        Text('BT 网络').fontSize(16).fontWeight(FontWeight.Medium)
        SettingNumber({ title: '首选监听端口', value: $port })
        Text('默认 6882。保留 IPv4 / IPv6 自动发现与可用端口回退；实际端口显示在网络状态中。').fontSize(12).fontColor('#666666')
        SettingSwitch({ title: 'DHT 节点发现', value: $dht })
        SettingSwitch({ title: 'LSD 本地发现', value: $lsd })
        SettingSwitch({ title: 'NAT-PMP 映射', value: $natPmp })
        SettingSwitch({ title: 'UPnP 映射', value: $upnp })
        SettingSwitch({ title: 'μTP 连接', value: $utp })
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(20)
        Column({ space: 14 }) {
        Text('Tracker').fontSize(16).fontWeight(FontWeight.Medium)
        SettingSwitch({ title: '新任务自动添加 Tracker', value: $autoTrackers })
        Text('默认地址').fontSize(15).fontWeight(FontWeight.Medium)
        Text(this.defaults).fontSize(12).width('100%').copyOption(CopyOptions.InApp)
        Text('自定义地址（每行一个）').fontSize(15).fontWeight(FontWeight.Medium)
        TextArea({ text: this.custom, placeholder: 'http://、https:// 或 udp:// 地址' }).fontSize(13).height(160).onChange((v: string) => { this.custom = v; })
        Text('自动去重，保留磁力和种子自带地址。已识别为私有的种子不补充公共 Tracker。').fontSize(12).fontColor('#666666')
        }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(20)
        Button(this.saving ? '正在保存…' : '保存核心设置').width('100%').backgroundColor('#F39A56').onClick(() => { this.save(); })
      }.enabled(this.loaded && !this.saving).alignItems(HorizontalAlign.Start).width('100%')
      if (this.message) { Text(this.message).fontSize(13).fontColor('#995522') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
