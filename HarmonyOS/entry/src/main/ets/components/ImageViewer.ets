@Component
export struct ImageViewer {
  @Prop source: string = '';
  onClose: () => void = () => {};
  @State zoom: number = 1;
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  private startZoom: number = 1;
  private startX: number = 0;
  private startY: number = 0;
  private areaWidth: number = 1;
  private areaHeight: number = 1;
  bound(value: number, size: number): number {
    const limit = Math.max(0, size * (this.zoom - 1) / 2);
    return Math.max(-limit, Math.min(limit, value));
  }
  constrain(): void { this.offsetX = this.bound(this.offsetX, this.areaWidth); this.offsetY = this.bound(this.offsetY, this.areaHeight); }
  reset(): void { this.zoom = 1; this.offsetX = 0; this.offsetY = 0; }
  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack() {
        Image('file://' + this.source).objectFit(ImageFit.Contain).width('100%').height('100%')
          .scale({ x: this.zoom, y: this.zoom }).translate({ x: this.offsetX, y: this.offsetY }).hitTestBehavior(HitTestMode.None)
      }.width('100%').height('100%').clip(true).backgroundColor(Color.Black)
      .onAreaChange((_old: Area, area: Area) => { this.areaWidth = Number(area.width); this.areaHeight = Number(area.height); this.constrain(); })
      .gesture(GestureGroup(GestureMode.Parallel,
        PinchGesture({ fingers: 2 }).onActionStart(() => { this.startZoom = this.zoom; })
          .onActionUpdate((event: GestureEvent) => { this.zoom = Math.max(1, Math.min(6, this.startZoom * event.scale)); this.constrain(); }),
        PanGesture({ fingers: 1 }).onActionStart(() => { this.startX = this.offsetX; this.startY = this.offsetY; })
          .onActionUpdate((event: GestureEvent) => { this.offsetX = this.bound(this.startX + event.offsetX, this.areaWidth); this.offsetY = this.bound(this.startY + event.offsetY, this.areaHeight); }),
        TapGesture({ count: 2 }).onAction(() => { animateTo({ duration: 180 }, () => { if (this.zoom > 1) this.reset(); else this.zoom = 2.5; }); })
      ))
      Button('×', { type: ButtonType.Circle }).width(48).height(48).fontSize(32).fontColor(Color.White)
        .backgroundColor('#AA333333').margin({ top: 12, right: 16 }).accessibilityText('关闭图片').onClick(() => { this.onClose(); })
    }.width('100%').height('100%').backgroundColor(Color.Black)
  }
}
