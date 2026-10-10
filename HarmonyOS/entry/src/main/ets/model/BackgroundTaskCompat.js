import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import deviceInfo from '@ohos.deviceInfo';

// Typed JS interop keeps the API 12 build target while using documented optional
// API 15/20 lifecycle APIs on newer phones. No private API or permission bypass.
function eventSupported(type) {
  return deviceInfo.sdkApiVersion >= (type === 'continuousTaskCancel' ? 15 : 20);
}
export function onTaskEvent(type, listener) {
  if (eventSupported(type) && typeof backgroundTaskManager.on === 'function') {
    backgroundTaskManager.on(type, listener);
  }
}
export function offTaskEvent(type, listener) {
  if (eventSupported(type) && typeof backgroundTaskManager.off === 'function') {
    backgroundTaskManager.off(type, listener);
  }
}
export async function queryTasks(context) {
  if (deviceInfo.sdkApiVersion < 20 || typeof backgroundTaskManager.getAllContinuousTasks !== 'function') {
    throw new Error('Continuous task query requires API 20');
  }
  const tasks = await backgroundTaskManager.getAllContinuousTasks(context, true);
  return tasks.map(task => ({ abilityName: task.abilityName,
    notificationId: task.notificationId, continuousTaskId: task.continuousTaskId,
    suspendState: task.suspendState === true }));
}
export async function startTransfer(context, agent) {
  const result = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
  if (!result || !Number.isInteger(result.notificationId) || result.notificationId < 0) {
    throw new Error('System did not return a continuous task notification ID');
  }
  return { notificationId: result.notificationId,
    continuousTaskId: Number.isInteger(result.continuousTaskId) ? result.continuousTaskId : -1 };
}
