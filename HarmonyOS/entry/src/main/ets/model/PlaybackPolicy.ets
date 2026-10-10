// Codec rejection and invalid player states must not be mistaken for buffering.
export function isAv1DecoderFailure(message: string, code: number): boolean {
  const text = message.toLowerCase();
  return (text.includes('video/av1') || text.includes('video/av01')) &&
    (code === 5400106 || text.includes('unsupported') || text.includes('unsupport') || text.includes('decoder'));
}
export function canControlPlayback(state: string): boolean {
  return ['prepared', 'playing', 'paused', 'completed'].includes(state);
}

export function clampSeekTarget(position: number, duration: number): number {
  if (!Number.isFinite(position) || !Number.isFinite(duration) || duration <= 0) return 0;
  return Math.floor(Math.max(0, Math.min(duration - 1, position)));
}

export function relativeSeekTarget(current: number, delta: number, duration: number, pending: number = -1): number {
  return clampSeekTarget((pending >= 0 ? pending : Math.max(0, current)) + delta, duration);
}
