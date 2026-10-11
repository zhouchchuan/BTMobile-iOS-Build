import webview from '@ohos.web.webview';

// Payment is rendered in an isolated Web component: no JS bridge, file access or HTTP content.
@Component
export struct SubscriptionCheckout {
  url: string = '';
  onClose: () => void = () => {};
  private controller: webview.WebviewController = new webview.WebviewController();
  @State origin: string = 'https://sub.linkyou.win:5288';
  @State message: string = '';
  build() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Button('‹').width(44).height(44).fontSize(28).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.card_background')).accessibilityText('返回支付上一页').onClick(() => {
          try { if (this.controller.accessBackward()) this.controller.backward(); else this.onClose(); } catch (_) { this.onClose(); }
        })
        Column({ space: 3 }) {
          Text('订阅支付').fontSize(17).fontWeight(FontWeight.Medium)
          Text(this.origin).fontSize(10).fontColor($r('app.color.text_secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1)
        Button('完成').height(44).fontSize(14).fontColor($r('app.color.accent')).backgroundColor($r('app.color.card_background')).onClick(() => { this.onClose(); })
        Button('×').width(44).height(44).fontSize(26).fontColor($r('app.color.text_primary')).backgroundColor($r('app.color.card_background')).accessibilityText('关闭支付页面').onClick(() => { this.onClose(); })
      }.padding({ left: 12, right: 12, top: 12 }).width('100%')
      Text('付款后点击“完成”刷新订阅；页面提示不代表已开通，以服务器确认结果为准。').fontSize(12).fontColor($r('app.color.text_secondary')).padding({ left: 16, right: 16 })
      if (this.message) { Text(this.message).fontSize(13).fontColor($r('app.color.warning')).padding(12) }
      Web({ src: this.url, controller: this.controller })
        .javaScriptAccess(true).domStorageAccess(true).fileAccess(false).mixedMode(MixedMode.None)
        .onLoadIntercept((event) => {
          const address = event?.data.getRequestUrl() ?? '';
          if (/^https:\/\/[^\s/@]+(?:\/|$)/i.test(address)) return false;
          this.message = '此跳转不是安全网页，已阻止外部应用或浏览器唤起。请使用页面内付款方式，或返回更换支付通道。';
          return true;
        })
        .onPageBegin((event) => { this.origin = (event?.url ?? '').split('/').slice(0, 3).join('/'); })
        .onErrorReceive(() => { this.message = '支付页面加载失败，请返回订阅页后重试。未自动重新创建订单。'; })
        .width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}

