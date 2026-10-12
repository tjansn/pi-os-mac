// MOCK ONLY: imports canned fixture data and prints deterministic policy decisions.
import { replay } from './gate.mjs';
import { scenarios } from './fixtures.mjs';

const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--help') {
  console.log('Mock-only replay, no models or OS effects.');
  console.log('Usage: node prototypes/ambient-gate/replay.mjs [--list | --scenario NAME]');
} else if (args.length === 1 && args[0] === '--list') {
  console.log(scenarios.map((scenario) => scenario.name).join('\n'));
} else {
  const name = args.length === 2 && args[0] === '--scenario' ? args[1] : null;
  const selected = args.length === 0 ? scenarios : scenarios.filter((scenario) => scenario.name === name);
  if (selected.length === 0) {
    console.error('Unknown scenario or arguments. Use --help or --list.');
    process.exitCode = 2;
  } else {
    for (const scenario of selected) {
      console.log(JSON.stringify({ scenario: scenario.name,
        evidence: 'synthetic fixture replay, NOT model accuracy', ...replay(scenario.events) }));
    }
  }
}
