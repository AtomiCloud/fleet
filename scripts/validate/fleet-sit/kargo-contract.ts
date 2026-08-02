// Field-exact oracle for the ratified v1 `stages:` -> Kargo mapping.
//
// It answers two independent questions about the SAME object set:
//
//   1. contract  — do the rendered (or API-server-persisted) Kargo objects
//                  carry EXACTLY the ratified canary v1 fields? Gate policy,
//                  direct/preceding/rendezvous sources, availabilityStrategy,
//                  requiredSoakTime, verification templates, and the fixed
//                  pin-only promotion template.
//   2. conformance — is every field path we assert a REAL field of the pinned
//                  Kargo CRDs? A field the CRD does not declare is pruned by
//                  the API server, so a render that "sets" it sets nothing.
//
// Run it over the render AND over the objects read back from a live API server
// that has the pinned CRDs installed: the second pass is what proves no
// asserted field was silently pruned.
//
// It does NOT execute Kargo controllers. Freight discovery, promotion,
// verification runs, and real soak timing are outside this oracle; the SIT
// records that residual explicitly rather than implying behaviour was run.

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };

type Check = { name: string; ok: boolean; detail: string };

type Config = {
  objectsPath: string;
  crdsPath: string;
  outPath: string;
  source: string;
  imageRepo: string;
  chartRepo: string;
  fleetRepo: string;
  kargoWebhookPersisted: boolean;
  selfTest: boolean;
};

const PLATFORM = 'canary';
const SERVICE = 'dummy';
const API_VERSION = 'kargo.akuity.io/v1alpha1';
const DEFAULT_IMAGE_REPO = 'registry.atomi.cloud/canary/dummy';
const DEFAULT_CHART_REPO = 'oci://registry.atomi.cloud/canary-dummy';
const DEFAULT_FLEET_REPO = 'https://github.com/AtomiCloud/fleet';
const KARGO_WEBHOOK_CANONICAL_SOAK_TIME = '15m0s';
const DEFAULT_REPOSITORIES = {
  image: DEFAULT_IMAGE_REPO,
  chart: DEFAULT_CHART_REPO,
  fleet: DEFAULT_FLEET_REPO,
};

const stageName = (landscape: string): string => `${PLATFORM}-${SERVICE}-${landscape}`;

// The ratified v1 canary DAG:
//   pichu -> [ {pikachu, manual, canary-smoke}, raichu ] -> {ampharos, auto, 15m, canary-analysis}
type StageContract = {
  landscape: string;
  gate: 'auto' | 'manual';
  direct: boolean;
  upstream: string[];
  availabilityStrategy: string | null;
  requiredSoakTime: string | null;
  analysisTemplates: string[];
};

const STAGE_CONTRACT: StageContract[] = [
  {
    landscape: 'pichu',
    gate: 'auto',
    direct: true,
    upstream: [],
    availabilityStrategy: null,
    requiredSoakTime: null,
    analysisTemplates: [],
  },
  {
    landscape: 'pikachu',
    gate: 'manual',
    direct: false,
    upstream: [stageName('pichu')],
    availabilityStrategy: null,
    requiredSoakTime: null,
    analysisTemplates: ['canary-smoke'],
  },
  {
    landscape: 'raichu',
    gate: 'auto',
    direct: false,
    upstream: [stageName('pichu')],
    availabilityStrategy: null,
    requiredSoakTime: null,
    analysisTemplates: [],
  },
  {
    landscape: 'ampharos',
    gate: 'auto',
    direct: false,
    upstream: [stageName('pikachu'), stageName('raichu')],
    availabilityStrategy: 'All',
    requiredSoakTime: '15m',
    analysisTemplates: ['canary-analysis'],
  },
];

// Load-bearing upstream semantics, quoted from the pinned CRD descriptions.
// Whitespace is collapsed before matching so a re-wrapped description still
// matches, while a changed CLAIM does not.
//
// `id` is the stable per-claim slug. A field carries MORE than one claim, so
// `kind.field` is not an identity: it is the check name and the report key that
// must be `kind.field.id`, or two claims collapse onto one another and the
// proof artifact silently loses records that were in fact checked.
const CRD_SEMANTICS = [
  {
    kind: 'Stage',
    field: 'availabilityStrategy',
    id: 'all-requires-every-upstream',
    claim: 'rendezvous All requires every upstream member, so a single-member promotion is not available',
    phrase: '- "All": Freight must be verified and, if applicable, soaked in all upstream Stages',
  },
  {
    kind: 'Stage',
    field: 'availabilityStrategy',
    id: 'omitted-defaults-to-oneof',
    claim: 'omitting the field silently weakens the rendezvous to OneOf',
    phrase: 'the field is implicitly treated as if its value were "OneOf"',
  },
  {
    kind: 'Stage',
    field: 'requiredSoakTime',
    id: 'soak-clock-is-upstream-residency',
    claim:
      'the soak clock is residency in the upstream Stage, i.e. it runs from promotion, not from verification success',
    phrase: 'must have continuously occupied ("soaked in") in an upstream Stage',
  },
  {
    kind: 'Stage',
    field: 'requiredSoakTime',
    id: 'soak-additional-to-verification',
    claim: 'soak is an ADDITIONAL requirement on top of upstream verification, never a substitute for it',
    phrase: 'is in ADDITION to the requirement that Freight be verified in an upstream Stage',
  },
  {
    kind: 'ProjectConfig',
    field: 'autoPromotionEnabled',
    id: 'defaults-to-false',
    claim: 'auto-promotion is off unless a policy enables it, so a manual Stage is manual by the ABSENCE of a policy',
    phrase: 'This field defaults to false',
  },
] as const;

