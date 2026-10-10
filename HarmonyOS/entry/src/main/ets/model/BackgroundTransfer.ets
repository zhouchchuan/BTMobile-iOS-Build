import common from '@ohos.app.ability.common';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import deviceInfo from '@ohos.deviceInfo';
import hilog from '@ohos.hilog';
import { call, TaskInfo, bytes } from './Native';
import { CompletionNotifications } from './CompletionNotifications';
import { TaskEvent, SystemTask, onTaskEvent, offTaskEvent, queryTasks, startTransfer } from './BackgroundTaskCompat';

// Owned by EntryAbility, not by an ArkUI page or a completion-notification promise.
// No fake audio, periodic stop/start, fabricated progress or exemption request.
export class BackgroundTransfer {
  private context: common.UIAbilityContext | undefined = undefined;
  private enabled: boolean = false;
  private foreground: boolean = false;
  private ready: boolean = false;
  private disposed: boolean = false;
  private timer: number = -1;
  private polling: boolean = false;
  private busy: boolean = false;
  private stopping: boolean = false;
  private waiters: Array<() => void> = [];
  private dirty: boolean = false;
  private rows: TaskInfo[] = [];
  private notificationId: number = -1;
  private taskId: number = -1;
  private cancelled: boolean = false;
  private suspended: boolean = false;
  private retryAfter: number = 0;
  private lastProgressAt: number = 0;
  private lastBytes: number = -1;
  private holdUntil: number = 0;
  private lastActiveAt: number = 0;
  private inspectRequired: boolean = false;
  private epoch: number = 0;
  private message: string = '';
  private completion: CompletionNotifications = new CompletionNotifications();

