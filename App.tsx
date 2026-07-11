/**
 * neo — macOS control app.
 *
 * Styled to the junctus "terminal specification" aesthetic: warm black,
 * phosphor green + amber, Instrument Serif display / Fragment Mono labels.
 *
 * Native modules:
 *  - NeoCore:   identity via the Rust core linked in-process (UniFFI).
 *  - NeoVPN:    installs/controls the system VPN (NeoTunnel packet-tunnel
 *               provider) that routes ALL traffic through neo's multi-hop network.
 *  - NeoDaemon: the bundled `neo` CLI for network diagnostics (snapshot/send).
 */

import React, {useCallback, useEffect, useRef, useState} from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import {
  IdentityInfo,
  NeoCore,
  NeoDaemon,
  onLog,
  onState,
} from './src/native/NeoNative';
import {NeoVPN, onVPNState, VPNStatus} from './src/native/NeoVPN';
import {NeoWindow} from './src/native/NeoWindow';
import {NeoStatusBar} from './src/native/NeoStatusBar';

// Bundled fonts (see macos/NeoMac-macOS/Fonts + ATSApplicationFontsPath).
const DISPLAY = 'Instrument Serif';
const MONO = 'Fragment Mono';
const BODY = 'Newsreader 16pt';

// Palette — mirrors the website's :root tokens.
const C = {
  bg: '#0a0c09',
  bgRaise: '#11140e',
  bgDeep: '#050605',
  black: '#000000',
  tx: '#e3e2d5',
  txSoft: '#9ba394',
  txFaint: '#667062',
  rule: 'rgba(227,226,213,0.18)',
  ruleSoft: 'rgba(227,226,213,0.08)',
  accent: '#3fd964',
  accentGlow: 'rgba(63,217,100,0.40)',
  accentDim: 'rgba(63,217,100,0.12)',
  warn: '#ffb454',
  danger: '#ff5a45',
  onAccent: '#04120a',
};

const MAX_LOG_LINES = 500;

// Discovery defaults are the core's baked-in mirrors + witness keys, read from
// `neo defaults` on launch (single source of truth). This initial mirror is only
// a placeholder until that load completes / in case it fails.
const DEFAULT_MIRROR = 'https://discovery.junctus.org';
const HEX_KEY = /^[0-9a-f]{64}$/i;

interface Defaults {
  mirrors: string[];
  witnesses: string[];
  threshold: number;
}

// Window geometry: the log pane is always shown to the right of the controls, so
// the window is always the full width. A minimum height keeps the log usefully
// tall even when the controls column is short.
const CONTROLS_W = 432;
const PANE_MARGIN = 16;
const LOG_PANE_W = 420;
const FULL_CONTENT_W = CONTROLS_W + LOG_PANE_W + PANE_MARGIN;
const MIN_CONTENT_H = 520;

// The core's privacy dial (neo_core::PrivacyLevel / neo_mix::MixParams::for_level).
// Each level sets the circuit length and the mixing/cover posture; the app drives
// the hop count today (deeper timing-mix + cover wiring in the multi-hop stack is
// the next core step). Mirrors the levels described on junctus.org.
type PrivacyLevel = 'off' | 'balanced' | 'paranoid';

interface LevelSpec {
  key: PrivacyLevel;
  name: string;
  hops: number;
  timing: string;
  cover: string;
  latency: number; // 0..1, for the latency-cost bar
  isDefault?: boolean;
  blurb: string;
}

const LEVELS: LevelSpec[] = [
  {
    key: 'off',
    name: 'Low',
    hops: 1,
    timing: 'none',
    cover: 'none',
    latency: 0.12,
    blurb: 'Lowest overhead — a single hop, no cover or mixing. Fast, minimal anonymity.',
  },
  {
    key: 'balanced',
    name: 'Balanced',
    hops: 3,
    timing: 'moderate per-hop',
    cover: 'periodic',
    latency: 0.5,
    isDefault: true,
    blurb: 'A sane default: a 3-hop circuit with moderate mixing and cover.',
  },
  {
    key: 'paranoid',
    name: 'Paranoid',
    hops: 5,
    timing: 'deep per-hop',
    cover: 'heavy, near constant-rate',
    latency: 0.92,
    blurb: 'Maximum anonymity: heavy cover traffic, deep mixing, committee exits.',
  },
];

const TRILEMMA =
  'The anonymity trilemma: strong anonymity, low latency, low overhead — pick ' +
  'two. The dial decides which two. There is no fourth option.';

interface LogLine {
  id: number;
  stream: string;
  line: string;
}

function parseList(raw: string): string[] {
  return raw
    .split(/[\s,]+/)
    .map(s => s.trim())
    .filter(Boolean);
}

const VPN_BUSY: VPNStatus[] = ['connecting', 'disconnecting', 'reasserting'];

