import {NativeEventEmitter, NativeModules} from 'react-native';

export type VPNStatus =
  | 'invalid'
  | 'disconnected'
  | 'connecting'
  | 'connected'
  | 'reasserting'
  | 'disconnecting'
  | 'unknown';

export interface VPNConnectConfig {
  /** The node identity secret, base64-encoded. */
  identityBase64: string;
  /** Discovery mirror base URLs to fetch the relay snapshot from. */
  mirrors: string[];
  /** Trusted witness keys, hex-encoded. */
  witnesses: string[];
  /** Required distinct witness signatures (defaults to witnesses.length). */
  threshold?: number;
  /** Relays per circuit; the last is the exit (defaults to 2). */
  hops?: number;
}

interface NeoVPNModule {
  connect(config: VPNConnectConfig): Promise<{started: boolean}>;
  disconnect(): Promise<{stopped: boolean}>;
  status(): Promise<{status: VPNStatus; installed: boolean}>;
}

export const NeoVPN: NeoVPNModule = NativeModules.NeoVPN;

const emitter = new NativeEventEmitter(NativeModules.NeoVPN);

export function onVPNState(handler: (e: {status: VPNStatus}) => void) {
  return emitter.addListener('neo-vpn-state', handler);
}
