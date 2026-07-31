// Deterministic AppSet contract tier. This is a temporary generator-input
// fixture, not a live ArgoCD reconciliation trace.
type Json = Record<string, unknown>;
type Row = { path: string; platform: string; landscape: string; service: string; tag: string };
type Secret = { metadata: { name: string; labels: Record<string, string> }; data: Record<string, string> };
type App = { name: string; destinationServer: string; targetRevision: string; row: string };

const [rowsRoot, appSetPath] = process.argv.slice(2);

if (!rowsRoot || !appSetPath) {
  console.error('usage: bun scripts/validate/fleet-row-expansion.ts <platforms-root> <rendered-appset.json>');
  process.exit(2);
}

const expect = (condition: unknown, message: string): asserts condition => {
  if (!condition) throw new Error(message);
};
const decode = (value: string): string => Buffer.from(value, 'base64').toString('utf8');
const yaml = (path: string): Json => {
  const result = Bun.spawnSync(['yq', '-o=json', '.', path]);
  if (result.exitCode !== 0) throw new Error(`could not parse ${path}: ${new TextDecoder().decode(result.stderr)}`);
  return JSON.parse(new TextDecoder().decode(result.stdout)) as Json;
};
const asJson = (value: unknown): Json => value as Json;
const names = (apps: Map<string, App>): string[] => [...apps.keys()].sort();
const changed = (before: Map<string, App>, after: Map<string, App>): string[] => {
  const all = new Set([...before.keys(), ...after.keys()]);
  return [...all].filter(name => JSON.stringify(before.get(name)) !== JSON.stringify(after.get(name))).sort();
};

const appSet = (await Bun.file(appSetPath).json()) as Json;
const generators = asJson(appSet.spec).generators as Json[];
const g1 = asJson(generators.find(generator => 'git' in generator)?.git);
const matrix = asJson(generators.find(generator => 'matrix' in generator)?.matrix);
const g2 = matrix.generators as Json[];
const g2Git = asJson(g2.find(generator => 'git' in generator)?.git);
const g2Clusters = asJson(g2.find(generator => 'clusters' in generator)?.clusters);

const pattern = 'platforms/canary/landscapes/*/*.yaml';
expect((g1.files as Json[])[0]?.path === pattern, 'g1 must use the exact canary row path pattern');
expect((g2Git.files as Json[])[0]?.path === pattern, 'g2 git side must use the exact canary row path pattern');
expect(
  asJson(asJson(g1.template).metadata).name === '{{ .platform }}-{{ .landscape }}-{{ .service }}-primordial',
  'g1 name must be row-derived',
);
expect(
  asJson(asJson(g1.template).spec).destination &&
    asJson(asJson(asJson(g1.template).spec).destination).server === 'https://kubernetes.default.svc',
  'g1 must target Primordial',
);
expect(
  asJson(asJson(matrix.template).metadata).name === '{{ .platform }}-{{ .landscape }}-{{ .service }}-{{ .name }}',
  'g2 name must include the Argo cluster name',
);
expect(
  asJson(asJson(asJson(matrix.template).spec).destination).server === '{{ .server }}',
  'g2 destination must derive from the Argo cluster Secret server',
);
expect(
  asJson(asJson(g2Clusters.selector).matchLabels)['atomi.cloud/landscape'] === '{{ .landscape }}',
  'g2 must select Secret inputs by row landscape',
);

const matchingPath = (path: string): boolean => /^platforms\/canary\/landscapes\/[^/]+\/[^/]+\.yaml$/.test(path);
expect(matchingPath('platforms/canary/landscapes/pichu/dummy.yaml'), 'row pattern must include a matching row path');
expect(
  !matchingPath('platforms/canary/services.yaml'),
  'both g1 and g2 exact row path patterns must exclude a non-row changed path',
);

