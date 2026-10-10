// Codec rejection and invalid player states must not be mistaken for buffering.
export function isAv1DecoderFailure(message: string, code: number): boolean {
  const text = message.toLowerCase();
  return (text.includes('video/av1') || text.includes('video/av01')) &&
    (code === 5400106 || text.includes('unsupported') || text.includes('unsupport') || text.includes('decoder'));
}
export function canControlPlayback(state: string): boolean {
  return ['prepared', 'playing', 'paused', 'completed'].includes(state);
}
