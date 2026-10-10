import * as native from 'libbtmobile.so';

export interface TaskInfo { id: string; name: string; progress: number; done: number; total: number; checking: boolean; checkProgress: number; download: number; upload: number; peers: number; paused: boolean; active: boolean; state: string; error: string; complete?: boolean; added?: number; downloaded?: number; uploaded?: number; seeds?: number; swarmSeeds?: number; swarmPeers?: number }
@Observed
export class TaskState implements TaskInfo {
  id: string = ''; name: string = ''; progress: number = 0; done: number = 0; total: number = 0;
  checking: boolean = false; checkProgress: number = 0; download: number = 0; upload: number = 0;
  peers: number = 0; paused: boolean = false; active: boolean = false; state: string = ''; error: string = '';
  complete: boolean = false; added: number = 0; downloaded: number = 0; uploaded: number = 0;
  seeds: number = 0; swarmSeeds: number = -1; swarmPeers: number = -1;
  update(value: TaskInfo): void {
    this.id = value.id; this.name = value.name; this.progress = value.progress; this.done = value.done; this.total = value.total;
    this.checking = value.checking; this.checkProgress = value.checkProgress; this.download = value.download; this.upload = value.upload;
    this.peers = value.peers; this.paused = value.paused; this.active = value.active; this.state = value.state; this.error = value.error;
    this.complete = value.complete ?? false; this.added = value.added ?? 0; this.downloaded = value.downloaded ?? 0; this.uploaded = value.uploaded ?? 0;
    this.seeds = value.seeds ?? 0; this.swarmSeeds = value.swarmSeeds ?? -1; this.swarmPeers = value.swarmPeers ?? -1;
  }
}
export interface TorrentFile { index: number; name: string; size: number; done: number }
export interface NetworkInfo { listening: boolean; listenPort: number; configuredPort: number; dhtNodes: number; trackerReplies: number; trackerPeers: number; metadataReceived: number; listenError: string; trackerError: string; networkCode: number; interfaces: number; routes: number; recoveries: number }
export interface NetworkSettings { listenPort?: number; dht?: boolean; lsd?: boolean; natPmp?: boolean; upnp?: boolean; utp?: boolean; downloadLimitKiB?: number; uploadLimitKiB?: number; queueEnabled?: boolean; maxActive?: number; maxDownloads?: number; maxSeeds?: number; seedEnabled?: boolean; autoAddTrackers?: boolean; customTrackers?: string[] }
export interface CompletionEvent { id: string; name: string }
export interface NativeResult { ok?: boolean; duplicate?: boolean; revision?: number; version?: string; id?: string; index?: number; complete?: boolean; url?: string; percent?: number; items?: TaskInfo[]; network?: NetworkInfo; port?: number; settings?: NetworkSettings; defaultTrackers?: string[]; deletingData?: boolean; deletionMessage?: string; deletionRevision?: number; trackers?: string[]; events?: CompletionEvent[] }
export interface FileResult { items: TorrentFile[] }
export interface PeerInfo { address: string; client: string; download: number; upload: number; progress: number }
interface PeerResult { items: PeerInfo[] }
export interface Request {
  op: string;
  trackers?: string[];
  revision?: number;
  root?: string;
  uri?: string;
  id?: string;
  index?: number;
  path?: string;
  output?: string;
  password?: string;
  port?: number;
  settings?: NetworkSettings;
  deleteData?: boolean;
}
export async function call(request: Request): Promise<NativeResult> {
  return JSON.parse(await native.invoke(JSON.stringify(request))) as NativeResult;
}
export async function files(id: string): Promise<TorrentFile[]> {
  let request: Request = { op: 'files', id: id };
  return (JSON.parse(await native.invoke(JSON.stringify(request))) as FileResult).items;
}
export async function peers(id: string): Promise<PeerInfo[]> {
  let request: Request = { op: 'peers', id: id };
  return (JSON.parse(await native.invoke(JSON.stringify(request))) as PeerResult).items;
}
export function bytes(size: number): string {
  if (size > 1073741824) return (size / 1073741824).toFixed(2) + ' GiB';
  if (size > 1048576) return (size / 1048576).toFixed(1) + ' MiB';
  if (size > 1024) return (size / 1024).toFixed(1) + ' KiB';
  return size.toFixed(0) + ' B';
}

