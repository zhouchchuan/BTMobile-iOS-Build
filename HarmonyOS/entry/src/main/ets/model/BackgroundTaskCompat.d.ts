import common from '@ohos.app.ability.common';
import { WantAgent } from '@ohos.wantAgent';

export interface TaskEvent { id?: number; reason?: number; continuousTaskId?: number; suspendReason?: number }
export interface SystemTask { abilityName: string; notificationId: number; continuousTaskId: number; suspendState: boolean }
export interface StartedTask { notificationId: number; continuousTaskId: number }
export function onTaskEvent(type: string, listener: (event: TaskEvent) => void): void;
export function offTaskEvent(type: string, listener: (event: TaskEvent) => void): void;
export function queryTasks(context: common.UIAbilityContext): Promise<SystemTask[]>;
export function startTransfer(context: common.UIAbilityContext, agent: WantAgent): Promise<StartedTask>;