export default function App(): React.JSX.Element {
  const [identity, setIdentity] = useState<IdentityInfo | null>(null);
  const [identityError, setIdentityError] = useState<string | null>(null);
  const [vpnStatus, setVpnStatus] = useState<VPNStatus>('disconnected');
  const [vpnError, setVpnError] = useState<string | null>(null);
  const [mirrorsRaw, setMirrorsRaw] = useState(DEFAULT_MIRROR);
  const [witnessesRaw, setWitnessesRaw] = useState('');
  const [privacy, setPrivacy] = useState<PrivacyLevel>('balanced');
  const [message, setMessage] = useState('no relay on this path can read me');
  const [hops, setHops] = useState(2);
  const [busy, setBusy] = useState<string | null>(null);
  const [relayRunning, setRelayRunning] = useState(false);
  const [relayEnabled, setRelayEnabled] = useState(true);
  const [relayExit, setRelayExit] = useState(false);
  const [announceAddr, setAnnounceAddr] = useState('');
  const [relayError, setRelayError] = useState<string | null>(null);
  const [logs, setLogs] = useState<LogLine[]>([]);
  const [diagOpen, setDiagOpen] = useState(false);
  const [advOpen, setAdvOpen] = useState(false);
  const logScroll = useRef<ScrollView>(null);
  // A ref (not a module global) so the id counter survives Fast Refresh — a
  // reset while `logs` state persists would mint duplicate React keys.
  const nextLogId = useRef(1);
  const prevVpnStatus = useRef<VPNStatus>('disconnected');
  const navHeight = useRef(0);
  const controlsHeight = useRef(0);
  const lastFitHeight = useRef(0);

  // Fit the window height to the controls content (nav + cards), so there's no
  // dead space below and the height tracks sections expanding/collapsing.
  const fitWindowHeight = useCallback(() => {
    if (navHeight.current > 0 && controlsHeight.current > 0) {
      // Round to whole points: a fractional content height puts text on
      // half-pixel boundaries on Retina, which renders blurry until a resize.
      // Never shorter than MIN_CONTENT_H so the always-visible log has room.
      const h = Math.max(
        MIN_CONTENT_H,
        Math.round(navHeight.current + controlsHeight.current),
      );
      const last = lastFitHeight.current;
      // Symmetric dead-band: ignore sub-4px changes in EITHER direction. RN
      // re-measures the ScrollView content a pixel or two off after each resize;
      // reacting to that jitter caused an endless wobble (and, when grow-biased,
      // ratcheted the window taller than the content). Real content changes
      // (sections toggling, errors appearing) are far larger than the band.
      if (last !== 0 && Math.abs(h - last) <= 3) {
        return;
      }
      lastFitHeight.current = h;
      NeoWindow.setContentHeight(h, false).catch(() => {});
    }
  }, []);

  const appendLog = useCallback((stream: string, line: string) => {
    // Compute the id once, outside the updater, so a double-invoked updater
    // (StrictMode) can't consume two ids or duplicate one.
    const id = nextLogId.current++;
    setLogs(prev => {
      const next = [...prev, {id, stream, line}];
      return next.length > MAX_LOG_LINES
        ? next.slice(next.length - MAX_LOG_LINES)
        : next;
    });
  }, []);

  useEffect(() => {
    NeoWindow.setTitle('Junctus Neo').catch(() => {});
    NeoWindow.setContentWidth(FULL_CONTENT_W, false).catch(() => {});
  }, []);

  // Prefill mirrors + witness keys from the core's baked-in defaults, so the app
  // is one-click and shows exactly what it trusts (no trust-on-first-use).
  useEffect(() => {
    NeoDaemon.exec(['defaults'], {timeoutMs: 10_000})
      .then(res => {
        if (res.code !== 0) {
          return;
        }
        const d: Defaults = JSON.parse(res.stdout);
        if (Array.isArray(d.mirrors) && d.mirrors.length > 0) {
          setMirrorsRaw(d.mirrors.join('\n'));
        }
        if (Array.isArray(d.witnesses) && d.witnesses.length > 0) {
          setWitnessesRaw(d.witnesses.join(' '));
        }
      })
      .catch(() => {});
  }, []);

  useEffect(() => {
    NeoCore.ensureIdentity()
      .then(setIdentity)
      .catch(e => setIdentityError(String(e?.message ?? e)));

    NeoVPN.status()
      .then(s => setVpnStatus(s.status))
      .catch(() => {});

    NeoDaemon.status()
      .then(s => setRelayRunning(s.running))
      .catch(() => {});

    const logSub = onLog(e => appendLog(e.stream, e.line));
    const stateSub = onState(e => {
      setRelayRunning(e.running);
      if (!e.running) {
        appendLog('app', `relay exited (code ${e.exitCode ?? '?'})`);
      }
    });
    const vpnSub = onVPNState(e => {
      setVpnStatus(e.status);
      appendLog('vpn', `status: ${e.status}`);
    });
    return () => {
      logSub.remove();
      stateSub.remove();
      vpnSub.remove();
    };
  }, [appendLog]);

  useEffect(() => {
    logScroll.current?.scrollToEnd({animated: false});
  }, [logs]);

  // Tie the relay's lifetime to the tunnel: when the tunnel settles back down
  // after an attempt (e.g. it couldn't build a circuit), stop the relay too, so
  // it doesn't linger holding its listen port and collide with the next attempt.
  useEffect(() => {
    const prev = prevVpnStatus.current;
    prevVpnStatus.current = vpnStatus;
    const settledDown = vpnStatus === 'disconnected' || vpnStatus === 'invalid';
    const wasActive =
      prev === 'connecting' ||
      prev === 'connected' ||
      prev === 'reasserting' ||
      prev === 'disconnecting';
    if (settledDown && wasActive && relayRunning) {
      NeoDaemon.stop()
        .then(() => appendLog('app', 'relay stopped (tunnel down)'))
        .catch(() => {});
    }
  }, [vpnStatus, relayRunning, appendLog]);

  const mirrors = parseList(mirrorsRaw);
  const mirrorArgs = mirrors.flatMap(m => ['--mirror', m]);
  const vpnConnected = vpnStatus === 'connected';
  const vpnBusy = VPN_BUSY.includes(vpnStatus);

  // Witness keys: normally the baked-in key prefilled above. Only if that field
  // is somehow empty do we fall back to fetching `GET /witness` from the mirror
  // and pinning it (trust-on-first-use — weaker; the mirror becomes the root).
  const ensureWitnesses = useCallback(async (): Promise<string[]> => {
    const typed = parseList(witnessesRaw);
    if (typed.length > 0) {
      return typed;
    }
    for (const mirror of parseList(mirrorsRaw)) {
      const url = `${mirror.replace(/\/+$/, '')}/witness`;
      try {
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), 10_000);
        const res = await fetch(url, {signal: abort.signal});
        clearTimeout(timer);
        const body = (await res.text()).trim();
        if (res.ok && HEX_KEY.test(body)) {
          setWitnessesRaw(body);
          appendLog(
            'app',
            `pinned witness ${body.slice(0, 16)}… from ${mirror} (trust-on-first-use)`,
          );
          return [body];
        }
        appendLog('app', `${url}: unexpected response (${res.status})`);
      } catch (e: any) {
        appendLog('app', `${url}: ${e?.message ?? e}`);
      }
    }
    throw new Error(
      'no witness key — could not fetch one from the mirrors; enter it manually',
    );
  }, [appendLog, mirrorsRaw, witnessesRaw]);

  const connectVpn = useCallback(async () => {
    setVpnError(null);
    setRelayError(null);
    const vpnMirrors = parseList(mirrorsRaw);
    if (vpnMirrors.length === 0) {
      setVpnError('enter at least one discovery mirror');
      return;
    }
    let witnesses: string[];
    try {
      witnesses = await ensureWitnesses();
    } catch (e: any) {
      setVpnError(String(e?.message ?? e));
      return;
    }
    // Start the relay first so it binds and registers before the tunnel
    // captures the default route. A relay failure doesn't block the tunnel.
    let startedRelay = false;
    if (relayEnabled && !relayRunning) {
      try {
        const extraArgs = ['--relay'];
        if (relayExit) {
          extraArgs.push('--exit');
        }
        if (announceAddr.trim()) {
          extraArgs.push('--announce-addr', announceAddr.trim());
        }
        const res = await NeoDaemon.start({
          mirrors: vpnMirrors,
          witnesses,
          extraArgs,
          // Keep the relay's own traffic off the tunnel we're about to raise.
          scopeInterface: true,
        });
        startedRelay = true;
        appendLog('app', `relay started (pid ${res.pid})`);
      } catch (e: any) {
        setRelayError(`relay: ${e?.message ?? e}`);
      }
    }
    try {
      const secret = await NeoCore.identitySecretBase64();
      const levelName = LEVELS.find(l => l.key === privacy)?.name ?? privacy;
      appendLog('vpn', `connecting — ${levelName} privacy, all traffic tunneled`);
      await NeoVPN.connect({
        identityBase64: secret,
        mirrors: vpnMirrors,
        witnesses,
        threshold: witnesses.length,
        privacy,
      });
    } catch (e: any) {
      const msg = String(e?.message ?? e);
      setVpnError(msg);
      appendLog('vpn', `connect failed: ${msg}`);
      // The tunnel never started, so don't leave the relay we just spawned
      // running (it would hold its port and collide with the next attempt).
      if (startedRelay) {
        await NeoDaemon.stop().catch(() => {});
      }
    }
  }, [
    announceAddr,
    appendLog,
    ensureWitnesses,
    mirrorsRaw,
    privacy,
    relayEnabled,
    relayExit,
    relayRunning,
  ]);

  const disconnectVpn = useCallback(async () => {
    try {
      await NeoVPN.disconnect();
    } catch (e: any) {
      appendLog('vpn', `disconnect failed: ${e?.message ?? e}`);
    }
    // Always stop the relay too. stop() is idempotent, so this is robust even if
    // our relayRunning state is stale (e.g. the relay was started in a prior run).
    try {
      const res = await NeoDaemon.stop();
      if (res.stopped) {
        appendLog('app', 'relay stopped');
      }
    } catch (e: any) {
      appendLog('app', `relay stop failed: ${e?.message ?? e}`);
    }
  }, [appendLog]);

  // Menu-bar item (Start/Stop Tunnel). Keep refs to the latest handlers so the
  // one-time subscription always calls the current config.
  const connectRef = useRef(connectVpn);
  const disconnectRef = useRef(disconnectVpn);
  connectRef.current = connectVpn;
  disconnectRef.current = disconnectVpn;

  useEffect(() => {
    NeoStatusBar.install()
      .then(ok =>
        appendLog(
          'app',
          ok ? 'menu-bar controls ready' : 'menu-bar module unavailable',
        ),
      )
      .catch(() => {});
    const sub = NeoStatusBar.onMenuAction(e => {
      if (e.action === 'start') {
        connectRef.current();
      } else {
        disconnectRef.current();
      }
    });
    return () => sub.remove();
  }, [appendLog]);

  useEffect(() => {
    NeoStatusBar.setStatus(vpnStatus).catch(() => {});
  }, [vpnStatus]);

  const runOneShot = useCallback(
    async (label: string, args: string[]) => {
      setBusy(label);
      // The bundled CLI has no baked-in witness keys, so pass ours along.
      try {
        const witnesses = await ensureWitnesses();
        args = [...args, ...witnesses.flatMap(w => ['--witness', w])];
      } catch (e: any) {
        appendLog('stderr', `error: ${e?.message ?? e}`);
        setBusy(null);
        return;
      }
      appendLog('app', `$ neo ${args.join(' ')}`);
      try {
        const res = await NeoDaemon.exec(args, {timeoutMs: 60_000});
        // Stream the one-shot command's output into the live log.
        for (const line of res.stdout.split('\n')) {
          if (line.trim()) {
            appendLog('stdout', line);
          }
        }
        for (const line of res.stderr.split('\n')) {
          if (line.trim()) {
            appendLog('stderr', line);
          }
        }
        appendLog('app', `exit ${res.timedOut ? 'timeout' : res.code}`);
      } catch (e: any) {
        appendLog('stderr', `error: ${e?.message ?? e}`);
      } finally {
        setBusy(null);
      }
    },
    [appendLog, ensureWitnesses],
  );

  const statusTone: Tone = vpnConnected
    ? 'accent'
    : vpnBusy
    ? 'warn'
    : 'faint';

  return (
    <View style={styles.root}>
      {/* top bar */}
      <View
        style={styles.nav}
        onLayout={e => {
          navHeight.current = e.nativeEvent.layout.height;
          fitWindowHeight();
        }}>
        <Text style={styles.wordmark}>
          <Text style={styles.wordmarkJunctus}>junctus </Text>neo
        </Text>
        <View style={styles.flex} />
        <StatusChip
          tone={statusTone}
          label={
            vpnConnected
              ? 'all traffic tunneled'
              : vpnBusy
              ? vpnStatus
              : 'not tunneled'
          }
        />
      </View>

      <View style={styles.body}>
        {/* left column: controls */}
        <ScrollView
          style={styles.controls}
          contentContainerStyle={styles.controlsInner}
          onContentSizeChange={(_w, h) => {
            controlsHeight.current = h;
            fitWindowHeight();
          }}>
          <Card no="01" title="identity">
            {identity ? (
              <>
                <Text style={styles.nodeId} selectable>
                  {identity.nodeId}
                </Text>
                <Text style={styles.hint} numberOfLines={1}>
                  {identity.created ? 'generated on first launch' : 'loaded'} ·{' '}
                  {identity.path}
                </Text>
              </>
            ) : identityError ? (
              <Text style={styles.error}>{identityError}</Text>
            ) : (
              <ActivityIndicator color={C.accent} />
            )}
          </Card>

          <Card no="02" title="route all traffic">
            <PrivacyDial
              value={privacy}
              onChange={setPrivacy}
              disabled={vpnConnected || vpnBusy}
            />
            <View style={styles.gap} />
            <View style={styles.rowBetween}>
              <Check
                label="relay node"
                value={relayEnabled}
                onChange={setRelayEnabled}
                disabled={vpnConnected || vpnBusy || relayRunning}
              />
              <Check
                label="offer clearnet exit"
                value={relayExit}
                onChange={setRelayExit}
                disabled={
                  !relayEnabled || vpnConnected || vpnBusy || relayRunning
                }
              />
            </View>
            <View style={styles.gap} />
            <Button
              wide
              label={
                vpnConnected
                  ? 'disconnect'
                  : vpnBusy
                  ? vpnStatus
                  : 'start tunnel'
              }
              kind={vpnConnected ? 'danger' : 'solid'}
              disabled={vpnBusy}
              onPress={vpnConnected ? disconnectVpn : connectVpn}
            />
            {relayRunning && (
              <Text style={[styles.relayState, styles.relayStateOn]}>
                ● relaying{relayExit ? ' + exit' : ''}
              </Text>
            )}
            {vpnError && <Text style={styles.error}>{vpnError}</Text>}
            {relayError && <Text style={styles.error}>{relayError}</Text>}
            <Pressable onPress={() => setAdvOpen(o => !o)}>
              {({pressed}) => (
                <View style={[styles.rowCenter, styles.advToggle]}>
                  <Text
                    style={[
                      styles.label,
                      styles.labelInline,
                      pressed && styles.advLabelOn,
                    ]}>
                    advanced
                  </Text>
                  <Text
                    style={[styles.paneArrow, pressed && styles.paneArrowOn]}>
                    {advOpen ? '▾' : '▸'}
                  </Text>
                </View>
              )}
            </Pressable>
            {advOpen && (
              <>
                <Label>discovery mirrors</Label>
                <Field
                  value={mirrorsRaw}
                  onChangeText={setMirrorsRaw}
                  placeholder="http://127.0.0.1:8899"
                  editable={!vpnConnected && !vpnBusy}
                />
                <Label>trusted witness keys (hex)</Label>
                <Field
                  value={witnessesRaw}
                  onChangeText={setWitnessesRaw}
                  placeholder="baked-in default; fetched from mirror if cleared"
                  editable={!vpnConnected && !vpnBusy}
                />
                <Label>relay announce address (public host:port)</Label>
                <Field
                  value={announceAddr}
                  onChangeText={setAnnounceAddr}
                  placeholder="auto — set this behind NAT"
                  editable={!relayRunning && !vpnBusy}
                />
              </>
            )}
          </Card>

          <Card
            no="03"
            title="diagnostics"
            collapsed={!diagOpen}
            onToggle={() => setDiagOpen(o => !o)}>
            <Text style={styles.note}>
              uses the mirrors and witness keys above (auto-fetched if empty).
            </Text>
            <View style={styles.gap} />
            <Button
              label="fetch relay snapshot"
              disabled={busy !== null}
              onPress={() => runOneShot('snapshot', ['snapshot', ...mirrorArgs])}
            />
            <View style={styles.gap} />
            <Label>send through an onion circuit</Label>
            <Field value={message} onChangeText={setMessage} />
            <View style={styles.rowBetween}>
              <View style={styles.rowCenter}>
                <Label inline>hops</Label>
                <Stepper value={hops} min={1} max={5} onChange={setHops} />
              </View>
              <Button
                label={busy === 'send' ? 'sending…' : 'send'}
                disabled={busy !== null || !message.trim()}
                onPress={() =>
                  runOneShot('send', [
                    'send',
                    '--message',
                    message,
                    '--hops',
                    String(hops),
                    ...mirrorArgs,
                  ])
                }
              />
            </View>
          </Card>

        </ScrollView>

        {/* right column: live log pane, always visible */}
        <View style={styles.logPane}>
          <View style={styles.logHead}>
            <Text style={styles.cardNo}>04</Text>
            <Text style={styles.cardTitle}>log</Text>
            <View style={styles.flex} />
            <Pressable onPress={() => setLogs([])} hitSlop={6}>
              {({pressed}) => (
                <Text style={[styles.clear, pressed && styles.clearOn]}>
                  clear
                </Text>
              )}
            </Pressable>
          </View>
          <ScrollView ref={logScroll} style={styles.logScroll}>
            {logs.length === 0 ? (
              <Text style={styles.hint}>
                events and daemon output stream here
              </Text>
            ) : (
              logs.map(l => (
                <Text key={l.id} style={styles.logLine} selectable>
                  <Text style={logTagStyle(l.stream)}>
                    {l.stream.padEnd(7)}
                  </Text>
                  {l.line}
                </Text>
              ))
            )}
          </ScrollView>
        </View>
      </View>
    </View>
  );
}

