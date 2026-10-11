import { themeService } from '../model/ThemeService';
import promptAction from '@ohos.promptAction';

@Component
export struct ThemeSettings {
  @StorageLink('btmobileTheme') mode: string = 'system';
  @StorageLink('btmobileThemeReady') ready: boolean = false;
  @State saving: boolean = false;
  private readonly modes: string[] = ['light', 'dark', 'system'];
  private readonly labels: string[] = ['日间模式', '夜间模式', '跟随系统'];
  build() {
    Column({ space: 14 }) {
      Text('主题切换').fontSize(16).fontWeight(FontWeight.Medium)
      Row({ space: 6 }) {
        ForEach(this.modes, (mode: string, index: number) => {
          Button(this.labels[index]).fontSize(13).height(42).layoutWeight(1)
            .fontColor(this.mode === mode ? $r('app.color.accent') : $r('app.color.text_primary'))
            .backgroundColor(this.mode === mode ? $r('app.color.accent_soft') : $r('app.color.input_background'))
            .accessibilityText(this.labels[index] + (this.mode === mode ? '，已选中' : ''))
            .enabled(this.ready && !this.saving).onClick(async () => {
              this.saving = true;
              try { await themeService.set(mode); }
              catch (_) { promptAction.showToast({ message: '主题保存失败，请重试' }); }
              finally { this.saving = false; }
            })
        })
      }.width('100%')
      Text('立即生效并保存，文本阅读也使用所选主题。跟随系统时自动切换日间与夜间。').fontSize(12).fontColor($r('app.color.text_secondary'))
    }.padding(16).width('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.card_background')).borderRadius(20)
  }
}