// The identity of a semantic claim, shared by its check name and its report
// key so the artifact and the check set are the same five records.
const semanticId = (entry: { kind: string; field: string; id: string }): string =>
  `${entry.kind}.${entry.field}.${entry.id}`;

const usage = (): never => {
  console.error(
    'usage: bun kargo-contract.ts --objects <json> --out <json> [--crds <json>] [--source <label>]\n' +
      '       [--image-repo <repo>] [--chart-repo <repo>] [--fleet-repo <repo>]\n' +
      '       [--kargo-webhook-persisted]\n' +
      '       bun kargo-contract.ts --self-test',
  );
  process.exit(2);
};

const parseArgs = (argv: string[]): Config => {
  const values = new Map<string, string>();
  let selfTest = false;
  let kargoWebhookPersisted = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--self-test') {
      selfTest = true;
    } else if (arg === '--kargo-webhook-persisted') {
      kargoWebhookPersisted = true;
    } else if (
      ['--objects', '--crds', '--out', '--source', '--image-repo', '--chart-repo', '--fleet-repo'].includes(arg)
    ) {
      const value = argv[index + 1] ?? '';
      if (!value) usage();
      values.set(arg, value);
      index += 1;
    } else {
      usage();
    }
  }
  if (selfTest)
    return {
      objectsPath: '',
      crdsPath: '',
      outPath: '',
      source: 'self-test',
      imageRepo: DEFAULT_IMAGE_REPO,
      chartRepo: DEFAULT_CHART_REPO,
      fleetRepo: DEFAULT_FLEET_REPO,
      kargoWebhookPersisted,
      selfTest,
    };
  const objectsPath = values.get('--objects') ?? '';
  const outPath = values.get('--out') ?? '';
  if (!objectsPath || !outPath) usage();
  return {
    objectsPath,
    crdsPath: values.get('--crds') ?? '',
    outPath,
    source: values.get('--source') ?? objectsPath,
    imageRepo: values.get('--image-repo') ?? DEFAULT_IMAGE_REPO,
    chartRepo: values.get('--chart-repo') ?? DEFAULT_CHART_REPO,
    fleetRepo: values.get('--fleet-repo') ?? DEFAULT_FLEET_REPO,
    kargoWebhookPersisted,
    selfTest,
  };
};

const isObject = (value: Json): value is JsonObject =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const asObjects = (value: Json): JsonObject[] => {
  if (Array.isArray(value)) return value.filter(isObject);
  if (isObject(value) && Array.isArray(value.items)) return value.items.filter(isObject);
  if (isObject(value)) return [value];
  return [];
};

const at = (value: Json, path: string): Json => {
  let cursor: Json = value;
  for (const segment of path.split('.')) {
    if (!isObject(cursor)) return null;
    cursor = cursor[segment] ?? null;
  }
  return cursor;
};

// Annotation and label keys carry dots, so they are read by exact key rather
// than through the dotted-path helper.
const annotation = (object: Json, key: string): Json => {
  const annotations = at(object, 'metadata.annotations');
  return isObject(annotations) ? (annotations[key] ?? null) : null;
};

const canonical = (value: Json): string => JSON.stringify(value);
const collapse = (value: string): string => value.replace(/\s+/g, ' ').trim();

class Checker {
  readonly checks: Check[] = [];

  assert(name: string, ok: boolean, detail: string): boolean {
    this.checks.push({ name, ok, detail });
    return ok;
  }

  equal(name: string, actual: Json, expected: Json): boolean {
    const ok = canonical(actual) === canonical(expected);
    return this.assert(
      name,
      ok,
      ok ? `== ${canonical(expected)}` : `expected ${canonical(expected)}, found ${canonical(actual)}`,
    );
  }

  get ok(): boolean {
    return this.checks.every(check => check.ok);
  }
}

const byKind = (objects: JsonObject[], kind: string): JsonObject[] =>
  objects.filter(object => object.apiVersion === API_VERSION && object.kind === kind);

