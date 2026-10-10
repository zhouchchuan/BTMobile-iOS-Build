import common from '@ohos.app.ability.common';
import http from '@ohos.net.http';
import systemDateTime from '@ohos.systemDateTime';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { call, TaskInfo } from './Native';
import { APP_VERSION, SUBSCRIPTION_ORIGIN, SUBSCRIPTION_AUDIENCE, Ledger, Entitlement, RuntimeConfig, Activity,
  validateEntitlement, validateConfig, fresh, paid, unlimited, remaining, reserve, refund, validCheckout, OrderRow } from './SubscriptionPolicy';
import { SubscriptionVault, uuid, sha256, verifyEnvelope } from './SubscriptionVault';

interface Bootstrap { aud: string; nonce: string; serverTime: number }
interface RegisterBody { deviceID: string; publicKey: string; proof: string }
interface OrderRequest { channel: string; requestID: string }
interface OrderResult { orderID: string; checkoutURL: string }
interface OrdersResult { aud: string; deviceID: string; issuedAt: number; orders: OrderRow[] }
interface ActivityAck { aud: string; kind: string; deviceID: string; nonce: string; issuedAt: number; trackersRevision: number }
interface ServiceReply { status: number; body: string }
interface RequestHeaders { header: Record<string, string>; nonce: string }

@Observed
export class SubscriptionState {
  ready: boolean = false;
  identityMessage: string = '正在读取';
  deviceID: string = '';
  status: string = '正在读取设备订阅…';
  expiresAt: number = 0;
  freeRemaining: number = 3;
  subscribed: boolean = false;
  unlimited: boolean = false;
  online: boolean = false;
  busy: boolean = false;
  alipay: boolean = false;
  wxpay: boolean = false;
  message: string = '';
  runtimeMessage: string = '等待同步';
  trackerRevision: number = 0;
  orderRows: OrderRow[] = [];
}

export class SubscriptionService {
  readonly state: SubscriptionState;
  private vault: SubscriptionVault | undefined = undefined;
  private ledger: Ledger | undefined = undefined;
  private entitlement: Entitlement | undefined = undefined;
  private serial: Promise<void> = Promise.resolve();
  private timer: number = -1;
  private syncBusy: boolean = false;
  private disposed: boolean = false;
  private lastRefresh: number = 0;
  private lastAttempt: number = 0;
  private anchor: number = 0;
  private anchorUptime: number = 0;
  private foreground: boolean = true;
  private registered: boolean = false;
  private pendingOrderID: string = '';
  private pendingOrderChannel: string = '';
  private context: common.UIAbilityContext | undefined = undefined;

  private failure(stage: string, error: Error): string {
    const code = (error as BusinessError).code;
    const suffix = typeof code === 'number' ? '（错误码 ' + code.toString() + '）' : '';
    // Never log keys, UUIDs, receipts, request bodies or payment URLs.
    hilog.warn(0x1203, 'BTMobileSubscription', '%{public}s failed; code=%{public}s', stage, typeof code === 'number' ? code.toString() : 'validation');
    return stage + '失败' + suffix;
  }

