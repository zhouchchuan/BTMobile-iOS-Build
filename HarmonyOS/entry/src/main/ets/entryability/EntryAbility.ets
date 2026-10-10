import UIAbility from '@ohos.app.ability.UIAbility';
import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import { incomingMagnet } from '../model/IncomingLink';
import { backgroundTransfer } from '../model/BackgroundTransfer';

export default class EntryAbility extends UIAbility {
  private acceptWant(want: Want): void {
    const magnet = incomingMagnet(want.uri ?? '');
    if (magnet) {
      AppStorage.setOrCreate('incomingMagnet', '');
      AppStorage.setOrCreate('incomingMagnet', magnet);
    }
    const task = want.parameters?.taskId;
    if (typeof task === 'string' && /^[0-9a-f]{40,64}$/i.test(task)) AppStorage.setOrCreate('notificationTask', task);
  }
  onCreate(want: Want): void { backgroundTransfer.attach(this.context); this.acceptWant(want); }
  onNewWant(want: Want): void { this.acceptWant(want); }
  onForeground(): void { backgroundTransfer.setForeground(true); AppStorage.setOrCreate('btmobileForeground', true); }
  onBackground(): void { backgroundTransfer.setForeground(false); AppStorage.setOrCreate('btmobileForeground', false); }
  onDestroy(): void { backgroundTransfer.detach(); }
  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent('pages/Index');
  }
}