const checkContract = (
  checker: Checker,
  objects: JsonObject[],
  repositories: { image: string; chart: string; fleet: string },
  kargoWebhookPersisted: boolean,
): void => {
  const projects = byKind(objects, 'Project');
  const projectConfigs = byKind(objects, 'ProjectConfig');
  const warehouses = byKind(objects, 'Warehouse');
  const stages = byKind(objects, 'Stage');

  checker.equal('kargo.project.count', projects.length, 1);
  checker.equal('kargo.projectconfig.count', projectConfigs.length, 1);
  checker.equal('kargo.warehouse.count', warehouses.length, 1);
  checker.equal(
    'kargo.stage.names',
    stages.map(stage => at(stage, 'metadata.name')).sort(),
    STAGE_CONTRACT.map(contract => stageName(contract.landscape)).sort(),
  );

  const projectConfig = projectConfigs[0] ?? {};
  const policies = at(projectConfig, 'spec.promotionPolicies');
  const policyList = Array.isArray(policies) ? policies.filter(isObject) : [];
  checker.assert(
    'kargo.projectconfig.policies.present',
    Array.isArray(policies),
    Array.isArray(policies) ? `${policyList.length} promotionPolicies` : 'spec.promotionPolicies is not a list',
  );
  checker.equal(
    'kargo.projectconfig.autoPromotionEnabled.set',
    policyList
      .filter(policy => policy.autoPromotionEnabled === true)
      .map(policy => at(policy, 'stageSelector.name'))
      .sort(),
    STAGE_CONTRACT.filter(contract => contract.gate === 'auto')
      .map(contract => stageName(contract.landscape))
      .sort(),
  );
  // ABSENCE is the manual gate. A padded `autoPromotionEnabled: false` entry
  // would still be a policy naming the Stage, so both are rejected.
  checker.equal(
    'kargo.projectconfig.manual.has.no.policy',
    policyList.filter(policy => at(policy, 'stageSelector.name') === stageName('pikachu')).length,
    0,
  );
  checker.equal(
    'kargo.projectconfig.no.disabled.padding',
    policyList.filter(policy => policy.autoPromotionEnabled !== true).length,
    0,
  );
  checker.equal(
    'kargo.projectconfig.no.deprecated.stage.field',
    policyList.filter(policy => Object.prototype.hasOwnProperty.call(policy, 'stage')).length,
    0,
  );

  for (const contract of STAGE_CONTRACT) {
    const name = stageName(contract.landscape);
    const stage = stages.find(candidate => at(candidate, 'metadata.name') === name);
    if (!stage) {
      checker.assert(`kargo.stage.${contract.landscape}.present`, false, `Stage ${name} is missing`);
      continue;
    }
    const requested = at(stage, 'spec.requestedFreight');
    const first = Array.isArray(requested) && isObject(requested[0]) ? requested[0] : {};
    checker.equal(
      `kargo.stage.${contract.landscape}.requestedFreight.count`,
      Array.isArray(requested) ? requested.length : -1,
      1,
    );
    checker.equal(`kargo.stage.${contract.landscape}.origin`, at(first, 'origin'), {
      kind: 'Warehouse',
      name: SERVICE,
    });
    checker.equal(
      `kargo.stage.${contract.landscape}.sources.direct`,
      at(first, 'sources.direct') ?? false,
      contract.direct,
    );
    checker.equal(
      `kargo.stage.${contract.landscape}.sources.stages`,
      at(first, 'sources.stages') ?? [],
      contract.upstream,
    );
    checker.equal(
      `kargo.stage.${contract.landscape}.sources.availabilityStrategy`,
      at(first, 'sources.availabilityStrategy'),
      contract.availabilityStrategy,
    );
    checker.equal(
      `kargo.stage.${contract.landscape}.sources.requiredSoakTime`,
      at(first, 'sources.requiredSoakTime'),
      kargoWebhookPersisted && contract.requiredSoakTime === '15m'
        ? KARGO_WEBHOOK_CANONICAL_SOAK_TIME
        : contract.requiredSoakTime,
    );
    const templates = at(stage, 'spec.verification.analysisTemplates');
    checker.equal(
      `kargo.stage.${contract.landscape}.verification`,
      Array.isArray(templates) ? templates.map(template => at(template, 'name')) : [],
      contract.analysisTemplates,
    );
    checker.equal(
      `kargo.stage.${contract.landscape}.gate.annotation`,
      annotation(stage, 'atomi.cloud/promotion-gate'),
      contract.gate,
    );

    const steps = at(stage, 'spec.promotionTemplate.spec.steps');
    const stepList = Array.isArray(steps) ? steps.filter(isObject) : [];
    checker.equal(
      `kargo.stage.${contract.landscape}.promotionTemplate.steps`,
      stepList.map(step => step.uses ?? null),
      ['git-clone', 'yaml-update', 'git-commit', 'git-push'],
    );
    const clone = stepList.find(step => step.uses === 'git-clone') ?? {};
    checker.equal(
      `kargo.stage.${contract.landscape}.promotionTemplate.repoURL`,
      at(clone, 'config.repoURL'),
      repositories.fleet,
    );
    const update = stepList.find(step => step.uses === 'yaml-update') ?? {};
    checker.equal(
      `kargo.stage.${contract.landscape}.promotionTemplate.path`,
      at(update, 'config.path'),
      `./repo/platforms/${PLATFORM}/landscapes/${contract.landscape}/${SERVICE}.yaml`,
    );
    const updates = at(update, 'config.updates');
    checker.equal(
      `kargo.stage.${contract.landscape}.promotionTemplate.updates`,
      Array.isArray(updates) ? updates.map(entry => ({ key: at(entry, 'key'), value: at(entry, 'value') })) : [],
      [{ key: 'pin.tag', value: `\${{ imageFrom(${JSON.stringify(repositories.image)}).Tag }}` }],
    );
  }

  const warehouse = warehouses[0] ?? {};
  checker.equal('kargo.warehouse.name', at(warehouse, 'metadata.name'), SERVICE);
  checker.equal(
    'kargo.warehouse.freightCreationCriteria',
    at(warehouse, 'spec.freightCreationCriteria.expression'),
    `imageFrom('${repositories.image}').Tag == chartFrom('${repositories.chart}').Version`,
  );
  const subscriptions = at(warehouse, 'spec.subscriptions');
  const subscriptionList = Array.isArray(subscriptions) ? subscriptions.filter(isObject) : [];
  checker.equal(
    'kargo.warehouse.subscriptions',
    [at(subscriptionList[0] ?? {}, 'image.repoURL'), at(subscriptionList[1] ?? {}, 'chart.repoURL')],
    [repositories.image, repositories.chart],
  );
};