  private cancelListener = (event: TaskEvent): void => {
    if (this.stopping || !this.matches(event)) return;
    this.epoch++;
    this.notificationId = -1; this.taskId = -1; this.cancelled = true; this.suspended = false;
    this.report('系统已取消后台传输（原因 ' + (event.reason ?? -1).toString() + '）；返回前台后重试');
  };
  private suspendListener = (event: TaskEvent): void => {
    if (!this.matches(event)) return;
    this.suspended = true;
    this.report('系统已挂起后台传输（原因 ' + (event.suspendReason ?? -1).toString() + '）；返回前台恢复');
  };
  private activeListener = (event: TaskEvent): void => {
    if (!this.matches(event)) return;
    this.suspended = false; this.inspectRequired = true; this.lastProgressAt = 0;
    this.poll();
  };
  private matches(event: TaskEvent): boolean {
    const id = event.continuousTaskId ?? event.id;
    return !this.disposed && (this.notificationId >= 0 || this.busy) && (this.taskId < 0 || id === this.taskId);
  }
  private report(value: string): void {
    if (this.message === value) return;
    this.message = value;
    AppStorage.setOrCreate('btmobileBackgroundMessage', value);
    // Only lifecycle/status information: no filename, magnet, device UUID or keys.
    hilog.info(0xB710, 'BTBackground', '%{public}s', value);
  }
  attach(context: common.UIAbilityContext): void {
    this.context = context; this.disposed = false;
    try { if (deviceInfo.sdkApiVersion >= 15) onTaskEvent('continuousTaskCancel', this.cancelListener); }
    catch (_) { this.report('后台任务取消监听暂不可用'); }
    try {
      if (deviceInfo.sdkApiVersion >= 20) {
        onTaskEvent('continuousTaskSuspend', this.suspendListener);
        onTaskEvent('continuousTaskActive', this.activeListener);
      }
    } catch (_) { this.report('后台任务挂起监听暂不可用'); }
  }
  start(enabled: boolean): void {
    this.ready = true; this.enabled = enabled;
    if (this.timer < 0) this.timer = setInterval(() => { this.poll(); }, 2000);
    this.poll();
  }
  setEnabled(value: boolean): void {
    this.enabled = value; this.retryAfter = 0;
    if (value && this.foreground) this.cancelled = false;
    this.reconcile();
  }
  setForeground(value: boolean): void {
    const returned = value && !this.foreground;
    this.foreground = value;
    hilog.info(0xB710, 'BTBackground', 'foreground=%{public}s notification=%{public}d', value.toString(), this.notificationId);
    if (returned) { this.cancelled = false; this.retryAfter = 0; this.inspectRequired = true; }
    // Use the already captured UIAbility context on background/lock, never getContext(page).
    this.reconcile(); this.poll();
  }
  observe(rows: TaskInfo[]): void {
    this.rows = rows;
    if (rows.some((row: TaskInfo) => row.active)) this.lastActiveAt = Date.now();
    this.reconcile();
  }
  async prepareTransfer(): Promise<void> {
    // Obtain runtime while foreground, before waiting for magnet metadata/queue admission.
    if (!this.enabled || !this.foreground) return;
    this.holdUntil = Date.now() + 15000; this.retryAfter = 0; this.cancelled = false;
    await this.reconcile(true);
  }
  private async poll(): Promise<void> {
    if (!this.ready || this.disposed || this.polling) return;
    this.polling = true;
    try {
      const result = await call({ op: 'tasks' });
      if (this.disposed) return;
      this.observe(result.items ?? []);
      // Completion reminders are independent and cannot block acquiring runtime.
      if (this.context) this.completion.deliver(this.context);
    } catch (_) { /* A failed snapshot must not masquerade as an empty task list. */ }
    finally { this.polling = false; }
  }
  private wanted(): boolean {
    return !this.disposed && this.enabled && (this.rows.some((row: TaskInfo) => row.active) ||
      Date.now() < this.holdUntil || (this.notificationId >= 0 && Date.now() - this.lastActiveAt < 5000));
  }
  private async inspect(): Promise<void> {
    if (!this.context || !this.inspectRequired || deviceInfo.sdkApiVersion < 20) return;
    this.inspectRequired = false;
    try {
      const tasks = await queryTasks(this.context);
      const task = tasks.find((item: SystemTask) => item.abilityName === 'EntryAbility');
      this.notificationId = task ? task.notificationId : -1;
      this.taskId = task ? task.continuousTaskId : -1;
      this.suspended = task ? task.suspendState : false;
    } catch (_) { /* Keep confirmed state; event callbacks still reflect cancellation. */ }
  }
  private async progress(force: boolean): Promise<void> {
    if (this.notificationId < 0 || this.suspended || this.cancelled) return;
    const rows = this.rows.filter((row: TaskInfo) => row.active);
    let done = 0, total = 0, downloaded = 0, uploaded = 0, down = 0, up = 0;
    rows.forEach((row: TaskInfo) => {
      if (!row.complete) { done += row.done; total += row.total; }
      downloaded += row.downloaded ?? row.done; uploaded += row.uploaded ?? 0;
      down += row.download; up += row.upload;
    });
    const transferred = downloaded + uploaded;
    if (!force && (Date.now() - this.lastProgressAt < 5000 || transferred === this.lastBytes)) return;
    const detail = rows.length.toString() + ' 个活动任务 · ↓ ' + bytes(down) + '/s · ↑ ' + bytes(up) + '/s';
    const value = total > 0 ? Math.max(0, Math.min(100, done / total * 100)) : 0;
    const id = this.notificationId;
    await notificationManager.publish({ id: id,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: 'BTmobie · 后台传输', text: detail } },
      template: { name: 'downloadTemplate', data: { title: detail,
        fileName: total > 0 ? bytes(done) + ' / ' + bytes(total) : '已上传 ' + bytes(uploaded), progressValue: value } }
    });
    if (this.notificationId !== id || this.suspended || this.cancelled) return;
    this.lastProgressAt = Date.now(); this.lastBytes = transferred;
    this.report('后台传输已启用；系统实况通知已更新');
    hilog.info(0xB710, 'BTBackground', 'progress id=%{public}d bytes=%{public}f down=%{public}f up=%{public}f', id, transferred, down, up);
  }
  private async reconcile(wait: boolean = false): Promise<void> {
    if (!this.context || !this.ready) return;
    if (this.busy) {
      this.dirty = true;
      if (wait) await new Promise<void>((resolve: () => void) => { this.waiters.push(resolve); });
      return;
    }
    this.busy = true;
    try {
      do {
        this.dirty = false;
        await this.inspect();
        if (!this.wanted()) {
          if (this.notificationId >= 0) {
            this.stopping = true;
            try { await backgroundTaskManager.stopBackgroundRunning(this.context); }
            finally { this.stopping = false; }
            this.notificationId = -1; this.taskId = -1; this.suspended = false;
          }
          this.report(this.enabled ? '无活动传输；后台任务已停止' : '后台传输未启用');
          continue;
        }
        if (this.cancelled || this.suspended || Date.now() < this.retryAfter) continue;
        let started = false;
        if (this.notificationId < 0) {
          if (!this.foreground) { this.report('后台任务未建立；请返回前台后再继续传输'); continue; }
          const agent = await wantAgent.getWantAgent({
            wants: [{ bundleName: 'com.mxmall123.btmobile.hm', abilityName: 'EntryAbility' }],
            operationType: wantAgent.OperationType.START_ABILITY, requestCode: 1,
            wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
          });
          if (!this.wanted() || !this.foreground) continue;
          const epoch = this.epoch;
          const result = await startTransfer(this.context, agent);
          if (epoch !== this.epoch) continue; // A concurrent system cancellation wins.
          this.notificationId = result.notificationId; this.taskId = result.continuousTaskId ?? -1;
          this.lastBytes = -1; this.lastProgressAt = 0;
          started = true;
          this.report('后台传输任务已建立，正在更新实况通知');
          if (!this.wanted()) { this.dirty = true; continue; }
        }
        await this.progress(started);
      } while (this.dirty);
    } catch (e) {
      this.retryAfter = Date.now() + 15000;
      this.report('后台传输操作失败：' + (e as Error).message + '；请返回前台检查通知权限');
    } finally {
      this.busy = false;
      const waiters = this.waiters; this.waiters = [];
      waiters.forEach((resolve: () => void) => { resolve(); });
    }
  }
  async detach(): Promise<void> {
    this.disposed = true; this.enabled = false; clearInterval(this.timer); this.timer = -1;
    try { if (deviceInfo.sdkApiVersion >= 15) offTaskEvent('continuousTaskCancel', this.cancelListener); } catch (_) {}
    try {
      if (deviceInfo.sdkApiVersion >= 20) {
        offTaskEvent('continuousTaskSuspend', this.suspendListener);
        offTaskEvent('continuousTaskActive', this.activeListener);
      }
    } catch (_) {}
    await this.reconcile();
  }
}
export const backgroundTransfer: BackgroundTransfer = new BackgroundTransfer();