type Tone = 'accent' | 'warn' | 'danger' | 'faint';

function logTagStyle(stream: string) {
  if (stream === 'app' || stream === 'vpn') {
    return styles.logTagApp;
  }
  return stream === 'stderr' ? styles.logTagErr : styles.logTagOut;
}

function StatusChip({tone, label}: {tone: Tone; label: string}) {
  const dotColor =
    tone === 'accent' ? C.accent : tone === 'warn' ? C.warn : C.txFaint;
  return (
    <View style={styles.chip}>
      <View
        style={[
          styles.chipDot,
          {backgroundColor: dotColor},
          tone === 'accent' && styles.chipDotGlow,
        ]}
      />
      <Text style={styles.chipText}>{label}</Text>
    </View>
  );
}

function Card({
  no,
  title,
  children,
  collapsed,
  onToggle,
}: {
  no: string;
  title: string;
  children: React.ReactNode;
  collapsed?: boolean;
  onToggle?: () => void;
}) {
  const head = (pressed: boolean) => (
    <View style={[styles.cardHead, collapsed && styles.cardHeadCollapsed]}>
      <Text style={styles.cardNo}>{no}</Text>
      <Text style={styles.cardTitle}>{title}</Text>
      {onToggle && (
        <>
          <View style={styles.flex} />
          <Text style={[styles.paneArrow, pressed && styles.paneArrowOn]}>
            {collapsed ? '▸' : '▾'}
          </Text>
        </>
      )}
    </View>
  );
  return (
    <View style={styles.card}>
      {onToggle ? (
        <Pressable onPress={onToggle}>{({pressed}) => head(pressed)}</Pressable>
      ) : (
        head(false)
      )}
      {!collapsed && children}
    </View>
  );
}

