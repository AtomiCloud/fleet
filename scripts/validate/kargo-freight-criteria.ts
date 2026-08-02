type Image = { RepoURL: string; Tag: string };
type Chart = { RepoURL: string; Version: string };
type Fixture = { images: Image[]; charts: Chart[] };

const [expression, fixturePath] = process.argv.slice(2);

if (!expression || !fixturePath) {
  console.error("usage: bun scripts/validate/kargo-freight-criteria.ts '<expression>' <fixture.json>");
  process.exit(2);
}

const match = expression.match(/^imageFrom\('([^']+)'\)\.Tag == chartFrom\('([^']+)'\)\.Version$/);

if (!match) {
  console.error(`unsupported Kargo freight criterion: ${expression}`);
  process.exit(2);
}

const fixture = (await Bun.file(fixturePath).json()) as Fixture;
const image = fixture.images.find(({ RepoURL }) => RepoURL === match[1]);
const chart = fixture.charts.find(({ RepoURL }) => RepoURL === match[2]);

if (!image || !chart) {
  console.error('fixture is missing an artifact referenced by the Kargo criterion');
  process.exit(2);
}

process.exit(image.Tag === chart.Version ? 0 : 1);
