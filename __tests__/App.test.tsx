/**
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';

jest.mock('../src/native/NeoNative', () => ({
  NeoCore: {
    ensureIdentity: jest.fn().mockResolvedValue({
      nodeId: 'neo:0123456789abcdef',
      path: '/tmp/identity.key',
      created: true,
    }),
  },
  NeoDaemon: {
    start: jest.fn().mockResolvedValue({pid: 1, binPath: '/tmp/neo', args: []}),
    stop: jest.fn().mockResolvedValue({stopped: true}),
    status: jest.fn().mockResolvedValue({
      running: false,
      pid: null,
      binPath: '/tmp/neo',
      dataDir: '/tmp',
    }),
    exec: jest.fn().mockResolvedValue({
      code: 0,
      stdout: '',
      stderr: '',
      timedOut: false,
    }),
  },
  onLog: jest.fn().mockReturnValue({remove: jest.fn()}),
  onState: jest.fn().mockReturnValue({remove: jest.fn()}),
}));

jest.mock('../src/native/NeoVPN', () => ({
  NeoVPN: {
    connect: jest.fn().mockResolvedValue({started: true}),
    disconnect: jest.fn().mockResolvedValue({stopped: true}),
    status: jest.fn().mockResolvedValue({status: 'disconnected', installed: false}),
  },
  onVPNState: jest.fn().mockReturnValue({remove: jest.fn()}),
}));

import App from '../App';

test('renders correctly', async () => {
  await ReactTestRenderer.act(async () => {
    ReactTestRenderer.create(<App />);
  });
});
