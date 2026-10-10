import { NetworkInfo } from './Native';

export interface NetworkDisplay { port: string; dht: string; trackers: string }

export function networkDisplay(network: NetworkInfo): NetworkDisplay {
  return {
    port: network.listening && network.listenPort > 0 ? network.listenPort.toString() : '未监听',
    dht: Math.max(0, network.dhtNodes).toString(),
    trackers: Math.max(0, network.trackerReplies).toString()
  };
}

// Successful deletion is already acknowledged by a toast. Keep failures visible.
export function deletionBanner(message: string): string {
  return message === '任务下载数据已删除' ? '' : message;
}