function Label({
  children,
  inline,
}: {
  children: React.ReactNode;
  inline?: boolean;
}) {
  return <Text style={[styles.label, inline && styles.labelInline]}>{children}</Text>;
}

function Check({
  label,
  value,
  onChange,
  disabled,
}: {
  label: string;
  value: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <Pressable
      onPress={() => onChange(!value)}
      disabled={disabled}
      hitSlop={4}>
      {({pressed}) => (
        <View style={[styles.rowCenter, disabled && styles.btnDim]}>
          <View
            style={[
              styles.checkBox,
              value && styles.checkBoxOn,
              pressed && styles.checkBoxPressed,
            ]}
          />
          <Text style={styles.checkLabel}>{label}</Text>
        </View>
      )}
    </Pressable>
  );
}

function Field(props: React.ComponentProps<typeof TextInput>) {
  return (
    <TextInput
      {...props}
      style={styles.input}
      placeholderTextColor={C.txFaint}
      autoCapitalize="none"
      autoCorrect={false}
    />
  );
}

function Button({
  label,
  onPress,
  disabled,
  kind = 'ghost',
  wide,
}: {
  label: string;
  onPress: () => void;
  disabled?: boolean;
  kind?: 'ghost' | 'solid' | 'danger';
  wide?: boolean;
}) {
  return (
    <Pressable onPress={onPress} disabled={disabled} style={wide && styles.flex}>
      {({pressed}) => (
        <View
          style={[
            styles.btn,
            wide && styles.btnWide,
            kind === 'solid' && styles.btnSolid,
            kind === 'danger' && styles.btnDanger,
            pressed && kind === 'ghost' && styles.btnGhostOn,
            (pressed || disabled) && styles.btnDim,
          ]}>
          <Text
            style={[
              styles.btnText,
              kind === 'solid' && styles.btnTextSolid,
              kind === 'danger' && styles.btnTextDanger,
            ]}>
            {label}
          </Text>
        </View>
      )}
    </Pressable>
  );
}

