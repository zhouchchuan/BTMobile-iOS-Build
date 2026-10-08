import * as native from 'libbtmobile.so';

export interface TaskInfo { id: string; name: string; progress: number; download: number; upload: number; peers: number; paused: boolean; state: string; error: string }
export interface TorrentFile { index: number; name: string; size: number; done: number }
export interface NativeResult { ok?: boolean; version?: string; id?: string; index?: number; complete?: boolean; url?: string; percent?: number; items?: TaskInfo[] }
export interface FileResult { items: TorrentFile[] }
export interface Request {
  op: string;
  root?: string;
  uri?: string;
  id?: string;
  index?: number;
  path?: string;
  output?: string;
  password?: string;
}
export async function call(request: Request): Promise<NativeResult> {
  return JSON.parse(await native.invoke(JSON.stringify(request))) as NativeResult;
}
export async function files(id: string): Promise<TorrentFile[]> {
  let request: Request = { op: 'files', id: id };
  return (JSON.parse(await native.invoke(JSON.stringify(request))) as FileResult).items;
}
export function bytes(size: number): string {
  if (size > 1073741824) return (size / 1073741824).toFixed(2) + ' GiB';
  if (size > 1048576) return (size / 1048576).toFixed(1) + ' MiB';
  if (size > 1024) return (size / 1024).toFixed(1) + ' KiB';
  return size.toFixed(0) + ' B';
}
