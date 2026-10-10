@Component
export struct IconButton {
  @Prop icon: Resource = $r('app.media.nav_add');
  @Prop label: string = '';
  @Prop selected: boolean = false;
  @Prop preserveSvgStroke: boolean = false;
  action: () => void = () => {};
  build() {
    Button({ type: ButtonType.Circle }) {
      if (this.preserveSvgStroke) { Image(this.icon).width(24).height(24) }
      else { Image(this.icon).width(24).height(24).fillColor(this.selected ? '#F39A56' : '#202022') }
    }.width(48).height(48).backgroundColor(this.selected ? '#FFF0E5' : '#FFFFFF')
      .border({ width: this.selected ? 1 : 0, color: '#F6B67E' })
      .shadow({ radius: 14, color: '#0D000000', offsetY: 4 })
      .accessibilityText(this.label).onClick(() => { this.action(); })
  }
}