function PrivacyDial({
  value,
  onChange,
  disabled,
}: {
  value: PrivacyLevel;
  onChange: (v: PrivacyLevel) => void;
  disabled?: boolean;
}) {
  const spec = LEVELS.find(l => l.key === value) ?? LEVELS[1];
  return (
    <View>
      <Text style={styles.dialLabel}>config · privacy_level</Text>
      <View style={styles.dialOpts}>
        {LEVELS.map((l, i) => (
          <Pressable
            key={l.key}
            style={styles.flex}
            onPress={() => onChange(l.key)}
            disabled={disabled}>
            {({pressed}) => (
              <View
                style={[
                  styles.dialOpt,
                  i > 0 && styles.dialOptDivided,
                  value === l.key && styles.dialOptOn,
                  pressed && value !== l.key && styles.dialOptHover,
                ]}>
                <Text
                  style={[
                    styles.dialOptName,
                    value === l.key && styles.dialOptNameOn,
                  ]}>
                  {l.name}
                </Text>
                <Text
                  style={[
                    styles.dialOptTag,
                    value === l.key && styles.dialOptTagOn,
                  ]}>
                  {l.isDefault ? 'default' : ' '}
                </Text>
              </View>
            )}
          </Pressable>
        ))}
      </View>
      <Text style={styles.dialTrilemma}>{TRILEMMA}</Text>
      <Text style={styles.dialBlurb}>{spec.blurb}</Text>
      <View style={styles.dialSpecs}>
        <SpecRow k="timing mixing" v={spec.timing} />
        <SpecRow k="cover traffic" v={spec.cover} />
        <SpecRow k="route" v={`${spec.hops}-hop circuit`} />
        <View style={styles.specRow}>
          <Text style={styles.specKey}>latency cost</Text>
          <View style={styles.meterTrack}>
            <View style={[styles.meterFill, {width: `${spec.latency * 100}%`}]} />
          </View>
        </View>
      </View>
    </View>
  );
}

