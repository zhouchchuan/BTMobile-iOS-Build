// Compatible with the existing iOS / Android subscription service. No store prices are invented here.
export const SUBSCRIPTION_ORIGIN: string = 'https://sub.linkyou.win:5288';
export const SUBSCRIPTION_AUDIENCE: string = 'com.mxmall123.app';
export const APP_VERSION: string = '1.0.2';
export const DAILY_FREE: number = 3;
export const SERVER_PUBLIC_KEY: string = 'BFuxu2aaqgEyrjxGOADET1X69miait64KLxm4JYS2oTrRL/MH4iad2NTleo01HrMJCPt1sQHzVSGoaEnG8G+T2E=';
export interface SignedEnvelope { payload: string; signature: string }
export interface PaymentChannels { alipay: boolean; wxpay: boolean }
export interface Entitlement {
  aud: string; deviceID: string; issuedAt: number; expiresAt: number; validUntil: number;
  priceCents: number; days: number; paymentsEnabled: boolean; subscriptionEnabled: boolean; paymentChannels: PaymentChannels;
}
export interface RuntimeConfig {
  aud: string; kind: string; nonce: string; issuedAt: number; trackersRevision: number; trackers: string[];
  heartbeatInterval: number; onlineWindow: number;
}
export interface Activity {
  platform: string; version: string; foreground: boolean; downloading: number; seeding: number;
  metadata: number; checking: number; downloadRate: number; uploadRate: number;
}
export interface Ledger {
  schema: number; deviceID: string; day: string; used: number; maxTime: number;
  receipt: string; config: string; revision: number;
}
export interface OrderRow { id: string; channel: string; priceCents: number; days: number; createdAt: number; paidAt?: number; status: string }
export function shanghaiDay(seconds: number): string { return new Date((seconds + 28800) * 1000).toISOString().slice(0, 10); }
export function safeInteger(value: number, min: number, max: number): boolean { return Number.isSafeInteger(value) && value >= min && value <= max; }
export function validateLedger(value: Ledger): void {
  if (!value || value.schema !== 1 || !/^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$/.test(value.deviceID) ||
    !/^\d{4}-\d{2}-\d{2}$/.test(value.day) || !safeInteger(value.used, 0, DAILY_FREE) || !safeInteger(value.maxTime, 0, 9999999999) ||
    typeof value.receipt !== 'string' || typeof value.config !== 'string' || !safeInteger(value.revision, 0, Number.MAX_SAFE_INTEGER)) {
    throw new Error('订阅安全数据无效，请勿清除应用数据；请联系管理员恢复设备身份');
  }
}
export function validateEntitlement(value: Entitlement, deviceID: string, now: number, previousIssued: number = 0): void {
  if (!value || value.aud !== SUBSCRIPTION_AUDIENCE || value.deviceID !== deviceID ||
    !safeInteger(value.issuedAt, 1, now + 300) || value.issuedAt < previousIssued ||
    !safeInteger(value.expiresAt, 0, 9999999999) || !safeInteger(value.validUntil, 1, 9999999999) || !safeInteger(value.validUntil - value.issuedAt, 1, 86400) ||
    value.priceCents !== 800 || value.days !== 30 || typeof value.paymentsEnabled !== 'boolean' || typeof value.subscriptionEnabled !== 'boolean' ||
    !value.paymentChannels || typeof value.paymentChannels.alipay !== 'boolean' || typeof value.paymentChannels.wxpay !== 'boolean') {
    throw new Error('订阅凭据校验失败，已保留上一次有效状态');
  }
}
export function fresh(value: Entitlement | undefined, now: number): boolean {
  return value !== undefined && value.issuedAt <= now + 300 && value.validUntil > now;
}
export function paid(value: Entitlement | undefined, now: number): boolean { return fresh(value, now) && (value?.expiresAt ?? 0) > now; }
export function unlimited(value: Entitlement | undefined, now: number): boolean { return fresh(value, now) && (value?.subscriptionEnabled === false || paid(value, now)); }
export function remaining(ledger: Ledger, now: number): number { return DAILY_FREE - (ledger.day === shanghaiDay(now) ? ledger.used : 0); }
export function reserve(ledger: Ledger, now: number): Ledger {
  if (remaining(ledger, now) < 1) throw new Error('DAILY_LIMIT');
  return { schema: ledger.schema, deviceID: ledger.deviceID, day: shanghaiDay(now),
    used: (ledger.day === shanghaiDay(now) ? ledger.used : 0) + 1, maxTime: Math.max(ledger.maxTime, now),
    receipt: ledger.receipt, config: ledger.config, revision: ledger.revision };
}
export function refund(ledger: Ledger, day: string): Ledger {
  return { schema: ledger.schema, deviceID: ledger.deviceID, day: ledger.day, used: ledger.day === day ? Math.max(0, ledger.used - 1) : ledger.used,
    maxTime: ledger.maxTime, receipt: ledger.receipt, config: ledger.config, revision: ledger.revision };
}
export function validTracker(value: string): boolean {
  if (typeof value !== 'string' || value.length > 512 || /[\s\x00-\x1f\x7f\\#@]/.test(value)) return false;
  const match = /^(https?|udp):\/\/(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9.-]+)(?::([0-9]+))?(?:\/[^\s]*)?$/.exec(value);
  return match !== null && (match[1] !== 'udp' || match[3] !== undefined) &&
    (match[3] === undefined || safeInteger(Number(match[3]), 1, 65535));
}
export function validateConfig(value: RuntimeConfig, nonce: string, now: number, previous: number, cached: boolean = false): void {
  if (!value || value.aud !== SUBSCRIPTION_AUDIENCE || value.kind !== 'client-config' ||
    (!cached && (value.nonce !== nonce || Math.abs(value.issuedAt - now) >= 300)) ||
    !safeInteger(value.issuedAt, 1, 9999999999) || !safeInteger(value.trackersRevision, Math.max(1, previous), Number.MAX_SAFE_INTEGER) ||
    !Array.isArray(value.trackers) || value.trackers.length > 100 || value.trackers.join('\n').length > 12000 ||
    !value.trackers.every((item: string) => validTracker(item)) || value.heartbeatInterval !== 60 || value.onlineWindow !== 180) {
    throw new Error('默认 Tracker 配置校验失败，继续使用已保存的地址');
  }
}
export function validCheckout(value: string): boolean {
  return typeof value === 'string' && /^https:\/\/sub\.linkyou\.win:5288\/checkout\?token=[0-9a-f]{64}$/.test(value);
}

