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

// NeoDaemon (the bundled `neo` CLI) is macOS-only — there's no such module on
// Android. `hasDaemon` lets the shared UI hide the relay + diagnostics features
// there, and the subscriptions below no-op instead of crashing.
export const NeoDaemon: NeoDaemonModule | undefined = NativeModules.NeoDaemon;
export const hasDaemon = !!NeoDaemon;

const noopSub = {remove() {}};
const neoEvents = NeoDaemon ? new NativeEventEmitter(NativeModules.NeoDaemon) : null;

export function onLog(handler: (e: LogEvent) => void) {
  return neoEvents ? neoEvents.addListener('neo-log', handler) : noopSub;
}

export function onState(handler: (e: StateEvent) => void) {
  return neoEvents ? neoEvents.addListener('neo-state', handler) : noopSub;
}
