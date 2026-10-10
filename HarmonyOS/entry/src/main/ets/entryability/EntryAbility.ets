import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';

export default class EntryAbility extends UIAbility {
  onForeground(): void { AppStorage.setOrCreate('btmobileForeground', true); }
  onBackground(): void { AppStorage.setOrCreate('btmobileForeground', false); }
  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index');
  }
}