// Start from a committed row, then add one temporary second-service row. This
// makes service isolation observable without changing topology or row files.
const sourcePath = `${rowsRoot}/canary/landscapes/pichu/dummy.yaml`;
const source = yaml(sourcePath);
const sourcePin = asJson(source.pin);
const rows: Row[] = [
  {
    path: 'platforms/canary/landscapes/pichu/dummy.yaml',
    platform: String(source.platform),
    landscape: String(source.landscape),
    service: String(source.service),
    tag: String(sourcePin.tag),
  },
  {
    path: 'platforms/canary/landscapes/raichu/api.yaml',
    platform: String(source.platform),
    landscape: 'raichu',
    service: 'api',
    tag: String(sourcePin.tag),
  },
];
expect(
  rows[0].platform === 'canary' && rows[0].landscape === 'pichu' && rows[0].service === 'dummy',
  'temporary fixture must begin with the committed pichu/dummy row',
);

// These are precisely the data fields supplied by Argo cluster Secrets: .name
// and .server are base64 data values, while landscape is a metadata label.
const secret = (resourceName: string, name: string, server: string, landscape: string): Secret => ({
  metadata: { name: resourceName, labels: { 'atomi.cloud/landscape': landscape } },
  data: { name: Buffer.from(name).toString('base64'), server: Buffer.from(server).toString('base64') },
});
const secrets: Secret[] = [
  secret('pichu-blue-secret', 'pichu-blue', 'https://pichu-blue.example.invalid', 'pichu'),
  secret('pichu-green-secret', 'pichu-green', 'https://pichu-green.example.invalid', 'pichu'),
  secret('raichu-secret', 'raichu-main', 'https://raichu.example.invalid', 'raichu'),
];

const expand = (changedPaths: string[], input: Row[] = rows): Map<string, App> => {
  const applications = new Map<string, App>();
  for (const row of input.filter(candidate => changedPaths.includes(candidate.path) && matchingPath(candidate.path))) {
    const primordial = `${row.platform}-${row.landscape}-${row.service}-primordial`;
    applications.set(primordial, {
      name: primordial,
      destinationServer: 'https://kubernetes.default.svc',
      targetRevision: row.tag,
      row: row.path,
    });
    for (const cluster of secrets.filter(
      ({ metadata }) => metadata.labels['atomi.cloud/landscape'] === row.landscape,
    )) {
      const clusterName = decode(cluster.data.name);
      const name = `${row.platform}-${row.landscape}-${row.service}-${clusterName}`;
      applications.set(name, {
        name,
        destinationServer: decode(cluster.data.server),
        targetRevision: row.tag,
        row: row.path,
      });
    }
  }
  return applications;
};

const expected = (row: Row): string[] =>
  [
    `${row.platform}-${row.landscape}-${row.service}-primordial`,
    ...secrets
      .filter(({ metadata }) => metadata.labels['atomi.cloud/landscape'] === row.landscape)
      .map(cluster => `${row.platform}-${row.landscape}-${row.service}-${decode(cluster.data.name)}`),
  ].sort();
const empty = new Map<string, App>();
const first = rows[0];
const second = rows[1];
const one = expand([first.path]);
const two = expand([first.path, second.path]);

expect(
  JSON.stringify(names(one)) === JSON.stringify(expected(first)),
  'one row must produce exactly its primordial and matching-Secret Applications',
);
expect(
  JSON.stringify(changed(empty, two)) ===
    JSON.stringify([...new Set([...expected(first), ...expected(second)])].sort()),
  'two distinct services must produce exactly their Application union',
);
expect(
  names(two).every(name => !name.includes('pichu-api') && !name.includes('raichu-dummy')),
  'service or landscape identity bled across temporary fixture rows',
);
expect(
  [...one.values()]
    .filter(app => app.destinationServer !== 'https://kubernetes.default.svc')
    .every(app => app.destinationServer.includes('pichu-')),
  'g2 destination servers must derive from matching pichu Secret data',
);
expect(
  [...two.values()].find(app => app.name === 'canary-raichu-api-raichu-main')?.destinationServer ===
    'https://raichu.example.invalid',
  'g2 must derive both Application name and destination server from the Raichu Secret',
);
expect(
  expand(['platforms/canary/services.yaml']).size === 0,
  'a non-row changed path must be excluded by both g1 and g2 path patterns',
);

console.log(
  'deterministic AppSet contract tier: two-service row expansion, Secret name/server derivation, and non-row path exclusion ✓',
);
