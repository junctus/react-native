import {NativeModules} from 'react-native';

interface NeoWindowModule {
  setTitle(title: string): Promise<string>;
  setContentWidth(width: number, animate: boolean): Promise<number>;
  setContentHeight(height: number, animate: boolean): Promise<number>;
}

const native: NeoWindowModule | undefined = NativeModules.NeoWindow;

/**
 * Window helpers (title, sizing). No-op if the native module is missing, e.g.
 * when running against a binary built before it existed.
 */
export const NeoWindow = {
  setTitle(title: string): Promise<string> {
    return native ? native.setTitle(title) : Promise.resolve(title);
  },
  setContentWidth(width: number, animate: boolean): Promise<number> {
    return native ? native.setContentWidth(width, animate) : Promise.resolve(0);
  },
  setContentHeight(height: number, animate: boolean): Promise<number> {
    return native
      ? native.setContentHeight(height, animate)
      : Promise.resolve(0);
  },
};
