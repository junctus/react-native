import {NativeEventEmitter, NativeModules} from 'react-native';

export interface IdentityInfo {
  nodeId: string;
  path: string;
  created: boolean;
}

export interface DaemonStartConfig {
  binPath?: string;
  mirrors?: string[];
  witnesses?: string[];
  identityPath?: string;
  extraArgs?: string[];
  env?: Record<string, string>;
  /** Pin the node's sockets to the physical interface (bypass a default-route VPN). */
  scopeInterface?: boolean;
}

export interface DaemonStartResult {
  pid: number;
  binPath: string;
  args: string[];
}

export interface DaemonStatus {
  running: boolean;
  pid: number | null;
  binPath: string | null;
  dataDir: string;
}

export interface ExecConfig {
  binPath?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
}

export interface ExecResult {
  code: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export interface LogEvent {
  stream: 'stdout' | 'stderr';
  line: string;
}

export interface StateEvent {
  running: boolean;
  exitCode?: number;
}

interface NeoCoreModule {
  getConstants(): {dataDir: string; identityPath: string};
  ensureIdentity(): Promise<IdentityInfo>;
  identitySecretBase64(): Promise<string>;
}

interface NeoDaemonModule {
  start(config: DaemonStartConfig): Promise<DaemonStartResult>;
  stop(): Promise<{stopped: boolean}>;
  status(): Promise<DaemonStatus>;
  exec(args: string[], config: ExecConfig): Promise<ExecResult>;
}

export const NeoCore: NeoCoreModule = NativeModules.NeoCore;
export const NeoDaemon: NeoDaemonModule = NativeModules.NeoDaemon;

export const neoEvents = new NativeEventEmitter(NativeModules.NeoDaemon);

export function onLog(handler: (e: LogEvent) => void) {
  return neoEvents.addListener('neo-log', handler);
}

export function onState(handler: (e: StateEvent) => void) {
  return neoEvents.addListener('neo-state', handler);
}
