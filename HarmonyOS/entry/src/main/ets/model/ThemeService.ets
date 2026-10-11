import common from '@ohos.app.ability.common';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import preferences from '@ohos.data.preferences';

export function validTheme(value: string): string {
  return value === 'light' || value === 'dark' ? value : 'system';
}
class ThemeService {
  private context: common.ApplicationContext | undefined = undefined;
  private store: preferences.Preferences | undefined = undefined;
  private writes: Promise<void> = Promise.resolve();
  async initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context.getApplicationContext();
    try {
      this.store = await preferences.getPreferences(context, { name: 'btmobile-settings' });
      this.apply(validTheme((await this.store.get('themeMode', 'system')) as string));
      AppStorage.setOrCreate('btmobileThemeReady', true);
    } catch (_) { AppStorage.setOrCreate('btmobileThemeReady', false); }
  }
  private apply(mode: string): void {
    if (!this.context) throw new Error('主题尚未就绪');
    this.context.setColorMode(mode === 'dark' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK :
      mode === 'light' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    AppStorage.setOrCreate('btmobileTheme', mode);
  }
  set(mode: string): Promise<void> {
    const next = validTheme(mode);
    const pending = this.writes.then(async () => {
      if (!this.store) throw new Error('主题设置尚未就绪，请稍后重试');
      const previous = AppStorage.get<string>('btmobileTheme') ?? 'system';
      this.apply(next);
      try { await this.store.put('themeMode', next); await this.store.flush(); }
      catch (e) { this.apply(previous); await this.store.put('themeMode', previous); throw e as Error; }
    });
    this.writes = pending.catch(() => {});
    return pending;
  }
}
export const themeService: ThemeService = new ThemeService();