const schemaFor = (crd: JsonObject): Json => {
  const versions = at(crd, 'spec.versions');
  if (!Array.isArray(versions)) return null;
  const version = versions.filter(isObject).find(candidate => candidate.name === 'v1alpha1') ?? versions[0];
  return at(version ?? null, 'schema.openAPIV3Schema');
};

// Walk a value against an openAPIV3Schema node and report every path the
// schema does not declare. Those are exactly the paths a real API server
// prunes, which is why the same walk runs over the persisted objects.
const walkSchema = (
  value: Json,
  schema: Json,
  path: string,
  problems: string[],
  preservedUnknownPaths: string[] = [],
): void => {
  if (!isObject(schema)) {
    problems.push(`${path}: no schema node`);
    return;
  }
  if (schema['x-kubernetes-preserve-unknown-fields'] === true) {
    preservedUnknownPaths.push(path);
    return;
  }
  if (Array.isArray(value)) {
    const items = schema.items ?? null;
    if (items === null) {
      problems.push(`${path}: array is not declared`);
      return;
    }
    value.forEach((entry, index) => walkSchema(entry, items, `${path}[${index}]`, problems, preservedUnknownPaths));
    return;
  }
  if (isObject(value)) {
    const properties = isObject(schema.properties) ? schema.properties : null;
    const additional = schema.additionalProperties ?? null;
    for (const [key, child] of Object.entries(value)) {
      const declared = properties && Object.prototype.hasOwnProperty.call(properties, key) ? properties[key] : null;
      if (declared !== null) {
        walkSchema(child, declared, `${path}.${key}`, problems, preservedUnknownPaths);
      } else if (additional !== null && additional !== false) {
        if (additional !== true) walkSchema(child, additional, `${path}.${key}`, problems, preservedUnknownPaths);
      } else {
        problems.push(`${path}.${key}: not declared by the CRD (an API server prunes it)`);
      }
    }
    return;
  }
  if (typeof value === 'string') {
    const values = schema.enum;
    if (Array.isArray(values) && !values.some(candidate => candidate === value)) {
      problems.push(`${path}: ${JSON.stringify(value)} is not in the CRD enum ${canonical(values)}`);
    }
    const pattern = schema.pattern;
    if (typeof pattern === 'string' && !new RegExp(pattern).test(value)) {
      problems.push(`${path}: ${JSON.stringify(value)} violates the CRD pattern ${pattern}`);
    }
  }
};

const findProperty = (schema: Json, field: string): JsonObject | null => {
  if (Array.isArray(schema)) {
    for (const entry of schema) {
      const found = findProperty(entry, field);
      if (found) return found;
    }
    return null;
  }
  if (!isObject(schema)) return null;
  const properties = schema.properties;
  if (isObject(properties) && isObject(properties[field])) return properties[field] as JsonObject;
  for (const child of Object.values(schema)) {
    const found = findProperty(child, field);
    if (found) return found;
  }
  return null;
};