  constructor(state: SubscriptionState) { this.state = state; }
  private exclusive<T>(action: () => Promise<T>): Promise<T> {
    const next = this.serial.then(action); this.serial = next.then(() => {}, () => {}); return next;
  }
  private now(): number {
    const wall = Math.floor(Date.now() / 1000);
    const anchored = this.anchor + Math.max(0, Math.floor((systemDateTime.getUptime(systemDateTime.TimeType.STARTUP) - this.anchorUptime) / 1000));
    return Math.max(wall, this.ledger?.maxTime ?? 0, this.anchor > 0 ? anchored : 0);
  }
  private publish(): void {
    const current = this.now(); const value = this.entitlement;
    this.state.deviceID = this.ledger?.deviceID ?? '';
    this.state.ready = this.ledger !== undefined;
    this.state.identityMessage = this.ledger ? '已就绪' : '暂不可用，请重试';
    this.state.expiresAt = value?.expiresAt ?? 0;
    this.state.subscribed = paid(value, current);
    this.state.unlimited = unlimited(value, current);
    this.state.freeRemaining = this.ledger ? remaining(this.ledger, current) : 0;
    this.state.trackerRevision = this.ledger?.revision ?? 0;
    this.state.status = this.state.subscribed ? '已订阅' : this.state.unlimited ? '当前不限次数' : '免费用户';
    const canPay = this.state.online && fresh(value, current) && value?.paymentsEnabled === true;
    this.state.alipay = canPay && value?.paymentChannels.alipay === true;
    this.state.wxpay = canPay && value?.paymentChannels.wxpay === true;
  }
  private async save(value: Ledger): Promise<void> {
    if (!this.vault) throw new Error('设备安全存储尚未就绪');
    await this.vault.save(value); this.ledger = value; this.publish();
  }
  async start(context: common.UIAbilityContext): Promise<void> {
    this.context = context; this.disposed = false;
    // Install retries even when the first keystore attempt fails. No key/data reset is performed.
    if (this.timer < 0) this.timer = setInterval(() => { this.synchronize(); }, 60000);
    await this.synchronize(true);
  }
  private async ensureIdentity(): Promise<void> {
    if (this.ledger) return;
    if (!this.context) throw new Error('设备上下文尚未就绪');
    this.state.identityMessage = '正在读取'; this.state.status = '正在初始化设备身份…';
    this.state.runtimeMessage = '正在初始化设备身份，随后同步';
    this.vault = new SubscriptionVault(this.context);
    this.ledger = await this.vault.load();
    this.publish();
    hilog.info(0x1203, 'BTMobileSubscription', 'Device identity ready');
    if (this.ledger.receipt) {
      try {
        const claim = JSON.parse(await verifyEnvelope(this.ledger.receipt)) as Entitlement;
        validateEntitlement(claim, this.ledger.deviceID, this.now()); this.entitlement = claim;
      } catch (error) { this.state.message = this.failure('订阅缓存校验', error as Error) + '，正在尝试在线刷新'; }
    }
    if (this.ledger.config) {
      try {
        const config = JSON.parse(await verifyEnvelope(this.ledger.config)) as RuntimeConfig;
        validateConfig(config, '', this.now(), this.ledger.revision, true);
        await call({ op: 'setManagedTrackers', trackers: config.trackers, revision: config.trackersRevision });
      } catch (error) { this.failure('Tracker 缓存读取', error as Error); }
    }
    this.publish();
  }
  stop(): void { this.disposed = true; clearInterval(this.timer); this.timer = -1; }
  setForeground(value: boolean): void {
    this.foreground = value;
    // Foreground transition is a refresh opportunity, not a new background keepalive request.
    if (value && this.context && !this.disposed) this.synchronize();
  }
  private async request(path: string, method: http.RequestMethod = http.RequestMethod.GET, body: string = '', headers?: Record<string, string>): Promise<ServiceReply> {
    if (!/^\/v1\/[a-z-]+(?:\?nonce=[A-F0-9-]+)?$/.test(path)) throw new Error('订阅接口路径无效');
    const client = http.createHttp();
    try {
      const header: Record<string, string> = headers ?? {};
      header['Content-Type'] = 'application/json'; header['Accept'] = 'application/json';
      const response = await client.request(SUBSCRIPTION_ORIGIN + path, { method: method, header: header,
        extraData: body, expectDataType: http.HttpDataType.STRING, usingCache: false, connectTimeout: 8000, readTimeout: 8000, maxLimit: 131072 });
      if (typeof response.result !== 'string' || response.result.length > 131072) throw new Error('订阅服务响应无效');
      return { status: response.responseCode, body: response.result as string };
    } finally { client.destroy(); }
  }
  private async signedHeaders(path: string, method: string, body: string): Promise<RequestHeaders> {
    if (!this.vault || !this.ledger) throw new Error('设备身份尚未就绪');
    const timestamp = this.now().toString(); const nonce = uuid();
    const header: Record<string, string> = { 'X-Device-ID': this.ledger.deviceID, 'X-Time': timestamp, 'X-Nonce': nonce,
      'X-Signature': await this.vault.sign(method + '\n' + path + '\n' + timestamp + '\n' + nonce + '\n' + await sha256(body)) };
    return { header: header, nonce: nonce };
  }
  private async updateEntitlement(force: boolean): Promise<void> {
    if (!this.vault || !this.ledger) throw new Error('设备身份尚未就绪');
    if (!force && this.now() - this.lastRefresh < 60) return;
    this.lastAttempt = Date.now();
    const nonce = uuid();
    const bootstrap = await this.request('/v1/bootstrap?nonce=' + nonce);
    if (bootstrap.status !== 200) throw new Error('暂时无法连接订阅服务');
    const boot = JSON.parse(await verifyEnvelope(bootstrap.body)) as Bootstrap;
    if (boot.aud !== SUBSCRIPTION_AUDIENCE || boot.nonce !== nonce || !Number.isSafeInteger(boot.serverTime) ||
      Math.abs(boot.serverTime - Math.floor(Date.now() / 1000)) > 300 || boot.serverTime < this.ledger.maxTime - 300) throw new Error('请检查手机日期、时间与时区');
    this.anchor = boot.serverTime; this.anchorUptime = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
    const payload: RegisterBody = { deviceID: this.ledger.deviceID, publicKey: await this.vault.publicKey(), proof: await this.vault.sign('register\n' + this.ledger.deviceID) };
    const response = await this.request('/v1/register', http.RequestMethod.POST, JSON.stringify(payload));
    if (response.status !== 200) throw new Error('设备身份同步失败，请稍后重试');
    const claim = JSON.parse(await verifyEnvelope(response.body)) as Entitlement;
    validateEntitlement(claim, this.ledger.deviceID, this.now(), this.entitlement?.issuedAt ?? 0);
    const next: Ledger = { schema: 1, deviceID: this.ledger.deviceID, day: this.ledger.day, used: this.ledger.used,
      maxTime: this.now(), receipt: response.body, config: this.ledger.config, revision: this.ledger.revision };
    await this.save(next); this.entitlement = claim; this.lastRefresh = this.now(); this.registered = true; this.state.online = true; this.state.message = ''; this.publish();
  }
  private async updateTrackers(): Promise<void> {
    if (!this.ledger) return;
    const nonce = uuid(); const response = await this.request('/v1/client-config?nonce=' + nonce);
    if (response.status !== 200) throw new Error('默认 Tracker 暂时无法同步，继续使用缓存');
    const config = JSON.parse(await verifyEnvelope(response.body)) as RuntimeConfig;
    validateConfig(config, nonce, this.now(), this.ledger.revision);
    if (config.trackersRevision > this.ledger.revision) {
      // Persist only authenticated data; never alter the user's custom trackers or network parameters.
      const next: Ledger = { schema: 1, deviceID: this.ledger.deviceID, day: this.ledger.day, used: this.ledger.used,
        maxTime: this.now(), receipt: this.ledger.receipt, config: response.body, revision: config.trackersRevision };
      await this.save(next);
    }
    await call({ op: 'setManagedTrackers', trackers: config.trackers, revision: config.trackersRevision });
    hilog.info(0x1203, 'BTMobileSubscription', 'Managed trackers synchronized; revision=%{public}d', config.trackersRevision);
  }
  private async updateActivity(): Promise<void> {
    if (!this.registered || !this.ledger) throw new Error('设备身份尚未完成注册');
    const tasks = (await call({ op: 'tasks' })).items ?? [];
    const active = tasks.filter((item: TaskInfo) => item.active && !item.paused);
    const activity: Activity = { platform: 'harmonyos', version: APP_VERSION, foreground: this.foreground,
      downloading: active.filter((item: TaskInfo) => !item.complete && !item.checking && item.total > 0).length,
      seeding: active.filter((item: TaskInfo) => item.complete === true).length,
      metadata: active.filter((item: TaskInfo) => item.total <= 0 && !item.checking).length,
      checking: active.filter((item: TaskInfo) => item.checking).length,
      downloadRate: Math.floor(tasks.reduce((sum: number, item: TaskInfo) => sum + Math.max(0, item.download), 0)),
      uploadRate: Math.floor(tasks.reduce((sum: number, item: TaskInfo) => sum + Math.max(0, item.upload), 0)) };
    const body = JSON.stringify(activity); const auth = await this.signedHeaders('/v1/activity', 'POST', body);
    const result = await this.request('/v1/activity', http.RequestMethod.POST, body, auth.header);
    if (result.status !== 200) throw new Error('在线状态暂未上报');
    const ack = JSON.parse(await verifyEnvelope(result.body)) as ActivityAck;
    if (ack.aud !== SUBSCRIPTION_AUDIENCE || ack.kind !== 'activity-ack' || ack.deviceID !== this.ledger.deviceID ||
      ack.nonce !== auth.nonce || Math.abs(ack.issuedAt - this.now()) >= 300) throw new Error('在线状态响应未通过校验');
    hilog.info(0x1203, 'BTMobileSubscription', 'HarmonyOS activity acknowledged');
  }
  async synchronize(force: boolean = false): Promise<void> {
    if (this.disposed) return;
    if (this.syncBusy) { if (force) await this.serial; return; }
    if (!force && Date.now() - this.lastAttempt < 15000) return;
    this.lastAttempt = Date.now();
    this.syncBusy = true; this.state.busy = true;
    try {
      await this.exclusive(async () => {
        try { await this.ensureIdentity(); }
        catch (error) {
          this.state.ready = false; this.state.online = false;
          this.state.status = '设备身份初始化失败'; this.state.identityMessage = '暂不可用，请点击刷新订阅重试';
          this.state.message = this.failure('设备安全存储', error as Error) + '。可点击刷新重试；请勿卸载或清除应用数据，现有任务不受影响。';
          this.state.runtimeMessage = '设备身份尚未就绪；可点击同步重试，当前 Tracker 地址继续有效';
          return;
        }
        try { await this.updateEntitlement(force); }
        catch (error) { this.state.online = false; this.state.message = this.failure('订阅同步', error as Error) + '；使用最近有效凭据，现有任务不受影响。'; this.publish(); }
        let trackerStatus = '';
        let activityStatus = '';
        try { await this.updateTrackers(); trackerStatus = '默认 Tracker 已同步 · 配置 ' + this.state.trackerRevision.toString(); }
        catch (error) { trackerStatus = this.failure('Tracker 同步', error as Error) + '，保留已保存的地址'; }
        // A failed configuration fetch must not suppress the independent presence heartbeat.
        try { await this.updateActivity(); activityStatus = '在线状态已同步'; }
        catch (error) { activityStatus = this.registered ? this.failure('在线状态上报', error as Error) : '在线状态等待设备注册'; }
        this.state.runtimeMessage = trackerStatus + '；' + activityStatus;
      });
    } finally { this.syncBusy = false; this.state.busy = false; }
  }
  async addTask(uri: string): Promise<boolean> {
    return this.exclusive(async (): Promise<boolean> => {
      if (!this.state.ready || !this.ledger) throw new Error('订阅安全存储尚未就绪，请稍后重试');
      // Parse with the same core before consuming quota. Duplicate imports do not consume a new use.
      const validated = await call({ op: 'validateAdd', uri: uri });
      if (validated.duplicate) return true;
      if (this.now() - this.lastRefresh >= 60 && Date.now() - this.lastAttempt >= 15000) {
        try { await this.updateEntitlement(false); } catch (_) { this.state.online = false; this.publish(); }
      }
      let reservedDay = '';
      if (!unlimited(this.entitlement, this.now())) {
        if (remaining(this.ledger, this.now()) <= 0) { this.publish(); return false; }
        const next = reserve(this.ledger, this.now()); await this.save(next); reservedDay = next.day;
      }
      try {
        const added = await call({ op: 'add', uri: uri });
        if (added.duplicate && reservedDay) await this.save(refund(this.ledger, reservedDay));
      } catch (error) {
        if (reservedDay) { try { await this.save(refund(this.ledger, reservedDay)); } catch (_) { this.state.message = '新增失败且次数恢复失败，请联系管理员；未静默重置次数。'; } }
        throw error as Error;
      }
      this.publish(); return true;
    });
  }
  async checkout(channel: string): Promise<string> {
    return this.exclusive(async (): Promise<string> => {
      await this.updateEntitlement(true);
      if (this.entitlement?.subscriptionEnabled === false) throw new Error('服务端当前已开放免费使用，无需订阅');
      if (!((channel === 'alipay' && this.state.alipay) || (channel === 'wxpay' && this.state.wxpay))) throw new Error('当前支付通道不可用');
      // Retain an idempotency ID across uncertain network failures; never make an order on page-open.
      if (!this.pendingOrderID || this.pendingOrderChannel !== channel) { this.pendingOrderID = uuid(); this.pendingOrderChannel = channel; }
      const request: OrderRequest = { channel: channel, requestID: this.pendingOrderID };
      const body = JSON.stringify(request); const auth = await this.signedHeaders('/v1/orders', 'POST', body);
      const result = await this.request('/v1/orders', http.RequestMethod.POST, body, auth.header);
      if (result.status === 409) { this.pendingOrderID = ''; throw new Error('该请求可能已创建订单，请先查看订单记录。确认未支付后，可再次点击创建新订单。'); }
      if (result.status !== 200) throw new Error('订单创建暂未成功，请稍后重试');
      const order = JSON.parse(result.body) as OrderResult;
      if (!validCheckout(order.checkoutURL)) throw new Error('支付地址未通过安全校验');
      this.pendingOrderID = ''; return order.checkoutURL;
    });
  }
  async loadOrders(): Promise<void> {
    await this.exclusive(async () => {
      if (!this.ledger) throw new Error('设备身份尚未就绪');
      const auth = await this.signedHeaders('/v1/orders', 'GET', '');
      const result = await this.request('/v1/orders', http.RequestMethod.GET, '', auth.header);
      if (result.status !== 200) throw new Error('订单记录暂时不可用');
      const orders = JSON.parse(await verifyEnvelope(result.body)) as OrdersResult;
      if (orders.aud !== SUBSCRIPTION_AUDIENCE || orders.deviceID !== this.ledger.deviceID || Math.abs(orders.issuedAt - this.now()) >= 300 ||
        !Array.isArray(orders.orders) || orders.orders.length > 20 || !orders.orders.every((row: OrderRow) => row.priceCents === 800 && row.days === 30)) throw new Error('订单记录校验失败');
      this.state.orderRows = orders.orders;
    });
  }
}

