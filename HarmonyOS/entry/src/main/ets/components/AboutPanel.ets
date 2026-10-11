import util from '@ohos.util';
import { APP_VERSION } from '../model/SubscriptionPolicy';
import { ABOUT_SECTIONS, AboutSection, LICENSE_NOTICES, LicenseNotice } from '../model/AboutContent';
import { IconButton } from './IconButton';

@Component
export struct AboutPanel {
  onClose: () => void = () => {};
  @Prop @Watch('handleBack') backRequest: number = 0;
  @State noticeTitle: string = '';
  @State noticeText: string = '';
  handleBack(): void {
    if (this.noticeTitle) { this.noticeTitle = ''; this.noticeText = ''; }
    else this.onClose();
  }
  openNotice(notice: LicenseNotice): void {
    const sections: string[] = [];
    for (const file of notice.files) {
      try {
        const data = getContext(this).resourceManager.getRawFileContentSync('licenses/' + file);
        sections.push(file + '\n\n' + util.TextDecoder.create('utf-8').decodeWithStream(data));
      } catch (_) { sections.push(file + '\n\n此许可文件暂时无法读取，请重试。'); }
    }
    this.noticeText = sections.join('\n\n────────────────\n\n');
    this.noticeTitle = notice.name;
  }
  build() {
    Column() {
      Row({ space: 12 }) {
        IconButton({ icon: $r('app.media.nav_back'), label: this.noticeTitle ? '返回关于 BTmobie' : '返回设置', action: () => { this.handleBack(); } })
        Text(this.noticeTitle || '关于 BTmobie').fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('V' + APP_VERSION).fontSize(12).fontColor($r('app.color.text_secondary'))
      }.padding(16).width('100%')
      if (this.noticeTitle) {
        Scroll() {
          Text(this.noticeText).fontSize(13).lineHeight(21).fontColor($r('app.color.text_primary')).copyOption(CopyOptions.InApp).padding(18).width('100%')
        }.layoutWeight(1).width('100%').backgroundColor($r('app.color.card_background'))
      } else {
        Scroll() {
          Column({ space: 16 }) {
            ForEach(ABOUT_SECTIONS, (section: AboutSection) => {
              Column({ space: 12 }) {
                Text(section.title).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
                Text(section.text).fontSize(14).lineHeight(23).fontColor($r('app.color.text_primary')).width('100%')
              }.padding(18).width('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.card_background')).borderRadius(20)
            }, (section: AboutSection) => section.title)
            Column({ space: 8 }) {
              Text('开源软件许可').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).padding({ bottom: 8 })
              ForEach(LICENSE_NOTICES, (notice: LicenseNotice) => {
                Row() {
                  Text(notice.name).fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
                  Text('查看 ›').fontSize(14).fontColor($r('app.color.accent'))
                }.width('100%').constraintSize({ minHeight: 48 }).onClick(() => { this.openNotice(notice); })
              }, (notice: LicenseNotice) => notice.name)
            }.padding(18).width('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.card_background')).borderRadius(20)
          }.padding(16).width('100%')
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
