import { TaskState } from './Native';

export function matchesTask(task: TaskState, keyword: string, filter: number): boolean {
  const words = keyword.trim().toLocaleLowerCase().split(/\s+/).filter((s: string) => s.length > 0);
  const haystack = (task.name + ' ' + task.id).toLocaleLowerCase();
  if (!words.every((word: string) => haystack.includes(word))) return false;
  if (filter === 1) return task.complete;
  if (filter === 2) return task.state === '下载中';
  if (filter === 3) return task.state === '做种中';
  if (filter === 4) return task.paused;
  if (filter === 5) return task.checking;
  if (filter === 6) return task.state === '获取元数据';
  return true;
}
