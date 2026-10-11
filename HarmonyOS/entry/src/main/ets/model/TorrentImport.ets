import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import util from '@ohos.util';

export const MAX_TORRENT_BYTES: number = 16 * 1024 * 1024;
export function torrentUrl(value: string): string {
  const address = value.trim();
  if (address.length > 8192 || /[\s\u0000-\u001f]/.test(address) ||
    !/^https?:\/\/[^\s/@?#]+(?:[/?#]|$)/i.test(address)) {
    throw new Error('请输入 http:// 或 https:// 开头的 Torrent 下载地址');
  }
  return address;
}
export function checkTorrentBytes(buffer: ArrayBuffer): void {
  if (buffer.byteLength === 0 || buffer.byteLength > MAX_TORRENT_BYTES) throw new Error('Torrent 文件须大于 0 且不超过 16 MiB');
  // Reject error pages early; the unchanged core validates the complete bencode and info hash.
  if (new Uint8Array(buffer)[0] !== 100) throw new Error('此内容不是 Torrent 文件，请使用种子文件的直接下载地址');
}
export class TorrentImport {
  // Only remove files owned by this instance, never the picked original.
  private owned: Set<string> = new Set<string>();
  constructor(private root: string) {}
  private save(buffer: ArrayBuffer): string {
    checkTorrentBytes(buffer);
    const name = '.btmobile-import-' + util.generateRandomUUID() + '.torrent';
    const path = this.root + '/' + name;
    if (fs.accessSync(path)) throw new Error('临时文件名冲突，请重试');
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    this.owned.add(name);
    try {
      let written = 0;
      while (written < buffer.byteLength) {
        const count = fs.writeSync(file.fd, buffer.slice(written), { offset: written });
        if (count <= 0) throw new Error('无法完整保存 Torrent 文件');
        written += count;
      }
    } catch (e) { fs.closeSync(file); this.release(name); throw e; }
    fs.closeSync(file);
    return name;
  }
  fromFile(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(file.fd).size;
      if (size <= 0 || size > MAX_TORRENT_BYTES) throw new Error('Torrent 文件须大于 0 且不超过 16 MiB');
      const buffer = new ArrayBuffer(size);
      if (fs.readSync(file.fd, buffer, { offset: 0, length: size }) !== size) throw new Error('无法完整读取 Torrent 文件，请重新选择');
      return this.save(buffer);
    } finally { fs.closeSync(file); }
  }
  async fromUrl(value: string): Promise<string> {
    const address = torrentUrl(value);
    const request = http.createHttp();
    try {
      const response = await request.request(address, { method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER, maxLimit: MAX_TORRENT_BYTES,
        connectTimeout: 10000, readTimeout: 20000,
        header: { 'Accept': 'application/x-bittorrent, application/octet-stream;q=0.9, */*;q=0.1' } });
      if (response.responseCode !== 200) throw new Error('种子地址返回 HTTP ' + response.responseCode.toString());
      if (!(response.result instanceof ArrayBuffer)) throw new Error('种子地址未返回有效文件');
      return this.save(response.result);
    } finally { request.destroy(); }
  }
  release(name: string): void {
    if (!this.owned.has(name)) return;
    try { fs.unlinkSync(this.root + '/' + name); this.owned.delete(name); } catch (_) {}
  }
  releaseAll(): void { this.owned.forEach((name: string) => this.release(name)); }
}
