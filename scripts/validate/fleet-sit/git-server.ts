import { resolve, sep } from 'node:path';

type Config = {
  root: string;
  port: number;
  selfTest: boolean;
};

const usage = (): never => {
  console.error('usage: bun git-server.ts --root <bare-repo-root> [--port <0-65535>] [--self-test]');
  process.exit(2);
};

const parseArgs = (argv: string[]): Config => {
  let root = '';
  let port = 0;
  let selfTest = false;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--root') {
      root = argv[index + 1] ?? '';
      index += 1;
    } else if (arg === '--port') {
      const raw = argv[index + 1] ?? '';
      port = Number(raw);
      index += 1;
    } else if (arg === '--self-test') {
      selfTest = true;
    } else {
      usage();
    }
  }

  if (!root || !Number.isInteger(port) || port < 0 || port > 65535) usage();
  return { root: resolve(root), port, selfTest };
};

type GitPath = {
  pathInfo: string;
  repoPath: string;
};

const gitPath = (root: string, encodedPathname: string): GitPath | null => {
  let pathname: string;
  try {
    pathname = decodeURIComponent(encodedPathname);
  } catch {
    return null;
  }

  if (pathname.includes('\0') || pathname.includes('\\')) return null;
  const segments = pathname.split('/').filter(Boolean);
  if (segments.length < 2 || segments.some(segment => segment === '.' || segment === '..')) return null;
  const repoName = segments[0];
  if (!repoName.endsWith('.git')) return null;
  const repoPath = resolve(root, repoName);
  if (!repoPath.startsWith(`${root}${sep}`)) return null;
  return { pathInfo: `/${segments.join('/')}`, repoPath };
};

const findHeaderEnd = (output: Uint8Array): { index: number; length: number } | null => {
  for (let index = 0; index < output.length - 1; index += 1) {
    if (output[index] === 10 && output[index + 1] === 10) return { index, length: 2 };
    if (
      index < output.length - 3 &&
      output[index] === 13 &&
      output[index + 1] === 10 &&
      output[index + 2] === 13 &&
      output[index + 3] === 10
    ) {
      return { index, length: 4 };
    }
  }
  return null;
};

const cgiResponse = (output: Uint8Array): { status: number; headers: Headers; body: Uint8Array } => {
  const end = findHeaderEnd(output);
  if (end === null) throw new Error('git http-backend returned no CGI header terminator');

  const headerText = new TextDecoder().decode(output.slice(0, end.index));
  const headers = new Headers();
  let status = 200;
  for (const line of headerText.split(/\r?\n/)) {
    const separator = line.indexOf(':');
    if (separator < 1) continue;
    const name = line.slice(0, separator).trim();
    const value = line.slice(separator + 1).trim();
    if (name.toLowerCase() === 'status') {
      status = Number(value.split(' ', 1)[0]);
    } else {
      headers.append(name, value);
    }
  }
  headers.set('Cache-Control', 'no-store, max-age=0');
  headers.set('X-Content-Type-Options', 'nosniff');
  return { status, headers, body: output.slice(end.index + end.length) };
};

const config = parseArgs(process.argv.slice(2));

if (config.selfTest) {
  const allowed = gitPath(config.root, '/fleet.git/info/refs');
  const escaped = gitPath(config.root, '/%2e%2e/outside');
  const parsed = cgiResponse(new TextEncoder().encode('Status: 201 Created\r\nContent-Type: text/plain\r\n\r\nok'));
  if (
    allowed?.repoPath !== resolve(config.root, 'fleet.git') ||
    escaped !== null ||
    parsed.status !== 201 ||
    new TextDecoder().decode(parsed.body) !== 'ok'
  ) {
    throw new Error('path containment self-test failed');
  }
  console.log(JSON.stringify({ status: 'pass', check: 'git-http-backend-cgi-and-path-containment' }));
  process.exit(0);
}

const server = Bun.serve({
  hostname: '0.0.0.0',
  port: config.port,
  async fetch(request) {
    if (!['GET', 'HEAD', 'POST'].includes(request.method)) {
      return new Response('method not allowed\n', {
        status: 405,
        headers: { Allow: 'GET, HEAD, POST' },
      });
    }

    const url = new URL(request.url);
    const path = gitPath(config.root, url.pathname);
    if (path === null) return new Response('bad path\n', { status: 400 });
    if (!(await Bun.file(resolve(path.repoPath, 'HEAD')).exists())) {
      return new Response('repository not found\n', { status: 404 });
    }

    const input = request.method === 'POST' ? new Uint8Array(await request.arrayBuffer()) : new Uint8Array();
    if (input.byteLength > 16 * 1024 * 1024) return new Response('request too large\n', { status: 413 });
    const result = Bun.spawnSync(['git', 'http-backend'], {
      env: {
        ...process.env,
        GATEWAY_INTERFACE: 'CGI/1.1',
        GIT_HTTP_EXPORT_ALL: '1',
        GIT_PROJECT_ROOT: config.root,
        HTTP_GIT_PROTOCOL: request.headers.get('Git-Protocol') ?? '',
        PATH_INFO: path.pathInfo,
        QUERY_STRING: url.search.slice(1),
        REMOTE_ADDR: '127.0.0.1',
        REQUEST_METHOD: request.method,
        SERVER_NAME: url.hostname,
        SERVER_PORT: url.port || '80',
        SERVER_PROTOCOL: 'HTTP/1.1',
        CONTENT_TYPE: request.headers.get('Content-Type') ?? '',
        CONTENT_LENGTH: String(input.byteLength),
      },
      stdin: input,
      stdout: 'pipe',
      stderr: 'pipe',
    });
    if (result.exitCode !== 0) {
      console.error(new TextDecoder().decode(result.stderr));
      return new Response('git backend failed\n', { status: 500 });
    }

    const response = cgiResponse(result.stdout);
    return new Response(request.method === 'HEAD' ? null : response.body, {
      status: response.status,
      headers: response.headers,
    });
  },
  error(error) {
    console.error(error);
    return new Response('internal error\n', { status: 500 });
  },
});

console.log(JSON.stringify({ port: server.port, root: config.root }));