const checkConformance = (
  checker: Checker,
  objects: JsonObject[],
  crds: JsonObject[],
): { semantics: JsonObject; preserveUnknownFieldsBlindSpots: Json[] } => {
  const schemas = new Map<string, Json>();
  for (const crd of crds) {
    const kind = at(crd, 'spec.names.kind');
    if (typeof kind === 'string') schemas.set(kind, schemaFor(crd));
  }
  checker.equal('kargo.crds.kinds', [...schemas.keys()].sort(), ['Project', 'ProjectConfig', 'Stage', 'Warehouse']);

  const preservedUnknownPaths = new Set<string>();
  for (const object of objects) {
    const kind = typeof object.kind === 'string' ? object.kind : 'unknown';
    const name = at(object, 'metadata.name');
    const schema = schemas.get(kind) ?? null;
    if (schema === null) {
      checker.assert(`kargo.conformance.${kind}.${String(name)}`, false, 'no pinned CRD for this kind');
      continue;
    }
    const problems: string[] = [];
    const objectPreservedUnknownPaths: string[] = [];
    const spec = object.spec ?? null;
    if (spec !== null)
      walkSchema(
        spec,
        at(schema, 'properties.spec'),
        `${kind}/${String(name)}.spec`,
        problems,
        objectPreservedUnknownPaths,
      );
    objectPreservedUnknownPaths.forEach(path => preservedUnknownPaths.add(path));
    checker.assert(
      `kargo.conformance.${kind}.${String(name)}`,
      problems.length === 0,
      problems.length === 0 ? 'every asserted field is declared by the pinned CRD' : problems.join('; '),
    );
  }

  const semantics: JsonObject = {};
  for (const entry of CRD_SEMANTICS) {
    const schema = schemas.get(entry.kind) ?? null;
    const property = findProperty(schema, entry.field);
    const description = typeof property?.description === 'string' ? property.description : '';
    const ok = collapse(description).includes(collapse(entry.phrase));
    checker.assert(
      `kargo.crd.semantics.${semanticId(entry)}`,
      ok,
      ok ? entry.claim : `pinned ${entry.kind}.${entry.field} description does not contain: ${entry.phrase}`,
    );
    semantics[semanticId(entry)] = {
      claim: entry.claim,
      phrase: entry.phrase,
      present: ok,
      enum: property?.enum ?? null,
      pattern: property?.pattern ?? null,
      description,
    };
  }
  // A colliding key would shrink the artifact while every claim still "passed",
  // so the count is asserted in the oracle itself rather than only downstream.
  checker.assert(
    'kargo.crd.semantics.count',
    Object.keys(semantics).length === CRD_SEMANTICS.length,
    `${Object.keys(semantics).length} of ${CRD_SEMANTICS.length} distinct semantic claim entries`,
  );
  return {
    semantics,
    preserveUnknownFieldsBlindSpots: [...preservedUnknownPaths].sort().map(path => ({
      path,
      qualification:
        'the pinned CRD preserves arbitrary content below this path; admission/read-back proves persistence, not field-level schema declaration or expression validity',
    })),
  };
};

const evaluate = (
  objects: JsonObject[],
  crds: JsonObject[] | null,
  source: string,
  repositories: { image: string; chart: string; fleet: string },
  kargoWebhookPersisted: boolean,
): JsonObject => {
  const checker = new Checker();
  checkContract(checker, objects, repositories, kargoWebhookPersisted);
  const conformance = crds === null ? null : checkConformance(checker, objects, crds);
  return {
    source,
    kargoApiVersion: API_VERSION,
    expectedRepositories: repositories,
    requiredSoakTimeRepresentation: kargoWebhookPersisted
      ? {
          mode: 'kargo-webhook-canonical',
          source: '15m',
          expected: KARGO_WEBHOOK_CANONICAL_SOAK_TIME,
        }
      : { mode: 'source', expected: '15m' },
    ok: checker.ok,
    checkedObjects: objects.length,
    crdConformance: crds === null ? null : 'checked against the pinned Kargo CRDs',
    crdSemantics: conformance?.semantics ?? null,
    preserveUnknownFieldsBlindSpots: conformance?.preserveUnknownFieldsBlindSpots ?? null,
    failed: checker.checks.filter(check => !check.ok),
    checks: checker.checks,
  } as unknown as JsonObject;
};

const readJson = async (path: string): Promise<Json> => (await Bun.file(path).json()) as Json;

const config = parseArgs(process.argv.slice(2));

