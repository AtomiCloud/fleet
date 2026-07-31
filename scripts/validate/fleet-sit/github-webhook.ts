type SignatureMode = 'correct' | 'wrong' | 'missing';

type Config = {
  endpoint: string;
  repoUrl: string;
  secret: string;
  ref: string;
  before: string;
  after: string;
  changed: string[];
  signatureMode: SignatureMode;
  selfTest: boolean;
};

const usage = (): never => {
  console.error(
    'usage: bun github-webhook.ts --url <endpoint> --repo-url <git-url> --secret <value> ' +
      '--ref <refs/heads/main> --before <sha> --after <sha> [--changed <path>]... ' +
      '[--wrong-secret|--no-signature] [--self-test]',
  );
  process.exit(2);
};

const parseArgs = (argv: string[]): Config => {
  const values = new Map<string, string>();
  const changed: string[] = [];
  let signatureMode: SignatureMode = 'correct';
  let selfTest = false;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--wrong-secret') {
      if (signatureMode !== 'correct') usage();
      signatureMode = 'wrong';
    } else if (arg === '--no-signature') {
      if (signatureMode !== 'correct') usage();
      signatureMode = 'missing';
    } else if (arg === '--self-test') {
      selfTest = true;
    } else if (arg === '--changed') {
      const path = argv[index + 1] ?? '';
      if (!path) usage();
      changed.push(path);
      index += 1;
    } else if (['--url', '--repo-url', '--secret', '--ref', '--before', '--after'].includes(arg)) {
      const value = argv[index + 1] ?? '';
      if (!value) usage();
      values.set(arg, value);
      index += 1;
    } else {
      usage();
    }
  }

  if (selfTest) {
    return {
      endpoint: 'http://127.0.0.1/unused',
      repoUrl: 'http://example.invalid/fleet.git',
      secret: 'self-test',
      ref: 'refs/heads/main',
      before: '0'.repeat(40),
      after: '1'.repeat(40),
      changed: [],
      signatureMode,
      selfTest,
    };
  }

  const endpoint = values.get('--url') ?? '';
  const repoUrl = values.get('--repo-url') ?? '';
  const secret = values.get('--secret') ?? '';
  const ref = values.get('--ref') ?? '';
  const before = values.get('--before') ?? '';
  const after = values.get('--after') ?? '';
  if (!endpoint || !repoUrl || !secret || !ref || !before || !after) usage();

  return { endpoint, repoUrl, secret, ref, before, after, changed, signatureMode, selfTest };
};

const hmacSha256 = async (secret: string, body: string): Promise<string> => {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'sign',
  ]);
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(body));
  return [...new Uint8Array(signature)].map(byte => byte.toString(16).padStart(2, '0')).join('');
};

const config = parseArgs(process.argv.slice(2));

if (config.selfTest) {
  const first = await hmacSha256('secret', 'payload');
  const second = await hmacSha256('secret', 'payload');
  const wrong = await hmacSha256('wrong', 'payload');
  if (first.length !== 64 || first !== second || first === wrong) {
    throw new Error('HMAC-SHA256 self-test failed');
  }
  console.log(JSON.stringify({ status: 'pass', check: 'github-hmac-sha256' }));
  process.exit(0);
}

const repoName =
  config.repoUrl
    .split('/')
    .at(-1)
    ?.replace(/\.git$/, '') || 'fleet';
const branch = config.ref.startsWith('refs/heads/') ? config.ref.slice('refs/heads/'.length) : 'main';
const payload = {
  ref: config.ref,
  before: config.before,
  after: config.after,
  repository: {
    name: repoName,
    full_name: `fleet-sit/${repoName}`,
    html_url: config.repoUrl,
    clone_url: config.repoUrl,
    default_branch: branch,
  },
  commits: [
    {
      id: config.after,
      added: [],
      removed: [],
      modified: config.changed,
    },
  ],
};
const body = JSON.stringify(payload);
const headers = new Headers({
  'Content-Type': 'application/json',
  'User-Agent': 'diene-fleet-sit',
  'X-GitHub-Delivery': crypto.randomUUID(),
  'X-GitHub-Event': 'push',
});

if (config.signatureMode !== 'missing') {
  const signingSecret = config.signatureMode === 'wrong' ? `${config.secret}-wrong` : config.secret;
  headers.set('X-Hub-Signature-256', `sha256=${await hmacSha256(signingSecret, body)}`);
}

const response = await fetch(config.endpoint, {
  method: 'POST',
  headers,
  body,
  signal: AbortSignal.timeout(15_000),
});
const responseBody = (await response.text()).slice(0, 2_048);
console.log(
  JSON.stringify({
    endpoint: config.endpoint,
    repoUrl: config.repoUrl,
    ref: config.ref,
    before: config.before,
    after: config.after,
    changed: config.changed,
    signatureMode: config.signatureMode,
    status: response.status,
    ok: response.ok,
    responseBody,
  }),
);
