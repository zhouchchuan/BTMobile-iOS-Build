import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { call } from './Native';

export class CompletionNotifications {
  private busy: boolean = false;
  private retryAfter: number = 0;
  async enabled(): Promise<boolean> { return notificationManager.isNotificationEnabled(); }
  async authorize(context: common.UIAbilityContext): Promise<void> {
    if (!await this.enabled()) await notificationManager.requestEnableNotification(context);
    this.retryAfter = 0;
  }
  async deliver(context: common.UIAbilityContext): Promise<void> {
    if (this.busy || Date.now() < this.retryAfter) return;
    this.busy = true;
    try {
      const events = (await call({ op: 'completionEvents' })).events ?? [];
      if (events.length === 0) return;
      if ((await call({ op: 'getNetworkSettings' })).settings?.completionNotifications === false) return;
      if (!await this.enabled()) { this.retryAfter = Date.now() + 60000; return; }
      for (const event of events) {
        // Stable ID replaces an already-published event if acknowledgement was interrupted.
        const notificationId = (parseInt(event.id.slice(0, 7), 16) % 100000000) + 100;
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: 'com.mxmall123.btmobile.hm', abilityName: 'EntryAbility', parameters: { taskId: event.id } }],
          operationType: wantAgent.OperationType.START_ABILITY, requestCode: notificationId,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        });
        if ((await call({ op: 'getNetworkSettings' })).settings?.completionNotifications === false) return;
        await notificationManager.publish({ id: notificationId, label: event.id,
          notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
          content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: { title: 'BTmobie · 下载完成', text: event.name || '下载任务已完成', additionalText: '点击查看任务' } },
          wantAgent: agent
        });
        await call({ op: 'ackCompletion', id: event.id });
      }
    } catch (_) { this.retryAfter = Date.now() + 15000; }
    finally { this.busy = false; }
  }
}