if (config.selfTest) {
  const stage = (contract: StageContract): JsonObject => {
    const sources: JsonObject = {};
    if (contract.direct) sources.direct = true;
    else sources.stages = contract.upstream;
    if (contract.availabilityStrategy !== null) sources.availabilityStrategy = contract.availabilityStrategy;
    if (contract.requiredSoakTime !== null) sources.requiredSoakTime = contract.requiredSoakTime;
    const spec: JsonObject = {
      requestedFreight: [{ origin: { kind: 'Warehouse', name: SERVICE }, sources }],
      promotionTemplate: {
        spec: {
          steps: [
            { uses: 'git-clone', config: { repoURL: 'https://github.com/AtomiCloud/fleet' } },
            {
              uses: 'yaml-update',
              config: {
                path: `./repo/platforms/${PLATFORM}/landscapes/${contract.landscape}/${SERVICE}.yaml`,
                updates: [
                  {
                    key: 'pin.tag',
                    value: `\${{ imageFrom(${JSON.stringify(DEFAULT_IMAGE_REPO)}).Tag }}`,
                  },
                ],
              },
            },
            { uses: 'git-commit', config: { path: './repo' } },
            { uses: 'git-push', config: { path: './repo' } },
          ],
        },
      },
    };
    if (contract.analysisTemplates.length > 0) {
      spec.verification = { analysisTemplates: contract.analysisTemplates.map(name => ({ name })) };
    }
    return {
      apiVersion: API_VERSION,
      kind: 'Stage',
      metadata: {
        name: stageName(contract.landscape),
        namespace: PLATFORM,
        annotations: { 'atomi.cloud/promotion-gate': contract.gate },
      },
      spec,
    };
  };

  const good = (): JsonObject[] => [
    { apiVersion: API_VERSION, kind: 'Project', metadata: { name: PLATFORM } },
    {
      apiVersion: API_VERSION,
      kind: 'ProjectConfig',
      metadata: { name: PLATFORM, namespace: PLATFORM },
      spec: {
        promotionPolicies: STAGE_CONTRACT.filter(contract => contract.gate === 'auto').map(contract => ({
          autoPromotionEnabled: true,
          stageSelector: { name: stageName(contract.landscape) },
        })),
      },
    },
    {
      apiVersion: API_VERSION,
      kind: 'Warehouse',
      metadata: { name: SERVICE, namespace: PLATFORM },
      spec: {
        freightCreationCriteria: {
          expression: `imageFrom('${DEFAULT_IMAGE_REPO}').Tag == chartFrom('${DEFAULT_CHART_REPO}').Version`,
        },
        subscriptions: [{ image: { repoURL: DEFAULT_IMAGE_REPO } }, { chart: { repoURL: DEFAULT_CHART_REPO } }],
      },
    },
    ...STAGE_CONTRACT.map(stage),
  ];

  const executedMutations: string[] = [];
  const mutate = (label: string, mutator: (objects: JsonObject[]) => void): void => {
    const objects = good();
    mutator(objects);
    const result = evaluate(objects, null, `self-test:${label}`, DEFAULT_REPOSITORIES, false);
    if (result.ok === true) throw new Error(`kargo-contract self-test did not reject mutation: ${label}`);
    executedMutations.push(label);
  };

  const baseline = evaluate(good(), null, 'self-test:baseline', DEFAULT_REPOSITORIES, false);
  if (baseline.ok !== true) {
    throw new Error(`kargo-contract self-test baseline failed: ${JSON.stringify(baseline.failed)}`);
  }

  const stageOf = (objects: JsonObject[], landscape: string): JsonObject =>
    objects.find(object => at(object, 'metadata.name') === stageName(landscape)) as JsonObject;

  const webhookPersisted = good();
  const persistedAmpharos = (at(stageOf(webhookPersisted, 'ampharos'), 'spec.requestedFreight') as JsonObject[])[0];
  (persistedAmpharos.sources as JsonObject).requiredSoakTime = KARGO_WEBHOOK_CANONICAL_SOAK_TIME;
  const persistedBaseline = evaluate(
    webhookPersisted,
    null,
    'self-test:kargo-webhook-persisted',
    DEFAULT_REPOSITORIES,
    true,
  );
  if (persistedBaseline.ok !== true) {
    throw new Error(`kargo-contract persisted self-test baseline failed: ${JSON.stringify(persistedBaseline.failed)}`);
  }
  if (
    evaluate(webhookPersisted, null, 'self-test:canonical-render-negative', DEFAULT_REPOSITORIES, false).ok === true
  ) {
    throw new Error('kargo-contract source mode accepted the webhook-canonical duration spelling');
  }
  if (evaluate(good(), null, 'self-test:source-persisted-negative', DEFAULT_REPOSITORIES, true).ok === true) {
    throw new Error('kargo-contract webhook-persisted mode accepted the source duration spelling');
  }

  mutate('drop-availabilityStrategy', objects => {
    const sources = (at(stageOf(objects, 'ampharos'), 'spec.requestedFreight') as JsonObject[])[0] as JsonObject;
    delete (sources.sources as JsonObject).availabilityStrategy;
  });
  mutate('rendezvous-loses-a-member', objects => {
    const first = (at(stageOf(objects, 'ampharos'), 'spec.requestedFreight') as JsonObject[])[0] as JsonObject;
    (first.sources as JsonObject).stages = [stageName('pikachu')];
  });
  mutate('soak-1h-instead-of-15m', objects => {
    const first = (at(stageOf(objects, 'ampharos'), 'spec.requestedFreight') as JsonObject[])[0] as JsonObject;
    (first.sources as JsonObject).requiredSoakTime = '1h';
  });
  mutate('soak-on-a-parallel-member', objects => {
    const first = (at(stageOf(objects, 'raichu'), 'spec.requestedFreight') as JsonObject[])[0] as JsonObject;
    (first.sources as JsonObject).requiredSoakTime = '15m';
  });
  mutate('manual-stage-gains-a-policy', objects => {
    const config = objects.find(object => object.kind === 'ProjectConfig') as JsonObject;
    (at(config, 'spec.promotionPolicies') as unknown as JsonObject[]).push({
      autoPromotionEnabled: true,
      stageSelector: { name: stageName('pikachu') },
    });
  });
  mutate('manual-stage-padded-with-a-disabled-policy', objects => {
    const config = objects.find(object => object.kind === 'ProjectConfig') as JsonObject;
    (at(config, 'spec.promotionPolicies') as unknown as JsonObject[]).push({
      autoPromotionEnabled: false,
      stageSelector: { name: stageName('pikachu') },
    });
  });
  mutate('verification-moves-to-the-wrong-member', objects => {
    const pikachu = stageOf(objects, 'pikachu');
    delete (pikachu.spec as JsonObject).verification;
    (stageOf(objects, 'raichu').spec as JsonObject).verification = {
      analysisTemplates: [{ name: 'canary-smoke' }],
    };
  });
  mutate('first-step-loses-direct', objects => {
    const first = (at(stageOf(objects, 'pichu'), 'spec.requestedFreight') as JsonObject[])[0] as JsonObject;
    first.sources = { stages: [stageName('pikachu')] };
  });
  mutate('promotion-template-touches-a-second-key', objects => {
    const steps = at(stageOf(objects, 'pichu'), 'spec.promotionTemplate.spec.steps') as unknown as JsonObject[];
    const update = steps.find(step => step.uses === 'yaml-update') as JsonObject;
    (at(update, 'config.updates') as unknown as JsonObject[]).push({ key: 'values.image', value: 'x' });
  });
  mutate('yaml-update-regresses-to-legacy-pipe-syntax', objects => {
    const steps = at(stageOf(objects, 'pichu'), 'spec.promotionTemplate.spec.steps') as unknown as JsonObject[];
    const update = steps.find(step => step.uses === 'yaml-update') as JsonObject;
    const updates = at(update, 'config.updates') as unknown as JsonObject[];
    updates[0].value = `\${{ imageFrom ${JSON.stringify(DEFAULT_IMAGE_REPO)} | .Tag }}`;
  });

  // Conformance walk: an undeclared field must be reported, a declared one must not.
  const crdStub: JsonObject[] = [
    {
      spec: {
        names: { kind: 'Stage' },
        versions: [
          {
            name: 'v1alpha1',
            schema: {
              openAPIV3Schema: {
                properties: {
                  spec: {
                    properties: {
                      requestedFreight: {
                        items: {
                          properties: {
                            origin: { properties: { kind: { type: 'string' }, name: { type: 'string' } } },
                            sources: {
                              properties: {
                                direct: { type: 'boolean' },
                                stages: { items: { type: 'string' } },
                                availabilityStrategy: { type: 'string', enum: ['All', 'OneOf', ''] },
                                requiredSoakTime: { type: 'string', pattern: '^([0-9]+(\\.[0-9]+)?(s|m|h))+$' },
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        ],
      },
    },
  ];
  const stageSchema = schemaFor(crdStub[0] as JsonObject);
  const declared: string[] = [];
  walkSchema(
    at(stageOf(good(), 'ampharos'), 'spec.requestedFreight'),
    at(stageSchema, 'properties.spec.properties.requestedFreight'),
    'spec.requestedFreight',
    declared,
  );
  if (declared.length !== 0) throw new Error(`conformance self-test rejected a declared field: ${declared.join('; ')}`);

  const pruned: string[] = [];
  const invented = JSON.parse(
    JSON.stringify(at(stageOf(good(), 'ampharos'), 'spec.requestedFreight')),
  ) as unknown as JsonObject[];
  ((invented[0] as JsonObject).sources as JsonObject).availabilityStrategyy = 'All';
  walkSchema(
    invented as unknown as Json,
    at(stageSchema, 'properties.spec.properties.requestedFreight'),
    'spec.requestedFreight',
    pruned,
  );
  if (pruned.length !== 1) throw new Error('conformance self-test did not report an undeclared field');

  const badEnum: string[] = [];
  const wrong = JSON.parse(
    JSON.stringify(at(stageOf(good(), 'ampharos'), 'spec.requestedFreight')),
  ) as unknown as JsonObject[];
  ((wrong[0] as JsonObject).sources as JsonObject).availabilityStrategy = 'Sometimes';
  ((wrong[0] as JsonObject).sources as JsonObject).requiredSoakTime = '15minutes';
  walkSchema(
    wrong as unknown as Json,
    at(stageSchema, 'properties.spec.properties.requestedFreight'),
    'spec.requestedFreight',
    badEnum,
  );
  if (badEnum.length !== 2) throw new Error('conformance self-test did not reject the CRD enum/pattern violations');

  const preserveBlindSpots: string[] = [];
  const preserveProblems: string[] = [];
  walkSchema(
    { expression: 'any future expression grammar is intentionally opaque to this schema node' },
    { 'x-kubernetes-preserve-unknown-fields': true },
    'Stage/canary-dummy-pichu.spec.promotionTemplate.spec.steps[1].config',
    preserveProblems,
    preserveBlindSpots,
  );
  if (preserveProblems.length !== 0 || preserveBlindSpots.length !== 1) {
    throw new Error('conformance self-test did not collect the preserve-unknown-fields blind spot');
  }

  // Semantic-claim identity: the live path is the only one that reaches
  // CRD_SEMANTICS, so it is replayed here against stub CRDs whose descriptions
  // are built from the claim phrases themselves. It proves every claim gets its
  // own record and its own check name; nothing is downloaded or vendored.
  const semanticDescription = (kind: string, field: string): string =>
    CRD_SEMANTICS.filter(entry => entry.kind === kind && entry.field === field)
      .map(entry => entry.phrase)
      .join('\n');

  const semanticsStageCrd = JSON.parse(JSON.stringify(crdStub[0])) as JsonObject;
  const semanticsStageSources = at(
    schemaFor(semanticsStageCrd),
    'properties.spec.properties.requestedFreight.items.properties.sources.properties',
  ) as JsonObject;
  for (const field of ['availabilityStrategy', 'requiredSoakTime']) {
    (semanticsStageSources[field] as JsonObject).description = semanticDescription('Stage', field);
  }

  const emptyCrd = (kind: string): JsonObject => ({
    spec: {
      names: { kind },
      versions: [{ name: 'v1alpha1', schema: { openAPIV3Schema: { properties: {} } } }],
    },
  });

  const semanticsCrds: JsonObject[] = [
    emptyCrd('Project'),
    emptyCrd('Warehouse'),
    {
      spec: {
        names: { kind: 'ProjectConfig' },
        versions: [
          {
            name: 'v1alpha1',
            schema: {
              openAPIV3Schema: {
                properties: {
                  spec: {
                    properties: {
                      promotionPolicies: {
                        items: {
                          properties: {
                            autoPromotionEnabled: {
                              type: 'boolean',
                              description: semanticDescription('ProjectConfig', 'autoPromotionEnabled'),
                            },
                            stageSelector: { properties: { name: { type: 'string' } } },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        ],
      },
    },
    semanticsStageCrd,
  ];

  const semanticsChecker = new Checker();
  const semanticsReport = checkConformance(semanticsChecker, [], semanticsCrds).semantics;
  const expectedSemanticKeys = CRD_SEMANTICS.map(semanticId).sort();
  const semanticKeys = Object.keys(semanticsReport).sort();
  if (canonical(semanticKeys) !== canonical(expectedSemanticKeys)) {
    throw new Error(
      `semantics self-test emitted ${semanticKeys.length} of ${expectedSemanticKeys.length} distinct claim records: ${canonical(semanticKeys)}`,
    );
  }
  const absent = semanticKeys.filter(key => at(semanticsReport[key], 'present') !== true);
  if (absent.length !== 0) throw new Error(`semantics self-test claims not present: ${canonical(absent)}`);
  const semanticCheckNames = semanticsChecker.checks
    .filter(check => check.name.startsWith('kargo.crd.semantics.') && check.name !== 'kargo.crd.semantics.count')
    .map(check => check.name)
    .sort();
  if (canonical(semanticCheckNames) !== canonical(expectedSemanticKeys.map(key => `kargo.crd.semantics.${key}`))) {
    throw new Error(`semantics self-test check names are not stable and unique: ${canonical(semanticCheckNames)}`);
  }
  if (!semanticsChecker.ok) {
    throw new Error(
      `semantics self-test checker failed: ${canonical(semanticsChecker.checks.filter(check => !check.ok))}`,
    );
  }

  console.log(
    JSON.stringify({
      status: 'pass',
      check: 'kargo-v1-field-contract',
      baselineChecks: (baseline.checks as unknown as Check[]).length,
      persistedBaselineChecks: (persistedBaseline.checks as unknown as Check[]).length,
      rejectedMutations: executedMutations.length,
      conformanceRejections: pruned.length + badEnum.length,
      semanticClaims: semanticKeys.length,
      preserveUnknownFieldsBlindSpots: preserveBlindSpots,
    }),
  );
  process.exit(0);
}

const objects = asObjects(await readJson(config.objectsPath));
const crds = config.crdsPath ? asObjects(await readJson(config.crdsPath)) : null;
const result = evaluate(
  objects,
  crds,
  config.source,
  {
    image: config.imageRepo,
    chart: config.chartRepo,
    fleet: config.fleetRepo,
  },
  config.kargoWebhookPersisted,
);
await Bun.write(config.outPath, `${JSON.stringify(result, null, 2)}\n`);
if (result.ok !== true) {
  console.error(`kargo contract failed for ${config.source}:`);
  for (const check of result.failed as unknown as Check[]) console.error(`  - ${check.name}: ${check.detail}`);
  process.exit(1);
}
console.log(`kargo contract passed for ${config.source} (${(result.checks as unknown as Check[]).length} checks)`);
