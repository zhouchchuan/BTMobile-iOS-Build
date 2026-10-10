import * as compat from 'libbtmedia.so';
import media from '@ohos.multimedia.media';

export interface CompatRequest { op: string; token?: number; surface?: string; fd?: number; url?: string; position?: number; track?: number }
export interface CompatStatus {
  token?: number; stale?: boolean; ready?: boolean; position?: number; duration?: number;
  playing?: boolean; waiting?: boolean; complete?: boolean; error?: string; warning?: string;
  tracks?: media.MediaDescription[]; subtitle?: string; decoder?: string;
  width?: number; height?: number; audioTrack?: number; subtitleTrack?: number;
}
export async function compatibility(request: CompatRequest): Promise<CompatStatus> {
  return JSON.parse(await compat.invoke(JSON.stringify(request))) as CompatStatus;
}
