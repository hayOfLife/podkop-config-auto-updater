import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import vm from 'node:vm';

let checked = 0;
function walk(directory) {
	for (const entry of readdirSync(directory, { withFileTypes: true })) {
		const path = join(directory, entry.name);
		if (entry.isDirectory()) walk(path);
		else if (path.endsWith('.json')) { JSON.parse(readFileSync(path, 'utf8')); checked++; }
		else if (path.endsWith('.js')) { new vm.Script('(function() {\n' + readFileSync(path, 'utf8') + '\n})'); checked++; }
	}
}
walk('package');
console.log(`Source syntax: ${checked} files passed`);
