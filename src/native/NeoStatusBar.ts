import {NativeEventEmitter, NativeModules} from 'react-native';

export interface MenuAction {
  action: 'start' | 'stop';
}

interface NeoStatusBarModule {
  install(): Promise<boolean>;
  setStatus(status: string): Promise<boolean>;
}

const native: NeoStatusBarModule | undefined = NativeModules.NeoStatusBar;

/**
 * macOS menu-bar item with Start/Stop Tunnel. No-ops if the native module is
 * missing (e.g. a binary built before it existed).
 */
export const NeoStatusBar = {
  install(): Promise<boolean> {
    return native ? native.install() : Promise.resolve(false);
  },
  setStatus(status: string): Promise<boolean> {
    return native ? native.setStatus(status) : Promise.resolve(false);
  },
  onMenuAction(handler: (e: MenuAction) => void) {
    if (!native) {
      return {remove() {}};
    }
    return new NativeEventEmitter(NativeModules.NeoStatusBar).addListener(
      'neo-menu-action',
      handler,
    );
  },
};
