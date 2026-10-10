import media from '@ohos.multimedia.media';

export function trackLabel(track: media.MediaDescription, ordinal: number): string {
  const title = String(track['track_name'] ?? '').trim();
  const language = String(track['language'] ?? '').toLowerCase();
  let readable = language;
  if (['zh', 'chi', 'zho'].includes(language)) readable = '中文';
  else if (['zh-hans', 'zh-cn'].includes(language)) readable = '简体中文';
  else if (['zh-hant', 'zh-tw'].includes(language)) readable = '繁体中文';
  else if (['yue', 'zh-hk'].includes(language)) readable = '粤语';
  else if (['eng', 'en'].includes(language)) readable = '英语';
  else if (['jpn', 'ja'].includes(language)) readable = '日语';
  else if (['kor', 'ko'].includes(language)) readable = '韩语';
  else if (language === 'und') readable = '';
  if (title) return title + (readable && title.toLowerCase() !== readable.toLowerCase() ? ' · ' + readable : '');
  const kind = Number(track['track_type']) === 0 ? '音轨' : '字幕';
  return readable ? readable + ' · ' + kind + ' ' + (ordinal + 1) : kind + ' ' + (ordinal + 1) + ' · 未标注语言';
}

export function enrichTracks(nativeTracks: media.MediaDescription[], metadata: media.MediaDescription[]): media.MediaDescription[] {
  // The native selection ID must never be replaced by FFmpeg's stream index.
  // Only match same-type ordinal when both inventories have identical counts.
  return nativeTracks.map((track: media.MediaDescription) => {
    const type = Number(track['track_type']);
    const same = nativeTracks.filter((t: media.MediaDescription) => Number(t['track_type']) === type);
    const descriptions = metadata.filter((t: media.MediaDescription) => Number(t['track_type']) === type);
    const index = same.findIndex((t: media.MediaDescription) => Number(t['track_index']) === Number(track['track_index']));
    if (same.length !== descriptions.length || index < 0) return track;
    const description = descriptions[index];
    return { track_index: track['track_index'], track_type: track['track_type'], codec_mime: track['codec_mime'] ?? '',
      language: description['language'] || track['language'] || '', track_name: description['track_name'] || track['track_name'] || '' } as media.MediaDescription;
  });
}
