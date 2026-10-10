import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import huks from '@ohos.security.huks';
import crypto from '@ohos.security.cryptoFramework';
import util from '@ohos.util';
import { Ledger, SignedEnvelope, SERVER_PUBLIC_KEY, validateLedger, shanghaiDay } from './SubscriptionPolicy';

const SIGN_ALIAS: string = 'btmobile.subscription.device.v1';
const AES_ALIAS: string = 'btmobile.subscription.storage.v1';
const SPKI_PREFIX: number[] = [48, 89, 48, 19, 6, 7, 42, 134, 72, 206, 61, 2, 1, 6, 8, 42, 134, 72, 206, 61, 3, 1, 7, 3, 66, 0];
export function utf8(value: string): Uint8Array { return new util.TextEncoder().encodeInto(value); }
export function text(value: Uint8Array): string { return util.TextDecoder.create('utf-8', { fatal: true }).decodeWithStream(value); }
export function base64(value: Uint8Array): string { return new util.Base64Helper().encodeToStringSync(value); }
export function unbase64(value: string): Uint8Array {
  if (typeof value !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) throw new Error('安全数据编码无效');
  return new util.Base64Helper().decodeSync(value);
}
export function joinBytes(a: Uint8Array, b: Uint8Array): Uint8Array { const result = new Uint8Array(a.length + b.length); result.set(a); result.set(b, a.length); return result; }
export function uuid(): string { return util.generateRandomUUID(true).toUpperCase(); }
export async function sha256(value: string): Promise<string> {
  const md = crypto.createMd('SHA256'); await md.update({ data: utf8(value) });
  return Array.from((await md.digest()).data).map((v: number) => v.toString(16).padStart(2, '0')).join('');
}
// Some keystore providers return IEEE-P1363; the deployed server expects ASN.1 DER.
export function derSignature(raw: Uint8Array): Uint8Array {
  if (raw.length >= 8 && raw.length <= 72 && raw[0] === 48 && raw[1] === raw.length - 2 && raw[2] === 2) return raw;
  if (raw.length !== 64) throw new Error('设备签名格式无效');
  const integer = (data: Uint8Array): Uint8Array => {
    let offset = 0; while (offset < data.length - 1 && data[offset] === 0) offset++;
    let bytes = data.slice(offset); if ((bytes[0] & 128) !== 0) bytes = joinBytes(new Uint8Array([0]), bytes);
    return joinBytes(new Uint8Array([2, bytes.length]), bytes);
  };
  const body = joinBytes(integer(raw.slice(0, 32)), integer(raw.slice(32)));
  return joinBytes(new Uint8Array([48, body.length]), body);
}
function signProperties(purpose: number): huks.HuksParam[] {
  return [{ tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_ECC },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 }, { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
    { tag: huks.HuksTag.HUKS_TAG_DIGEST, value: huks.HuksKeyDigest.HUKS_DIGEST_SHA256 }];
}
function aesProperties(purpose: number, nonce?: Uint8Array, tag?: Uint8Array): huks.HuksParam[] {
  const values: huks.HuksParam[] = [{ tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: 256 }, { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM }];
  if (nonce) { values.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce }); values.push({ tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: utf8('BTmobile-subscription-v1') }); }
  if (tag) values.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
  return values;
}
async function finish(alias: string, properties: huks.HuksParam[], input: Uint8Array): Promise<Uint8Array> {
  const session = await huks.initSession(alias, { properties: properties });
  try {
    const result = await huks.finishSession(session.handle, { properties: properties, inData: input });
    if (!result.outData) throw new Error('设备安全服务未返回数据');
    return result.outData;
  } catch (error) { try { await huks.abortSession(session.handle, { properties: [] }); } catch (_) {} throw error as Error; }
}
export async function verifyEnvelope(raw: string): Promise<string> {
  if (raw.length > 131072) throw new Error('服务端响应过大');
  const envelope = JSON.parse(raw) as SignedEnvelope;
  const data = unbase64(envelope.payload); const signature = unbase64(envelope.signature);
  if (data.length > 65536 || signature.length > 80) throw new Error('服务端凭据格式无效');
  const key = await crypto.createAsyKeyGenerator('ECC256').convertKey({ data: joinBytes(new Uint8Array(SPKI_PREFIX), unbase64(SERVER_PUBLIC_KEY)) }, null);
  const verifier = crypto.createVerify('ECC256|SHA256'); await verifier.init(key.pubKey);
  if (!await verifier.verify({ data: data }, { data: signature })) throw new Error('服务端签名无效，已拒绝更新');
  return text(data);
}
export class SubscriptionVault {
  private path: string;
  constructor(context: common.UIAbilityContext) { this.path = context.filesDir + '/subscription-v1.enc'; }
  async load(): Promise<Ledger> {
    // isKeyItemExist rejects with 12000011 for a new install; it does not resolve false.
    // API 11+ hasKeyItem returns false for absence while still rejecting real keystore errors.
    const signExists = await huks.hasKeyItem(SIGN_ALIAS, { properties: [] });
    const aesExists = await huks.hasKeyItem(AES_ALIAS, { properties: [] });
    if (!fs.accessSync(this.path)) {
      if (signExists || aesExists) throw new Error('订阅记录丢失，安全密钥仍存在；请勿清除数据，联系管理员恢复');
      await huks.generateKeyItem(SIGN_ALIAS, { properties: signProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_VERIFY) });
      await huks.generateKeyItem(AES_ALIAS, { properties: aesProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT) });
      const now = Math.floor(Date.now() / 1000);
      const value: Ledger = { schema: 1, deviceID: uuid(), day: shanghaiDay(now), used: 0, maxTime: now, receipt: '', config: '', revision: 0 };
      await this.save(value); return value;
    }
    if (!signExists || !aesExists) throw new Error('设备安全密钥不可用，请勿清除数据；请联系管理员恢复订阅');
    if (fs.statSync(this.path).size > 131072) throw new Error('订阅安全数据过大');
    const sealed = unbase64(fs.readTextSync(this.path));
    if (sealed.length < 30 || sealed[0] !== 1) throw new Error('订阅安全数据无效');
    const body = sealed.slice(13);
    const plain = await finish(AES_ALIAS, aesProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, sealed.slice(1, 13), body.slice(-16)), body.slice(0, -16));
    const value = JSON.parse(text(plain)) as Ledger; validateLedger(value); return value;
  }
  async save(value: Ledger): Promise<void> {
    validateLedger(value);
    const nonce = (await crypto.createRandom().generateRandom(12)).data;
    const sealed = await finish(AES_ALIAS, aesProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce), utf8(JSON.stringify(value)));
    const encoded = base64(joinBytes(joinBytes(new Uint8Array([1]), nonce), sealed));
    const file = fs.openSync(this.path + '.tmp', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, encoded); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
    fs.renameSync(this.path + '.tmp', this.path);
  }
  async sign(value: string): Promise<string> {
    return base64(derSignature(await finish(SIGN_ALIAS, signProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN), utf8(value))));
  }
  async publicKey(): Promise<string> {
    const result = await huks.exportKeyItem(SIGN_ALIAS, { properties: [] }); const bytes = result.outData;
    if (!bytes || bytes.length !== 91 || !SPKI_PREFIX.every((v: number, i: number) => bytes[i] === v) || bytes[26] !== 4) throw new Error('设备公钥格式无效');
    return base64(bytes.slice(26));
  }
}

