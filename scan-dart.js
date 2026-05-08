const fs = require('fs');
const path = require('path');

const ROOT = 'C:\\MachinetranslateAI';
const SKIP = ['node_modules', '.git', 'context-mode', '.opencode', 'dist', 'build', '__pycache__', '.dart_tool', 'android', 'ios', 'linux', 'macos', 'windows', 'web'];

function walk(dir, depth = 0) {
  if (depth > 5) return [];
  const results = [];
  try {
    const items = fs.readdirSync(dir);
    for (const item of items) {
      if (SKIP.includes(item)) continue;
      const full = path.join(dir, item);
      const stat = fs.statSync(full);
      if (stat.isDirectory()) {
        results.push({ type: 'dir', path: path.relative(ROOT, full), depth });
        results.push(...walk(full, depth + 1));
      } else {
        results.push({ type: 'file', path: path.relative(ROOT, full), size: stat.size, depth });
      }
    }
  } catch (e) {}
  return results;
}

function analyzeDartFile(filePath) {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');
    const classes = [];
    const functions = [];
    const widgets = [];
    const imports = [];
    
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.match(/^class\s+(\w+)/)) {
        classes.push(RegExp.$1);
      }
      if (trimmed.match(/^(void|int|String|bool|double|List|Map|Future|Stream|Widget)\s+(\w+)\s*\(/)) {
        functions.push(RegExp.$2);
      }
      if (trimmed.match(/^import\s+['"](.+)['"]/)) {
        imports.push(RegExp.$1);
      }
      if (trimmed.match(/^class\s+(\w+)\s+extends\s+State(less|ful)Widget/)) {
        widgets.push(RegExp.$1);
      }
    }
    
    return { lines: lines.length, classes, functions, widgets, imports };
  } catch (e) {
    return null;
  }
}

console.log('=== DART PROJECT ANALYSIS ===');
const tree = walk(ROOT);
const dirs = tree.filter(i => i.type === 'dir').length;
const files = tree.filter(i => i.type === 'file');
const dartFiles = files.filter(f => f.path.endsWith('.dart'));

console.log(`Total files: ${files.length}`);
console.log(`Dart files: ${dartFiles.length}`);

let totalLines = 0;
let allClasses = [];
let allWidgets = [];
let allFunctions = [];

for (const file of dartFiles) {
  const analysis = analyzeDartFile(path.join(ROOT, file.path));
  if (analysis) {
    totalLines += analysis.lines;
    allClasses.push(...analysis.classes.map(c => `${file.path}::${c}`));
    allWidgets.push(...analysis.widgets.map(w => `${file.path}::${w}`));
    allFunctions.push(...analysis.functions.map(f => `${file.path}::${f}`));
  }
}

console.log(`Total lines: ${totalLines}`);
console.log(`Classes: ${allClasses.length}`);
console.log(`Widgets: ${allWidgets.length}`);
console.log(`Functions: ${allFunctions.length}`);

console.log('\n=== WIDGETS ===');
allWidgets.forEach(w => console.log(w));

console.log('\n=== CLASSES ===');
allClasses.forEach(c => console.log(c));

console.log('\n=== TOP DART FILES ===');
dartFiles.sort((a, b) => b.size - a.size);
dartFiles.slice(0, 15).forEach(f => {
  console.log(`${(f.size/1024).toFixed(1)}KB - ${f.path}`);
});
