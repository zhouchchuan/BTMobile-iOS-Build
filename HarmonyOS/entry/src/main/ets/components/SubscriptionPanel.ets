import promptAction from '@ohos.promptAction';
import { SubscriptionState, SubscriptionService } from '../model/SubscriptionService';
import { OrderRow, APP_VERSION } from '../model/SubscriptionPolicy';
import { IconButton } from './IconButton';
import { SubscriptionCheckout } from './SubscriptionCheckout';

export function subscriptionDate(seconds: number): string {
  return seconds > 0 ? new Date(seconds * 1000).toLocaleString() : '尚未订阅';
}

@Component
export struct SubscriptionPanel {
  @ObjectLink state: SubscriptionState;
  service: SubscriptionService = new SubscriptionService(new SubscriptionState());
  onClose: () => void = () => {};
  @State paying: boolean = false;
  @State loadingOrders: boolean = false;
  @State message: string = '';
  @State checkoutURL: string = '';
  @Prop @Watch('handleBack') backRequest: number = 0;
  handleBack(): void { if (this.checkoutURL) this.closeCheckout(); else this.onClose(); }
  closeCheckout(): void { this.checkoutURL = ''; this.service.synchronize(true); }
  async pay(channel: string): Promise<void> {
    if (this.paying) return;
    const choice = await promptAction.showDialog({ title: '确认订阅', message: '8 元 / 30 天，一次付费、手动续费，不自动扣款。订阅绑定当前鸿蒙设备身份。是否前往官方支付页？', buttons: [{ text: '取消', color: '#8E8E93' }, { text: '前往支付', color: '#F39A56' }] });
    if (choice.index !== 1 || this.paying) return;
    this.paying = true; this.message = '';
    try {
      this.checkoutURL = await this.service.checkout(channel);
      this.message = '支付后返回此页，点击“刷新订阅”。仅以服务端确认结果为准。';
    } catch (error) { this.message = (error as Error).message; }
    finally { this.paying = false; }
  }
  async orders(): Promise<void> {
    if (this.loadingOrders) return;
    this.loadingOrders = true;
    try { await this.service.loadOrders(); this.message = this.state.orderRows.length ? '' : '当前设备暂无订单'; }
    catch (error) { this.message = (error as Error).message; }
    finally { this.loadingOrders = false; }
  }
  build() {
    Stack() {
    Column({ space: 12 }) {
      Row() {
        IconButton({ icon: $r('app.media.nav_back'), label: '关闭订阅页', action: () => { this.onClose(); } })
        Text('订阅与设备身份').fontSize(19).fontWeight(FontWeight.Bold).layoutWeight(1).textAlign(TextAlign.Center)
        Blank().width(48)
      }.padding({ left: 16, right: 16, top: 12 }).width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 14 }) {
            Text(this.state.status).fontSize(23).fontWeight(FontWeight.Bold).fontColor('#F39A56')
            Text(this.state.unlimited ? '无限添加下载任务' : '今日免费剩余 ' + this.state.freeRemaining.toString() + ' / 3 次').fontSize(17)
            Text('订阅到期时间：' + subscriptionDate(this.state.expiresAt)).fontSize(14)
            Text('免费用户每天可新建 3 个任务，按北京时间 00:00 重置。重复任务不扣次数；新增失败恢复次数；现有下载、续传与文件播放不受次数限制。').fontSize(13).fontColor('#8E8E93')
          }.width('100%').padding(20).backgroundColor(Color.White).borderRadius(22).alignItems(HorizontalAlign.Start)
          Column({ space: 14 }) {
            Text('8 元 / 30 天').fontSize(22).fontWeight(FontWeight.Bold)
            Text('沿用现有订阅服务 · 手动续费 · 不自动扣款').fontSize(13).fontColor('#8E8E93')
            Button(this.paying ? '正在打开支付…' : '支付宝订阅').enabled(this.state.alipay && !this.paying).width('100%').backgroundColor('#F39A56').onClick(() => { this.pay('alipay'); })
            Button('微信支付订阅').enabled(this.state.wxpay && !this.paying).width('100%').backgroundColor('#34C759').onClick(() => { this.pay('wxpay'); })
            if (!this.state.alipay && !this.state.wxpay) { Text('支付尚未开放或订阅状态未同步，请刷新后查看。').fontSize(13).fontColor('#8E8E93') }
            Button(this.state.busy ? '正在同步…' : '刷新订阅').enabled(!this.state.busy).width('100%').fontColor('#EE9A64').backgroundColor('#FFF0E5').onClick(() => { this.service.synchronize(true); })
            if (this.state.message) { Text(this.state.message).fontSize(13).fontColor('#8E8E93') }
            if (this.message) { Text(this.message).fontSize(13).fontColor('#995522') }
          }.width('100%').padding(20).backgroundColor(Color.White).borderRadius(22)
          Column({ space: 12 }) {
            Text('设备身份').fontSize(16).fontWeight(FontWeight.Medium)
            Text('UUID：' + (this.state.deviceID || this.state.identityMessage)).fontSize(13).copyOption(CopyOptions.InApp)
            Text('订阅按设备身份生效，不会自动继承其他手机的订阅。卸载或清除应用数据可能丢失身份；请先保存 UUID，以便联系管理员恢复。').fontSize(12).fontColor('#8E8E93')
            Text('当前版本 V' + APP_VERSION).fontSize(13)
            Text(this.state.runtimeMessage).fontSize(12).fontColor('#8E8E93')
            Text('在线状态仅包含设备身份、平台/版本、前后台状态、任务数量和总速率；不上传磁力链接、文件名、视频或文件内容。').fontSize(12).fontColor('#8E8E93')
          }.width('100%').padding(20).backgroundColor(Color.White).borderRadius(22).alignItems(HorizontalAlign.Start)
          Button(this.loadingOrders ? '正在读取…' : '查看本设备订单').enabled(!this.loadingOrders && this.state.ready).onClick(() => { this.orders(); }).fontColor('#EE9A64').backgroundColor('#FFF0E5')
          ForEach(this.state.orderRows, (order: OrderRow) => {
            Column({ space: 8 }) {
              Text(order.status === 'paid' ? '已支付' : order.status === 'pending' ? '待支付' : order.status === 'closed' ? '已关闭' : '已过期').fontSize(15).fontColor('#EE9A64')
              Text(order.id).fontSize(12).copyOption(CopyOptions.InApp)
              Text('8 元 / 30 天 · ' + subscriptionDate(order.createdAt)).fontSize(12).fontColor('#8E8E93')
            }.width('100%').padding(16).backgroundColor(Color.White).borderRadius(18).alignItems(HorizontalAlign.Start)
          }, (order: OrderRow) => order.id + order.status)
        }.padding(16).width('100%')
      }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor('#F2F2F7')
    if (this.checkoutURL) { SubscriptionCheckout({ url: this.checkoutURL, onClose: () => { this.closeCheckout(); } }) }
    }.width('100%').height('100%')
  }
}