function SpecRow({k, v}: {k: string; v: string}) {
  return (
    <View style={styles.specRow}>
      <Text style={styles.specKey}>{k}</Text>
      <Text style={styles.specVal}>{v}</Text>
    </View>
  );
}

function Stepper({
  value,
  min,
  max,
  onChange,
}: {
  value: number;
  min: number;
  max: number;
  onChange: (v: number) => void;
}) {
  return (
    <View style={styles.stepper}>
      <Pressable
        onPress={() => onChange(Math.max(min, value - 1))}
        style={styles.stepBtn}>
        <Text style={styles.stepText}>−</Text>
      </Pressable>
      <Text style={styles.stepValue}>{value}</Text>
      <Pressable
        onPress={() => onChange(Math.min(max, value + 1))}
        style={[styles.stepBtn, styles.stepBtnRight]}>
        <Text style={styles.stepText}>+</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: C.bg},
  flex: {flex: 1},

  // top bar
  nav: {
    flexDirection: 'row',
    alignItems: 'baseline',
    paddingHorizontal: 22,
    paddingTop: 6,
    paddingBottom: 10,
    borderBottomWidth: 1,
    borderBottomColor: C.rule,
    backgroundColor: C.bg,
  },
  wordmark: {
    color: C.accent,
    fontSize: 30,
    fontFamily: DISPLAY,
    letterSpacing: 0.5,
    textShadowColor: C.accentGlow,
    textShadowOffset: {width: 0, height: 0},
    textShadowRadius: 16,
  },
  wordmarkJunctus: {color: C.tx, textShadowColor: 'transparent'},

  // status chip
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderColor: C.rule,
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  chipDot: {width: 7, height: 7, marginRight: 8},
  chipDotGlow: {
    shadowColor: C.accent,
    shadowOpacity: 0.9,
    shadowRadius: 5,
    shadowOffset: {width: 0, height: 0},
  },
  chipText: {
    color: C.tx,
    fontFamily: MONO,
    fontSize: 11,
    letterSpacing: 1,
    textTransform: 'uppercase',
  },

  body: {flex: 1, flexDirection: 'row'},

  // left controls column
  controls: {width: CONTROLS_W, flexGrow: 0},
  controlsInner: {padding: 16},

  card: {
    backgroundColor: C.bgDeep,
    borderWidth: 1,
    borderColor: C.rule,
    padding: 16,
    marginBottom: 14,
  },
  cardHead: {
    flexDirection: 'row',
    alignItems: 'baseline',
    marginBottom: 12,
  },
  cardHeadCollapsed: {marginBottom: 0},
  paneArrow: {color: C.txFaint, fontFamily: MONO, fontSize: 13},
  paneArrowOn: {color: C.accent},
  cardNo: {
    color: C.accent,
    fontFamily: MONO,
    fontSize: 11,
    letterSpacing: 1.6,
    marginRight: 10,
  },
  cardTitle: {
    color: C.txSoft,
    fontFamily: MONO,
    fontSize: 11,
    letterSpacing: 1.8,
    textTransform: 'uppercase',
  },

  nodeId: {color: C.tx, fontFamily: MONO, fontSize: 15, letterSpacing: 0.3},
  hint: {color: C.txFaint, fontFamily: MONO, fontSize: 11, marginTop: 8},
  note: {
    color: C.txSoft,
    fontFamily: BODY,
    fontSize: 13,
    fontStyle: 'italic',
    lineHeight: 19,
    marginTop: 10,
  },
  error: {color: C.danger, fontFamily: MONO, fontSize: 12, marginTop: 10},

  label: {
    color: C.txFaint,
    fontFamily: MONO,
    fontSize: 10.5,
    letterSpacing: 1.4,
    textTransform: 'uppercase',
    marginBottom: 7,
  },
  labelInline: {marginBottom: 0, marginRight: 10},

  input: {
    backgroundColor: C.black,
    borderWidth: 1,
    borderColor: C.rule,
    color: C.tx,
    fontFamily: MONO,
    fontSize: 12.5,
    paddingHorizontal: 10,
    paddingVertical: 8,
    marginBottom: 12,
  },

  rowBetween: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  rowCenter: {flexDirection: 'row', alignItems: 'center'},
  gap: {height: 12},
  advToggle: {marginTop: 14, marginBottom: 4},
  advLabelOn: {color: C.accent},

  // check + relay status
  checkBox: {
    width: 12,
    height: 12,
    borderWidth: 1,
    borderColor: C.rule,
    marginRight: 9,
  },
  checkBoxOn: {backgroundColor: C.accent, borderColor: C.accent},
  checkBoxPressed: {borderColor: C.accent},
  checkLabel: {
    color: C.txSoft,
    fontFamily: MONO,
    fontSize: 11,
    letterSpacing: 1.2,
    textTransform: 'uppercase',
  },
  relayState: {
    color: C.txFaint,
    fontFamily: MONO,
    fontSize: 11,
    letterSpacing: 1.2,
    textTransform: 'uppercase',
    marginTop: 10,
  },
  relayStateOn: {color: C.accent},

  // privacy dial
  dialLabel: {
    color: C.txFaint,
    fontFamily: MONO,
    fontSize: 10.5,
    letterSpacing: 1.8,
    textTransform: 'uppercase',
    marginBottom: 10,
  },
  dialOpts: {flexDirection: 'row', borderWidth: 1, borderColor: C.rule},
  dialOpt: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 12,
    paddingHorizontal: 6,
  },
  dialOptDivided: {borderLeftWidth: 1, borderLeftColor: C.rule},
  dialOptOn: {backgroundColor: C.accent},
  dialOptHover: {backgroundColor: C.bgRaise},
  dialOptName: {
    color: C.txSoft,
    fontFamily: MONO,
    fontSize: 12,
    letterSpacing: 1.5,
    textTransform: 'uppercase',
  },
  dialOptNameOn: {color: C.onAccent},
  dialOptTag: {
    color: C.txFaint,
    fontFamily: MONO,
    fontSize: 9,
    letterSpacing: 1.2,
    textTransform: 'uppercase',
    marginTop: 4,
  },
  dialOptTagOn: {color: C.onAccent, opacity: 0.65},
  dialTrilemma: {
    color: C.txSoft,
    fontFamily: BODY,
    fontStyle: 'italic',
    fontSize: 12.5,
    lineHeight: 18,
    borderLeftWidth: 2,
    borderLeftColor: C.accent,
    paddingLeft: 10,
    marginTop: 12,
  },
  dialBlurb: {
    color: C.txFaint,
    fontFamily: MONO,
    fontSize: 10.5,
    lineHeight: 15,
    marginTop: 10,
  },
  dialSpecs: {marginTop: 12, borderTopWidth: 1, borderTopColor: C.ruleSoft},
  specRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: C.ruleSoft,
  },
  specKey: {
    color: C.txFaint,
    fontFamily: MONO,
    fontSize: 9.5,
    letterSpacing: 1.3,
    textTransform: 'uppercase',
    width: 108,
  },
  specVal: {flex: 1, color: C.tx, fontFamily: MONO, fontSize: 11.5},
  meterTrack: {
    flex: 1,
    height: 6,
    borderWidth: 1,
    borderColor: C.rule,
    justifyContent: 'center',
  },
  meterFill: {
    height: 4,
    marginLeft: 1,
    backgroundColor: C.accent,
    shadowColor: C.accent,
    shadowOpacity: 0.8,
    shadowRadius: 5,
    shadowOffset: {width: 0, height: 0},
  },

  // buttons
  btn: {
    borderWidth: 1,
    borderColor: C.rule,
    paddingHorizontal: 16,
    paddingVertical: 9,
    alignItems: 'center',
  },
  btnWide: {alignSelf: 'stretch'},
  btnSolid: {backgroundColor: C.accent, borderColor: C.accent},
  btnDanger: {borderColor: C.danger},
  btnGhostOn: {borderColor: C.accent},
  btnDim: {opacity: 0.45},
  btnText: {
    color: C.tx,
    fontFamily: MONO,
    fontSize: 12,
    letterSpacing: 1.4,
    textTransform: 'uppercase',
  },
  btnTextSolid: {color: C.onAccent},
  btnTextDanger: {color: C.danger},

  // stepper
  stepper: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderColor: C.rule,
  },
  stepBtn: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRightWidth: 1,
    borderRightColor: C.rule,
  },
  stepBtnRight: {borderRightWidth: 0, borderLeftWidth: 1, borderLeftColor: C.rule},
  stepText: {color: C.txSoft, fontFamily: MONO, fontSize: 15},
  stepValue: {
    color: C.accent,
    fontFamily: MONO,
    fontSize: 13,
    minWidth: 30,
    textAlign: 'center',
  },

  // log pane
  logPane: {
    flex: 1,
    margin: 16,
    marginLeft: 0,
    backgroundColor: C.black,
    borderWidth: 1,
    borderColor: C.rule,
    padding: 16,
    shadowColor: C.accent,
    shadowOpacity: 0.14,
    shadowRadius: 26,
    shadowOffset: {width: 0, height: 0},
  },
  logHead: {
    flexDirection: 'row',
    alignItems: 'baseline',
    paddingBottom: 10,
    marginBottom: 10,
    borderBottomWidth: 1,
    borderBottomColor: C.ruleSoft,
  },
  clear: {
    color: C.txFaint,
    fontFamily: MONO,
    fontSize: 11,
    letterSpacing: 1,
    textTransform: 'uppercase',
  },
  clearOn: {color: C.accent},
  logScroll: {flex: 1},
  logLine: {color: C.txSoft, fontFamily: MONO, fontSize: 11.5, lineHeight: 17},
  logTagApp: {color: C.accent},
  logTagErr: {color: C.warn},
  logTagOut: {color: C.txFaint},
});
