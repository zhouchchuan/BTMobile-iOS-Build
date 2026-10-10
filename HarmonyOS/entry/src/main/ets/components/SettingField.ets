// @Link keeps async-loaded values and edits in one source of truth. @Builder
// primitive arguments previously retained the initial 0 / false on screen.
@Component
export struct SettingNumber {
  title: string = '';
  @Link value: string;
  build() {
    Row({ space: 8 }) {
      Text(this.title).fontSize(15).layoutWeight(1)
      TextInput({ text: this.value }).type(InputType.Number).width(110)
        .onChange((value: string) => { this.value = value; })
    }.width('100%')
  }
}
@Component
export struct SettingSwitch {
  title: string = '';
  @Link value: boolean;
  build() {
    Row() {
      Text(this.title).fontSize(15).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.value }).selectedColor('#34C759')
        .onChange((value: boolean) => { this.value = value; })
    }.width('100%')
  }
}
